import XCTest
@testable import LumeFS

final class APFSMetadataCollectorTests: XCTestCase {
    // Synthetic property list shaped like `diskutil info -plist` output; it is not
    // a capture from a real Mac.
    func testEnrichmentKeepsStatfsCapacityAndReadsMetadata() throws {
        let original = makeVolume()
        let plist: [String: Any] = [
            "VolumeName": "Data",
            "TotalSize": 9_999,
            "APFSContainerFree": 8_888,
            "SMARTStatus": "Verified",
            "CapacityQuota": 700,
            "CapacityReserve": 100
        ]

        let enriched = try enrich(original, plist)

        XCTAssertEqual(enriched.name, "Data")
        XCTAssertEqual(enriched.totalBytes, 1_000)
        XCTAssertEqual(enriched.availableBytes, 250)
        XCTAssertEqual(enriched.smartStatus, "Verified")
        XCTAssertEqual(enriched.apfsVolumeQuotaBytes, 700)
        XCTAssertEqual(enriched.apfsVolumeReserveBytes, 100)
        XCTAssertEqual(enriched.fileNodesTotal, 4_000, "statfs file-node counts survive enrichment")
        XCTAssertEqual(enriched.fileNodesUsed, 1_000)
        XCTAssertEqual(enriched.apfs?.containerFreeBytes, 8_888)
        XCTAssertNil(enriched.apfs?.containerSizeBytes)
        XCTAssertNil(enriched.apfs?.containerUsedFraction, "no fraction without both size and free")
    }

    func testContainerEncryptionAndDeviceFactsAreReadWhenPresent() throws {
        let plist: [String: Any] = [
            "VolumeName": "Models",
            "DeviceIdentifier": "disk3s5",
            "VolumeUUID": "00000000-0000-0000-0000-000000000001",
            "APFSContainerReference": "disk3",
            "APFSContainerSize": 1_000_000,
            "APFSContainerFree": 250_000,
            "APFSPhysicalStores": [["DeviceIdentifier": "disk0s2"], ["DeviceIdentifier": "disk1s2"]],
            "CapacityInUse": 400_000,
            "Encryption": true,
            "FileVault": true,
            "Locked": false,
            "Sealed": "No",
            "SolidState": true,
            "Internal": true,
            "BusProtocol": "Apple Fabric"
        ]

        let apfs = try XCTUnwrap(try enrich(makeVolume(), plist).apfs)
        XCTAssertEqual(apfs.deviceIdentifier, "disk3s5")
        XCTAssertEqual(apfs.volumeUUID, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(apfs.containerReference, "disk3")
        XCTAssertEqual(apfs.containerSizeBytes, 1_000_000)
        XCTAssertEqual(apfs.containerFreeBytes, 250_000)
        XCTAssertEqual(apfs.containerUsedFraction ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(apfs.physicalStores, ["disk0s2", "disk1s2"])
        XCTAssertEqual(apfs.capacityInUseBytes, 400_000)
        XCTAssertEqual(apfs.isEncrypted, true)
        XCTAssertEqual(apfs.fileVaultEnabled, true)
        XCTAssertEqual(apfs.isLocked, false)
        XCTAssertEqual(apfs.isSealed, false, "`Sealed` arrives as a Yes/No string")
        XCTAssertEqual(apfs.isSolidState, true)
        XCTAssertEqual(apfs.isInternal, true)
        XCTAssertEqual(apfs.busProtocol, "Apple Fabric")
        XCTAssertEqual(apfs.encryptionLabel, "Encrypted · FileVault")
    }

    func testMissingKeysStayNilAndLabelsSayNotReported() throws {
        let apfs = try XCTUnwrap(try enrich(makeVolume(), ["VolumeName": "Bare"]).apfs)
        XCTAssertNil(apfs.containerReference)
        XCTAssertNil(apfs.containerUsedFraction)
        XCTAssertTrue(apfs.physicalStores.isEmpty)
        XCTAssertNil(apfs.isEncrypted)
        XCTAssertNil(apfs.isSealed)
        XCTAssertEqual(apfs.encryptionLabel, "Not reported")

        let sealed = APFSMetadataCollector.details(from: ["Sealed": "Yes", "Encryption": false, "Locked": true])
        XCTAssertEqual(sealed.isSealed, true)
        XCTAssertEqual(sealed.encryptionLabel, "Locked", "a locked volume is reported as locked before anything else")
        XCTAssertEqual(APFSMetadataCollector.details(from: ["Encryption": false]).encryptionLabel, "Not encrypted")
        XCTAssertEqual(APFSMetadataCollector.details(from: ["Encryption": true]).encryptionLabel, "Encrypted")
        XCTAssertNil(APFSMetadataCollector.details(from: ["Sealed": "maybe"]).isSealed)
        XCTAssertNil(APFSMetadataCollector.details(from: ["APFSContainerFree": -1]).containerFreeBytes)
    }

    func testCorruptPropertyListThrowsAndLeavesTheVolumeUntouched() {
        let collector = APFSMetadataCollector(commandRunner: SystemCommandRunner())
        XCTAssertThrowsError(try collector.enrich(makeVolume(), with: Data("not a plist".utf8)))
    }

    private func enrich(_ volume: VolumeSnapshot, _ plist: [String: Any]) throws -> VolumeSnapshot {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return try APFSMetadataCollector(commandRunner: SystemCommandRunner()).enrich(volume, with: data)
    }

    private func makeVolume() -> VolumeSnapshot {
        VolumeSnapshot(
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
            apfsVolumeReserveBytes: nil,
            fileNodesTotal: 4_000,
            fileNodesFree: 3_000,
            apfs: nil
        )
    }
}
