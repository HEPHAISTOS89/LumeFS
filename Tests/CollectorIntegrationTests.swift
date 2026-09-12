import XCTest
@testable import LumeFS

final class CollectorIntegrationTests: XCTestCase {
    func testMountCollectorFindsRootVolume() {
        let volumes = MountCollector().collect()
        let root = volumes.first { $0.mountPoint == "/" }

        XCTAssertNotNil(root)
        XCTAssertGreaterThan(root?.totalBytes ?? 0, 0)
        XCTAssertGreaterThanOrEqual(root?.availableBytes ?? -1, 0)
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
