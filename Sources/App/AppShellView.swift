import SwiftUI

struct AppShellView: View {
    @Bindable var store: MonitoringStore

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $store.selectedSection) { section in
                Label(section.rawValue, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            .navigationTitle("LumeFS")
        } detail: {
            destination
                .navigationTitle(store.selectedSection?.rawValue ?? "LumeFS")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        CollectionStatusView(
                            isMonitoring: store.isMonitoring,
                            lastUpdated: store.lastUpdated
                        )

                        Button {
                            Task { await store.refreshNow() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh now (⌘R)")

                        Button {
                            store.isMonitoring ? store.stop() : store.start()
                        } label: {
                            Label(
                                store.isMonitoring ? "Pause" : "Resume",
                                systemImage: store.isMonitoring ? "pause.fill" : "play.fill"
                            )
                        }
                        .help(store.isMonitoring ? "Pause monitoring" : "Resume monitoring")
                    }
                }
        }
        .task {
            store.start()
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
        HStack(spacing: 6) {
            Circle()
                .fill(isMonitoring ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            if let lastUpdated {
                Text(lastUpdated, style: .relative)
            } else {
                Text("Starting…")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isMonitoring ? "Monitoring active" : "Monitoring paused"
        )
    }
}
