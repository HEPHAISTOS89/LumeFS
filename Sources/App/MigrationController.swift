import Foundation
import Observation

/// Drives one placement plan at a time: choose a source and a destination,
/// dry-run, confirm in the view, copy with progress, and journal every step.
/// Nothing here deletes, moves or overwrites; the original is always retained.
@MainActor
@Observable
final class MigrationController {
    private(set) var sourceURL: URL?
    private(set) var destinationFolder: URL?
    private(set) var destinationVolumeID: String?
    private(set) var plan: MigrationPlan?
    private(set) var planError: String?
    private(set) var isPlanning = false
    private(set) var isCopying = false
    private(set) var progress: MigrationProgress?
    private(set) var result: MigrationResult?
    private(set) var journal: MigrationJournal
    private(set) var journalError: String?

    /// Receives `(display path, description, date)` for the Activity feed.
    @ObservationIgnored
    var onActivity: ((String, String, Date) -> Void)?

    @ObservationIgnored
    private let planner = MigrationPlanner()
    @ObservationIgnored
    private let executor = MigrationExecutor()
    @ObservationIgnored
    private let persistence: MigrationJournalPersistence?
    @ObservationIgnored
    private var planningTask: Task<Result<MigrationPlan, Error>, Never>?
    @ObservationIgnored
    private var planningGeneration = 0
    @ObservationIgnored
    private var copyTask: Task<Void, Never>?

    init(persistence: MigrationJournalPersistence? = nil) {
        self.persistence = persistence
        self.journal = persistence?.load() ?? MigrationJournal()
    }

    var journalFileURL: URL? { persistence?.fileURL }

    var canPlan: Bool {
        sourceURL != nil && (destinationFolder != nil || destinationVolumeID != nil) && !isPlanning && !isCopying
    }

    /// Any change to the pair invalidates the plan and the previous result.
    func setSource(_ url: URL?) {
        guard !isCopying else { return }
        sourceURL = url
        invalidatePlan()
    }

    func selectDestinationVolume(_ id: String?) {
        guard !isCopying else { return }
        destinationVolumeID = id
        if id != nil { destinationFolder = nil }
        invalidatePlan()
    }

    func selectDestinationFolder(_ url: URL?) {
        guard !isCopying else { return }
        destinationFolder = url
        if url != nil { destinationVolumeID = nil }
        invalidatePlan()
    }

    func destinationRoot(volumes: [VolumeSnapshot]) -> URL? {
        if let destinationFolder { return destinationFolder }
        return destinationVolume(volumes: volumes).map { URL(fileURLWithPath: $0.mountPoint, isDirectory: true) }
    }

    /// The chosen volume, or the mounted volume that contains the chosen folder.
    func destinationVolume(volumes: [VolumeSnapshot]) -> VolumeSnapshot? {
        if let destinationVolumeID {
            return volumes.first { $0.id == destinationVolumeID }
        }
        guard let destinationFolder else { return nil }
        let path = destinationFolder.standardizedFileURL.path
        return volumes
            .filter { $0.mountPoint == path || MigrationPlanner.path(path, isInside: $0.mountPoint) }
            .max { $0.mountPoint.count < $1.mountPoint.count }
    }

    /// Dry run: walks the source off the main actor and validates the pair.
    func makePlan(volumes: [VolumeSnapshot], at date: Date = Date()) {
        guard let sourceURL, let root = destinationRoot(volumes: volumes), !isPlanning, !isCopying else { return }
        let volume = destinationVolume(volumes: volumes)
        let planner = planner
        plan = nil
        planError = nil
        result = nil
        isPlanning = true
        planningGeneration += 1
        let generation = planningGeneration

        // Detached so the tree walk never runs on the main actor; the handle is
        // kept so "Cancel" reaches `Task.checkCancellation()` inside the walk.
        let work = Task.detached(priority: .userInitiated) { () -> Result<MigrationPlan, Error> in
            do {
                let inventory = try planner.inventory(of: sourceURL)
                return .success(try planner.plan(
                    source: sourceURL,
                    destinationRoot: root,
                    destinationVolume: volume,
                    inventory: inventory,
                    at: date
                ))
            } catch {
                return .failure(error)
            }
        }
        planningTask = work

        Task { [weak self] in
            let outcome = await work.value
            guard let self, self.planningGeneration == generation else { return }
            self.isPlanning = false
            self.planningTask = nil
            switch outcome {
            case let .success(plan):
                self.plan = plan
                self.record(.planned, plan: plan, at: date, detail: plan.fits ? "Fits with a 20% margin." : "Does not fit.")
            case .failure(is CancellationError):
                break
            case let .failure(error):
                self.planError = error.localizedDescription
            }
        }
    }

    func cancelPlanning() {
        planningTask?.cancel()
        planningTask = nil
        planningGeneration += 1
        isPlanning = false
    }

    /// Starts the copy for the current plan. The view is responsible for the
    /// explicit confirmation before calling this.
    func startCopy(at date: Date = Date()) {
        guard let plan, !isCopying, !isPlanning else { return }
        isCopying = true
        result = nil
        progress = MigrationProgress(totalFiles: plan.inventory.fileCount, totalBytes: plan.inventory.totalBytes)
        record(.started, plan: plan, at: date, detail: nil)
        onActivity?(plan.destinationLabel, "Started copying \(plan.sourceLabel) to \(plan.destinationVolumeName): \(plan.inventory.fileCount) file(s), \(MetricFormatter.bytes(plan.inventory.totalBytes)). Original retained.", date)

        // Strong capture on purpose: the controller lives for the app's lifetime
        // and a running copy must be able to report its outcome.
        let executor = executor
        let controller = self
        copyTask = Task {
            let result = await executor.run(plan) { update in
                Task { @MainActor in
                    controller.applyProgress(update)
                }
            }
            controller.finish(result, plan: plan)
        }
    }

    private func applyProgress(_ update: MigrationProgress) {
        guard isCopying else { return }
        progress = update
    }

    func cancelCopy() {
        copyTask?.cancel()
    }

    func discardPlan() {
        guard !isCopying else { return }
        invalidatePlan()
    }

    func dismissResult() {
        result = nil
    }

    private func finish(_ result: MigrationResult, plan: MigrationPlan) {
        isCopying = false
        copyTask = nil
        progress = nil
        self.result = result
        self.plan = nil

        let kind: MigrationJournalEntry.Kind
        let detail: String
        switch result.outcome {
        case .completed:
            kind = .completed
            detail = "\(result.verifiedFiles) file(s) size-verified in \(Int(result.elapsedSeconds.rounded())) s."
        case .cancelled:
            kind = .cancelled
            detail = "Cancelled after \(result.copiedFiles) of \(plan.inventory.fileCount) file(s)." + (result.incompleteItem.map { " Incomplete: \($0)." } ?? "")
        case .failed:
            kind = .failed
            detail = (result.failureDescription ?? "Unknown error") + (result.incompleteItem.map { " Incomplete: \($0)." } ?? "")
        }
        record(kind, plan: plan, at: result.finishedAt, detail: detail, copiedFiles: result.copiedFiles, copiedBytes: result.copiedBytes)
        onActivity?(plan.destinationLabel, "\(kind.rawValue.capitalized) copy of \(plan.sourceLabel): \(detail) Original retained.", result.finishedAt)
    }

    private func invalidatePlan() {
        planningTask?.cancel()
        planningTask = nil
        planningGeneration += 1
        isPlanning = false
        plan = nil
        planError = nil
        result = nil
    }

    private func record(
        _ kind: MigrationJournalEntry.Kind,
        plan: MigrationPlan,
        at date: Date,
        detail: String?,
        copiedFiles: Int? = nil,
        copiedBytes: Int64? = nil
    ) {
        journal.append(MigrationJournalEntry(
            id: UUID(),
            planID: plan.id,
            kind: kind,
            timestamp: date,
            sourcePath: plan.sourceURL.path,
            destinationPath: plan.destinationURL.path,
            fileCount: copiedFiles ?? plan.inventory.fileCount,
            byteCount: copiedBytes ?? plan.inventory.totalBytes,
            detail: detail
        ))
        guard let persistence else { return }
        do {
            try persistence.save(journal)
            journalError = nil
        } catch {
            journalError = "Journal could not be saved: \(error.localizedDescription)"
        }
    }
}
