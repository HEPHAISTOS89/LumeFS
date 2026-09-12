import SwiftUI

struct AppShellView: View {
    @Bindable var store: MonitoringStore

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $store.selectedSection) { section in
                Label {
                    Text(section.rawValue)
                } icon: {
                    Image(section.navigationAsset)
                        .renderingMode(.template)
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
                    if #available(macOS 26.0, *) {
                        statusItem.sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    } else {
                        statusItem
                    }
                    monitoringActions
                }
        }
        .task {
            store.start()
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
        case .activity:
            ActivityView(store: store)
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
