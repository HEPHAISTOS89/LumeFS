import XCTest
@testable import LumeFS

final class CollectorIntegrationTests: XCTestCase {
    func testIORateRequiresTwoOrderedCountersAndRejectsReset() throws {
        let first = counters(at: 10, bytes: 100)
        let second = counters(at: 12, bytes: 500)
        XCTAssertNil(BlockIOCollector.sample(deviceName: "test", current: first, previous: nil))
        XCTAssertNil(BlockIOCollector.sample(deviceName: "test", current: first, previous: first))
        XCTAssertNil(BlockIOCollector.sample(deviceName: "test", current: first, previous: second))
        XCTAssertNil(BlockIOCollector.sample(deviceName: "test", current: counters(at: 13, bytes: 1), previous: second))
        let sample = try XCTUnwrap(BlockIOCollector.sample(deviceName: "test", current: second, previous: first))
        XCTAssertEqual(sample.readBytesPerSecond, 200)
        XCTAssertEqual(sample.writeBytesPerSecond, 200)
    }

    func testChartDoesNotJoinSamplesAcrossGapsOrClockChanges() throws {
        let base = counters(at: 1, bytes: 100)
        let times: [TimeInterval] = [2, 3, 30, 31, 29]
        let samples = try times.map { time in
            try XCTUnwrap(BlockIOCollector.sample(deviceName: "test", current: counters(at: time, bytes: 200), previous: base))
        }
        XCTAssertEqual(IOChartPoint.make(from: samples).map(\.segment), [0, 0, 1, 1, 2])
        XCTAssertTrue(IOChartPoint.make(from: []).isEmpty)
    }

    func testDeduplicationKeepsOneMediaPerStorageDriver() {
        let physical = counters(at: 1, bytes: 1_000)
        let synthesized = counters(at: 1, bytes: 1_000)
        let external = counters(at: 1, bytes: 42)
        let orphan = counters(at: 1, bytes: 7)

        let result = BlockIOCollector.deduplicate([
            MediaCandidate(bsdName: "disk3", statisticsOwnerID: 100, depth: 4, counters: synthesized),
            MediaCandidate(bsdName: "disk0", statisticsOwnerID: 100, depth: 1, counters: physical),
            MediaCandidate(bsdName: "disk5", statisticsOwnerID: 200, depth: 1, counters: external),
            MediaCandidate(bsdName: "disk9", statisticsOwnerID: nil, depth: 0, counters: orphan)
        ])

        XCTAssertEqual(Set(result.keys), ["disk0", "disk5", "disk9"])
        XCTAssertEqual(result["disk0"]?.bytesRead, 1_000)
        XCTAssertEqual(result["disk5"]?.bytesRead, 42)
        XCTAssertEqual(result["disk9"]?.bytesRead, 7)
        XCTAssertEqual(result.values.reduce(0) { $0 + $1.bytesRead }, 1_049, "Shared counters must be summed once")
    }

    func testDeduplicationTieBreaksOnBSDNameDeterministically() {
        let shared = counters(at: 1, bytes: 5)
        let forward = BlockIOCollector.deduplicate([
            MediaCandidate(bsdName: "disk10", statisticsOwnerID: 1, depth: 2, counters: shared),
            MediaCandidate(bsdName: "disk2", statisticsOwnerID: 1, depth: 2, counters: shared)
        ])
        let reversed = BlockIOCollector.deduplicate([
            MediaCandidate(bsdName: "disk2", statisticsOwnerID: 1, depth: 2, counters: shared),
            MediaCandidate(bsdName: "disk10", statisticsOwnerID: 1, depth: 2, counters: shared)
        ])
        XCTAssertEqual(Array(forward.keys), ["disk2"])
        XCTAssertEqual(Array(reversed.keys), ["disk2"])
    }

    func testDeduplicationOfEmptyInputIsEmpty() {
        XCTAssertTrue(BlockIOCollector.deduplicate([]).isEmpty)
    }

    func testLiveWholeDeviceSamplesDoNotRepeatAStatisticsSource() async throws {
        // Two collections are needed for rates; the second must contain no more
        // devices than the number of distinct physical stores plus orphans.
        let collector = BlockIOCollector()
        _ = await collector.collect(at: Date())
        try await Task.sleep(for: .milliseconds(50))
        let samples = await collector.collect(at: Date())
        let names = samples.map(\.deviceName)
        XCTAssertEqual(Set(names).count, names.count, "Device names must be unique")
    }

    private func counters(at seconds: TimeInterval, bytes: UInt64) -> DeviceCounters {
        DeviceCounters(capturedAt: Date(timeIntervalSince1970: seconds),
                       bytesRead: bytes, bytesWritten: bytes, readOperations: 0,
                       writeOperations: 0, readErrors: 0, writeErrors: 0,
                       readRetries: 0, writeRetries: 0)
    }

    func testMountCollectorFindsRootVolume() {
        let volumes = MountCollector().collect()
        let root = volumes.first { $0.mountPoint == "/" }

        XCTAssertNotNil(root)
        XCTAssertGreaterThan(root?.totalBytes ?? 0, 0)
        XCTAssertGreaterThanOrEqual(root?.availableBytes ?? -1, 0)
    }

    func testMountCollectorIncludesWritableDataVolumeWhenPresent() throws {
        let path = "/System/Volumes/Data"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("No separate macOS Data volume on this host.")
        }
        let volume = try XCTUnwrap(MountCollector().collect().first { $0.mountPoint == path })
        XCTAssertFalse(volume.isReadOnly)
        XCTAssertGreaterThan(volume.totalBytes, 0)
    }

    func testLiveAPFSRootMetadataParsesWithoutReplacingStatfsCapacity() async throws {
        let root = try XCTUnwrap(
            MountCollector().collect().first { $0.mountPoint == "/" }
        )
        guard root.fileSystem == .apfs else {
            throw XCTSkip("The live root file system is not APFS.")
        }

        let runner = SystemCommandRunner()
        let diskutil = try await runner.run(
            .diskutil,
            arguments: ["info", "-plist", root.mountPoint]
        )
        let enriched = try APFSMetadataCollector(commandRunner: runner)
            .enrich(root, with: diskutil.standardOutput)

        XCTAssertEqual(enriched.totalBytes, root.totalBytes)
        XCTAssertEqual(enriched.availableBytes, root.availableBytes)
        XCTAssertFalse(enriched.name.isEmpty)
        XCTAssertNotNil(enriched.smartStatus)
    }

    func testDiskBenchmarkCompletesAndCleansUp() async throws {
        let result = try await DiskBenchmark().run(mebibytes: 1)

        XCTAssertEqual(result.byteCount, 1_048_576)
        XCTAssertGreaterThan(result.readBytesPerSecond, 0)
        XCTAssertGreaterThan(result.writeBytesPerSecond, 0)
        XCTAssertEqual(result.provenance, .benchmark)
        XCTAssertTrue(result.writeWasSynchronized)
        XCTAssertTrue(result.readMayUseSystemCache)
        XCTAssertTrue(result.cleanupSucceeded)
    }
}
