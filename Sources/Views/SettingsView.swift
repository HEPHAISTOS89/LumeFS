import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    /// Nil when no notification bridge exists (tests, previews); the section then explains why.
    var notifier: CriticalAlertNotifier?

    @AppStorage("appearancePreference") private var appearancePreference = "system"
    @AppStorage(CriticalAlertNotifier.enabledDefaultsKey) private var criticalNotifications = false
    @AppStorage("interfaceAnimations") private var interfaceAnimations = true
    @AppStorage("capacityWarningThreshold") private var warningThreshold = 20.0
    @AppStorage("capacityCriticalThreshold") private var criticalThreshold = 10.0
    @AppStorage("nfsUserWriteBurstMBps") private var nfsUserWriteBurst = 100.0
    @AppStorage("nfsUserRequestBurstPerSecond") private var nfsUserRequestBurst = 1_000.0
    @AppStorage("showFullNFSClientAddresses") private var showFullAddresses = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearancePreference) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Animate value changes", isOn: $interfaceAnimations)
                Text("Animations also respect Reduce Motion in macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Capacity thresholds") {
                LabeledContent("Warning") {
                    Text("\(warningThreshold, specifier: "%.0f")% free")
                }
                Slider(value: $warningThreshold, in: 10...40, step: 1)
                    .accessibilityLabel("Warning threshold")
                    .accessibilityValue("\(warningThreshold.formatted(.number.precision(.fractionLength(0)))) percent free")
                    .accessibilityHint("Adjusts the free-space percentage that produces a warning")
                    .onChange(of: warningThreshold) { _, value in
                        criticalThreshold = min(criticalThreshold, value)
                    }

                LabeledContent("Critical") {
                    Text("\(criticalThreshold, specifier: "%.0f")% free")
                }
                Slider(value: $criticalThreshold, in: 2...20, step: 1)
                    .accessibilityLabel("Critical threshold")
                    .accessibilityValue("\(criticalThreshold.formatted(.number.precision(.fractionLength(0)))) percent free")
                    .accessibilityHint("Adjusts the free-space percentage that produces a critical alert")
                    .onChange(of: criticalThreshold) { _, value in
                        warningThreshold = max(warningThreshold, value)
                    }
            }

            Section("NFS user bursts") {
                LabeledContent("Write burst") {
                    Text("\(nfsUserWriteBurst, specifier: "%.0f") MB/s")
                }
                Slider(value: $nfsUserWriteBurst, in: 10...1_000, step: 10)
                    .accessibilityLabel("NFS user write burst threshold")
                    .accessibilityValue("\(nfsUserWriteBurst.formatted(.number.precision(.fractionLength(0)))) megabytes per second")
                    .accessibilityHint("Write rate of one NFS user over one collection interval that produces a warning")

                LabeledContent("Request burst") {
                    Text("\(nfsUserRequestBurst, specifier: "%.0f") requests/s")
                }
                Slider(value: $nfsUserRequestBurst, in: 100...10_000, step: 100)
                    .accessibilityLabel("NFS user request burst threshold")
                    .accessibilityValue("\(nfsUserRequestBurst.formatted(.number.precision(.fractionLength(0)))) requests per second")
                    .accessibilityHint("Request rate of one NFS user over one collection interval that produces a warning")

                Toggle("Show full NFS client addresses", isOn: $showFullAddresses)
                Text("Rates are deltas over the 3-second NFS interval, measured only on a Mac that runs nfsd. Alerts always use masked addresses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify me about critical alerts", isOn: $criticalNotifications)
                    .disabled(notifier?.isSupported != true)
                    .onChange(of: criticalNotifications) { _, enabled in
                        Task { await notifier?.setEnabled(enabled) }
                    }
                LabeledContent("Status", value: notifier?.statusLabel ?? "Unavailable in this context")
                if notifier?.authorizationStatus == .denied, criticalNotifications {
                    Button("Open Notification Settings…") {
                        openNotificationSettings()
                    }
                    .controlSize(.small)
                }
                if let error = notifier?.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Text("Critical alerts only, one notification per refresh, and the same alert stays quiet for 10 minutes after it was announced. The notification carries the alert title only; evidence stays in LumeFS. Nothing is requested from macOS until you turn this on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Collection") {
                LabeledContent("APFS and block I/O", value: "Enabled")
                LabeledContent("NFS client statistics", value: "Enabled")
                LabeledContent("NFS mounts and server users", value: "Read only · nfsstat, nfsd status")
                LabeledContent("File-system quota", value: "Read only")
                LabeledContent("Benchmark", value: "Manual · 128 MiB maximum used")
                LabeledContent("Alert history", value: "Application Support/LumeFS · \(AlertHistoryLedger.maximumEntries) entries maximum")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 900)
        .task {
            await notifier?.refreshAuthorizationStatus()
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
