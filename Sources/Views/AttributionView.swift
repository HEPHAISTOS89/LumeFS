import SwiftUI

/// Who is generating storage activity: local processes (libproc) and NFS users
/// seen by the local nfsd. Every figure here is attributed by the kernel, never
/// inferred by LumeFS.
struct AttributionView: View {
    let store: MonitoringStore
    @AppStorage("showFullNFSClientAddresses") private var showFullAddresses = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                ScreenHeader(
                    title: "Attribution",
                    subtitle: "Which processes and users drive storage activity · kernel-reported, not inferred"
                )

                processSection
                Divider()
                nfsUsersSection
            }
            .padding(LayoutMetrics.pageInset)
        }
    }

    // MARK: - Local processes

    private var processSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local processes").font(.headline)
                    Text("proc_pid_rusage disk bytes · deltas over the last 2 s · name and PID only")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProvenanceBadge(provenance: store.processIO.provenance)
            }

            if store.processIO.provenance != .live {
                unavailablePanel(
                    symbol: "cpu",
                    title: "Per-process disk I/O unavailable",
                    message: store.processIO.message ?? "Process counters could not be read."
                )
            } else {
                processCoverage

                if store.processIO.samples.isEmpty {
                    unavailablePanel(
                        symbol: "cpu",
                        title: "No process disk I/O in the last interval",
                        message: "None of the \(store.processIO.readableProcessCount) readable processes read or wrote to disk since the previous sample."
                    )
                } else {
                    InsetPanel {
                        processGrid
                            .padding(LayoutMetrics.contentSpacing)
                    }
                }

                Text("Counters are physical disk bytes attributed by the kernel to the issuing process; page-cache hits and network file systems are not included. “AI runtime?” is a name match on the executable, not a classification of what the process does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var processCoverage: some View {
        HStack(spacing: LayoutMetrics.contentSpacing) {
            ProductLabel("\(store.processIO.readableProcessCount) of \(store.processIO.totalProcessCount) processes readable", systemImage: "eye")
            if store.processIO.deniedProcessCount > 0 {
                ProductLabel("\(store.processIO.deniedProcessCount) other users' processes not permitted without administrator rights", systemImage: "lock")
                    .help("macOS only lets a process read I/O counters of processes with the same user id. LumeFS does not request administrator privileges.")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var processGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
            GridRow {
                Text("Process")
                Text("PID").gridColumnAlignment(.trailing)
                Text("User")
                Text("Read").gridColumnAlignment(.trailing)
                Text("Write").gridColumnAlignment(.trailing)
                Text("Written total").gridColumnAlignment(.trailing)
                Text("Hint")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Divider().gridCellUnsizedAxes(.horizontal)

            ForEach(store.processIO.samples) { sample in
                GridRow {
                    Text(sample.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(String(sample.pid)).monospacedDigit()
                    Text(sample.userName)
                    Text(MetricFormatter.throughput(sample.readBytesPerSecond)).monospacedDigit()
                    Text(MetricFormatter.throughput(sample.writeBytesPerSecond)).monospacedDigit()
                    Text(MetricFormatter.bytes(Int64(clamping: sample.cumulativeWriteBytes))).monospacedDigit()
                    if let hint = sample.workloadHint {
                        ProductLabel("AI runtime? (\(hint))", systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(sample.name), PID \(sample.pid), \(sample.userName), reading \(MetricFormatter.throughput(sample.readBytesPerSecond)), writing \(MetricFormatter.throughput(sample.writeBytesPerSecond))")
            }
        }
    }

    // MARK: - NFS users (server side)

    private var nfsUsersSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("NFS users on this server").font(.headline)
                    Text("nfsstat -u · per user and client address, per export · rates over the last collection interval")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProvenanceBadge(provenance: store.nfsUsers.provenance)
            }

            HStack(spacing: LayoutMetrics.contentSpacing) {
                ProductLabel(store.nfsUsers.serverState.label, systemImage: serverSymbol)
                    .font(.callout)
                    .foregroundStyle(store.nfsUsers.serverState == .running ? Color.primary : Color.secondary)
                Spacer()
                Toggle("Show full client addresses", isOn: $showFullAddresses)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .help("Addresses are masked by default so screenshots and exports do not expose clients.")
            }

            if store.nfsUsers.provenance != .live {
                unavailablePanel(
                    symbol: "person.2.slash",
                    title: "Per-user NFS activity unavailable",
                    message: store.nfsUsers.message ?? "nfsstat did not return active-user statistics."
                )
            } else if store.nfsUsers.users.isEmpty {
                unavailablePanel(
                    symbol: "person.2",
                    title: "No active NFS user",
                    message: store.nfsUsers.message ?? "nfsd reports no active user."
                )
            } else {
                InsetPanel {
                    usersGrid
                        .padding(LayoutMetrics.contentSpacing)
                }
                Text("Requests, read and write bytes are cumulative per active-user record; nfsd drops idle records, so a returning user restarts at zero. Retries are not reported per user by macOS; see the client-wide NFS counters on Performance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var serverSymbol: String {
        switch store.nfsUsers.serverState {
        case .running: "server.rack"
        case .notRunning: "server.rack"
        case .unknown: "questionmark.circle"
        }
    }

    private struct UserRow: Identifiable {
        let user: NFSUserActivity
        let rate: NFSUserActivityRate?
        var id: String { user.id }
    }

    private var sortedUsers: [UserRow] {
        let rates = Dictionary(store.nfsUserRates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return store.nfsUsers.users
            .map { UserRow(user: $0, rate: rates[$0.id]) }
            .sorted { lhs, rhs in
                let lhsWrite = lhs.rate?.writeBytesPerSecond ?? -1
                let rhsWrite = rhs.rate?.writeBytesPerSecond ?? -1
                if lhsWrite != rhsWrite { return lhsWrite > rhsWrite }
                if lhs.user.writeBytes != rhs.user.writeBytes { return lhs.user.writeBytes > rhs.user.writeBytes }
                return lhs.id < rhs.id
            }
    }

    private var usersGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
            GridRow {
                Text("User")
                Text("Export")
                Text("Client")
                Text("Write").gridColumnAlignment(.trailing)
                Text("Read").gridColumnAlignment(.trailing)
                Text("Requests/s").gridColumnAlignment(.trailing)
                Text("Written total").gridColumnAlignment(.trailing)
                Text("Idle").gridColumnAlignment(.trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Divider().gridCellUnsizedAxes(.horizontal)

            ForEach(sortedUsers) { entry in
                GridRow {
                    Text(entry.user.user).fontWeight(.medium)
                    Text(entry.user.export).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Text(showFullAddresses ? entry.user.address : entry.user.maskedAddress)
                        .font(.callout.monospaced())
                    Text(entry.rate.map { MetricFormatter.throughput($0.writeBytesPerSecond) } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(isWriteBurst(entry.rate) ? Color.orange : Color.primary)
                    Text(entry.rate.map { MetricFormatter.throughput($0.readBytesPerSecond) } ?? "—")
                        .monospacedDigit()
                    Text(entry.rate.map { $0.requestsPerSecond.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                        .monospacedDigit()
                    Text(MetricFormatter.bytes(Int64(clamping: entry.user.writeBytes)))
                        .monospacedDigit()
                    Text(idleLabel(entry.user.idleSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: entry.user, rate: entry.rate))
            }
        }
    }

    private func isWriteBurst(_ rate: NFSUserActivityRate?) -> Bool {
        guard let rate else { return false }
        return store.alerts.contains { $0.id == "nfs-user-write-\(rate.id)" }
    }

    private func idleLabel(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min" }
        return "\(Int(seconds / 3_600)) h"
    }

    private func accessibilityLabel(for user: NFSUserActivity, rate: NFSUserActivityRate?) -> String {
        var parts = ["\(user.user) on \(user.export)"]
        if let rate {
            parts.append("writing \(MetricFormatter.throughput(rate.writeBytesPerSecond))")
            parts.append("reading \(MetricFormatter.throughput(rate.readBytesPerSecond))")
        } else {
            parts.append("rate not yet available")
        }
        parts.append("\(MetricFormatter.bytes(Int64(clamping: user.writeBytes))) written in total")
        return parts.joined(separator: ", ")
    }

    private func unavailablePanel(symbol: String, title: String, message: String) -> some View {
        InsetPanel {
            HStack(alignment: .top, spacing: LayoutMetrics.rowSpacing) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).fontWeight(.medium)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(LayoutMetrics.contentSpacing)
        }
    }
}
