import SwiftUI

@main
struct LumeFSApp: App {
    @State private var store = MonitoringStore()

    var body: some Scene {
        WindowGroup {
            AppShellView(store: store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1_240, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Refresh Now") {
                    Task { await store.refreshNow() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
