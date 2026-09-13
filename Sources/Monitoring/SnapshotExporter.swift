import Foundation

/// Everything the UI currently shows, serialized with its provenance. Nothing is
/// recomputed at export time; values are the latest snapshot the store applied.
struct MonitoringExport: Codable, Sendable {
    var schemaVersion = 1
    let exportedAt: Date
    let appVersion: String
    let addressesMasked: Bool
    let volumes: [VolumeSnapshot]
    let deviceSamples: [DeviceIOSample]
    let nfsClient: NFSClientMetrics
    let nfsMounts: [NFSMountInfo]
    let nfsUsers: NFSUserActivitySnapshot
    let processIO: ProcessIOSnapshot
    let quotas: [QuotaSnapshot]
    let activeAlerts: [MonitoringAlert]
    let alertHistory: [AlertHistoryEntry]
}

enum SnapshotExportFormat: String, CaseIterable, Sendable {
    case json
    case csv

    var fileExtension: String { rawValue }
    var label: String { rawValue.uppercased() }
}

struct SnapshotExporter {
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func data(for export: MonitoringExport, format: SnapshotExportFormat) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(export)
        case .csv:
            return Data(csv(for: export).utf8)
        }
    }

    static func suggestedFileName(at date: Date, format: SnapshotExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "LumeFS-snapshot-\(formatter.string(from: date)).\(format.fileExtension)"
    }

    /// Long format: one measurement per row, so spreadsheets can filter by category
    /// and provenance without a schema per collector.
    func csv(for export: MonitoringExport) -> String {
        var rows: [[String]] = [["captured_at", "category", "identifier", "metric", "value", "unit", "provenance"]]
        func add(_ date: Date, _ category: String, _ identifier: String, _ metric: String, _ value: String, _ unit: String, _ provenance: DataProvenance) {
            rows.append([Self.isoFormatter.string(from: date), category, identifier, metric, value, unit, provenance.rawValue])
        }

        add(export.exportedAt, "export", "LumeFS", "app_version", export.appVersion, "", .live)
        add(export.exportedAt, "export", "LumeFS", "addresses_masked", export.addressesMasked ? "true" : "false", "", .live)

        for volume in export.volumes {
            add(volume.capturedAt, "volume", volume.mountPoint, "name", volume.name, "", .live)
            add(volume.capturedAt, "volume", volume.mountPoint, "file_system", volume.fileSystem.rawValue, "", .live)
            add(volume.capturedAt, "volume", volume.mountPoint, "total_bytes", String(volume.totalBytes), "bytes", .live)
            add(volume.capturedAt, "volume", volume.mountPoint, "available_bytes", String(volume.availableBytes), "bytes", .live)
            add(volume.capturedAt, "volume", volume.mountPoint, "used_bytes", String(volume.usedBytes), "bytes", .live)
            add(volume.capturedAt, "volume", volume.mountPoint, "smart_status", volume.smartStatus ?? "", "", volume.smartStatus == nil ? .unavailable : .live)
            add(volume.capturedAt, "volume", volume.mountPoint, "file_nodes_used", volume.fileNodesUsed.map(String.init) ?? "", "count", volume.fileNodesUsed == nil ? .unavailable : .live)
            let apfsProvenance: DataProvenance = volume.apfs == nil ? .unavailable : .live
            add(volume.capturedAt, "volume", volume.mountPoint, "apfs_container", volume.apfs?.containerReference ?? "", "", apfsProvenance)
            add(volume.capturedAt, "volume", volume.mountPoint, "apfs_container_free_bytes", volume.apfs?.containerFreeBytes.map(String.init) ?? "", "bytes", apfsProvenance)
            add(volume.capturedAt, "volume", volume.mountPoint, "apfs_encryption", volume.apfs?.encryptionLabel ?? "", "", apfsProvenance)
        }

        for sample in export.deviceSamples {
            add(sample.timestamp, "device", sample.deviceName, "read_bytes_per_second", Self.number(sample.readBytesPerSecond), "bytes/s", sample.provenance)
            add(sample.timestamp, "device", sample.deviceName, "write_bytes_per_second", Self.number(sample.writeBytesPerSecond), "bytes/s", sample.provenance)
            add(sample.timestamp, "device", sample.deviceName, "read_errors", String(sample.readErrors), "count", sample.provenance)
            add(sample.timestamp, "device", sample.deviceName, "write_errors", String(sample.writeErrors), "count", sample.provenance)
        }

        let nfs = export.nfsClient
        for (metric, value) in [
            ("requests", nfs.requests), ("retries", nfs.retries), ("timed_out", nfs.timedOut),
            ("read_operations", nfs.readOperations), ("write_operations", nfs.writeOperations),
            ("layout_gets", nfs.layoutGets), ("layout_commits", nfs.layoutCommits),
            ("layout_returns", nfs.layoutReturns), ("device_info_requests", nfs.deviceInfoRequests)
        ] {
            add(nfs.capturedAt, "nfs_client", "client", metric, String(value), "count", nfs.provenance)
        }

        for mount in export.nfsMounts {
            add(mount.capturedAt, "nfs_mount", mount.mountPoint, "server", mount.displayServer, "", mount.provenance)
            add(mount.capturedAt, "nfs_mount", mount.mountPoint, "export", mount.displayExport, "", mount.provenance)
            add(mount.capturedAt, "nfs_mount", mount.mountPoint, "nfs_version", mount.nfsVersion ?? "", "", mount.provenance)
            add(mount.capturedAt, "nfs_mount", mount.mountPoint, "transport", mount.transport ?? "", "", mount.provenance)
            add(mount.capturedAt, "nfs_mount", mount.mountPoint, "status", mount.statusLabel, "", mount.provenance)
        }

        for user in export.nfsUsers.users {
            add(user.capturedAt, "nfs_user", user.id, "requests", String(user.requests), "count", user.provenance)
            add(user.capturedAt, "nfs_user", user.id, "read_bytes", String(user.readBytes), "bytes", user.provenance)
            add(user.capturedAt, "nfs_user", user.id, "write_bytes", String(user.writeBytes), "bytes", user.provenance)
            add(user.capturedAt, "nfs_user", user.id, "idle_seconds", user.idleSeconds.map(Self.number) ?? "", "s", user.provenance)
        }
        if export.nfsUsers.users.isEmpty {
            add(export.nfsUsers.capturedAt, "nfs_user", "none", "message", export.nfsUsers.message ?? "", "", export.nfsUsers.provenance)
        }

        for process in export.processIO.samples {
            let identifier = "\(process.pid) \(process.name)"
            add(process.timestamp, "process", identifier, "user", process.userName, "", process.provenance)
            add(process.timestamp, "process", identifier, "read_bytes_per_second", Self.number(process.readBytesPerSecond), "bytes/s", process.provenance)
            add(process.timestamp, "process", identifier, "write_bytes_per_second", Self.number(process.writeBytesPerSecond), "bytes/s", process.provenance)
            add(process.timestamp, "process", identifier, "cumulative_write_bytes", String(process.cumulativeWriteBytes), "bytes", process.provenance)
            add(process.timestamp, "process", identifier, "workload_hint", process.workloadHint ?? "", "", process.provenance)
        }
        add(export.processIO.capturedAt, "process", "coverage", "readable_processes", String(export.processIO.readableProcessCount), "count", export.processIO.provenance)
        add(export.processIO.capturedAt, "process", "coverage", "denied_processes", String(export.processIO.deniedProcessCount), "count", export.processIO.provenance)
        add(export.processIO.capturedAt, "process", "coverage", "total_processes", String(export.processIO.totalProcessCount), "count", export.processIO.provenance)

        for quota in export.quotas {
            add(quota.capturedAt, "quota", quota.mountPoint, "subject", quota.subject, "", quota.provenance)
            add(quota.capturedAt, "quota", quota.mountPoint, "used_bytes", quota.usedBytes.map(String.init) ?? "", "bytes", quota.provenance)
            add(quota.capturedAt, "quota", quota.mountPoint, "soft_limit_bytes", quota.softLimitBytes.map(String.init) ?? "", "bytes", quota.provenance)
            add(quota.capturedAt, "quota", quota.mountPoint, "hard_limit_bytes", quota.hardLimitBytes.map(String.init) ?? "", "bytes", quota.provenance)
        }

        for alert in export.activeAlerts {
            add(alert.createdAt, "alert", alert.id, "rule", alert.ruleID, "", alert.provenance)
            add(alert.createdAt, "alert", alert.id, "severity", alert.severity.label, "", alert.provenance)
            add(alert.createdAt, "alert", alert.id, "title", alert.title, "", alert.provenance)
            add(alert.createdAt, "alert", alert.id, "evidence", alert.evidence, "", alert.provenance)
        }

        for entry in export.alertHistory {
            add(entry.raisedAt, "alert_history", entry.id, "state", entry.state.label, "", entry.alert.provenance)
            add(entry.raisedAt, "alert_history", entry.id, "rule", entry.alert.ruleID, "", entry.alert.provenance)
            add(entry.raisedAt, "alert_history", entry.id, "severity", entry.alert.severity.label, "", entry.alert.provenance)
            add(entry.raisedAt, "alert_history", entry.id, "title", entry.alert.title, "", entry.alert.provenance)
            add(entry.raisedAt, "alert_history", entry.id, "cleared_at", entry.clearedAt.map { Self.isoFormatter.string(from: $0) } ?? "", "", entry.alert.provenance)
            add(entry.raisedAt, "alert_history", entry.id, "acknowledged_at", entry.acknowledgedAt.map { Self.isoFormatter.string(from: $0) } ?? "", "", entry.alert.provenance)
        }

        return rows.map { $0.map(Self.escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.3f", value)
    }
}

extension NFSUserActivity {
    /// Copy with the client address reduced to its network prefix (id included).
    func masked() -> NFSUserActivity {
        NFSUserActivity(
            id: "\(export)|\(user)@\(maskedAddress)",
            export: export,
            user: user,
            uid: uid,
            address: maskedAddress,
            requests: requests,
            readBytes: readBytes,
            writeBytes: writeBytes,
            idleSeconds: idleSeconds,
            capturedAt: capturedAt,
            provenance: provenance
        )
    }
}

extension NFSUserActivitySnapshot {
    func maskingAddresses() -> NFSUserActivitySnapshot {
        NFSUserActivitySnapshot(
            users: users.map { $0.masked() },
            serverState: serverState,
            capturedAt: capturedAt,
            provenance: provenance,
            message: message
        )
    }
}
