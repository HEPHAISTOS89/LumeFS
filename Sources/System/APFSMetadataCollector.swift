import Foundation

struct APFSMetadataCollector: Sendable {
    let commandRunner: SystemCommandRunner

    func enrich(_ volumes: [VolumeSnapshot]) async -> [VolumeSnapshot] {
        var enrichedVolumes: [VolumeSnapshot] = []

        for volume in volumes {
            guard volume.fileSystem == .apfs else {
                enrichedVolumes.append(volume)
                continue
            }

            do {
                let output = try await commandRunner.run(
                    .diskutil,
                    arguments: ["info", "-plist", volume.mountPoint]
                )
                enrichedVolumes.append(
                    try enrich(volume, with: output.standardOutput)
                )
            } catch {
                enrichedVolumes.append(volume)
            }
        }

        return enrichedVolumes
    }

    func enrich(
        _ volume: VolumeSnapshot,
        with propertyListData: Data
    ) throws -> VolumeSnapshot {
        let object = try PropertyListSerialization.propertyList(
            from: propertyListData,
            options: [],
            format: nil
        )

        guard let dictionary = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        return VolumeSnapshot(
            id: volume.id,
            name: dictionary["VolumeName"] as? String ?? volume.name,
            mountPoint: volume.mountPoint,
            source: volume.source,
            fileSystem: volume.fileSystem,
            fileSystemName: volume.fileSystemName,
            totalBytes: volume.totalBytes,
            availableBytes: volume.availableBytes,
            isReadOnly: volume.isReadOnly,
            isLocal: volume.isLocal,
            capturedAt: volume.capturedAt,
            smartStatus: dictionary["SMARTStatus"] as? String,
            apfsVolumeQuotaBytes: positiveInteger("CapacityQuota", in: dictionary),
            apfsVolumeReserveBytes: positiveInteger("CapacityReserve", in: dictionary),
            fileNodesTotal: volume.fileNodesTotal,
            fileNodesFree: volume.fileNodesFree,
            apfs: Self.details(from: dictionary)
        )
    }

    /// Reads only keys observed in `diskutil info -plist` output for APFS volumes.
    /// Booleans arrive as plist booleans or as “Yes”/“No” strings (`Sealed`).
    static func details(from dictionary: [String: Any]) -> APFSVolumeDetails {
        var details = APFSVolumeDetails()
        details.deviceIdentifier = string("DeviceIdentifier", in: dictionary)
        details.volumeUUID = string("VolumeUUID", in: dictionary)
        details.containerReference = string("APFSContainerReference", in: dictionary)
        details.containerSizeBytes = nonNegativeInteger("APFSContainerSize", in: dictionary)
        details.containerFreeBytes = nonNegativeInteger("APFSContainerFree", in: dictionary)
        details.capacityInUseBytes = nonNegativeInteger("CapacityInUse", in: dictionary)
        details.isEncrypted = bool("Encryption", in: dictionary)
        details.fileVaultEnabled = bool("FileVault", in: dictionary)
        details.isLocked = bool("Locked", in: dictionary)
        details.isSealed = bool("Sealed", in: dictionary)
        details.isSolidState = bool("SolidState", in: dictionary)
        details.isInternal = bool("Internal", in: dictionary)
        details.busProtocol = string("BusProtocol", in: dictionary)
        if let stores = dictionary["APFSPhysicalStores"] as? [[String: Any]] {
            details.physicalStores = stores.compactMap { string("DeviceIdentifier", in: $0) }
        }
        return details
    }

    private static func string(_ key: String, in dictionary: [String: Any]) -> String? {
        guard let value = dictionary[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ key: String, in dictionary: [String: Any]) -> Bool? {
        if let number = dictionary[key] as? NSNumber { return number.boolValue }
        guard let text = dictionary[key] as? String else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true": return true
        case "no", "false": return false
        default: return nil
        }
    }

    private static func nonNegativeInteger(_ key: String, in dictionary: [String: Any]) -> Int64? {
        guard let value = (dictionary[key] as? NSNumber)?.int64Value, value >= 0 else { return nil }
        return value
    }

    private func positiveInteger(_ key: String, in dictionary: [String: Any]) -> Int64? {
        guard let value = (dictionary[key] as? NSNumber)?.int64Value, value > 0 else { return nil }
        return value
    }
}
