import SwiftUI

struct PerformanceView: View {
    let store: MonitoringStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                ScreenHeader(
                    title: "I/O performance",
                    subtitle: "Live block-storage throughput across whole devices"
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
                    ProgressView("Collecting I/O samples…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ThroughputChart(samples: store.ioHistory)
                        .frame(height: 260)
                }

                HStack {
                    Label("Counters are sampled from IOKit", systemImage: "info.circle")
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
            value: MetricFormatter.throughput(store.totalReadBytesPerSecond),
            color: .blue
        )
        PerformanceMetric(
            title: "Write",
            value: MetricFormatter.throughput(store.totalWriteBytesPerSecond),
            color: .teal
        )
        PerformanceMetric(
            title: "Combined",
            value: MetricFormatter.throughput(store.totalBytesPerSecond),
            color: .primary
        )
    }

    private var benchmarkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Controlled benchmark")
                        .font(.headline)
                    Text("128 MiB, app-owned temporary file, automatic cleanup")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.runBenchmark() }
                } label: {
                    if store.isBenchmarkRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Run benchmark", systemImage: "speedometer")
                    }
                }
                .disabled(store.isBenchmarkRunning)
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

                Label(
                    "Synchronized write · immediate read may use the macOS cache · temporary file removed",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let error = store.benchmarkError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func benchmarkMetrics(result: BenchmarkResult) -> some View {
        PerformanceMetric(
            title: "Benchmark read",
            value: MetricFormatter.throughput(result.readBytesPerSecond),
            color: .blue
        )
        PerformanceMetric(
            title: "Benchmark write",
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

    private var nfsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NFS client and pNFS")
                    .font(.headline)
                Spacer()
                ProvenanceBadge(provenance: store.nfsMetrics.provenance)
            }

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                nfsRow("RPC requests", store.nfsMetrics.requests)
                nfsRow("Retries", store.nfsMetrics.retries)
                nfsRow("Timed out", store.nfsMetrics.timedOut)
                nfsRow("Read operations", store.nfsMetrics.readOperations)
                nfsRow("Write operations", store.nfsMetrics.writeOperations)
                nfsRow("pNFS layout gets", store.nfsMetrics.layoutGets)
                nfsRow("pNFS layout commits", store.nfsMetrics.layoutCommits)
                nfsRow("pNFS device info", store.nfsMetrics.deviceInfoRequests)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Label(
                store.nfsMetrics.pNFSObserved
                    ? "pNFS layout activity has been observed on this client."
                    : "No pNFS layout activity has been observed on this client.",
                systemImage: store.nfsMetrics.pNFSObserved ? "checkmark.circle" : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                if let replay = store.pNFSReplayMetrics {
                    Button("Hide replay") {
                        store.hidePNFSReplay()
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Text(
                        "Replay evidence: \(replay.layoutGets) layout gets · \(replay.deviceInfoRequests) device-info requests"
                    )
                    .font(.caption.monospacedDigit())
                    ProvenanceBadge(provenance: .replay)
                } else {
                    Button("Preview deterministic pNFS evidence") {
                        store.showPNFSReplay()
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Text("Does not replace live counters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = store.pNFSReplayError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func nfsRow(_ label: String, _ value: UInt64) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .monospacedDigit()
        }
    }
}

private struct PerformanceMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbolName)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var symbolName: String {
        if title.localizedCaseInsensitiveContains("read") { return "arrow.down" }
        if title.localizedCaseInsensitiveContains("write") { return "arrow.up" }
        return "arrow.up.arrow.down"
    }
}
