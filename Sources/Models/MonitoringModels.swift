import Foundation

enum DataProvenance: String, Codable, CaseIterable, Sendable {
    case live = "LIVE"
    case benchmark = "BENCHMARK"
    case estimate = "ESTIMATE"
    case replay = "REPLAY"
    case unavailable = "UNAVAILABLE"
}

enum FileSystemKind: String, Codable, Sendable {
    case apfs = "APFS"
    case nfs = "NFS"
    case autofs = "AutoFS"
    case other = "Other"
}

enum HealthSeverity: Int, Codable, Comparable, Sendable {
    case healthy = 0
    case notice = 1
    case warning = 2
    case critical = 3

    static func < (lhs: HealthSeverity, rhs: HealthSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .healthy: "Healthy"
        case .notice: "Notice"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    var symbolName: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .notice: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

/// Interpretation of the free-text `SMARTStatus` string that `diskutil` reports.
///
/// `diskutil` emits `Verified` for a healthy device, `Not Supported` for devices or
/// bridges that expose no SMART data (most USB enclosures, disk images, network or
/// virtual storage), and failure wording such as `Failing` when the device reports a
/// problem. Only explicit failure wording is a health signal; everything else is an
/// absence of evidence and must not be presented as a critical device fault.
enum SMARTAssessment: Equatable, Sendable {
    case verified
    case notSupported
    case degraded(String)
    case unrecognized(String)

    private static let degradedMarkers = [
        "fail", "fault", "error", "critical", "degrad", "warn", "bad", "predict"
    ]
    private static let notSupportedValues: Set<String> = [
        "", "not supported", "unsupported", "not available", "n/a", "unknown", "none"
    ]

    static func assess(_ raw: String?) -> SMARTAssessment {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered == "verified" { return .verified }
        if notSupportedValues.contains(lowered) { return .notSupported }
        if degradedMarkers.contains(where: { lowered.contains($0) }) {
            return .degraded(trimmed)
        }
        return .unrecognized(trimmed)
    }

    var label: String {
        switch self {
        case .verified: "Verified"
        case .notSupported: "Not reported by this device"
        case let .degraded(raw): "Degraded (\(raw))"
        case let .unrecognized(raw): "Unrecognized (\(raw))"
        }
    }

    var isEvidence: Bool {
        switch self {
        case .verified, .degraded: true
        case .notSupported, .unrecognized: false
        }
    }
}

struct VolumeSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let mountPoint: String
    let source: String
    let fileSystem: FileSystemKind
    let fileSystemName: String
    let totalBytes: Int64
    let availableBytes: Int64
    let isReadOnly: Bool
    let isLocal: Bool
    let capturedAt: Date
    var smartStatus: String?
    var apfsVolumeQuotaBytes: Int64?
    var apfsVolumeReserveBytes: Int64?

    var smartAssessment: SMARTAssessment {
        SMARTAssessment.assess(smartStatus)
    }

    func capacitySeverity(thresholds: CapacityThresholds) -> HealthSeverity {
        guard totalBytes > 0 else { return .notice }
        if availableFraction < thresholds.criticalFreeFraction { return .critical }
        if availableFraction < thresholds.warningFreeFraction { return .warning }
        return .healthy
    }

    var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    var availableFraction: Double {
        1 - usedFraction
    }
}

struct DeviceIOSample: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let deviceName: String
    let timestamp: Date
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let readOperationsPerSecond: Double
    let writeOperationsPerSecond: Double
    let readErrors: UInt64
    let writeErrors: UInt64
    let readRetries: UInt64
    let writeRetries: UInt64
    let provenance: DataProvenance

    init(
        id: UUID = UUID(),
        deviceName: String,
        timestamp: Date,
        readBytesPerSecond: Double,
        writeBytesPerSecond: Double,
        readOperationsPerSecond: Double,
        writeOperationsPerSecond: Double,
        readErrors: UInt64,
        writeErrors: UInt64,
        readRetries: UInt64,
        writeRetries: UInt64,
        provenance: DataProvenance = .live
    ) {
        self.id = id
        self.deviceName = deviceName
        self.timestamp = timestamp
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readOperationsPerSecond = readOperationsPerSecond
        self.writeOperationsPerSecond = writeOperationsPerSecond
        self.readErrors = readErrors
        self.writeErrors = writeErrors
        self.readRetries = readRetries
        self.writeRetries = writeRetries
        self.provenance = provenance
    }

    var totalBytesPerSecond: Double {
        readBytesPerSecond + writeBytesPerSecond
    }
}

struct NFSClientMetrics: Codable, Hashable, Sendable {
    let requests: UInt64
    let retries: UInt64
    let timedOut: UInt64
    let invalidReplies: UInt64
    let readOperations: UInt64
    let writeOperations: UInt64
    let layoutGets: UInt64
    let layoutCommits: UInt64
    let layoutReturns: UInt64
    let deviceInfoRequests: UInt64
    let capturedAt: Date
    let provenance: DataProvenance

    static let unavailable = NFSClientMetrics(
        requests: 0,
        retries: 0,
        timedOut: 0,
        invalidReplies: 0,
        readOperations: 0,
        writeOperations: 0,
        layoutGets: 0,
        layoutCommits: 0,
        layoutReturns: 0,
        deviceInfoRequests: 0,
        capturedAt: .distantPast,
        provenance: .unavailable
    )

    var pNFSObserved: Bool {
        layoutGets > 0 || layoutCommits > 0 || layoutReturns > 0 || deviceInfoRequests > 0
    }
}

/// Per-mount NFS information as reported by `nfsstat -m` for a single mount point.
///
/// Values are the client's view of the mount (server name, export path, negotiated
/// parameters and kernel status flags). They are not throughput counters, which macOS
/// only exposes client-wide (`NFSClientMetrics`).
struct NFSMountInfo: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let mountPoint: String
    let source: String
    let server: String?
    let export: String?
    let addresses: [String]
    let nfsVersion: String?
    let transport: String?
    let parameters: [String]
    let mountFlags: [String]
    let statusFlags: [String]
    let capturedAt: Date
    let provenance: DataProvenance
    let message: String?

    static func unavailable(
        mountPoint: String,
        source: String,
        message: String,
        at date: Date
    ) -> NFSMountInfo {
        NFSMountInfo(
            id: mountPoint,
            mountPoint: mountPoint,
            source: source,
            server: nil,
            export: nil,
            addresses: [],
            nfsVersion: nil,
            transport: nil,
            parameters: [],
            mountFlags: [],
            statusFlags: [],
            capturedAt: date,
            provenance: .unavailable,
            message: message
        )
    }

    /// Kernel flags emitted by `nfsstat -m` (`NFS_MIFLAG_DEAD`, `NFS_MIFLAG_NOTRESP`,
    /// `NFS_MIFLAG_RECOVERY`). Missing flags on an UNAVAILABLE record mean "unknown",
    /// not "healthy".
    var isDead: Bool { statusFlags.contains("dead") }
    var isNotResponding: Bool { statusFlags.contains("not responding") }
    var inRecovery: Bool { statusFlags.contains("recovery") }

    var isResponding: Bool {
        provenance == .live && !isDead && !isNotResponding
    }

    var statusLabel: String {
        guard provenance == .live else { return "Unavailable" }
        if isDead { return "Dead" }
        if isNotResponding { return "Not responding" }
        if inRecovery { return "Recovering" }
        return "Responding"
    }

    var displayServer: String {
        server ?? source.split(separator: ":", maxSplits: 1).first.map(String.init) ?? source
    }

    var displayExport: String {
        if let export { return export }
        let parts = source.split(separator: ":", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : source
    }
}

/// State of the local NFS server (`nfsd status`, an unprivileged command).
enum NFSServerState: String, Codable, Sendable {
    case running
    case notRunning
    case unknown

    var label: String {
        switch self {
        case .running: "nfsd running"
        case .notRunning: "nfsd not running"
        case .unknown: "nfsd state unknown"
        }
    }
}

/// One `user@address` record under one export from `nfsstat -u` (server side).
///
/// Counters are cumulative for the lifetime of the kernel's active-user node, which
/// nfsd reclaims after an idle period; a reclaimed and recreated node restarts at
/// zero. Rates therefore use non-negative deltas between consecutive LIVE samples.
struct NFSUserActivity: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let export: String
    let user: String
    let uid: UInt32?
    let address: String
    let requests: UInt64
    let readBytes: UInt64
    let writeBytes: UInt64
    let idleSeconds: TimeInterval?
    let capturedAt: Date
    let provenance: DataProvenance

    /// Keeps the network prefix so an operator can still recognize a subnet
    /// while screenshots and exports do not carry a full client address.
    var maskedAddress: String {
        Self.mask(address)
    }

    static func mask(_ address: String) -> String {
        if address.contains(":") {
            let groups = address.split(separator: ":", omittingEmptySubsequences: false)
            let kept = groups.prefix(2).map(String.init).joined(separator: ":")
            return kept.isEmpty ? "…" : "\(kept):…"
        }
        let octets = address.split(separator: ".")
        guard octets.count == 4 else { return address.isEmpty ? "unknown" : "…" }
        return "\(octets[0]).\(octets[1]).·.·"
    }
}

struct NFSUserActivitySnapshot: Codable, Hashable, Sendable {
    let users: [NFSUserActivity]
    let serverState: NFSServerState
    let capturedAt: Date
    let provenance: DataProvenance
    let message: String?

    static let unavailable = NFSUserActivitySnapshot(
        users: [],
        serverState: .unknown,
        capturedAt: .distantPast,
        provenance: .unavailable,
        message: "Per-user NFS activity has not been collected."
    )

    static func unavailable(
        message: String,
        serverState: NFSServerState,
        at date: Date
    ) -> NFSUserActivitySnapshot {
        NFSUserActivitySnapshot(
            users: [],
            serverState: serverState,
            capturedAt: date,
            provenance: .unavailable,
            message: message
        )
    }
}

/// Per-user rates derived from two consecutive LIVE `NFSUserActivitySnapshot`s.
struct NFSUserActivityRate: Identifiable, Hashable, Sendable {
    let activity: NFSUserActivity
    let intervalSeconds: Double
    let requestsPerSecond: Double
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double

    var id: String { activity.id }

    /// Users present in both samples get a rate; counter decreases count as zero.
    static func rates(
        current: NFSUserActivitySnapshot,
        previous: NFSUserActivitySnapshot?
    ) -> [NFSUserActivityRate] {
        guard current.provenance == .live,
              let previous, previous.provenance == .live else { return [] }
        let interval = current.capturedAt.timeIntervalSince(previous.capturedAt)
        guard interval > 0 else { return [] }
        let earlier = Dictionary(previous.users.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return current.users.compactMap { user in
            guard let before = earlier[user.id] else { return nil }
            func delta(_ now: UInt64, _ then: UInt64) -> Double {
                now >= then ? Double(now - then) : 0
            }
            return NFSUserActivityRate(
                activity: user,
                intervalSeconds: interval,
                requestsPerSecond: delta(user.requests, before.requests) / interval,
                readBytesPerSecond: delta(user.readBytes, before.readBytes) / interval,
                writeBytesPerSecond: delta(user.writeBytes, before.writeBytes) / interval
            )
        }
    }
}

/// Deterministic per-user burst thresholds. Defaults: 100 MB/s written or 1,000
/// requests/s sustained over one collection interval. Settings can change them.
struct NFSUserAlertThresholds: Equatable, Sendable {
    let writeBytesPerSecond: Double
    let requestsPerSecond: Double

    static let `default` = NFSUserAlertThresholds(
        writeBytesPerSecond: 100_000_000,
        requestsPerSecond: 1_000
    )

    init(writeBytesPerSecond: Double, requestsPerSecond: Double) {
        self.writeBytesPerSecond = max(1_000_000, writeBytesPerSecond)
        self.requestsPerSecond = max(10, requestsPerSecond)
    }
}

struct QuotaSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let subject: String
    let mountPoint: String
    let usedBytes: Int64?
    let softLimitBytes: Int64?
    let hardLimitBytes: Int64?
    let message: String
    let capturedAt: Date
    let provenance: DataProvenance
}


extension QuotaSnapshot {
    /// Exact filesystem matching only; raw all-filesystem output is not a numeric limit.
    func applies(to volume: VolumeSnapshot) -> Bool {
        mountPoint == volume.mountPoint || mountPoint == volume.source
    }

    var remainingBytes: Int64? {
        guard provenance == .live, let usedBytes, usedBytes >= 0 else { return nil }
        let limits = [softLimitBytes, hardLimitBytes].compactMap { $0 }.filter { $0 > 0 }
        guard let limit = limits.min() else { return nil }
        return max(0, limit - usedBytes)
    }

    var limitSeverity: HealthSeverity? {
        guard provenance == .live, let usedBytes, usedBytes >= 0 else { return nil }
        if let hardLimitBytes, hardLimitBytes > 0, usedBytes >= hardLimitBytes { return .critical }
        if let softLimitBytes, softLimitBytes > 0, usedBytes >= softLimitBytes { return .warning }
        return nil
    }
}

struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let displayPath: String
    let eventDescription: String
    let provenance: DataProvenance

    init(
        id: UUID = UUID(),
        timestamp: Date,
        displayPath: String,
        eventDescription: String,
        provenance: DataProvenance = .live
    ) {
        self.id = id
        self.timestamp = timestamp
        self.displayPath = displayPath
        self.eventDescription = eventDescription
        self.provenance = provenance
    }
}

struct BenchmarkResult: Codable, Hashable, Sendable {
    let byteCount: Int64
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let elapsedSeconds: Double
    let completedAt: Date
    let provenance: DataProvenance
    let writeWasSynchronized: Bool
    let readMayUseSystemCache: Bool
    let cleanupSucceeded: Bool
}

struct CapacityThresholds: Equatable, Sendable {
    let warningFreeFraction: Double
    let criticalFreeFraction: Double

    static let `default` = CapacityThresholds(
        warningFreeFraction: 0.20,
        criticalFreeFraction: 0.10
    )

    init(warningFreeFraction: Double, criticalFreeFraction: Double) {
        let warning = min(0.95, max(0.01, warningFreeFraction))
        let critical = min(warning, max(0.01, criticalFreeFraction))
        self.warningFreeFraction = warning
        self.criticalFreeFraction = critical
    }
}

struct WorkloadReadiness: Equatable, Sendable {
    let workloadBytes: Int64
    let requiredBytesWithMargin: Int64
    let headroomBytes: Int64
    let availableBytes: Int64
    let quotaLimited: Bool
    let fits: Bool
}

struct MonitoringAlert: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let ruleID: String
    let severity: HealthSeverity
    let title: String
    let message: String
    let evidence: String
    let recommendation: String
    let relatedVolumeID: String?
    let createdAt: Date
    let provenance: DataProvenance
}

struct SystemSnapshot: Sendable {
    let volumes: [VolumeSnapshot]
    let deviceSamples: [DeviceIOSample]
    let nfsMetrics: NFSClientMetrics
    let nfsMounts: [NFSMountInfo]
    let nfsUsers: NFSUserActivitySnapshot
    let nfsUserRates: [NFSUserActivityRate]
    let quotas: [QuotaSnapshot]
    let alerts: [MonitoringAlert]
    let capturedAt: Date

    init(
        volumes: [VolumeSnapshot],
        deviceSamples: [DeviceIOSample],
        nfsMetrics: NFSClientMetrics,
        nfsMounts: [NFSMountInfo] = [],
        nfsUsers: NFSUserActivitySnapshot = .unavailable,
        nfsUserRates: [NFSUserActivityRate] = [],
        quotas: [QuotaSnapshot],
        alerts: [MonitoringAlert],
        capturedAt: Date
    ) {
        self.volumes = volumes
        self.deviceSamples = deviceSamples
        self.nfsMetrics = nfsMetrics
        self.nfsMounts = nfsMounts
        self.nfsUsers = nfsUsers
        self.nfsUserRates = nfsUserRates
        self.quotas = quotas
        self.alerts = alerts
        self.capturedAt = capturedAt
    }
}

/// Separate series prevent a line from implying measurements across a collection gap.
struct IOChartPoint: Identifiable {
    let sample: DeviceIOSample
    let segment: Int
    var id: UUID { sample.id }

    static func make(from samples: [DeviceIOSample], maximumGap: TimeInterval = 10) -> [Self] {
        var points: [Self] = []
        var segment = 0
        var previousDate: Date?
        for sample in samples {
            if let previousDate {
                let interval = sample.timestamp.timeIntervalSince(previousDate)
                if interval <= 0 || interval > maximumGap { segment += 1 }
            }
            points.append(Self(sample: sample, segment: segment))
            previousDate = sample.timestamp
        }
        return points
    }
}
