import SwiftUI

struct AppShellView: View {
    @Bindable var store: MonitoringStore

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $store.selectedSection) { section in
                Label {
                    Text(section.rawValue)
                } icon: {
                    Image(systemName: section.symbolName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            .navigationTitle("LumeFS")
        } detail: {
            destination
                .navigationTitle(store.selectedSection?.rawValue ?? "LumeFS")
                .toolbar {
                    // `ToolbarSpacer` and `sharedBackgroundVisibility` exist only in the
                    // macOS 26 SDK (Swift 6.2 toolchain). The compiler check keeps the
                    // project buildable with Xcode 16 while the runtime check keeps the
                    // Liquid Glass grouping on macOS 26 hosts.
                    #if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        statusItem.sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    } else {
                        statusItem
                    }
                    #else
                    statusItem
                    #endif
                    monitoringActions
                }
        }
        .task {
            store.start()
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { store.exportError != nil },
                set: { if !$0 { store.dismissExportError() } }
            ),
            presenting: store.exportError
        ) { _ in
            Button("OK") { store.dismissExportError() }
        } message: { error in
            Text(error)
        }
    }

    private var statusItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            CollectionStatusView(isMonitoring: store.isMonitoring, lastUpdated: store.lastUpdated)
        }
    }

    private var monitoringActions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await store.refreshNow() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh now (⌘R)")
            .disabled(store.isRefreshing)

            Button {
                store.isMonitoring ? store.stop() : store.start()
            } label: {
                Label(store.isMonitoring ? "Pause" : "Resume",
                      systemImage: store.isMonitoring ? "pause" : "play")
            }
            .help(store.isMonitoring ? "Pause monitoring" : "Resume monitoring")

            Menu {
                Button("Export Snapshot as JSON…") {
                    SnapshotExportCoordinator.export(from: store, format: .json)
                }
                Button("Export Snapshot as CSV…") {
                    SnapshotExportCoordinator.export(from: store, format: .csv)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the current snapshot and alert history (⇧⌘E)")
            .disabled(store.lastUpdated == nil)
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch store.selectedSection ?? .overview {
        case .overview:
            OverviewView(store: store)
        case .volumes:
            VolumesView(store: store)
        case .performance:
            PerformanceView(store: store)
        case .attribution:
            AttributionView(store: store)
        case .activity:
            ActivityView(store: store)
        case .placement:
            PlacementView(store: store)
        case .alerts:
            AlertsView(store: store)
        }
    }
}

private struct CollectionStatusView: View {
    let isMonitoring: Bool
    let lastUpdated: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = CollectionFreshness.evaluate(
                isMonitoring: isMonitoring,
                lastUpdated: lastUpdated,
                now: context.date
            )
            HStack(spacing: 6) {
                Image(systemName: symbol(for: status))
                    .foregroundStyle(color(for: status))
                    .accessibilityHidden(true)
                Text(status.rawValue)
                if status == .delayed, let lastUpdated {
                    Text(lastUpdated, style: .relative)
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(lastUpdated.map {
                "Last snapshot: \($0.formatted(date: .omitted, time: .standard))"
            } ?? "Waiting for the first snapshot")
            .accessibilityElement(children: .combine)
        }
    }

    private func symbol(for status: CollectionFreshness) -> String {
        switch status {
        case .current: "checkmark.circle"
        case .delayed: "exclamationmark.clock"
        case .connecting: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        }
    }

    private func color(for status: CollectionFreshness) -> Color {
        switch status {
        case .current: .green
        case .delayed: .orange
        case .connecting, .paused: .secondary
        }
    }
}
