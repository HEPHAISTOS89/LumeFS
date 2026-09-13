import Darwin
import Foundation

/// Result of walking the source tree without touching anything: what a copy
/// would move. Labeled `ESTIMATE` because sizes are logical file sizes, not the
/// blocks the destination will allocate.
struct MigrationInventory: Codable, Hashable, Sendable {
    var fileCount = 0
    var directoryCount = 0
    var symlinkCount = 0
    var unreadableCount = 0
    var totalBytes: Int64 = 0
    var largestFileBytes: Int64 = 0
}

enum MigrationPlanError: LocalizedError, Equatable {
    case sourceMissing
    case sourceNotReadable
    case destinationInsideSource
    case sourceInsideDestination
    case destinationExists
    case destinationParentMissing
    case destinationReadOnly
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case emptySource

    var errorDescription: String? {
        switch self {
        case .sourceMissing: "The source no longer exists."
        case .sourceNotReadable: "The source cannot be read."
        case .destinationInsideSource: "The destination is inside the source; the copy would never end."
        case .sourceInsideDestination: "The source is inside the destination."
        case .destinationExists: "Something already exists at the destination. LumeFS never merges into or overwrites existing data."
        case .destinationParentMissing: "The destination volume or folder is not mounted."
        case .destinationReadOnly: "The destination is read-only."
        case let .insufficientSpace(required, available): "The destination needs \(MetricFormatter.bytes(required)) free (data plus a 20% margin); \(MetricFormatter.bytes(available)) is available."
        case .emptySource: "The source contains no files to copy."
        }
    }
}

/// A dry run: source, destination, inventory and the capacity verdict. Creating
/// a plan changes nothing on disk.
struct MigrationPlan: Identifiable, Codable, Hashable, Sendable {
    /// Same margin as the workload readiness estimate: logical bytes understate
    /// allocated blocks, and a destination should not be filled to the last byte.
    static let safetyMargin = 0.20

    let id: UUID
    let sourceURL: URL
    let destinationURL: URL
    let destinationVolumeName: String
    let destinationMountPoint: String
    let sameVolume: Bool
    let inventory: MigrationInventory
    let destinationAvailableBytes: Int64
    let requiredBytes: Int64
    let createdAt: Date
    let provenance: DataProvenance

    var fits: Bool { destinationAvailableBytes >= requiredBytes }
    var sourceLabel: String { sourceURL.lastPathComponent }
    var destinationLabel: String { destinationURL.lastPathComponent }

    static func requiredBytes(for totalBytes: Int64) -> Int64 {
        let margin = Int64(Double(totalBytes) * safetyMargin)
        let sum = totalBytes.addingReportingOverflow(margin)
        return sum.overflow ? Int64.max : sum.partialValue
    }
}

/// Builds plans. Only reads metadata; never creates, moves or deletes.
struct MigrationPlanner: Sendable {
    /// Cancellation is checked every `checkInterval` entries.
    static let checkInterval = 256

    private var fileManager: FileManager { .default }

    func inventory(of sourceURL: URL) throws -> MigrationInventory {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw MigrationPlanError.sourceMissing
        }
        guard fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw MigrationPlanError.sourceNotReadable
        }

        var inventory = MigrationInventory()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]

        if !isDirectory.boolValue {
            try record(sourceURL, keys: keys, into: &inventory)
            return inventory
        }

        // The enumerator does not descend into symbolic links, so a link to a
        // parent folder cannot loop and counts once as a symlink.
        var unreadable = 0
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                unreadable += 1
                return true
            }
        ) else {
            throw MigrationPlanError.sourceNotReadable
        }

        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited % Self.checkInterval == 0 {
                try Task.checkCancellation()
            }
            do {
                try record(url, keys: keys, into: &inventory)
            } catch {
                unreadable += 1
            }
        }
        inventory.unreadableCount += unreadable
        return inventory
    }

    private func record(_ url: URL, keys: Set<URLResourceKey>, into inventory: inout MigrationInventory) throws {
        let values = try url.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true {
            inventory.symlinkCount += 1
        } else if values.isDirectory == true {
            inventory.directoryCount += 1
        } else if values.isRegularFile == true {
            inventory.fileCount += 1
            let size = Int64(values.fileSize ?? 0)
            inventory.totalBytes = inventory.totalBytes.addingReportingOverflow(size).partialValue
            inventory.largestFileBytes = max(inventory.largestFileBytes, size)
        } else {
            inventory.unreadableCount += 1
        }
    }

    /// Validates the pair and produces the plan. `destinationRoot` is the folder
    /// the copy will be created *inside*; the copy itself is `<root>/<source name>`.
    /// Available space is `statfs`-style free space; purgeable space is not
    /// counted, which keeps the verdict conservative.
    func plan(
        source sourceURL: URL,
        destinationRoot: URL,
        destinationVolume: VolumeSnapshot?,
        inventory: MigrationInventory,
        at date: Date = Date()
    ) throws -> MigrationPlan {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let root = destinationRoot.standardizedFileURL.resolvingSymlinksInPath()
        let destination = root.appendingPathComponent(source.lastPathComponent, isDirectory: true)

        guard inventory.fileCount > 0 else { throw MigrationPlanError.emptySource }
        // Destination equal to the source falls through to the existence check.
        if Self.path(destination.path, isInside: source.path) {
            throw MigrationPlanError.destinationInsideSource
        }
        if Self.path(source.path, isInside: destination.path) {
            throw MigrationPlanError.sourceInsideDestination
        }

        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue else {
            throw MigrationPlanError.destinationParentMissing
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw MigrationPlanError.destinationExists
        }
        if let destinationVolume, destinationVolume.isReadOnly {
            throw MigrationPlanError.destinationReadOnly
        }
        guard fileManager.isWritableFile(atPath: root.path) else {
            throw MigrationPlanError.destinationReadOnly
        }

        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeURLKey])
        let available = values?.volumeAvailableCapacity.map(Int64.init)
            ?? destinationVolume?.availableBytes
            ?? 0
        let required = MigrationPlan.requiredBytes(for: inventory.totalBytes)
        guard available >= required else {
            throw MigrationPlanError.insufficientSpace(requiredBytes: required, availableBytes: available)
        }

        let sourceVolume = (try? source.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path
        let destinationVolumePath = values?.volume?.path
        let sameVolume = sourceVolume != nil && sourceVolume == destinationVolumePath

        return MigrationPlan(
            id: UUID(),
            sourceURL: source,
            destinationURL: destination,
            destinationVolumeName: destinationVolume?.name ?? (destinationVolumePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? root.lastPathComponent),
            destinationMountPoint: destinationVolume?.mountPoint ?? destinationVolumePath ?? root.path,
            sameVolume: sameVolume,
            inventory: inventory,
            destinationAvailableBytes: available,
            requiredBytes: required,
            createdAt: date,
            provenance: .estimate
        )
    }

    static func path(_ candidate: String, isInside container: String) -> Bool {
        let prefix = container.hasSuffix("/") ? container : container + "/"
        return candidate.hasPrefix(prefix)
    }
}

struct MigrationProgress: Equatable, Sendable {
    var copiedFiles = 0
    var copiedBytes: Int64 = 0
    var totalFiles: Int
    var totalBytes: Int64
    var currentItem: String?

    var fraction: Double {
        guard totalBytes > 0 else { return totalFiles > 0 ? Double(copiedFiles) / Double(totalFiles) : 0 }
        return min(1, Double(copiedBytes) / Double(totalBytes))
    }
}

enum MigrationOutcome: String, Codable, Sendable {
    case completed
    case cancelled
    case failed
}

struct MigrationResult: Codable, Hashable, Sendable {
    let planID: UUID
    let outcome: MigrationOutcome
    let copiedFiles: Int
    let copiedBytes: Int64
    let verifiedFiles: Int
    let startedAt: Date
    let finishedAt: Date
    let failureDescription: String?
    /// Relative path of a file whose copy was interrupted, if any. It stays in
    /// place for the user to inspect; LumeFS does not remove it.
    let incompleteItem: String?
    /// Always true: the original is left in place on every outcome.
    let originalRetained: Bool
    /// Where a partial or complete copy sits; the user decides what to do with it.
    let destinationURL: URL

    var elapsedSeconds: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

enum MigrationCopyError: LocalizedError {
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case copyFailed(path: String, message: String)
    case destinationAppeared

    var errorDescription: String? {
        switch self {
        case let .sizeMismatch(path, expected, actual):
            "\(path) copied \(MetricFormatter.bytes(actual)) of \(MetricFormatter.bytes(expected)); the copy stopped."
        case let .copyFailed(path, message):
            "\(path): \(message)"
        case .destinationAppeared:
            "The destination appeared after planning; LumeFS never overwrites."
        }
    }
}

/// Bridges `copyfile(3)` status callbacks to Swift. Kept unretained for the
/// duration of one `copyfile` call only.
private final class CopyProgressContext {
    let base: MigrationProgress
    let progress: @Sendable (MigrationProgress) -> Void
    var lastReport = Date.distantPast

    init(base: MigrationProgress, progress: @escaping @Sendable (MigrationProgress) -> Void) {
        self.base = base
        self.progress = progress
    }

    func report(copiedBytes: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= MigrationExecutor.progressInterval else { return }
        lastReport = now
        var state = base
        state.copiedBytes = base.copiedBytes + copiedBytes
        progress(state)
    }
}

/// `copyfile` invokes this on the copying thread after each block. Returning
/// `COPYFILE_QUIT` makes `copyfile` stop with `ECANCELED`, which is how a
/// cancellation takes effect inside a large file instead of after it.
private let copyStatusCallback: copyfile_callback_t = { what, stage, state, _, _, context in
    if Task.isCancelled { return COPYFILE_QUIT }
    guard let context, what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS else {
        return COPYFILE_CONTINUE
    }
    var copied: off_t = 0
    if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
        Unmanaged<CopyProgressContext>.fromOpaque(context).takeUnretainedValue().report(copiedBytes: Int64(copied))
    }
    return COPYFILE_CONTINUE
}

/// Copies a plan. Additive only: it creates directories and files under the
/// destination and never removes, moves or modifies anything at the source or
/// the destination, including on cancellation or error. Regular files go
/// through `copyfile(3)` with `COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_CLONE`,
/// so ownership, modes, dates, extended attributes and ACLs are preserved and a
/// same-volume APFS copy becomes a clone. Directories are recreated with
/// default attributes.
actor MigrationExecutor {
    /// Progress callbacks inside one file are throttled to this interval.
    static let progressInterval: TimeInterval = 0.2

    private let fileManager = FileManager.default

    func run(
        _ plan: MigrationPlan,
        progress: @escaping @Sendable (MigrationProgress) -> Void
    ) async -> MigrationResult {
        let startedAt = Date()
        var state = MigrationProgress(totalFiles: plan.inventory.fileCount, totalBytes: plan.inventory.totalBytes)
        var verified = 0
        var incomplete: String?

        func result(_ outcome: MigrationOutcome, failure: String? = nil) -> MigrationResult {
            MigrationResult(
                planID: plan.id,
                outcome: outcome,
                copiedFiles: state.copiedFiles,
                copiedBytes: state.copiedBytes,
                verifiedFiles: verified,
                startedAt: startedAt,
                finishedAt: Date(),
                failureDescription: failure,
                incompleteItem: incomplete,
                originalRetained: true,
                destinationURL: plan.destinationURL
            )
        }

        do {
            guard !fileManager.fileExists(atPath: plan.destinationURL.path) else {
                throw MigrationCopyError.destinationAppeared
            }
            try Task.checkCancellation()

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: plan.sourceURL.path, isDirectory: &isDirectory) else {
                throw MigrationPlanError.sourceMissing
            }

            if !isDirectory.boolValue {
                try copyFile(
                    from: plan.sourceURL,
                    to: plan.destinationURL,
                    relativePath: plan.sourceURL.lastPathComponent,
                    state: &state,
                    verified: &verified,
                    incomplete: &incomplete,
                    progress: progress
                )
                state.currentItem = nil
                progress(state)
                return result(.completed)
            }

            try fileManager.createDirectory(at: plan.destinationURL, withIntermediateDirectories: false)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
            guard let enumerator = fileManager.enumerator(at: plan.sourceURL, includingPropertiesForKeys: keys, options: []) else {
                throw MigrationPlanError.sourceNotReadable
            }

            let sourcePrefix = plan.sourceURL.path.hasSuffix("/") ? plan.sourceURL.path : plan.sourceURL.path + "/"
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                let relative = String(url.standardizedFileURL.path.dropFirst(sourcePrefix.count))
                let target = plan.destinationURL.appendingPathComponent(relative)
                let values = try url.resourceValues(forKeys: Set(keys))

                if values.isSymbolicLink == true {
                    // Recreate the link with its literal target; never follow it.
                    let linkTarget = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                    try fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
                } else if values.isDirectory == true {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } else if values.isRegularFile == true {
                    try copyFile(
                        from: url,
                        to: target,
                        relativePath: relative,
                        state: &state,
                        verified: &verified,
                        incomplete: &incomplete,
                        progress: progress
                    )
                }
            }
            state.currentItem = nil
            progress(state)
            return result(.completed)
        } catch is CancellationError {
            return result(.cancelled)
        } catch {
            return result(.failed, failure: error.localizedDescription)
        }
    }

    private func copyFile(
        from source: URL,
        to target: URL,
        relativePath: String,
        state: inout MigrationProgress,
        verified: inout Int,
        incomplete: inout String?,
        progress: @escaping @Sendable (MigrationProgress) -> Void
    ) throws {
        state.currentItem = relativePath
        progress(state)

        let expected = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let context = CopyProgressContext(base: state, progress: progress)
        let copyState = copyfile_state_alloc()
        defer { copyfile_state_free(copyState) }
        copyfile_state_set(copyState, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyStatusCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(copyState, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

        incomplete = relativePath
        // COPYFILE_ALL spelled out (ACL, stat, xattr, data) plus exclusive create,
        // no symlink following and best-effort clone.
        let flags = copyfile_flags_t(
            COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA
                | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC | COPYFILE_CLONE
        )
        let status = withExtendedLifetime(context) {
            copyfile(source.path, target.path, copyState, flags)
        }
        if status != 0 {
            let code = errno
            if code == ECANCELED || Task.isCancelled { throw CancellationError() }
            throw MigrationCopyError.copyFailed(path: relativePath, message: String(cString: strerror(code)))
        }

        let actual = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1)
        guard actual == expected else {
            throw MigrationCopyError.sizeMismatch(path: relativePath, expected: expected, actual: max(0, actual))
        }
        incomplete = nil
        verified += 1
        state.copiedFiles += 1
        state.copiedBytes += expected
        progress(state)
    }
}

/// One line per event, newest last. Bounded so the file cannot grow forever;
/// nothing in it is ever rewritten except by trimming the oldest lines.
struct MigrationJournalEntry: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case planned
        case started
        case completed
        case cancelled
        case failed
    }

    let id: UUID
    let planID: UUID
    let kind: Kind
    let timestamp: Date
    let sourcePath: String
    let destinationPath: String
    let fileCount: Int
    let byteCount: Int64
    let detail: String?
}

struct MigrationJournal: Codable, Equatable, Sendable {
    static let maximumEntries = 200
    static let schemaVersion = 1

    var schemaVersion = MigrationJournal.schemaVersion
    private(set) var entries: [MigrationJournalEntry] = []

    init() {}

    mutating func append(_ entry: MigrationJournalEntry) {
        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
    }

    var newestFirst: [MigrationJournalEntry] { entries.reversed() }
}

struct MigrationJournalPersistence: Sendable {
    let fileURL: URL

    /// `~/Library/Application Support/LumeFS/migration-journal.json`, next to the alert history.
    static func applicationSupport() -> MigrationJournalPersistence? {
        (try? AlertHistoryPersistence.defaultURL()).map {
            MigrationJournalPersistence(fileURL: $0.deletingLastPathComponent().appendingPathComponent("migration-journal.json"))
        }
    }

    /// An unreadable or foreign-schema file is set aside as `.unreadable.json`
    /// (LumeFS's own file only) and an empty journal is returned.
    func load() -> MigrationJournal {
        guard let data = try? Data(contentsOf: fileURL) else { return MigrationJournal() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let journal = try? decoder.decode(MigrationJournal.self, from: data), journal.schemaVersion == MigrationJournal.schemaVersion {
            return journal
        }
        let damaged = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
        try? FileManager.default.removeItem(at: damaged)
        try? FileManager.default.moveItem(at: fileURL, to: damaged)
        return MigrationJournal()
    }

    func save(_ journal: MigrationJournal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(journal).write(to: fileURL, options: [.atomic])
    }
}
