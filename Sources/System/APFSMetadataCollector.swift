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
            apfsVolumeReserveBytes: positiveInteger("CapacityReserve", in: dictionary)
        )
    }

    private func integer(_ key: String, in dictionary: [String: Any]) -> Int64? {
        (dictionary[key] as? NSNumber)?.int64Value
    }

    private func positiveInteger(_ key: String, in dictionary: [String: Any]) -> Int64? {
        guard let value = integer(key, in: dictionary), value > 0 else { return nil }
        return value
    }
}
