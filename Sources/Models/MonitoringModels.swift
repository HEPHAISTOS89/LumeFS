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
    let quotas: [QuotaSnapshot]
    let alerts: [MonitoringAlert]
    let capturedAt: Date
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
