import SwiftUI

@main
struct LumeFSApp: App {
    @AppStorage("appearancePreference") private var appearancePreference = "system"
    @State private var store = MonitoringStore()

    var body: some Scene {
        WindowGroup {
            AppShellView(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(AppAppearance.resolve(appearancePreference).colorScheme)
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
                .preferredColorScheme(AppAppearance.resolve(appearancePreference).colorScheme)
        }
    }
}
