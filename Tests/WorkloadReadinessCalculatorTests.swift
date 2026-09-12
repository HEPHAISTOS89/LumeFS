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

    private func makeVolume(availableBytes: Int64) -> VolumeSnapshot {
        VolumeSnapshot(
            id: "test",
            name: "Test",
            mountPoint: "/Volumes/Test",
            source: "/dev/disk99",
            fileSystem: .apfs,
            fileSystemName: "apfs",
            totalBytes: 100 * 1_073_741_824,
            availableBytes: availableBytes,
            isReadOnly: false,
            isLocal: true,
            capturedAt: Date(),
            smartStatus: "Verified",
            apfsVolumeQuotaBytes: nil,
            apfsVolumeReserveBytes: nil
        )
    }
}
