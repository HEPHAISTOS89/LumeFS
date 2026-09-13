import SwiftUI

@main
struct LumeFSApp: App {
    @AppStorage("appearancePreference") private var appearancePreference = "system"
    @State private var store = MonitoringStore.forApplication()

    var body: some Scene {
        WindowGroup {
            AppShellView(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(AppAppearance.resolve(appearancePreference).colorScheme)
        }
        .defaultSize(width: 1_240, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export Snapshot as JSON…") {
                    SnapshotExportCoordinator.export(from: store, format: .json)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.lastUpdated == nil)
                Button("Export Snapshot as CSV…") {
                    SnapshotExportCoordinator.export(from: store, format: .csv)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift, .option])
                .disabled(store.lastUpdated == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh Now") {
                    Task { await store.refreshNow() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                Divider()
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button("Show \(section.rawValue)") {
                        store.selectedSection = section
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                }
            }
        }

        Settings {
            SettingsView(notifier: store.criticalAlertNotifier)
                .preferredColorScheme(AppAppearance.resolve(appearancePreference).colorScheme)
        }
    }
}
