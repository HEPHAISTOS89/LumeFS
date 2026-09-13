import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case volumes = "Volumes"
    case performance = "Performance"
    case activity = "Activity"
    case alerts = "Alerts"

    var id: String { rawValue }

    var navigationAsset: String {
        switch self {
        case .overview: "Lucide-gauge"
        case .volumes: "Lucide-hard-drive"
        case .performance: "Lucide-chart-no-axes-combined"
        case .activity: "Lucide-clock-arrow-left"
        case .alerts: "Lucide-bell"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .volumes: "internaldrive"
        case .performance: "chart.xyaxis.line"
        case .activity: "clock.arrow.circlepath"
        case .alerts: "bell.badge"
        }
    }
}

enum CollectionFreshness: String {
    case connecting = "Connecting"
    case current = "Monitoring"
    case delayed = "Data delayed"
    case paused = "Paused"

    static func evaluate(isMonitoring: Bool, lastUpdated: Date?, now: Date) -> Self {
        guard isMonitoring else { return .paused }
        guard let lastUpdated else { return .connecting }
        return now.timeIntervalSince(lastUpdated) > 10 ? .delayed : .current
    }
}

@MainActor
@Observable
final class MonitoringStore {
    var selectedSection: AppSection? = .overview
    var selectedVolumeID: String?
    var selectedAlertID: String?
    var plannedWorkloadGiB = 16
    private(set) var volumes: [VolumeSnapshot] = []
    private(set) var latestDeviceSamples: [DeviceIOSample] = []
    private(set) var ioHistory: [DeviceIOSample] = []
    private(set) var nfsMetrics = NFSClientMetrics.unavailable
    private(set) var nfsMounts: [NFSMountInfo] = []
    private(set) var pNFSReplayMetrics: NFSClientMetrics?
    private(set) var pNFSReplayError: String?
    private(set) var quotas: [QuotaSnapshot] = []
    private(set) var alerts: [MonitoringAlert] = []
    private(set) var activity: [ActivityEvent] = []
    private(set) var watchedFolderLabel: String?
    private(set) var fileActivityError: String?
    private(set) var benchmarkResult: BenchmarkResult?
    private(set) var benchmarkError: String?
    private(set) var isBenchmarkRunning = false
    private(set) var lastUpdated: Date?
    private(set) var isMonitoring = false
    private(set) var isRefreshing = false

    @ObservationIgnored
    private let collectSnapshot: @Sendable () async -> SystemSnapshot
    @ObservationIgnored
    private let benchmark = DiskBenchmark()
    @ObservationIgnored
    private var monitoringTask: Task<Void, Never>?
    @ObservationIgnored
    private var fileActivityCollector: FileActivityCollector?
    @ObservationIgnored
    private var fileActivityTask: Task<Void, Never>?

    init(collectSnapshot: (@Sendable () async -> SystemSnapshot)? = nil) {
        if let collectSnapshot {
            self.collectSnapshot = collectSnapshot
        } else {
            let engine = MonitoringEngine()
            self.collectSnapshot = { await engine.refresh() }
        }
    }

    var selectedVolume: VolumeSnapshot? {
        volumes.first { $0.id == selectedVolumeID }
    }

    func nfsMount(for volume: VolumeSnapshot) -> NFSMountInfo? {
        nfsMounts.first { $0.mountPoint == volume.mountPoint }
    }

    var selectedAlert: MonitoringAlert? {
        alerts.first { $0.id == selectedAlertID }
    }

    var overallSeverity: HealthSeverity {
        alerts.map(\.severity).max() ?? .healthy
    }

    var totalReadBytesPerSecond: Double {
        latestDeviceSamples.reduce(0) { $0 + $1.readBytesPerSecond }
    }

    var totalWriteBytesPerSecond: Double {
        latestDeviceSamples.reduce(0) { $0 + $1.writeBytesPerSecond }
    }

    var totalBytesPerSecond: Double {
        totalReadBytesPerSecond + totalWriteBytesPerSecond
    }

    var ioProvenance: DataProvenance {
        latestDeviceSamples.first?.provenance ?? .unavailable
    }

    func start() {
        guard monitoringTask == nil else { return }

        isMonitoring = true
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNow()

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = await collectSnapshot()
        guard !Task.isCancelled else { return }
        apply(snapshot)
    }

    func runBenchmark() async {
        guard !isBenchmarkRunning else { return }

        isBenchmarkRunning = true
        benchmarkError = nil
        benchmarkResult = nil

        do {
            let result = try await benchmark.run(mebibytes: 128)
            benchmarkResult = result
            appendActivity(
                displayPath: "Temporary workspace",
                description: "Completed a bounded 128 MiB read/write benchmark.",
                provenance: .benchmark,
                at: result.completedAt
            )
        } catch {
            benchmarkError = error.localizedDescription
        }

        isBenchmarkRunning = false
    }

    func showPNFSReplay() {
        pNFSReplayError = nil
        let url = Bundle.main.url(
            forResource: "pnfs-client-sample",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? Bundle.main.url(
            forResource: "pnfs-client-sample",
            withExtension: "json"
        )

        guard let url else {
            pNFSReplayError = "The bundled pNFS replay fixture is missing."
            return
        }

        do {
            let data = try Data(contentsOf: url)
            pNFSReplayMetrics = try NFSCollector(
                commandRunner: SystemCommandRunner()
            ).parse(data: data, provenance: .replay)
            appendActivity(
                displayPath: "Bundled fixture",
                description: "Opened a deterministic pNFS evidence replay.",
                provenance: .replay,
                at: Date()
            )
        } catch {
            pNFSReplayError = "Could not load the pNFS replay: \(error.localizedDescription)"
        }
    }

    func hidePNFSReplay() {
        pNFSReplayMetrics = nil
    }

    func watchFolder(_ url: URL) {
        stopWatchingFolder()
        fileActivityError = nil

        do {
            let label = url.lastPathComponent.isEmpty ? "Selected folder" : url.lastPathComponent
            let root = try FileActivityRoot(url: url, label: label)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw FileActivityCollectorError.rootIsNotDirectory(root.label)
            }
            let collector = FileActivityCollector(roots: [root], latency: 0.5)
            let stream = collector.events()

            fileActivityCollector = collector
            watchedFolderLabel = root.label
            appendActivity(
                displayPath: root.label,
                description: "Started privacy-preserving file activity monitoring.",
                provenance: .live,
                at: Date()
            )

            fileActivityTask = Task { [weak self] in
                do {
                    for try await batch in stream {
                        guard !Task.isCancelled else { return }
                        self?.recordFileActivity(batch)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fileActivityError = error.localizedDescription
                    self?.watchedFolderLabel = nil
                }
            }
        } catch {
            fileActivityError = error.localizedDescription
            watchedFolderLabel = nil
        }
    }

    func stopWatchingFolder() {
        let previousLabel = watchedFolderLabel
        fileActivityTask?.cancel()
        fileActivityTask = nil
        fileActivityCollector?.stop()
        fileActivityCollector = nil
        watchedFolderLabel = nil

        if let previousLabel {
            appendActivity(
                displayPath: previousLabel,
                description: "Stopped file activity monitoring.",
                provenance: .live,
                at: Date()
            )
        }
    }

    private func apply(_ snapshot: SystemSnapshot) {
        recordChanges(in: snapshot)
        volumes = snapshot.volumes
        latestDeviceSamples = snapshot.deviceSamples
        nfsMetrics = snapshot.nfsMetrics
        nfsMounts = snapshot.nfsMounts
        quotas = snapshot.quotas
        alerts = snapshot.alerts
        lastUpdated = snapshot.capturedAt

        if let aggregate = aggregateSample(snapshot.deviceSamples, at: snapshot.capturedAt) {
            ioHistory.append(aggregate)
        }
        if ioHistory.count > 900 {
            ioHistory.removeFirst(ioHistory.count - 900)
        }

        if !volumes.contains(where: { $0.id == selectedVolumeID }) {
            selectedVolumeID = volumes.first?.id
        }
        if !alerts.contains(where: { $0.id == selectedAlertID }) {
            selectedAlertID = alerts.first?.id
        }
    }

    private func aggregateSample(
        _ samples: [DeviceIOSample],
        at date: Date
    ) -> DeviceIOSample? {
        guard !samples.isEmpty else { return nil }

        return DeviceIOSample(
            deviceName: "All devices",
            timestamp: date,
            readBytesPerSecond: samples.reduce(0) { $0 + $1.readBytesPerSecond },
            writeBytesPerSecond: samples.reduce(0) { $0 + $1.writeBytesPerSecond },
            readOperationsPerSecond: samples.reduce(0) { $0 + $1.readOperationsPerSecond },
            writeOperationsPerSecond: samples.reduce(0) { $0 + $1.writeOperationsPerSecond },
            readErrors: samples.reduce(0) { $0 + $1.readErrors },
            writeErrors: samples.reduce(0) { $0 + $1.writeErrors },
            readRetries: samples.reduce(0) { $0 + $1.readRetries },
            writeRetries: samples.reduce(0) { $0 + $1.writeRetries }
        )
    }

    private func recordChanges(in snapshot: SystemSnapshot) {
        if lastUpdated == nil {
            appendActivity(
                displayPath: "Local host",
                description: "Started live APFS, block I/O, quota, and NFS monitoring.",
                provenance: .live,
                at: snapshot.capturedAt
            )
        }

        let previousVolumes = Dictionary(uniqueKeysWithValues: volumes.map { ($0.id, $0) })
        let currentVolumes = Dictionary(uniqueKeysWithValues: snapshot.volumes.map { ($0.id, $0) })

        for volume in snapshot.volumes where previousVolumes[volume.id] == nil && lastUpdated != nil {
            appendActivity(
                displayPath: volume.name,
                description: "Mounted a \(volume.fileSystem.rawValue) volume.",
                provenance: .live,
                at: snapshot.capturedAt
            )
        }

        for volume in volumes where currentVolumes[volume.id] == nil {
            appendActivity(
                displayPath: volume.name,
                description: "Unmounted a \(volume.fileSystem.rawValue) volume.",
                provenance: .live,
                at: snapshot.capturedAt
            )
        }

        let previousAlertIDs = Set(alerts.map(\.id))
        let currentAlertIDs = Set(snapshot.alerts.map(\.id))

        for alert in snapshot.alerts where !previousAlertIDs.contains(alert.id) {
            appendActivity(
                displayPath: alert.relatedVolumeID.flatMap { currentVolumes[$0]?.name } ?? "System",
                description: "Raised alert: \(alert.title)",
                provenance: alert.provenance,
                at: snapshot.capturedAt
            )
        }

        for alert in alerts where !currentAlertIDs.contains(alert.id) {
            appendActivity(
                displayPath: "System",
                description: "Cleared alert: \(alert.title)",
                provenance: .live,
                at: snapshot.capturedAt
            )
        }

        if !nfsMetrics.pNFSObserved && snapshot.nfsMetrics.pNFSObserved {
            appendActivity(
                displayPath: "NFS client",
                description: "Observed NFSv4.1 layout operations as pNFS evidence.",
                provenance: .live,
                at: snapshot.capturedAt
            )
        }
    }

    private func recordFileActivity(_ batch: FileActivityBatch) {
        for summary in batch.summaries {
            let operationLabels = summary.operations
                .map(\.displayLabel)
                .sorted()
                .joined(separator: ", ")

            let description: String
            if summary.requiresRescan {
                description = "Observed \(summary.eventCount) file-system event(s); a rescan is required."
            } else {
                description = "Observed \(summary.eventCount) file-system event(s): \(operationLabels)."
            }

            appendActivity(
                displayPath: summary.rootLabel,
                description: description,
                provenance: batch.provenance,
                at: batch.capturedAt
            )
        }
    }

    private func appendActivity(
        displayPath: String,
        description: String,
        provenance: DataProvenance,
        at date: Date
    ) {
        activity.insert(
            ActivityEvent(
                timestamp: date,
                displayPath: displayPath,
                eventDescription: description,
                provenance: provenance
            ),
            at: 0
        )

        if activity.count > 200 {
            activity.removeLast(activity.count - 200)
        }
    }
}

private extension FileActivityOperation {
    var displayLabel: String {
        switch self {
        case .changed: "changed"
        case .created: "created"
        case .removed: "removed"
        case .renamed: "renamed"
        case .contentModified: "content modified"
        case .metadataModified: "metadata modified"
        case .ownerChanged: "owner changed"
        case .extendedAttributesModified: "extended attributes modified"
        case .finderInfoModified: "Finder info modified"
        case .cloned: "cloned"
        case .mounted: "mounted"
        case .unmounted: "unmounted"
        case .rootChanged: "root changed"
        }
    }
}
