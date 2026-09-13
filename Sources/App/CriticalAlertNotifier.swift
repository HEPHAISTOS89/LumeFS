import Foundation
import Observation
@preconcurrency import UserNotifications

/// Opt-in bridge between raised critical alerts and the macOS notification center.
///
/// The app constructs one instance; tests never do, so the notification center
/// is never touched from the test host. Authorization is requested only when the
/// user turns the Settings toggle on, and nothing is posted while the toggle is
/// off or authorization is missing.
@MainActor
@Observable
final class CriticalAlertNotifier {
    static let enabledDefaultsKey = "criticalAlertNotifications"

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var lastError: String?
    private(set) var deliveredCount = 0

    @ObservationIgnored private var planner = CriticalAlertNotificationPlanner()
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `UNUserNotificationCenter` aborts when the process has no bundle identifier.
    var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledDefaultsKey) }

    var statusLabel: String {
        guard isSupported else { return "Unavailable outside an app bundle" }
        guard isEnabled else { return "Off" }
        switch authorizationStatus {
        case .authorized: return "Allowed by macOS"
        case .provisional: return "Delivered quietly (provisional)"
        case .denied: return "Denied in System Settings"
        case .notDetermined: return "Waiting for permission"
        @unknown default: return "Unknown"
        }
    }

    var canDeliver: Bool {
        isSupported && isEnabled && (authorizationStatus == .authorized || authorizationStatus == .provisional)
    }

    func refreshAuthorizationStatus() async {
        guard isSupported else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Called when the Settings toggle changes. Enabling asks macOS once; the
    /// system remembers the answer and later calls return it without a prompt.
    func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        lastError = nil
        guard enabled, isSupported else { return }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            lastError = error.localizedDescription
        }
        await refreshAuthorizationStatus()
    }

    func deliver(raised entries: [AlertHistoryEntry], at date: Date) {
        guard canDeliver else { return }
        guard let plan = planner.plan(raised: entries, at: date) else { return }

        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = plan.body
        content.sound = .default
        content.threadIdentifier = "lumefs.critical"
        content.interruptionLevel = .active

        let request = UNNotificationRequest(identifier: plan.identifier, content: content, trigger: nil)
        deliveredCount += 1
        Task { @MainActor [weak self] in
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }
}
