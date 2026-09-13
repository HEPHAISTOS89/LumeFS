import Foundation

/// What one macOS notification would say. Only alert titles are used: evidence,
/// mount paths, device names and user names stay inside the app.
struct CriticalAlertNotificationPlan: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let alertIDs: [String]
}

/// Decides whether newly raised alerts deserve a notification. Pure value type so
/// the anti-spam rules are testable without the notification center.
///
/// Rules: only `critical` alerts; one notification per refresh regardless of how
/// many alerts were raised in it; an alert id that already produced a
/// notification stays silent for `cooldown` seconds even if it clears and comes
/// back (flapping mounts, oscillating capacity).
struct CriticalAlertNotificationPlanner: Equatable, Sendable {
    static let cooldown: TimeInterval = 600
    static let maximumTitlesInBody = 3

    private var lastDelivery: [String: Date] = [:]

    init() {}

    mutating func plan(raised entries: [AlertHistoryEntry], at date: Date) -> CriticalAlertNotificationPlan? {
        lastDelivery = lastDelivery.filter { date.timeIntervalSince($0.value) < Self.cooldown }

        let eligible = entries.filter { entry in
            entry.alert.severity == .critical && lastDelivery[entry.alert.id] == nil
        }
        guard !eligible.isEmpty else { return nil }

        for entry in eligible {
            lastDelivery[entry.alert.id] = date
        }

        let titles = eligible.map(\.alert.title)
        let shown = titles.prefix(Self.maximumTitlesInBody).joined(separator: "; ")
        let remainder = titles.count - min(titles.count, Self.maximumTitlesInBody)
        let body = remainder > 0 ? "\(shown); and \(remainder) more. Open LumeFS for evidence." : "\(shown). Open LumeFS for evidence."

        return CriticalAlertNotificationPlan(
            identifier: "lumefs.critical.\(Int(date.timeIntervalSince1970 * 1_000))",
            title: eligible.count == 1 ? "Critical storage alert" : "\(eligible.count) critical storage alerts",
            body: body,
            alertIDs: eligible.map(\.alert.id)
        )
    }
}
