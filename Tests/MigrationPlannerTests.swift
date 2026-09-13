import XCTest
@testable import LumeFS

/// Exercises the placement plan and the additive copy against a temporary tree.
/// Every test asserts that the source is byte-for-byte intact afterwards.
final class MigrationPlannerTests: XCTestCase {
    private var workspace: URL!
    private var source: URL!
    private var destinationRoot: URL!
    private let planner = MigrationPlanner()

    private let filePayloads: [String: Int] = [
        "model.bin": 3 * 1_048_576,
        "nested/shard.bin": 256 * 1_024,
        "nested/deeper/config.json": 512
    ]

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeFSMigration-\(UUID().uuidString)", isDirectory: true)
        source = workspace.appendingPathComponent("dataset", isDirectory: true)
        destinationRoot = workspace.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        for (path, size) in filePayloads {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload(size, seed: UInt8(truncatingIfNeeded: path.utf8.count)).write(to: url)
        }
        // A valid relative link and a dangling one: a copy must preserve both literally.
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("latest").path, withDestinationPath: "model.bin")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("previous").path, withDestinationPath: "../gone/older.bin")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: Inventory and plan

    func testInventoryCountsFilesDirectoriesAndSymlinksWithoutFollowingLinks() throws {
        let inventory = try planner.inventory(of: source)
        XCTAssertEqual(inventory.fileCount, 3)
        XCTAssertEqual(inventory.directoryCount, 2)
        XCTAssertEqual(inventory.symlinkCount, 2)
        XCTAssertEqual(inventory.unreadableCount, 0)
        XCTAssertEqual(inventory.totalBytes, Int64(filePayloads.values.reduce(0, +)))
        XCTAssertEqual(inventory.largestFileBytes, 3 * 1_048_576)
    }

    func testInventoryOfASingleFile() throws {
        let inventory = try planner.inventory(of: source.appendingPathComponent("model.bin"))
        XCTAssertEqual(inventory.fileCount, 1)
        XCTAssertEqual(inventory.directoryCount, 0)
        XCTAssertEqual(inventory.totalBytes, 3 * 1_048_576)
    }

    func testRequiredBytesAddsTheTwentyPercentMargin() {
        XCTAssertEqual(MigrationPlan.safetyMargin, 0.20)
        XCTAssertEqual(MigrationPlan.requiredBytes(for: 1_000), 1_200)
        XCTAssertEqual(MigrationPlan.requiredBytes(for: 0), 0)
        XCTAssertEqual(MigrationPlan.requiredBytes(for: Int64.max), Int64.max)
    }

    func testPlanDescribesTheCopyAndChangesNothing() throws {
        let inventory = try planner.inventory(of: source)
        let plan = try planner.plan(source: source, destinationRoot: destinationRoot, destinationVolume: nil, inventory: inventory)

        XCTAssertEqual(plan.destinationURL.lastPathComponent, "dataset")
        XCTAssertEqual(plan.destinationURL.deletingLastPathComponent().resolvingSymlinksInPath().path, destinationRoot.resolvingSymlinksInPath().path)
        XCTAssertEqual(plan.requiredBytes, MigrationPlan.requiredBytes(for: inventory.totalBytes))
        XCTAssertTrue(plan.fits)
        XCTAssertTrue(plan.sameVolume, "the temporary directory keeps source and destination on one volume")
        XCTAssertEqual(plan.provenance, .estimate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destinationURL.path), "planning must not create the destination")
    }

    func testPlanRejectsUnsafePairs() throws {
        let inventory = try planner.inventory(of: source)

        XCTAssertThrowsError(try planner.plan(source: source, destinationRoot: source.appendingPathComponent("nested"), destinationVolume: nil, inventory: inventory)) {
            XCTAssertEqual($0 as? MigrationPlanError, .destinationInsideSource)
        }
        XCTAssertThrowsError(try planner.plan(source: source, destinationRoot: source.deletingLastPathComponent(), destinationVolume: nil, inventory: inventory)) {
            XCTAssertEqual($0 as? MigrationPlanError, .destinationExists, "the source itself sits at <parent>/dataset")
        }
        XCTAssertThrowsError(try planner.plan(source: source, destinationRoot: workspace.appendingPathComponent("missing"), destinationVolume: nil, inventory: inventory)) {
            XCTAssertEqual($0 as? MigrationPlanError, .destinationParentMissing)
        }
        XCTAssertThrowsError(try planner.plan(source: source, destinationRoot: destinationRoot, destinationVolume: nil, inventory: MigrationInventory())) {
            XCTAssertEqual($0 as? MigrationPlanError, .emptySource)
        }

        try FileManager.default.createDirectory(at: destinationRoot.appendingPathComponent("dataset"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try planner.plan(source: source, destinationRoot: destinationRoot, destinationVolume: nil, inventory: inventory)) {
            XCTAssertEqual($0 as? MigrationPlanError, .destinationExists)
        }
        try FileManager.default.removeItem(at: destinationRoot.appendingPathComponent("dataset"))

        var oversized = inventory
        oversized.totalBytes = Int64.max / 2
        XCTAssertThrowsError(try planner.plan(source: source, destinationRoot: destinationRoot, destinationVolume: nil, inventory: oversized)) { error in
            guard case let .insufficientSpace(required, available)? = error as? MigrationPlanError else {
                return XCTFail("expected insufficientSpace, got \(error)")
            }
            XCTAssertGreaterThan(required, available)
        }

        let readOnly = VolumeSnapshot(id: "ro", name: "Archive", mountPoint: destinationRoot.path, source: "disk9s1",
                                      fileSystem: .apfs, fileSystemName: "apfs", totalBytes: 1, availableBytes: 1,
                                      isReadOnly: true, isLocal: true, capturedAt: Date())
        XCTAssertThrowsError(try planner.plan(source: source, destinationRoot: destinationRoot, destinationVolume: readOnly, inventory: inventory)) {
            XCTAssertEqual($0 as? MigrationPlanError, .destinationReadOnly)
        }
    }

    func testPathContainmentIsComponentAware() {
        XCTAssertTrue(MigrationPlanner.path("/Volumes/Data/models", isInside: "/Volumes/Data"))
        XCTAssertTrue(MigrationPlanner.path("/Volumes/Data/models", isInside: "/Volumes/Data/"))
        XCTAssertFalse(MigrationPlanner.path("/Volumes/Data2", isInside: "/Volumes/Data"))
        XCTAssertFalse(MigrationPlanner.path("/Volumes/Data", isInside: "/Volumes/Data"))
    }

    // MARK: Copy

    func testCopyLeavesTheOriginalIntactAndVerifiesEveryFile() async throws {
        let inventory = try planner.inventory(of: source)
        let plan = try planner.plan(source: source, destinationRoot: destinationRoot, destinationVolume: nil, inventory: inventory)
        let before = try snapshotOfSource()

        let result = await MigrationExecutor().run(plan) { _ in }

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.copiedFiles, 3)
        XCTAssertEqual(result.verifiedFiles, 3)
        XCTAssertEqual(result.copiedBytes, inventory.totalBytes)
        XCTAssertNil(result.failureDescription)
        XCTAssertNil(result.incompleteItem)
        XCTAssertTrue(result.originalRetained)
        XCTAssertEqual(try snapshotOfSource(), before, "the source must be byte-for-byte unchanged")

        for path in filePayloads.keys {
            XCTAssertEqual(
                try Data(contentsOf: plan.destinationURL.appendingPathComponent(path)),
                try Data(contentsOf: source.appendingPathComponent(path)),
                "\(path) must be identical at the destination"
            )
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: plan.destinationURL.appendingPathComponent("latest").path),
            "model.bin",
            "symbolic links are copied as links, not followed"
        )
        XCTAssertEqual(
            try linkTarget(at: plan.destinationURL.appendingPathComponent("previous")),
            "../gone/older.bin",
            "dangling links are preserved literally"
        )
    }

    func testCancellationStopsBetweenFilesAndRetainsBothTrees() async throws {
        let inventory = try planner.inventory(of: source)
        let plan = try planner.plan(source: source, destinationRoot: destinationRoot, destinationVolume: nil, inventory: inventory)
        let before = try snapshotOfSource()
        let executor = MigrationExecutor()

        // The progress callback runs inside the copying task, so cancelling the
        // current task after the first verified file is deterministic.
        let result = await Task {
            await executor.run(plan) { update in
                if update.copiedFiles == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }.value

        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.copiedFiles, 1)
        XCTAssertLessThan(result.copiedBytes, inventory.totalBytes)
        XCTAssertTrue(result.originalRetained)
        XCTAssertEqual(try snapshotOfSource(), before, "cancellation must leave the source untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destinationURL.path), "the partial copy is left for the user to inspect")
    }

    func testCopyRefusesADestinationThatAppearedAfterPlanning() async throws {
        let inventory = try planner.inventory(of: source)
        let plan = try planner.plan(source: source, destinationRoot: destinationRoot, destinationVolume: nil, inventory: inventory)
        try FileManager.default.createDirectory(at: plan.destinationURL, withIntermediateDirectories: false)
        let marker = plan.destinationURL.appendingPathComponent("existing.txt")
        try Data("keep me".utf8).write(to: marker)
        let before = try snapshotOfSource()

        let result = await MigrationExecutor().run(plan) { _ in }

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.copiedFiles, 0)
        XCTAssertEqual(result.failureDescription, MigrationCopyError.destinationAppeared.errorDescription)
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep me".utf8), "existing data is never overwritten")
        XCTAssertEqual(try snapshotOfSource(), before)
    }

    func testProgressFractionUsesBytesWhenKnown() {
        var progress = MigrationProgress(totalFiles: 4, totalBytes: 1_000)
        XCTAssertEqual(progress.fraction, 0)
        progress.copiedBytes = 250
        XCTAssertEqual(progress.fraction, 0.25)
        progress.copiedBytes = 5_000
        XCTAssertEqual(progress.fraction, 1)

        var countOnly = MigrationProgress(totalFiles: 4, totalBytes: 0)
        countOnly.copiedFiles = 1
        XCTAssertEqual(countOnly.fraction, 0.25)
    }

    // MARK: Journal

    func testJournalIsBoundedAndKeepsTheNewestEntries() {
        var journal = MigrationJournal()
        for index in 0..<(MigrationJournal.maximumEntries + 5) {
            journal.append(entry(kind: .planned, detail: "\(index)"))
        }
        XCTAssertEqual(journal.entries.count, MigrationJournal.maximumEntries)
        XCTAssertEqual(journal.entries.first?.detail, "5")
        XCTAssertEqual(journal.newestFirst.first?.detail, "\(MigrationJournal.maximumEntries + 4)")
    }

    func testJournalPersistenceRoundTripsAndSetsAsideUnreadableFiles() throws {
        let persistence = MigrationJournalPersistence(fileURL: workspace.appendingPathComponent("journal/migration-journal.json"))
        var journal = MigrationJournal()
        journal.append(entry(kind: .planned, detail: "dry run"))
        journal.append(entry(kind: .completed, detail: "3 files"))
        try persistence.save(journal)

        XCTAssertEqual(persistence.load(), journal)

        try Data("not json".utf8).write(to: persistence.fileURL)
        XCTAssertEqual(persistence.load(), MigrationJournal())
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.fileURL.deletingPathExtension().appendingPathExtension("unreadable.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.fileURL.path))
    }

    func testApplicationSupportJournalSitsNextToTheAlertHistory() throws {
        let journal = try XCTUnwrap(MigrationJournalPersistence.applicationSupport())
        let history = try AlertHistoryPersistence.defaultURL()
        XCTAssertEqual(journal.fileURL.deletingLastPathComponent(), history.deletingLastPathComponent())
        XCTAssertEqual(journal.fileURL.lastPathComponent, "migration-journal.json")
    }

    // MARK: Controller

    @MainActor
    func testControllerPlansConfirmsCopiesAndJournalsEachStep() async throws {
        let persistence = MigrationJournalPersistence(fileURL: workspace.appendingPathComponent("controller-journal.json"))
        let controller = MigrationController(persistence: persistence)
        var activity: [String] = []
        controller.onActivity = { _, description, _ in activity.append(description) }
        let before = try snapshotOfSource()

        XCTAssertFalse(controller.canPlan)
        controller.setSource(source)
        controller.selectDestinationFolder(destinationRoot)
        XCTAssertTrue(controller.canPlan)
        XCTAssertNil(controller.destinationVolumeID, "choosing a folder clears the volume choice")

        controller.makePlan(volumes: [])
        XCTAssertTrue(controller.isPlanning)
        try await waitUntil { !controller.isPlanning }

        let plan = try XCTUnwrap(controller.plan)
        XCTAssertNil(controller.planError)
        XCTAssertEqual(plan.inventory.fileCount, 3)
        XCTAssertEqual(controller.journal.entries.map(\.kind), [.planned])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destinationURL.path))

        controller.startCopy()
        XCTAssertTrue(controller.isCopying)
        XCTAssertNil(controller.result)
        try await waitUntil { !controller.isCopying }

        let result = try XCTUnwrap(controller.result)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertNil(controller.plan, "a used plan is consumed")
        XCTAssertNil(controller.progress)
        XCTAssertEqual(controller.journal.entries.map(\.kind), [.planned, .started, .completed])
        XCTAssertEqual(persistence.load(), controller.journal, "every step is written to disk")
        XCTAssertEqual(activity.count, 2)
        XCTAssertTrue(activity.allSatisfy { $0.contains("Original retained") })
        XCTAssertEqual(try snapshotOfSource(), before)
    }

    @MainActor
    func testControllerReportsPlanErrorsAndResolvesTheContainingVolume() async throws {
        let controller = MigrationController()
        let volumes = [
            VolumeSnapshot(id: "root", name: "Macintosh HD", mountPoint: "/", source: "disk3s1",
                           fileSystem: .apfs, fileSystemName: "apfs", totalBytes: 10, availableBytes: 5,
                           isReadOnly: false, isLocal: true, capturedAt: Date()),
            VolumeSnapshot(id: "scratch", name: "Scratch", mountPoint: workspace.path, source: "disk9s1",
                           fileSystem: .apfs, fileSystemName: "apfs", totalBytes: 10, availableBytes: 5,
                           isReadOnly: false, isLocal: true, capturedAt: Date())
        ]

        controller.selectDestinationFolder(destinationRoot)
        XCTAssertEqual(controller.destinationVolume(volumes: volumes)?.id, "scratch", "the deepest containing mount wins")
        controller.selectDestinationVolume("root")
        XCTAssertNil(controller.destinationFolder, "choosing a volume clears the folder choice")
        XCTAssertEqual(controller.destinationRoot(volumes: volumes)?.path, "/")

        controller.setSource(source)
        controller.selectDestinationFolder(source.appendingPathComponent("nested"))
        controller.makePlan(volumes: volumes)
        try await waitUntil { !controller.isPlanning }

        XCTAssertNil(controller.plan)
        XCTAssertEqual(controller.planError, MigrationPlanError.destinationInsideSource.errorDescription)
        XCTAssertTrue(controller.journal.entries.isEmpty, "rejected plans are not journaled")
    }

    // MARK: Helpers

    private func payload(_ size: Int, seed: UInt8) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) })
    }

    /// Path, size and contents of every regular file under the source.
    private func snapshotOfSource() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for (path, _) in filePayloads {
            files[path] = try Data(contentsOf: source.appendingPathComponent(path))
        }
        for link in ["latest", "previous"] {
            files[link] = Data(try linkTarget(at: source.appendingPathComponent(link)).utf8)
        }
        return files
    }

    /// `readlink(2)` directly, so a dangling link is read literally.
    private func linkTarget(at url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(url.path, &buffer, buffer.count - 1)
        guard length >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        buffer[Int(length)] = 0
        return String(cString: buffer)
    }

    private func entry(kind: MigrationJournalEntry.Kind, detail: String) -> MigrationJournalEntry {
        MigrationJournalEntry(
            id: UUID(),
            planID: UUID(),
            kind: kind,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            sourcePath: "/Users/demo/datasets/x",
            destinationPath: "/Volumes/Scratch/x",
            fileCount: 3,
            byteCount: 4_096,
            detail: detail
        )
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 15, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                return XCTFail("condition not met within \(timeout) s")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
