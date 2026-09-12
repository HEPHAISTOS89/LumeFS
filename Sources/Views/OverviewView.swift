import Charts
import SwiftUI

struct OverviewView: View {
    @Bindable var store: MonitoringStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                header
                metricStrip
                readinessSection
                throughputSection
                volumeSection
                recentAlertsSection
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
                            WorkloadReadinessRow(
                                volume: volume,
                                workloadGiB: store.plannedWorkloadGiB
                            )
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
            Text("AI workload placement")
                .font(.headline)
            Text("Checks capacity for a model or checkpoint plus a 20% safety margin")
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
            StatusLabel(severity: store.overallSeverity)
        }
    }

    private var metricStrip: some View {
        InsetPanel {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    metricCells(vertical: false)
                }

                VStack(spacing: 0) {
                    metricCells(vertical: true)
                }
            }
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func metricCells(vertical: Bool) -> some View {
        MetricCell(
            title: "Current I/O",
            value: MetricFormatter.throughput(store.totalBytesPerSecond),
            detail: "Read + write",
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
            detail: store.nfsMetrics.pNFSObserved ? "pNFS observed" : "pNFS not observed",
            symbol: "network"
        )
        .frame(minHeight: vertical ? 56 : nil)
    }

    private var throughputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Block-storage throughput")
                    .font(.headline)
                Spacer()
                ProvenanceBadge(provenance: store.ioProvenance)
            }

            if store.ioHistory.isEmpty {
                ProgressView("Collecting I/O samples…")
                    .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                ThroughputChart(samples: store.ioHistory)
                    .frame(height: 220)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Volumes")
                    .font(.headline)
                Spacer()
                Button("View all") {
                    store.selectedSection = .volumes
                }
                .buttonStyle(.link)
            }

            if store.volumes.isEmpty {
                EmptyStateView(
                    symbol: "internaldrive",
                    title: "No supported volumes",
                    message: "LumeFS is waiting for an APFS or NFS volume."
                )
                .frame(minHeight: 130)
            } else {
                InsetPanel {
                    VStack(spacing: 0) {
                        ForEach(store.volumes.prefix(5)) { volume in
                            VolumeSummaryRow(volume: volume)
                            if volume.id != store.volumes.prefix(5).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var recentAlertsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent alerts")
                    .font(.headline)
                Spacer()
                if !store.alerts.isEmpty {
                    Button("View all") {
                        store.selectedSection = .alerts
                    }
                    .buttonStyle(.link)
                }
            }

            if store.alerts.isEmpty {
                InsetPanel {
                    Label("No active alerts", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .accessibilityLabel("Status: no active alerts")
                }
            } else {
                InsetPanel {
                    VStack(spacing: 0) {
                        ForEach(store.alerts.prefix(3)) { alert in
                            AlertSummaryRow(alert: alert)
                            if alert.id != store.alerts.prefix(3).last?.id {
                                Divider()
                            }
                        }
                    }
                }
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

    private var result: WorkloadReadiness {
        WorkloadReadinessCalculator().evaluate(
            volume: volume,
            workloadGibibytes: workloadGiB
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.fits ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.fits ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .fontWeight(.medium)
                Text(
                    result.fits
                        ? "Fits with \(MetricFormatter.bytes(result.headroomBytes)) left before margin"
                        : "Needs \(MetricFormatter.bytes(max(0, result.requiredBytesWithMargin - volume.availableBytes))) more free space"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(result.fits ? "Ready" : "At risk")
                .font(.callout.weight(.medium))
                .foregroundStyle(result.fits ? .green : .orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            Image(systemName: symbol)
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
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }
}

struct ThroughputChart: View {
    let samples: [DeviceIOSample]

    private var displayedSamples: ArraySlice<DeviceIOSample> {
        samples.suffix(120)
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(.separator.opacity(0.8))

            ForEach(displayedSamples) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Read bytes per second", sample.readBytesPerSecond),
                    series: .value("Direction", "Read")
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [.blue.opacity(0.22), .blue.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.linear)

                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Write bytes per second", sample.writeBytesPerSecond),
                    series: .value("Direction", "Write")
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [.teal.opacity(0.18), .teal.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Read bytes per second", sample.readBytesPerSecond),
                    series: .value("Direction", "Read")
                )
                .foregroundStyle(by: .value("Direction", "Read"))
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Write bytes per second", sample.writeBytesPerSecond),
                    series: .value("Direction", "Write")
                )
                .foregroundStyle(by: .value("Direction", "Write"))
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

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
        }
        .chartForegroundStyleScale([
            "Read": Color.blue,
            "Write": Color.teal
        ])
        .chartLegend(position: .top, alignment: .trailing, spacing: 12)
        .chartYScale(domain: .automatic(includesZero: true))
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
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisGridLine()
                    .foregroundStyle(.separator.opacity(0.35))
                AxisValueLabel(format: .dateTime.minute().second())
            }
        }
        .accessibilityLabel("Read and write throughput over time")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let latest = samples.last else {
            return "No samples"
        }

        return "Showing \(displayedSamples.count) of \(samples.count) retained samples. Latest read \(MetricFormatter.throughput(latest.readBytesPerSecond)); latest write \(MetricFormatter.throughput(latest.writeBytesPerSecond))."
    }
}

struct VolumeSummaryRow: View {
    let volume: VolumeSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: volume.fileSystem == .nfs ? "network" : "internaldrive")
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
            Image(systemName: alert.severity.symbolName)
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
