import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case volumes = "Volumes"
    case performance = "Performance"
    case attribution = "Attribution"
    case activity = "Activity"
    case placement = "Placement"
    case alerts = "Alerts"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .volumes: "internaldrive"
        case .performance: "chart.xyaxis.line"
        case .attribution: "person.2"
        case .activity: "clock.arrow.circlepath"
        case .placement: "arrow.right.doc.on.clipboard"
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
    private(set) var nfsUsers = NFSUserActivitySnapshot.unavailable
    private(set) var nfsUserRates: [NFSUserActivityRate] = []
    private(set) var processIO = ProcessIOSnapshot.unavailable
    private(set) var pNFSReplayMetrics: NFSClientMetrics?
    private(set) var pNFSReplayError: String?
    private(set) var quotas: [QuotaSnapshot] = []
    private(set) var alerts: [MonitoringAlert] = []
    /// Newest raised first; mirrors the ledger after every refresh.
    private(set) var alertHistory: [AlertHistoryEntry] = []
    private(set) var alertHistoryError: String?
    private(set) var lastExportURL: URL?
    private(set) var exportError: String?
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
    private var benchmarkTask: Task<Void, Never>?
    @ObservationIgnored
    private var fileActivityCollector: FileActivityCollector?
    @ObservationIgnored
    private var fileActivityTask: Task<Void, Never>?
    @ObservationIgnored
    private var ledger: AlertHistoryLedger
    @ObservationIgnored
    private let alertHistoryPersistence: AlertHistoryPersistence?
    /// Nil in tests and in any context without an app bundle: no notification is ever posted.
    let criticalAlertNotifier: CriticalAlertNotifier?
    /// Placement plans and confirmed copies; its journal is in memory unless a persistence is given.
    let placement: MigrationController

    /// - Parameters:
    ///   - alertHistoryPersistence: where the alert ledger is read at start and
    ///     written on lifecycle changes. Nil keeps the history in memory only.
    ///   - criticalAlertNotifier: opt-in notification bridge; nil disables delivery.
    ///   - migrationJournalPersistence: where placement plans and copies are journaled.
    init(
        collectSnapshot: (@Sendable () async -> SystemSnapshot)? = nil,
        alertHistoryPersistence: AlertHistoryPersistence? = nil,
        criticalAlertNotifier: CriticalAlertNotifier? = nil,
        migrationJournalPersistence: MigrationJournalPersistence? = nil
    ) {
        if let collectSnapshot {
            self.collectSnapshot = collectSnapshot
        } else {
            let engine = MonitoringEngine()
            self.collectSnapshot = { await engine.refresh() }
        }
        self.alertHistoryPersistence = alertHistoryPersistence
        self.criticalAlertNotifier = criticalAlertNotifier
        self.placement = MigrationController(persistence: migrationJournalPersistence)
        self.ledger = alertHistoryPersistence?.load() ?? AlertHistoryLedger()
        self.alertHistory = ledger.entries
        placement.onActivity = { [weak self] displayPath, description, date in
            self?.appendActivity(displayPath: displayPath, description: description, provenance: .live, at: date)
        }
    }

    /// Production configuration: ledger and journal in Application Support, notifications available.
    static func forApplication() -> MonitoringStore {
        MonitoringStore(
            alertHistoryPersistence: .applicationSupport(),
            criticalAlertNotifier: CriticalAlertNotifier(),
            migrationJournalPersistence: .applicationSupport()
        )
    }

    var alertHistoryFileURL: URL? { alertHistoryPersistence?.fileURL }

    var openAlertHistory: [AlertHistoryEntry] { ledger.openEntries }

    func historyEntry(forAlertID alertID: String) -> AlertHistoryEntry? {
        ledger.openEntry(forAlertID: alertID)
    }

    /// Marks an open entry as acknowledged. Acknowledgement is bookkeeping only:
    /// the alert stays active until its rule stops firing.
    @discardableResult
    func acknowledgeAlert(entryID: String, at date: Date = Date()) -> Bool {
        guard ledger.acknowledge(entryID: entryID, at: date) else { return false }
        alertHistory = ledger.entries
        persistAlertHistory()
        if let entry = ledger.entries.first(where: { $0.id == entryID }) {
            appendActivity(
                displayPath: "Alerts",
                description: "Acknowledged alert: \(entry.alert.title)",
                provenance: entry.alert.provenance,
                at: date
            )
        }
        return true
    }

    /// Removes cleared entries from the ledger; open alerts are always kept.
    func clearClosedAlertHistory() {
        ledger.clearHistory(keepOpen: true)
        alertHistory = ledger.entries
        persistAlertHistory()
    }

    var appVersionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// Serializes what the UI currently shows. Nothing is re-collected.
    func makeExport(maskAddresses: Bool, at date: Date = Date()) -> MonitoringExport {
        MonitoringExport(
            exportedAt: date,
            appVersion: appVersionLabel,
            addressesMasked: maskAddresses,
            volumes: volumes,
            deviceSamples: latestDeviceSamples,
            nfsClient: nfsMetrics,
            nfsMounts: nfsMounts,
            nfsUsers: maskAddresses ? nfsUsers.maskingAddresses() : nfsUsers,
            processIO: processIO,
            quotas: quotas,
            quotaCoverage: .current(),
            activeAlerts: alerts,
            alertHistory: ledger.entries
        )
    }

    func exportData(format: SnapshotExportFormat, maskAddresses: Bool, at date: Date = Date()) throws -> Data {
        try SnapshotExporter().data(for: makeExport(maskAddresses: maskAddresses, at: date), format: format)
    }

    /// Writes one export to a user-chosen location. Addresses are masked unless
    /// the user opted into full NFS client addresses in Settings.
    func exportSnapshot(format: SnapshotExportFormat, to url: URL, at date: Date = Date()) {
        exportError = nil
        let showFullAddresses = UserDefaults.standard.bool(forKey: "showFullNFSClientAddresses")
        do {
            let data = try exportData(format: format, maskAddresses: !showFullAddresses, at: date)
            try data.write(to: url, options: [.atomic])
            lastExportURL = url
            appendActivity(
                displayPath: url.lastPathComponent,
                description: "Exported a \(format.label) snapshot: \(alerts.count) active alert(s), \(ledger.entries.count) history entries, \(showFullAddresses ? "full" : "masked") NFS client addresses.",
                provenance: .live,
                at: date
            )
        } catch {
            exportError = error.localizedDescription
        }
    }

    func dismissExportError() {
        exportError = nil
    }

    private func persistAlertHistory() {
        guard let alertHistoryPersistence else { return }
        do {
            try alertHistoryPersistence.save(ledger)
            alertHistoryError = nil
        } catch {
            alertHistoryError = "Alert history could not be saved: \(error.localizedDescription)"
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
        // Open entries only refresh `lastSeenAt` in memory during a session;
        // pausing is the natural point to write that progress down.
        if !ledger.openEntries.isEmpty {
            persistAlertHistory()
        }
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = await collectSnapshot()
        guard !Task.isCancelled else { return }
        apply(snapshot)
    }

    /// Starts the benchmark as an owned task so the UI can cancel it.
    func startBenchmark(mebibytes: Int = BenchmarkGuard.defaultMebibytes) {
        guard benchmarkTask == nil else { return }
        benchmarkTask = Task { [weak self] in
            await self?.runBenchmark(mebibytes: mebibytes)
            self?.benchmarkTask = nil
        }
    }

    func cancelBenchmark() {
        benchmarkTask?.cancel()
    }

    func runBenchmark(mebibytes: Int = BenchmarkGuard.defaultMebibytes) async {
        guard !isBenchmarkRunning else { return }

        isBenchmarkRunning = true
        benchmarkError = nil
        benchmarkResult = nil
        defer { isBenchmarkRunning = false }

        do {
            let result = try await benchmark.run(mebibytes: mebibytes)
            benchmarkResult = result
            appendActivity(
                displayPath: "Temporary workspace",
                description: "Completed a bounded \(result.mebibytes) MiB benchmark: uncached write, uncached read, cached read; temporary file removed.",
                provenance: .benchmark,
                at: result.completedAt
            )
        } catch is CancellationError {
            benchmarkError = "Benchmark cancelled. The temporary workspace was removed."
            appendActivity(
                displayPath: "Temporary workspace",
                description: "Cancelled the \(mebibytes) MiB benchmark; temporary file removed.",
                provenance: .benchmark,
                at: Date()
            )
        } catch {
            benchmarkError = error.localizedDescription
        }
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
        nfsUsers = snapshot.nfsUsers
        nfsUserRates = snapshot.nfsUserRates
        processIO = snapshot.processIO
        quotas = snapshot.quotas
        alerts = snapshot.alerts
        lastUpdated = snapshot.capturedAt

        let reconciliation = ledger.reconcile(activeAlerts: snapshot.alerts, at: snapshot.capturedAt)
        alertHistory = ledger.entries
        if !reconciliation.isEmpty {
            persistAlertHistory()
            criticalAlertNotifier?.deliver(raised: reconciliation.raised, at: snapshot.capturedAt)
        }

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
