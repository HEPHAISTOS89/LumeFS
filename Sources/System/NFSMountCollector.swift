import Foundation

/// Per-mount NFS information from `nfsstat -m -f JSON <mount point>`.
///
/// Apple's `nfsstat` (apple-oss-distributions/NFS, `nfsstat/nfsstat.c` and
/// `nfsstat/printer.c`) opens a root dictionary for `-f JSON`, then
/// `json_mount_header` nests one dictionary per mount under its `f_mntfromname`
/// (for example `"server:/export"`). That dictionary carries `Mount Point`,
/// `Original mount options`, `Current mount parameters` and `Status flags`. Two
/// mounts of the same export would collide on that key, so LumeFS queries one mount
/// point per invocation and reads the first dictionary that has a `Mount Point`.
struct NFSMountCollector: Sendable {
    let commandRunner: SystemCommandRunner

    func collect(volumes: [VolumeSnapshot], at date: Date = Date()) async -> [NFSMountInfo] {
        var mounts: [NFSMountInfo] = []
        for volume in volumes where volume.fileSystem == .nfs {
            do {
                let output = try await commandRunner.run(
                    .nfsstat,
                    arguments: ["-m", "-f", "JSON", volume.mountPoint]
                )
                mounts.append(
                    try parse(
                        data: output.standardOutput,
                        mountPoint: volume.mountPoint,
                        source: volume.source,
                        at: date
                    )
                )
            } catch {
                mounts.append(
                    .unavailable(
                        mountPoint: volume.mountPoint,
                        source: volume.source,
                        message: error.localizedDescription,
                        at: date
                    )
                )
            }
        }
        return mounts
    }

    func parse(
        data: Data,
        mountPoint: String,
        source: String,
        at date: Date = Date(),
        provenance: DataProvenance = .live
    ) throws -> NFSMountInfo {
        guard !data.isEmpty else {
            throw NFSMountParseError.noMountInformation
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let document = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let root = Self.mountDictionary(in: document, mountPoint: mountPoint) else {
            throw NFSMountParseError.noMountInformation
        }

        let parameters = (root["Current mount parameters"] as? [String: Any])
            ?? (root["Original mount options"] as? [String: Any])
            ?? [:]
        let nfsParameters = parameters["NFS parameters"] as? [String] ?? []
        let mountFlags = (parameters["General mount flags"] as? [String: Any])?["Flags"] as? [String] ?? []
        let statusFlags = (root["Status flags"] as? [String: Any])?["Flags"] as? [String] ?? []

        var server: String?
        var export: String?
        var addresses: [String] = []
        if let locations = parameters["File system locations"] as? [[String: Any]],
           let first = locations.first {
            server = first["Server"] as? String
            export = first["Export"] as? String
            addresses = first["Locations"] as? [String] ?? []
        }
        // `json_add_locations` writes into the current dictionary when the location
        // array was opened without a nested dictionary; accept that layout as well.
        if server == nil {
            server = parameters["Server"] as? String
            export = export ?? parameters["Export"] as? String
            addresses = parameters["Locations"] as? [String] ?? addresses
        }

        return NFSMountInfo(
            id: mountPoint,
            mountPoint: root["Mount Point"] as? String ?? mountPoint,
            source: source,
            server: server,
            export: export,
            addresses: addresses,
            nfsVersion: Self.version(from: nfsParameters),
            transport: Self.transport(from: nfsParameters),
            parameters: nfsParameters,
            mountFlags: mountFlags,
            statusFlags: statusFlags,
            capturedAt: date,
            provenance: provenance,
            message: nil
        )
    }

    /// Accepts the nested layout (`{"server:/export": {"Mount Point": ...}}`) and a
    /// flat layout with `Mount Point` at the root. Prefers the entry whose mount point
    /// matches the requested path; otherwise the only/first mount dictionary.
    static func mountDictionary(
        in document: [String: Any],
        mountPoint: String
    ) -> [String: Any]? {
        if document["Mount Point"] is String {
            return document
        }
        let candidates = document
            .sorted { $0.key < $1.key }
            .compactMap { entry -> [String: Any]? in
                guard let dictionary = entry.value as? [String: Any],
                      dictionary["Mount Point"] is String else { return nil }
                return dictionary
            }
        return candidates.first { ($0["Mount Point"] as? String) == mountPoint } ?? candidates.first
    }

    static func version(from parameters: [String]) -> String? {
        for parameter in parameters where parameter.hasPrefix("vers=") {
            return String(parameter.dropFirst("vers=".count))
        }
        return nil
    }

    static func transport(from parameters: [String]) -> String? {
        let transports: Set<String> = ["tcp", "udp", "tcp4", "tcp6", "udp4", "udp6", "ticlts", "ticotsord"]
        return parameters.first { transports.contains($0) }
    }
}

enum NFSMountParseError: LocalizedError {
    case noMountInformation

    var errorDescription: String? {
        switch self {
        case .noMountInformation:
            "nfsstat returned no mount information for this path."
        }
    }
}
