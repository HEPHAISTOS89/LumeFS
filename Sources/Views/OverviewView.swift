import Charts
import SwiftUI

struct OverviewView: View {
    @Bindable var store: MonitoringStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                header
                attentionSection
                metricStrip
                readinessSection
                throughputSection
            }
            .padding(LayoutMetrics.pageInset)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.contentSpacing) {
                    readinessTitle
                    Spacer()
                    readinessControls
                }

                VStack(alignment: .leading, spacing: LayoutMetrics.compactSpacing) {
                    readinessTitle
                    HStack {
                        Spacer()
                        readinessControls
                    }
                }
            }

            if store.volumes.isEmpty {
                Text("Waiting for volume capacity data…")
                    .foregroundStyle(.secondary)
            } else {
                InsetPanel {
                    VStack(spacing: 0) {
                        ForEach(store.volumes) { volume in
                            Button {
                                store.selectedVolumeID = volume.id
                                store.selectedSection = .volumes
                            } label: {
                                WorkloadReadinessRow(
                                    volume: volume,
                                    workloadGiB: store.plannedWorkloadGiB,
                                    quota: store.quotas.first { $0.applies(to: volume) }
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Inspect \(volume.name)")
                            if volume.id != store.volumes.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var readinessTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Where will it fit?")
                .font(.headline)
            Text("Model or checkpoint · includes 20% extra space")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var readinessControls: some View {
        HStack(spacing: LayoutMetrics.compactSpacing) {
            Picker("Workload size", selection: $store.plannedWorkloadGiB) {
                ForEach([8, 16, 32, 64, 128], id: \.self) { size in
                    Text("\(size) GiB").tag(size)
                }
            }
            .pickerStyle(.menu)
            .accessibilityValue("\(store.plannedWorkloadGiB) gibibytes")
            ProvenanceBadge(provenance: .estimate)
        }
    }

    private var header: some View {
        ScreenHeader(
            title: "Storage overview",
            subtitle: "\(store.volumes.count) volume\(store.volumes.count == 1 ? "" : "s") monitored · \(store.alerts.count) active alert\(store.alerts.count == 1 ? "" : "s")"
        ) {
            if store.lastUpdated == nil {
                Text(store.isMonitoring ? "Connecting…" : "Not collecting").foregroundStyle(.secondary)
            } else {
                Text("On this Mac").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var metricStrip: some View {
        InsetPanel {
            HStack(spacing: 0) {
                metricCells(vertical: false)
            }
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func metricCells(vertical: Bool) -> some View {
        MetricCell(
            title: "Current I/O",
            value: store.ioProvenance == .unavailable ? "—" : MetricFormatter.throughput(store.totalBytesPerSecond),
            detail: store.ioProvenance == .unavailable ? "Unavailable" : "All devices · read + write",
            symbol: "arrow.up.arrow.down"
        )
        Divider()
            .frame(height: vertical ? nil : 56)
        MetricCell(
            title: "Lowest free space",
            value: capacityRiskValue,
            detail: "Across monitored volumes",
            symbol: "internaldrive"
        )
        Divider()
            .frame(height: vertical ? nil : 56)
        MetricCell(
            title: "NFS retries",
            value: store.nfsMetrics.provenance == .live ? "\(store.nfsMetrics.retries)" : "—",
            detail: store.nfsMetrics.provenance == .unavailable ? "Unavailable" : "Client total · cumulative",
            symbol: "network"
        )
        .frame(minHeight: vertical ? 56 : nil)
    }

    private var throughputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Read & write")
                    .font(.headline)
                Spacer()
                ProvenanceBadge(provenance: store.ioProvenance)
            }

            if store.ioHistory.isEmpty {
                EmptyStateView(
                    symbol: "chart.xyaxis.line",
                    title: store.isMonitoring && store.lastUpdated == nil ? "Connecting to storage" : "I/O unavailable",
                    message: "Device samples will appear here when available."
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ThroughputChart(samples: store.ioHistory)
                    .frame(height: 190)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var attentionSection: some View {
        Group {
            if let alert = store.alerts.first {
                Button {
                    store.selectedAlertID = alert.id
                    store.selectedSection = .alerts
                } label: {
                    HStack(spacing: 12) {
                        ProductIcon(systemName: alert.severity.symbolName)
                            .font(.title2)
                            .foregroundStyle(alert.severity.color)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(alert.title).font(.headline)
                            Text(alert.message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProductLabel("Inspect", systemImage: "chevron.right")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                    .padding(16)
                    .background(alert.severity.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the evidence and next step for this alert")
            } else if store.lastUpdated != nil {
                ProductLabel("No active alerts in collected data", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var capacityRiskValue: String {
        guard let lowest = store.volumes.min(by: { $0.availableFraction < $1.availableFraction }) else {
            return "—"
        }
        return MetricFormatter.percentage(lowest.availableFraction)
    }
}

private struct WorkloadReadinessRow: View {
    let volume: VolumeSnapshot
    let workloadGiB: Int
    let quota: QuotaSnapshot?

    private var result: WorkloadReadiness {
        WorkloadReadinessCalculator().evaluate(
            volume: volume,
            workloadGibibytes: workloadGiB,
            quota: quota
        )
    }

    private var status: String {
        if volume.isReadOnly { return "Read only" }
        if volume.totalBytes <= 0 { return "Unknown" }
        if result.quotaLimited && !result.fits { return "Quota limited" }
        return result.fits ? "Capacity fits" : "Too large"
    }

    private var symbol: String {
        if volume.isReadOnly { return "lock" }
        if volume.totalBytes <= 0 { return "questionmark.circle" }
        return result.fits ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var statusColor: Color {
        if volume.isReadOnly || volume.totalBytes <= 0 { return .secondary }
        return result.fits ? .green : .orange
    }

    private var detail: String {
        if volume.isReadOnly { return "Read-only volume · cannot receive files" }
        if volume.totalBytes <= 0 { return "Capacity unavailable" }
        if result.quotaLimited {
            return "\(MetricFormatter.bytes(result.availableBytes)) within user quota · soft limit treated conservatively"
        }
        if result.fits {
            return "\(MetricFormatter.bytes(max(0, volume.availableBytes - result.requiredBytesWithMargin))) spare after margin"
        }
        return "Needs \(MetricFormatter.bytes(max(0, result.requiredBytesWithMargin - volume.availableBytes))) more"
    }

    var body: some View {
        HStack(spacing: 12) {
            ProductIcon(systemName: volume.fileSystem == .nfs ? "network" : "internaldrive")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(volume.name).fontWeight(.medium)
                    Text(volume.fileSystem.rawValue)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                ProductLabel(status, systemImage: symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(statusColor)
                Text("\(MetricFormatter.bytes(volume.availableBytes)) free")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProductIcon(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MetricCell: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            ProductIcon(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value). \(detail)")
    }
}

struct ThroughputChart: View {
    let samples: [DeviceIOSample]
    @State private var selectedTimestamp: Date?

    private var displayedSamples: ArraySlice<DeviceIOSample> {
        samples.suffix(120)
    }

    private var selectedSample: DeviceIOSample? {
        guard let selectedTimestamp,
              let first = displayedSamples.first,
              let last = displayedSamples.last,
              (first.timestamp...last.timestamp).contains(selectedTimestamp) else { return nil }
        return displayedSamples.min {
            abs($0.timestamp.timeIntervalSince(selectedTimestamp)) < abs($1.timestamp.timeIntervalSince(selectedTimestamp))
        }
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(.separator.opacity(0.8))

            ForEach(IOChartPoint.make(from: Array(displayedSamples))) { point in
                let sample = point.sample
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Read bytes per second", sample.readBytesPerSecond),
                    series: .value("Read segment", "Read \(point.segment)")
                )
                .foregroundStyle(by: .value("Direction", "Read"))
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Write bytes per second", sample.writeBytesPerSecond),
                    series: .value("Write segment", "Write \(point.segment)")
                )
                .foregroundStyle(by: .value("Direction", "Write"))
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 3]))

                if sample.id == displayedSamples.last?.id {
                    PointMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Latest read", sample.readBytesPerSecond)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(34)

                    PointMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Latest write", sample.writeBytesPerSecond)
                    )
                    .foregroundStyle(.teal)
                    .symbolSize(34)
                }
            }

            if let selectedSample {
                RuleMark(x: .value("Selected time", selectedSample.timestamp))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedSample.timestamp, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                            Text("Read \(MetricFormatter.throughput(selectedSample.readBytesPerSecond))")
                                .foregroundStyle(.blue)
                            Text("Write \(MetricFormatter.throughput(selectedSample.writeBytesPerSecond))")
                                .foregroundStyle(.teal)
                        }
                        .font(.caption2.monospacedDigit())
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }

                PointMark(
                    x: .value("Selected time", selectedSample.timestamp),
                    y: .value("Selected read", selectedSample.readBytesPerSecond)
                )
                .foregroundStyle(.blue)
                .symbolSize(48)

                PointMark(
                    x: .value("Selected time", selectedSample.timestamp),
                    y: .value("Selected write", selectedSample.writeBytesPerSecond)
                )
                .foregroundStyle(.teal)
                .symbolSize(48)
            }
        }
        .chartForegroundStyleScale([
            "Read": Color.blue,
            "Write": Color.teal
        ])
        .chartLegend(position: .top, alignment: .trailing, spacing: 12)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXScale(range: .plotDimension(startPadding: 8, endPadding: 24))
        .chartXSelection(value: $selectedTimestamp)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let frame = geometry[plotFrame]
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                guard frame.contains(location) else { return }
                                selectedTimestamp = proxy.value(atX: location.x - frame.minX)
                            case .ended:
                                selectedTimestamp = nil
                            }
                        }
                        .simultaneousGesture(
                            SpatialTapGesture().onEnded { value in
                                guard frame.contains(value.location) else { return }
                                selectedTimestamp = proxy.value(atX: value.location.x - frame.minX)
                            }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0).onChanged { value in
                                guard frame.contains(value.location) else { return }
                                selectedTimestamp = proxy.value(atX: value.location.x - frame.minX)
                            }
                        )
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(.quaternary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                    .foregroundStyle(.separator.opacity(0.45))
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(MetricFormatter.throughput(bytes))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                    .foregroundStyle(.separator.opacity(0.35))
                AxisValueLabel(anchor: .topTrailing) {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.minute().second())
                            .fixedSize()
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Read and write throughput over time")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let latest = samples.last else {
            return "No samples"
        }

        let selected = selectedSample.map {
            " Selected read \(MetricFormatter.throughput($0.readBytesPerSecond)); selected write \(MetricFormatter.throughput($0.writeBytesPerSecond))."
        } ?? ""
        return "Showing \(displayedSamples.count) of \(samples.count) retained samples. Latest read \(MetricFormatter.throughput(latest.readBytesPerSecond)); latest write \(MetricFormatter.throughput(latest.writeBytesPerSecond)).\(selected)"
    }
}

struct VolumeSummaryRow: View {
    let volume: VolumeSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ProductIcon(systemName: volume.fileSystem == .nfs ? "network" : "internaldrive")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .fontWeight(.medium)
                Text(volume.mountPoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(volume.fileSystem.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            CapacityMeter(volume: volume, width: 100)
            Text(MetricFormatter.percentage(volume.usedFraction))
                .font(.callout.monospacedDigit())
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(volume.name), \(volume.fileSystem.rawValue), \(MetricFormatter.percentage(volume.usedFraction)) used, \(MetricFormatter.bytes(volume.availableBytes)) available")
    }
}

struct AlertSummaryRow: View {
    let alert: MonitoringAlert

    var body: some View {
        HStack(spacing: 12) {
            ProductIcon(systemName: alert.severity.symbolName)
                .foregroundStyle(alert.severity.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .fontWeight(.medium)
                Text(alert.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            ProvenanceBadge(provenance: alert.provenance)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
