import SwiftUI

struct VolumesView: View {
    @Bindable var store: MonitoringStore

    var body: some View {
        if store.volumes.isEmpty {
            EmptyStateView(
                symbol: "internaldrive",
                title: "No volumes",
                message: "No volume data is available. Resume monitoring or refresh to check again."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            volumeColumns
        }
    }

    private var volumeColumns: some View {
        HStack(spacing: 0) {
            volumeList
                .frame(
                    minWidth: LayoutMetrics.listMinimumWidth,
                    idealWidth: LayoutMetrics.listIdealWidth,
                    maxWidth: LayoutMetrics.listIdealWidth
                )

            Divider()

            Group {
                if let volume = store.selectedVolume {
                    VolumeDetailView(
                        volume: volume,
                        quota: quota(for: volume),
                        nfsMount: store.nfsMount(for: volume),
                        showPerformance: { store.selectedSection = .performance }
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
            volumeRow(volume)
                .tag(volume.id)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(volume.name), \(volume.fileSystem.rawValue), \(MetricFormatter.bytes(volume.availableBytes)) available")
        }
    }

    private func volumeRow(_ volume: VolumeSnapshot) -> some View {
        HStack(spacing: 10) {
            ProductIcon(systemName: volume.fileSystem == .nfs ? "network" : "internaldrive")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(volume.name).fontWeight(.medium)
                    Spacer()
                    Text(volume.fileSystem.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
                CapacityMeter(volume: volume)
                Text("\(MetricFormatter.bytes(volume.availableBytes)) available")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

}

private struct VolumeDetailView: View {
    let volume: VolumeSnapshot
    let quota: QuotaSnapshot?
    let nfsMount: NFSMountInfo?
    let showPerformance: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                identity
                capacity
                if volume.fileSystem == .nfs {
                    nfsMountSection
                }
                quotaSection
                Button(action: showPerformance) {
                    ProductLabel("View all-device I/O", systemImage: "chart.xyaxis.line")
                }
                .help("Device throughput cannot be attributed to this volume.")
                metadata
            }
            .padding(LayoutMetrics.pageInset)
        }
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 14) {
            ProductIcon(systemName: volume.fileSystem == .nfs ? "network" : "internaldrive")
                .frame(width: 28, height: 28)
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
            CapacityStatusView(volume: volume)
        }
    }

    private var capacity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capacity").font(.headline).accessibilityAddTraits(.isHeader)
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

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current-user quota").font(.headline).accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 10) {
                ProductIcon(systemName: quota?.provenance == .live ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(quota?.subject ?? "Current user")
                        .fontWeight(.medium)
                    if let quota, let severity = quota.limitSeverity {
                        ProductLabel(severity == .critical ? "Hard limit reached" : "Soft limit reached", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(severity == .critical ? Color.red : Color.orange)
                    }
                    if let quota, let usedBytes = quota.usedBytes {
                        Text(quotaSummary(quota, usedBytes: usedBytes))
                            .font(.callout.monospacedDigit())
                    } else {
                        Text(quota?.provenance == .live ? "No structured limits reported" : "No quota data available")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let quota {
                        DisclosureGroup("Source details") {
                            Text(quota.message)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        }
                    }
                }
                Spacer()
                ProvenanceBadge(provenance: quota?.provenance ?? .unavailable)
            }
            .padding(.vertical, 6)
        }
    }

    private var nfsMountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NFS mount").font(.headline).accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 10) {
                ProductIcon(systemName: nfsMountSymbol)
                    .foregroundStyle(nfsMountTint)
                VStack(alignment: .leading, spacing: 8) {
                    Text(nfsMount?.statusLabel ?? "Not queried yet")
                        .fontWeight(.medium)
                        .foregroundStyle(nfsMountTint)
                    if let nfsMount, nfsMount.provenance == .live {
                        VStack(alignment: .leading, spacing: 6) {
                            detailRow("Server", nfsMount.displayServer)
                            detailRow("Export", nfsMount.displayExport)
                            detailRow("Version", nfsMount.nfsVersion.map { "NFSv\($0)" } ?? "Not reported")
                            detailRow("Transport", nfsMount.transport?.uppercased() ?? "Not reported")
                            if !nfsMount.addresses.isEmpty {
                                detailRow("Addresses", nfsMount.addresses.joined(separator: ", "))
                            }
                        }
                        if !nfsMount.parameters.isEmpty || !nfsMount.mountFlags.isEmpty {
                            DisclosureGroup("Mount parameters") {
                                Text((nfsMount.mountFlags + nfsMount.parameters).joined(separator: ", "))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .padding(.top, 4)
                            }
                        }
                    } else {
                        Text(nfsMount?.message ?? "Mount parameters are read from nfsstat every 10 s.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("Status flags come from the kernel (dead, not responding, recovery). Throughput is not attributable per mount on macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ProvenanceBadge(provenance: nfsMount?.provenance ?? .unavailable)
            }
            .padding(.vertical, 6)
        }
    }

    private var nfsMountSymbol: String {
        guard let nfsMount, nfsMount.provenance == .live else { return "network.badge.shield.half.filled" }
        if nfsMount.isDead || nfsMount.isNotResponding { return "network.slash" }
        if nfsMount.inRecovery { return "arrow.triangle.2.circlepath" }
        return "network"
    }

    private var nfsMountTint: Color {
        guard let nfsMount, nfsMount.provenance == .live else { return .secondary }
        if nfsMount.isDead || nfsMount.isNotResponding { return .red }
        if nfsMount.inRecovery { return .orange }
        return .primary
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
        DisclosureGroup("File-system details") {
            VStack(alignment: .leading, spacing: 10) {
                detailRow("Format", volume.fileSystemName.uppercased())
                detailRow("Source", volume.source)
                detailRow("Local", volume.isLocal ? "Yes" : "No")
                detailRow("Read only", volume.isReadOnly ? "Yes" : "No")
                detailRow("SMART", volume.smartStatus == nil ? "Unavailable" : volume.smartAssessment.label)
                if volume.fileSystem == .apfs {
                    detailRow("APFS volume quota", volume.apfsVolumeQuotaBytes.map(MetricFormatter.bytes) ?? "Not reported")
                    detailRow("APFS reserve", volume.apfsVolumeReserveBytes.map(MetricFormatter.bytes) ?? "Not reported")
                }
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
