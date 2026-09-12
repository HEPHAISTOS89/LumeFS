import XCTest
@testable import LumeFS

final class WorkloadReadinessCalculatorTests: XCTestCase {
    func testRequiresTwentyPercentSafetyMargin() {
        let oneGiB: Int64 = 1_073_741_824
        let volume = makeVolume(availableBytes: 12 * oneGiB)

        let result = WorkloadReadinessCalculator().evaluate(
            volume: volume,
            workloadGibibytes: 10
        )

        XCTAssertEqual(result.requiredBytesWithMargin, 12 * oneGiB)
        XCTAssertTrue(result.fits)
    }

    func testReportsWorkloadThatDoesNotFit() {
        let volume = makeVolume(availableBytes: 10 * 1_073_741_824)
        let result = WorkloadReadinessCalculator().evaluate(
            volume: volume,
            workloadGibibytes: 16
        )

        XCTAssertFalse(result.fits)
        XCTAssertLessThan(result.headroomBytes, 0)
    }

    func testReadOnlyVolumeCannotReceiveWorkload() {
        let volume = makeVolume(availableBytes: 80 * 1_073_741_824, isReadOnly: true)
        let result = WorkloadReadinessCalculator().evaluate(volume: volume, workloadGibibytes: 16)
        XCTAssertFalse(result.fits)
    }

    func testUserQuotaCanPreventPlacementOnOtherwiseSpaciousVolume() {
        let quota = makeQuota(mount: "/Volumes/Test", provenance: .live)
        let result = WorkloadReadinessCalculator().evaluate(
            volume: makeVolume(availableBytes: 80 * 1_073_741_824), workloadGibibytes: 16, quota: quota)
        XCTAssertFalse(result.fits)
        XCTAssertTrue(result.quotaLimited)
        XCTAssertEqual(result.availableBytes, 2 * 1_073_741_824)
    }

    func testUnrelatedOrReplayQuotaCannotLimitLivePlacement() {
        for quota in [makeQuota(mount: "/Volumes/Other", provenance: .live),
                      makeQuota(mount: "/Volumes/Test", provenance: .replay)] {
            let result = WorkloadReadinessCalculator().evaluate(
                volume: makeVolume(availableBytes: 80 * 1_073_741_824), workloadGibibytes: 16, quota: quota)
            XCTAssertTrue(result.fits)
            XCTAssertFalse(result.quotaLimited)
        }
    }

    private func makeQuota(mount: String, provenance: DataProvenance) -> QuotaSnapshot {
        QuotaSnapshot(id: "test", subject: "fixture", mountPoint: mount,
                      usedBytes: 8 * 1_073_741_824, softLimitBytes: 10 * 1_073_741_824,
                      hardLimitBytes: 20 * 1_073_741_824, message: "fixture", capturedAt: Date(), provenance: provenance)
    }

    private func makeVolume(availableBytes: Int64, isReadOnly: Bool = false) -> VolumeSnapshot {
        VolumeSnapshot(
            id: "test",
            name: "Test",
            mountPoint: "/Volumes/Test",
            source: "/dev/disk99",
            fileSystem: .apfs,
            fileSystemName: "apfs",
            totalBytes: 100 * 1_073_741_824,
            availableBytes: availableBytes,
            isReadOnly: isReadOnly,
            isLocal: true,
            capturedAt: Date(),
            smartStatus: "Verified",
            apfsVolumeQuotaBytes: nil,
            apfsVolumeReserveBytes: nil
        )
    }
}
