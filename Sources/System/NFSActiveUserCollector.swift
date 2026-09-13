import Foundation

/// Server-side per-user NFS activity from `nfsstat -u -n net -f JSON`.
///
/// `nfsstat -u` reads the kernel's active-user list through `nfssvc(NFSSVC_USERSTATS)`,
/// which XNU allows without superuser (only `NFSSVC_NFSD` and `NFSSVC_ADDSOCK` require
/// it). Records exist only on a Mac that serves NFS (`nfsd`); a pure client sees the
/// text `No NFS active user statistics found.` followed by an empty JSON document.
/// `-n net` keeps client addresses numeric so no DNS lookup happens during collection.
///
/// JSON layout (apple-oss-distributions/NFS, `nfsstat.c` `do_active_users_normal`,
/// `printer.c` `json_active_users`):
///
///     {"NFS Active User Info": {"/export": {"alice@192.0.2.10": {"User": "alice",
///       "Requests": 12, "Read Bytes": 0, "Write Bytes": 4096, "Idle": "0:00:03"}}}}
///
/// Unknown uids carry `"Uuid": <uid>` instead of `"User"`.
struct NFSActiveUserCollector: Sendable {
    let commandRunner: SystemCommandRunner

    static let noStatisticsMarker = "No NFS active user statistics found."
    static let arguments = ["-u", "-n", "net", "-f", "JSON"]

    func collect(at date: Date = Date()) async -> NFSUserActivitySnapshot {
        let serverState = await serverState()
        do {
            let output = try await commandRunner.run(.nfsstat, arguments: Self.arguments)
            return try parse(data: output.standardOutput, serverState: serverState, at: date)
        } catch {
            return .unavailable(
                message: Self.unavailableMessage(for: error, serverState: serverState),
                serverState: serverState,
                at: date
            )
        }
    }

    /// `nfsd status` is documented in Apple's `nfsd/main.c` as an unprivileged command
    /// that exits 0 when nfsd runs and 1 when it does not.
    func serverState() async -> NFSServerState {
        do {
            let output = try await commandRunner.run(.nfsd, arguments: ["status"])
            return Self.serverState(from: output.standardOutputString)
        } catch CommandRunnerError.nonZeroExit(_, 1, _) {
            return .notRunning
        } catch {
            return .unknown
        }
    }

    static func serverState(from statusOutput: String) -> NFSServerState {
        if statusOutput.contains("nfsd is running") { return .running }
        if statusOutput.contains("nfsd is not running") { return .notRunning }
        return .unknown
    }

    func parse(
        data: Data,
        serverState: NFSServerState,
        at date: Date = Date(),
        provenance: DataProvenance = .live
    ) throws -> NFSUserActivitySnapshot {
        let text = String(decoding: data, as: UTF8.self)
        if text.contains(Self.noStatisticsMarker) {
            return NFSUserActivitySnapshot(
                users: [],
                serverState: serverState,
                capturedAt: date,
                provenance: provenance,
                message: Self.emptyMessage(for: serverState)
            )
        }
        guard let start = data.firstIndex(of: UInt8(ascii: "{")) else {
            throw NFSActiveUserParseError.noActiveUserSection
        }
        let object = try JSONSerialization.jsonObject(with: data[start...])
        guard let root = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let info = root["NFS Active User Info"] as? [String: Any] else {
            throw NFSActiveUserParseError.noActiveUserSection
        }

        var users: [NFSUserActivity] = []
        for (export, exportValue) in info {
            guard let records = exportValue as? [String: Any] else { continue }
            for (key, recordValue) in records {
                guard let record = recordValue as? [String: Any] else { continue }
                users.append(Self.activity(
                    export: export,
                    key: key,
                    record: record,
                    at: date,
                    provenance: provenance
                ))
            }
        }
        users.sort {
            if $0.export != $1.export { return $0.export < $1.export }
            if $0.user != $1.user { return $0.user < $1.user }
            return $0.address < $1.address
        }

        return NFSUserActivitySnapshot(
            users: users,
            serverState: serverState,
            capturedAt: date,
            provenance: provenance,
            message: nil
        )
    }

    private static func activity(
        export: String,
        key: String,
        record: [String: Any],
        at date: Date,
        provenance: DataProvenance
    ) -> NFSUserActivity {
        // Keys are "<user>@<address>"; the address is everything after the last "@"
        // because IPv6 literals contain no "@" while user names might.
        let address: String
        let keyUser: String
        if let separator = key.lastIndex(of: "@") {
            address = String(key[key.index(after: separator)...])
            keyUser = String(key[..<separator])
        } else {
            address = ""
            keyUser = key
        }
        let uid = (record["Uuid"] as? NSNumber)?.uint32Value
        let user = (record["User"] as? String)
            ?? uid.map { "uid \($0)" }
            ?? keyUser

        return NFSUserActivity(
            id: "\(export)|\(user)@\(address)",
            export: export,
            user: user,
            uid: uid,
            address: address,
            requests: number(record["Requests"]),
            readBytes: number(record["Read Bytes"]),
            writeBytes: number(record["Write Bytes"]),
            idleSeconds: idleSeconds(from: record["Idle"] as? String),
            capturedAt: date,
            provenance: provenance
        )
    }

    private static func number(_ value: Any?) -> UInt64 {
        guard let number = value as? NSNumber else { return 0 }
        let signed = number.int64Value
        return signed < 0 ? 0 : UInt64(signed)
    }

    /// `Idle` is printed as `h:mm:ss`.
    static func idleSeconds(from text: String?) -> TimeInterval? {
        guard let text else { return nil }
        let parts = text.split(separator: ":").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        return TimeInterval(values[0] * 3_600 + values[1] * 60 + values[2])
    }

    static func emptyMessage(for serverState: NFSServerState) -> String {
        switch serverState {
        case .running:
            "nfsd is running and reports no active NFS user. Records appear only while clients issue requests."
        case .notRunning:
            "nfsd is not running on this Mac. Per-user NFS activity is only visible on the NFS server."
        case .unknown:
            "No active NFS user reported. nfsd state could not be determined."
        }
    }

    static func unavailableMessage(for error: Error, serverState: NFSServerState) -> String {
        let base = "Per-user NFS activity is unavailable: \(error.localizedDescription)"
        switch serverState {
        case .notRunning:
            return base + " nfsd is not running on this Mac."
        case .running, .unknown:
            return base
        }
    }
}

enum NFSActiveUserParseError: LocalizedError {
    case noActiveUserSection

    var errorDescription: String? {
        switch self {
        case .noActiveUserSection:
            "nfsstat returned no active-user section."
        }
    }
}
