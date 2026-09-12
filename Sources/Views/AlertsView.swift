import SwiftUI

struct AlertsView: View {
    @Bindable var store: MonitoringStore

    var body: some View {
        if store.alerts.isEmpty {
            EmptyStateView(
                symbol: store.lastUpdated == nil ? "bell" : "checkmark.circle",
                title: store.lastUpdated == nil ? "No measurements yet" : "No active alerts",
                message: store.lastUpdated == nil
                    ? "Resume monitoring or refresh to evaluate alerts."
                    : "No alert was raised from the available measurements."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            alertColumns
        }
    }

    private var alertColumns: some View {
        HStack(spacing: 0) {
            List(store.alerts, selection: $store.selectedAlertID) { alert in
                alertRow(alert)
                    .tag(alert.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(alert.severity.label). \(alert.title). \(alert.message)")
            }
            .frame(minWidth: LayoutMetrics.listMinimumWidth, idealWidth: LayoutMetrics.listIdealWidth, maxWidth: LayoutMetrics.listIdealWidth)

            Divider()

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
    private func alertRow(_ alert: MonitoringAlert) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProductIcon(systemName: alert.severity.symbolName)
                .foregroundStyle(alert.severity.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.title).fontWeight(.medium)
                Text(alert.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

}

private struct AlertDetailView: View {
    @Bindable var store: MonitoringStore
    let alert: MonitoringAlert

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                HStack(alignment: .top, spacing: 14) {
                    ProductIcon(systemName: alert.severity.symbolName)
                        .frame(width: 28, height: 28)
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Evidence").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(alert.evidence)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recommended next step").font(.headline).accessibilityAddTraits(.isHeader)
                    ProductLabel(alert.recommendation, systemImage: "arrow.right.circle")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Actions").font(.headline).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 10) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                actionButtons
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                actionButtons
                            }
                        }

                        ProductLabel(
                            "Read-only actions · no files or mounts changed",
                            systemImage: "hand.raised"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }

                DisclosureGroup("Rule details") {
                    ruleDetails
                }
            }
            .padding(LayoutMetrics.pageInset)
        }
    }

    private var ruleDetails: some View {
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

    @ViewBuilder
    private var actionButtons: some View {
        if let volumeID = alert.relatedVolumeID {
            Button {
                store.selectedVolumeID = volumeID
                store.selectedSection = .volumes
            } label: {
                ProductLabel("Inspect related volume", systemImage: "internaldrive")
            }
            .buttonStyle(.borderedProminent)
        }

        Button {
            Task { await store.refreshNow() }
        } label: {
            ProductLabel("Refresh evidence", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
    }
}
