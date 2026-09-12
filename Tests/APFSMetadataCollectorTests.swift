import XCTest
@testable import LumeFS

final class APFSMetadataCollectorTests: XCTestCase {
    func testEnrichmentKeepsStatfsCapacityAndReadsMetadata() throws {
        let original = VolumeSnapshot(
            id: "root",
            name: "Original",
            mountPoint: "/",
            source: "/dev/disk1s1",
            fileSystem: .apfs,
            fileSystemName: "apfs",
            totalBytes: 1_000,
            availableBytes: 250,
            isReadOnly: false,
            isLocal: true,
            capturedAt: Date(timeIntervalSince1970: 100),
            smartStatus: nil,
            apfsVolumeQuotaBytes: nil,
            apfsVolumeReserveBytes: nil
        )
        let plist: [String: Any] = [
            "VolumeName": "Data",
            "TotalSize": 9_999,
            "APFSContainerFree": 8_888,
            "SMARTStatus": "Verified",
            "CapacityQuota": 700,
            "CapacityReserve": 100
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        let enriched = try APFSMetadataCollector(
            commandRunner: SystemCommandRunner()
        ).enrich(original, with: data)

        XCTAssertEqual(enriched.name, "Data")
        XCTAssertEqual(enriched.totalBytes, 1_000)
        XCTAssertEqual(enriched.availableBytes, 250)
        XCTAssertEqual(enriched.smartStatus, "Verified")
        XCTAssertEqual(enriched.apfsVolumeQuotaBytes, 700)
        XCTAssertEqual(enriched.apfsVolumeReserveBytes, 100)
    }
}
