import Foundation

enum AlertLifecycleState: String, Codable, Sendable {
    case active
    case acknowledged
    case cleared

    var label: String {
        switch self {
        case .active: "Active"
        case .acknowledged: "Acknowledged"
        case .cleared: "Cleared"
        }
    }
}

/// One occurrence of an alert: raised when its id first appears in a refresh,
/// cleared when the id disappears, optionally acknowledged by the user in between.
struct AlertHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var alert: MonitoringAlert
    let raisedAt: Date
    var lastSeenAt: Date
    var acknowledgedAt: Date?
    var clearedAt: Date?

    var state: AlertLifecycleState {
        if clearedAt != nil { return .cleared }
        if acknowledgedAt != nil { return .acknowledged }
        return .active
    }

    var isOpen: Bool { clearedAt == nil }
}

/// Bounded, ordered alert history. Pure value type so reconciliation is testable
/// without the store, the file system, or a clock.
struct AlertHistoryLedger: Codable, Equatable, Sendable {
    static let maximumEntries = 500
    static let schemaVersion = 1

    var schemaVersion: Int = AlertHistoryLedger.schemaVersion
    /// Newest raised first.
    private(set) var entries: [AlertHistoryEntry] = []

    init() {}

    struct Reconciliation: Equatable, Sendable {
        let raised: [AlertHistoryEntry]
        let cleared: [AlertHistoryEntry]

        var isEmpty: Bool { raised.isEmpty && cleared.isEmpty }
    }

    /// Opens an entry for every alert id that has no open entry, refreshes the
    /// payload of alerts that are still present, and closes open entries whose id
    /// is no longer reported. Acknowledged entries stay open until they clear.
    @discardableResult
    mutating func reconcile(activeAlerts: [MonitoringAlert], at date: Date) -> Reconciliation {
        var raised: [AlertHistoryEntry] = []
        var cleared: [AlertHistoryEntry] = []
        let activeByID = Dictionary(activeAlerts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for index in entries.indices where entries[index].isOpen {
            if let current = activeByID[entries[index].alert.id] {
                entries[index].alert = current
                entries[index].lastSeenAt = date
            } else {
                entries[index].clearedAt = date
                cleared.append(entries[index])
            }
        }

        let openIDs = Set(entries.filter(\.isOpen).map(\.alert.id))
        for alert in activeAlerts where !openIDs.contains(alert.id) {
            let entry = AlertHistoryEntry(
                id: "\(alert.id)#\(Int(date.timeIntervalSince1970 * 1_000))",
                alert: alert,
                raisedAt: date,
                lastSeenAt: date,
                acknowledgedAt: nil,
                clearedAt: nil
            )
            entries.insert(entry, at: 0)
            raised.append(entry)
        }

        trim()
        return Reconciliation(raised: raised, cleared: cleared)
    }

    @discardableResult
    mutating func acknowledge(entryID: String, at date: Date) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              entries[index].isOpen,
              entries[index].acknowledgedAt == nil else { return false }
        entries[index].acknowledgedAt = date
        return true
    }

    mutating func clearHistory(keepOpen: Bool = true) {
        entries = keepOpen ? entries.filter(\.isOpen) : []
    }

    var openEntries: [AlertHistoryEntry] { entries.filter(\.isOpen) }

    func openEntry(forAlertID alertID: String) -> AlertHistoryEntry? {
        entries.first { $0.isOpen && $0.alert.id == alertID }
    }

    /// Drops the oldest closed entries first so open alerts are never lost to the cap.
    private mutating func trim() {
        guard entries.count > Self.maximumEntries else { return }
        var excess = entries.count - Self.maximumEntries
        var kept: [AlertHistoryEntry] = []
        kept.reserveCapacity(Self.maximumEntries)
        for entry in entries.reversed() {
            if excess > 0, !entry.isOpen {
                excess -= 1
                continue
            }
            kept.append(entry)
        }
        entries = Array(kept.reversed().prefix(Self.maximumEntries))
    }
}

/// JSON file in Application Support. Loading a corrupt or foreign-schema file
/// yields an empty ledger and keeps the damaged file aside instead of deleting it.
struct AlertHistoryPersistence: Sendable {
    let fileURL: URL

    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("LumeFS", isDirectory: true)
            .appendingPathComponent("alert-history.json", isDirectory: false)
    }

    /// The app's persistence, or nil when Application Support cannot be resolved
    /// (the store then keeps the history in memory for the session).
    static func applicationSupport() -> AlertHistoryPersistence? {
        (try? defaultURL()).map { AlertHistoryPersistence(fileURL: $0) }
    }

    func load() -> AlertHistoryLedger {
        guard let data = try? Data(contentsOf: fileURL) else { return AlertHistoryLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let ledger = try? decoder.decode(AlertHistoryLedger.self, from: data),
           ledger.schemaVersion == AlertHistoryLedger.schemaVersion {
            return ledger
        }
        let damaged = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
        try? FileManager.default.removeItem(at: damaged)
        try? FileManager.default.moveItem(at: fileURL, to: damaged)
        return AlertHistoryLedger()
    }

    func save(_ ledger: AlertHistoryLedger) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ledger)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }
}
