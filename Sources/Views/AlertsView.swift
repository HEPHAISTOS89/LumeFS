import SwiftUI

struct AlertsView: View {
    @Bindable var store: MonitoringStore

    var body: some View {
        HSplitView {
            List(store.alerts, selection: $store.selectedAlertID) { alert in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: alert.severity.symbolName)
                        .foregroundStyle(alert.severity.color)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(alert.title)
                            .fontWeight(.medium)
                        Text(alert.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(alert.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .tag(alert.id)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(alert.severity.label) alert, \(alert.title). \(alert.message). Observed \(alert.createdAt.formatted(date: .abbreviated, time: .shortened))"
                )
            }
            .frame(
                minWidth: LayoutMetrics.listMinimumWidth,
                idealWidth: LayoutMetrics.listIdealWidth
            )
            .overlay {
                if store.alerts.isEmpty {
                    EmptyStateView(
                        symbol: "checkmark.circle",
                        title: "No active alerts",
                        message: "LumeFS will explain capacity, device, and NFS issues here."
                    )
                }
            }

            Group {
                if let alert = store.selectedAlert {
                    AlertDetailView(store: store, alert: alert)
                } else {
                    EmptyStateView(
                        symbol: "bell",
                        title: "Select an alert",
                        message: "Choose an alert to see its evidence and recommended action."
                    )
                }
            }
            .frame(minWidth: LayoutMetrics.detailMinimumWidth)
        }
    }
}

private struct AlertDetailView: View {
    @Bindable var store: MonitoringStore
    let alert: MonitoringAlert

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: alert.severity.symbolName)
                        .font(.system(size: 28))
                        .foregroundStyle(alert.severity.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(alert.title)
                            .font(.title2.weight(.semibold))
                            .lineLimit(2)
                        Text(alert.message)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(alert.severity.label) alert. \(alert.title). \(alert.message)")

                ProvenanceBadge(provenance: alert.provenance)

                GroupBox("Evidence") {
                    Text(alert.evidence)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }

                GroupBox("Recommended next step") {
                    Label(alert.recommendation, systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }

                GroupBox("Operator actions") {
                    VStack(alignment: .leading, spacing: 10) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                actionButtons
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                actionButtons
                            }
                        }

                        Label(
                            "Actions only navigate or refresh evidence. LumeFS never deletes files, repairs disks, or changes mounts.",
                            systemImage: "hand.raised"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Rule")
                            .foregroundStyle(.secondary)
                        Text(alert.ruleID).monospaced()
                    }
                    GridRow {
                        Text("Severity")
                            .foregroundStyle(.secondary)
                        StatusLabel(severity: alert.severity, compact: true)
                    }
                    GridRow {
                        Text("Observed")
                            .foregroundStyle(.secondary)
                        Text(alert.createdAt.formatted(date: .abbreviated, time: .standard))
                    }
                }
                .accessibilityElement(children: .contain)
            }
            .padding(LayoutMetrics.pageInset)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let volumeID = alert.relatedVolumeID {
            Button {
                store.selectedVolumeID = volumeID
                store.selectedSection = .volumes
            } label: {
                Label("Inspect related volume", systemImage: "internaldrive")
            }
            .buttonStyle(.borderedProminent)
        }

        Button {
            Task { await store.refreshNow() }
        } label: {
            Label("Refresh evidence", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
    }
}
