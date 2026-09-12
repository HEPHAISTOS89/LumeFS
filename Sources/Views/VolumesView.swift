import SwiftUI

struct VolumesView: View {
    @Bindable var store: MonitoringStore

    var body: some View {
        HSplitView {
            volumeList
                .frame(
                    minWidth: LayoutMetrics.listMinimumWidth,
                    idealWidth: LayoutMetrics.listIdealWidth
                )

            Group {
                if let volume = store.selectedVolume {
                    VolumeDetailView(
                        volume: volume,
                        quota: quota(for: volume),
                        samples: store.ioHistory,
                        ioProvenance: store.ioProvenance
                    )
                } else {
                    EmptyStateView(
                        symbol: "internaldrive",
                        title: "Select a volume",
                        message: "Choose a volume to inspect its capacity and file-system details."
                    )
                }
            }
            .frame(minWidth: LayoutMetrics.detailMinimumWidth)
        }
    }

    private func quota(for volume: VolumeSnapshot) -> QuotaSnapshot? {
        let exact = store.quotas.first {
            $0.mountPoint == volume.mountPoint || $0.mountPoint == volume.source
        }
        if let exact { return exact }

        return store.quotas.first {
            $0.mountPoint == "All mounted file systems"
        }
    }

    private var volumeList: some View {
        List(store.volumes, selection: $store.selectedVolumeID) { volume in
            HStack(spacing: 10) {
                Image(systemName: volume.fileSystem == .nfs ? "network" : "internaldrive")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(volume.name)
                            .fontWeight(.medium)
                        Spacer()
                        Text(volume.fileSystem.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: volume.usedFraction)
                        .tint(volume.capacityTint)
                    Text("\(MetricFormatter.bytes(volume.availableBytes)) available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .tag(volume.id)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(volume.name), \(volume.fileSystem.rawValue), \(MetricFormatter.percentage(volume.usedFraction)) used, \(MetricFormatter.bytes(volume.availableBytes)) available"
            )
        }
        .overlay {
            if store.volumes.isEmpty {
                EmptyStateView(
                    symbol: "internaldrive",
                    title: "No volumes",
                    message: "No user-visible APFS or NFS volume was found."
                )
            }
        }
    }
}

private struct VolumeDetailView: View {
    let volume: VolumeSnapshot
    let quota: QuotaSnapshot?
    let samples: [DeviceIOSample]
    let ioProvenance: DataProvenance

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                identity
                capacity
                ioChart
                quotaSection
                metadata
            }
            .padding(LayoutMetrics.pageInset)
        }
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: volume.fileSystem == .nfs ? "network" : "internaldrive")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                Text(volume.mountPoint)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            StatusLabel(severity: volume.capacitySeverity)
        }
    }

    private var capacity: some View {
        GroupBox("Capacity") {
            VStack(alignment: .leading, spacing: 10) {
                CapacityMeter(volume: volume)
                HStack {
                    Text("\(MetricFormatter.bytes(volume.usedBytes)) used")
                    Spacer()
                    Text("\(MetricFormatter.bytes(volume.availableBytes)) available")
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private var ioChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Whole-device throughput")
                        .font(.headline)
                    Text("Live block-storage counters are not attributed to this volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ProvenanceBadge(provenance: ioProvenance)
            }
            if samples.isEmpty {
                ProgressView("Collecting I/O samples…")
                    .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                ThroughputChart(samples: samples)
                    .frame(height: 190)
            }
        }
    }

    private var quotaSection: some View {
        GroupBox("Quota") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: quota?.provenance == .live ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(quota?.subject ?? "Current user")
                        .fontWeight(.medium)
                    Text(quota?.message ?? "Quota information is unavailable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let quota, let usedBytes = quota.usedBytes {
                        Text(quotaSummary(quota, usedBytes: usedBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ProvenanceBadge(provenance: quota?.provenance ?? .unavailable)
            }
            .padding(.vertical, 6)
        }
    }

    private func quotaSummary(
        _ quota: QuotaSnapshot,
        usedBytes: Int64
    ) -> String {
        let soft = quota.softLimitBytes.map(MetricFormatter.bytes) ?? "none"
        let hard = quota.hardLimitBytes.map(MetricFormatter.bytes) ?? "none"
        return "Used \(MetricFormatter.bytes(usedBytes)) · soft \(soft) · hard \(hard)"
    }

    private var metadata: some View {
        GroupBox("File-system details") {
            VStack(alignment: .leading, spacing: 10) {
                detailRow("Format", volume.fileSystemName.uppercased())
                detailRow("Source", volume.source)
                detailRow("Local", volume.isLocal ? "Yes" : "No")
                detailRow("Read only", volume.isReadOnly ? "Yes" : "No")
                detailRow("SMART", volume.smartStatus ?? "Unavailable")
                detailRow("APFS volume quota", volume.apfsVolumeQuotaBytes.map(MetricFormatter.bytes) ?? "Not configured")
                detailRow("APFS reserve", volume.apfsVolumeReserveBytes.map(MetricFormatter.bytes) ?? "Not configured")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.contentSpacing) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 132, alignment: .leading)
                Text(value)
                    .monospaced()
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .monospaced()
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
