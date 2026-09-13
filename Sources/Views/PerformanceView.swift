import SwiftUI

struct PerformanceView: View {
    let store: MonitoringStore
    @AppStorage("benchmarkMebibytes") private var benchmarkMebibytes = BenchmarkGuard.defaultMebibytes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                ScreenHeader(
                    title: "I/O performance",
                    subtitle: "All devices · not attributed to a volume or a model"
                ) {
                    ProvenanceBadge(provenance: store.ioProvenance)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 32) {
                        liveMetrics
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
                        liveMetrics
                    }
                }

                if store.ioHistory.isEmpty {
                    EmptyStateView(
                        symbol: "chart.xyaxis.line",
                        title: store.isMonitoring && store.lastUpdated == nil ? "Connecting to storage" : "I/O unavailable",
                        message: "No device samples are available. Try refreshing."
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    if store.ioProvenance == .unavailable || !store.isMonitoring {
                        ProductLabel("Showing earlier samples", systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ThroughputChart(samples: store.ioHistory)
                        .frame(height: 260)
                }

                HStack {
                    ProductLabel("Counters are sampled from IOKit", systemImage: "info.circle")
                    Spacer()
                    Text("\(store.ioHistory.count) samples retained")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)

                Divider()

                benchmarkSection
                nfsSection
            }
            .padding(LayoutMetrics.pageInset)
        }
    }

    @ViewBuilder
    private var liveMetrics: some View {
        PerformanceMetric(
            title: "Read",
            value: measuredRate(store.totalReadBytesPerSecond),
            color: .blue
        )
        PerformanceMetric(
            title: "Write",
            value: measuredRate(store.totalWriteBytesPerSecond),
            color: .teal
        )
        PerformanceMetric(
            title: "Combined",
            value: measuredRate(store.totalBytesPerSecond),
            color: .primary
        )
    }

    private var benchmarkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: LayoutMetrics.rowSpacing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quick speed test")
                        .font(.headline)
                    Text("\(benchmarkMebibytes) MiB temporary file · uncached write, uncached read, cached read · removed after the test")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Size", selection: $benchmarkMebibytes) {
                    ForEach(BenchmarkGuard.selectableMebibytes, id: \.self) { size in
                        Text("\(size) MiB").tag(size)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .disabled(store.isBenchmarkRunning)
                .help("Temporary file size; the volume must have twice that amount free")
                .accessibilityLabel("Benchmark size")

                if store.isBenchmarkRunning {
                    Button {
                        store.cancelBenchmark()
                    } label: {
                        ProductLabel("Cancel", systemImage: "xmark.circle")
                    }
                    .help("Stop the benchmark; the temporary file is removed")
                } else {
                    Button {
                        store.startBenchmark(mebibytes: benchmarkMebibytes)
                    } label: {
                        ProductLabel("Run benchmark", systemImage: "speedometer")
                    }
                }
            }

            if store.isBenchmarkRunning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Benchmark running")
            }

            if let result = store.benchmarkResult {
                InsetPanel {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 32) {
                            benchmarkMetrics(result: result)
                        }

                        VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
                            benchmarkMetrics(result: result)
                        }
                    }
                    .padding(LayoutMetrics.contentSpacing)
                }

                ProductLabel(
                    benchmarkCaveat(result),
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = store.benchmarkError {
                ProductLabel(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func benchmarkCaveat(_ result: BenchmarkResult) -> String {
        let sync = result.writeUsedFullSync ? "F_FULLFSYNC" : "fsync only (F_FULLFSYNC refused)"
        return "Write bypassed the cache and was flushed with \(sync) · uncached read used F_NOCACHE on non-resident pages (drive cache may still help) · cached read is the second pass from the macOS cache · temporary file removed"
    }

    @ViewBuilder
    private func benchmarkMetrics(result: BenchmarkResult) -> some View {
        PerformanceMetric(
            title: "Uncached read",
            value: MetricFormatter.throughput(result.uncachedReadBytesPerSecond),
            color: .blue
        )
        PerformanceMetric(
            title: "Cached read",
            value: MetricFormatter.throughput(result.cachedReadBytesPerSecond),
            color: .indigo
        )
        PerformanceMetric(
            title: "Write",
            value: MetricFormatter.throughput(result.writeBytesPerSecond),
            color: .teal
        )
        VStack(alignment: .leading, spacing: 3) {
            Text("Duration")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(result.elapsedSeconds.formatted(.number.precision(.fractionLength(2))) + " s")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: 0)
        ProvenanceBadge(provenance: result.provenance)
    }

    private func measuredRate(_ value: Double) -> String {
        guard store.ioProvenance != .unavailable else { return "—" }
        return MetricFormatter.throughput(value)
    }

    private var nfsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Network storage").font(.headline)
                    Text("NFS client · cumulative counters")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProvenanceBadge(provenance: store.nfsMetrics.provenance)
            }

            if store.nfsMetrics.provenance == .unavailable {
                ProductLabel("NFS counters unavailable", systemImage: "network.slash")
                    .foregroundStyle(.secondary)
                    .help("macOS did not return NFS client statistics. Missing counters are not zero.")
            } else {
                HStack(spacing: 32) {
                    networkMetric("Requests", store.nfsMetrics.requests, symbol: "network")
                    networkMetric("Retries", store.nfsMetrics.retries, symbol: "arrow.clockwise")
                    networkMetric("Timeouts", store.nfsMetrics.timedOut, symbol: "clock.badge.exclamationmark")
                    Spacer(minLength: 0)
                }
                ProductLabel(
                    store.nfsMetrics.pNFSObserved ? "pNFS operations observed" : "No pNFS operations observed",
                    systemImage: store.nfsMetrics.pNFSObserved ? "checkmark.circle" : "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                DisclosureGroup("Counter details") {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                        nfsRow("Read operations", store.nfsMetrics.readOperations)
                        nfsRow("Write operations", store.nfsMetrics.writeOperations)
                        nfsRow("Layout gets", store.nfsMetrics.layoutGets)
                        nfsRow("Layout commits", store.nfsMetrics.layoutCommits)
                        nfsRow("Layout returns", store.nfsMetrics.layoutReturns)
                        nfsRow("Device info", store.nfsMetrics.deviceInfoRequests)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    Text("Client-wide evidence, not proof that this workload uses pNFS.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !store.nfsMounts.isEmpty {
                mountList
            }

            Divider()
            replaySection
        }
    }

    private var mountList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mounts").font(.callout.weight(.medium))
            ForEach(store.nfsMounts) { mount in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ProductIcon(systemName: mount.isResponding ? "network" : "network.slash")
                        .foregroundStyle(mount.isResponding ? Color.secondary : Color.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mount.mountPoint).font(.callout.monospaced())
                        Text("\(mount.displayServer):\(mount.displayExport) · \(mount.nfsVersion.map { "NFSv\($0)" } ?? "version not reported") · \(mount.statusLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProvenanceBadge(provenance: mount.provenance)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Per-mount throughput is not exposed by macOS; counters above are client-wide.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var replaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProductLabel("pNFS example", systemImage: "play.rectangle")
                    .font(.callout.weight(.medium))
                Spacer()
                Button(store.pNFSReplayMetrics == nil ? "Show example" : "Hide example") {
                    if store.pNFSReplayMetrics == nil {
                        store.showPNFSReplay()
                    } else {
                        store.hidePNFSReplay()
                    }
                }
            }
            Text("Bundled sample · never replaces live measurements")
                .font(.caption).foregroundStyle(.secondary)
            if let replay = store.pNFSReplayMetrics {
                InsetPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        ProvenanceBadge(provenance: .replay)
                        HStack(spacing: 32) {
                            networkMetric("Layout gets", replay.layoutGets, symbol: "square.stack.3d.up")
                            networkMetric("Device info", replay.deviceInfoRequests, symbol: "externaldrive")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
            if let error = store.pNFSReplayError {
                ProductLabel(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func networkMetric(_ title: String, _ value: UInt64, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProductLabel(title, systemImage: symbol)
                .font(.caption).foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.title2.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func nfsRow(_ label: String, _ value: UInt64) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.formatted()).monospacedDigit()
        }
    }
}

private struct PerformanceMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProductLabel(title, systemImage: symbolName)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var symbolName: String {
        if title.localizedCaseInsensitiveContains("read") { return "arrow.down" }
        if title.localizedCaseInsensitiveContains("write") { return "arrow.up" }
        return "arrow.up.arrow.down"
    }
}
