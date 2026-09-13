import SwiftUI

struct AlertsView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case active = "Active"
        case history = "History"
        var id: String { rawValue }
    }

    @Bindable var store: MonitoringStore
    @State private var scope: Scope = .active
    @State private var selectedHistoryID: String?
    @State private var isConfirmingClear = false

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(minWidth: LayoutMetrics.listMinimumWidth, idealWidth: LayoutMetrics.listIdealWidth, maxWidth: LayoutMetrics.listIdealWidth)

            Divider()

            detailColumn
                .frame(minWidth: LayoutMetrics.detailMinimumWidth)
        }
        .onChange(of: store.alertHistory) { _, entries in
            if !entries.contains(where: { $0.id == selectedHistoryID }) {
                selectedHistoryID = entries.first?.id
            }
        }
        .onChange(of: scope) { _, scope in
            if scope == .history, selectedHistoryID == nil {
                selectedHistoryID = store.alertHistory.first?.id
            }
        }
    }

    // MARK: List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            Picker("Scope", selection: $scope) {
                Text("Active (\(store.alerts.count))").tag(Scope.active)
                Text("History (\(store.alertHistory.count))").tag(Scope.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, LayoutMetrics.rowSpacing)
            .padding(.vertical, LayoutMetrics.compactSpacing)
            .accessibilityLabel("Alert scope")

            Divider()

            switch scope {
            case .active:
                activeList
            case .history:
                historyList
            }
        }
    }

    @ViewBuilder
    private var activeList: some View {
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
            List(store.alerts, selection: $store.selectedAlertID) { alert in
                alertRow(alert, entry: store.historyEntry(forAlertID: alert.id))
                    .tag(alert.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(alert.severity.label). \(alert.title). \(alert.message)")
            }
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if store.alertHistory.isEmpty {
            EmptyStateView(
                symbol: "clock.arrow.circlepath",
                title: "No alert history",
                message: "Raised, acknowledged and cleared alerts are kept here across launches."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(store.alertHistory, selection: $selectedHistoryID) { entry in
                historyRow(entry)
                    .tag(entry.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(entry.state.label). \(entry.alert.severity.label). \(entry.alert.title). Raised \(entry.raisedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            historyFooter
        }
    }

    private var historyFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: LayoutMetrics.compactSpacing) {
                Text("\(store.alertHistory.count) of \(AlertHistoryLedger.maximumEntries) · \(store.openAlertHistory.count) open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Clear Closed…") {
                    isConfirmingClear = true
                }
                .controlSize(.small)
                .disabled(store.alertHistory.count == store.openAlertHistory.count)
                .help("Remove cleared entries from the local history; open alerts are kept")
                .confirmationDialog(
                    "Remove cleared alerts from the history?",
                    isPresented: $isConfirmingClear,
                    titleVisibility: .visible
                ) {
                    Button("Remove Cleared Entries", role: .destructive) {
                        store.clearClosedAlertHistory()
                    }
                } message: {
                    Text("Only LumeFS's local alert history file changes. Active and acknowledged alerts stay.")
                }
            }
            if let error = store.alertHistoryError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, LayoutMetrics.rowSpacing)
        .padding(.bottom, LayoutMetrics.compactSpacing)
    }

    private func alertRow(_ alert: MonitoringAlert, entry: AlertHistoryEntry?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProductIcon(systemName: alert.severity.symbolName)
                .foregroundStyle(alert.severity.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(alert.title).fontWeight(.medium)
                    if entry?.acknowledgedAt != nil {
                        lifecycleBadge(.acknowledged)
                    }
                }
                Text(alert.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func historyRow(_ entry: AlertHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProductIcon(systemName: entry.alert.severity.symbolName)
                .foregroundStyle(entry.isOpen ? entry.alert.severity.color : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.alert.title).fontWeight(.medium)
                    lifecycleBadge(entry.state)
                }
                Text(historyCaption(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func historyCaption(_ entry: AlertHistoryEntry) -> String {
        var parts = ["Raised \(entry.raisedAt.formatted(date: .abbreviated, time: .shortened))"]
        if let cleared = entry.clearedAt {
            parts.append("cleared \(cleared.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func lifecycleBadge(_ state: AlertLifecycleState) -> some View {
        Text(state.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Lifecycle: \(state.label)")
    }

    // MARK: Detail column

    @ViewBuilder
    private var detailColumn: some View {
        switch scope {
        case .active:
            if let alert = store.selectedAlert {
                AlertDetailView(store: store, alert: alert, entry: store.historyEntry(forAlertID: alert.id))
            } else {
                EmptyStateView(
                    symbol: "bell",
                    title: "Select an alert",
                    message: "Choose an alert to see its evidence and recommended action."
                )
            }
        case .history:
            if let entry = store.alertHistory.first(where: { $0.id == selectedHistoryID }) {
                AlertDetailView(store: store, alert: entry.alert, entry: entry)
            } else {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "Select a history entry",
                    message: "Each entry keeps the evidence as it was when the alert was last observed."
                )
            }
        }
    }
}

private struct AlertDetailView: View {
    @Bindable var store: MonitoringStore
    let alert: MonitoringAlert
    let entry: AlertHistoryEntry?

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

                HStack(spacing: LayoutMetrics.compactSpacing) {
                    ProvenanceBadge(provenance: alert.provenance)
                    if let entry {
                        Text(entry.state.label)
                            .font(.system(.caption2, design: .monospaced, weight: .semibold))
                            .tracking(0.4)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(entry.isOpen ? .primary : .secondary)
                            .accessibilityLabel("Lifecycle: \(entry.state.label)")
                    }
                }

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

                if let entry {
                    DisclosureGroup("Lifecycle") {
                        lifecycleDetails(entry)
                    }
                }

                DisclosureGroup("Rule details") {
                    ruleDetails
                }
            }
            .padding(LayoutMetrics.pageInset)
        }
    }

    private func lifecycleDetails(_ entry: AlertHistoryEntry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("State").foregroundStyle(.secondary)
                Text(entry.state.label)
            }
            GridRow {
                Text("Raised").foregroundStyle(.secondary)
                Text(entry.raisedAt.formatted(date: .abbreviated, time: .standard))
            }
            GridRow {
                Text("Last seen").foregroundStyle(.secondary)
                Text(entry.lastSeenAt.formatted(date: .abbreviated, time: .standard))
            }
            GridRow {
                Text("Acknowledged").foregroundStyle(.secondary)
                Text(entry.acknowledgedAt?.formatted(date: .abbreviated, time: .standard) ?? "—")
            }
            GridRow {
                Text("Cleared").foregroundStyle(.secondary)
                Text(entry.clearedAt?.formatted(date: .abbreviated, time: .standard) ?? "—")
            }
            GridRow {
                Text("Stored in").foregroundStyle(.secondary)
                Text(store.alertHistoryFileURL.map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent } ?? "This session only")
                    .monospaced()
            }
        }
        .accessibilityElement(children: .contain)
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

    private var canAcknowledge: Bool {
        guard let entry else { return false }
        return entry.isOpen && entry.acknowledgedAt == nil
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let entry, canAcknowledge {
            Button {
                store.acknowledgeAlert(entryID: entry.id)
            } label: {
                ProductLabel("Acknowledge", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .help("Record that someone looked at this alert; it stays active until its rule stops firing")
        }

        if let volumeID = alert.relatedVolumeID {
            let inspect = Button {
                store.selectedVolumeID = volumeID
                store.selectedSection = .volumes
            } label: {
                ProductLabel("Inspect related volume", systemImage: "internaldrive")
            }
            if canAcknowledge {
                inspect.buttonStyle(.bordered)
            } else {
                inspect.buttonStyle(.borderedProminent)
            }
        }

        Button {
            Task { await store.refreshNow() }
        } label: {
            ProductLabel("Refresh evidence", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
    }
}
