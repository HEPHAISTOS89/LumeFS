import Foundation

actor MonitoringEngine {
    private let mountCollector = MountCollector()
    private let blockIOCollector = BlockIOCollector()
    private let processIOCollector = ProcessIOCollector()
    private let commandRunner = SystemCommandRunner()
    private let alertEngine = AlertRuleEngine()

    private var cachedVolumes: [VolumeSnapshot] = []
    private var cachedNFS = NFSClientMetrics.unavailable
    private var cachedNFSMounts: [NFSMountInfo] = []
    private var cachedNFSUsers = NFSUserActivitySnapshot.unavailable
    private var cachedNFSUserRates: [NFSUserActivityRate] = []
    private var cachedProcessIO = ProcessIOSnapshot.unavailable
    private var cachedQuotas: [QuotaSnapshot] = []
    private var previousNFS: NFSClientMetrics?
    private var refreshCount = 0

    func refresh() async -> SystemSnapshot {
        let now = Date()
        refreshCount += 1

        async let samples = blockIOCollector.collect(at: now)

        // Every other cycle: one sysctl plus one proc_pid_rusage per readable process.
        // Two-second deltas are smoother than one-second ones for bursty writers.
        if refreshCount == 1 || refreshCount.isMultiple(of: 2) {
            cachedProcessIO = await processIOCollector.collect(at: now)
        }

        if cachedVolumes.isEmpty || refreshCount.isMultiple(of: 10) {
            let volumes = mountCollector.collect(at: now)
            cachedVolumes = await APFSMetadataCollector(
                commandRunner: commandRunner
            ).enrich(volumes)
            // Same cadence as the mount table: mount parameters and status flags
            // only change on remount or when the kernel marks the server unreachable.
            cachedNFSMounts = await NFSMountCollector(
                commandRunner: commandRunner
            ).collect(volumes: cachedVolumes, at: now)
        }

        if refreshCount == 1 || refreshCount.isMultiple(of: 3) {
            previousNFS = cachedNFS.provenance == .live ? cachedNFS : nil
            cachedNFS = await NFSCollector(
                commandRunner: commandRunner
            ).collect(at: now)

            // Same cadence as the client counters: per-user rates are deltas over
            // this three-second window, which is what the burst thresholds refer to.
            let previousUsers = cachedNFSUsers
            cachedNFSUsers = await NFSActiveUserCollector(
                commandRunner: commandRunner
            ).collect(at: now)
            cachedNFSUserRates = NFSUserActivityRate.rates(
                current: cachedNFSUsers,
                previous: previousUsers
            )
        }

        if cachedQuotas.isEmpty || refreshCount.isMultiple(of: 30) {
            cachedQuotas = await QuotaCollector(
                commandRunner: commandRunner
            ).collect(at: now)
        }

        let currentSamples = await samples
        let thresholds = capacityThresholds()
        let alerts = alertEngine.evaluate(
            volumes: cachedVolumes,
            samples: currentSamples,
            nfs: cachedNFS,
            previousNFS: previousNFS,
            capacityThresholds: thresholds,
            quotas: cachedQuotas,
            nfsMounts: cachedNFSMounts,
            nfsUserRates: cachedNFSUserRates,
            nfsUserThresholds: nfsUserThresholds()
        )

        return SystemSnapshot(
            volumes: cachedVolumes,
            deviceSamples: currentSamples,
            nfsMetrics: cachedNFS,
            nfsMounts: cachedNFSMounts,
            nfsUsers: cachedNFSUsers,
            nfsUserRates: cachedNFSUserRates,
            processIO: cachedProcessIO,
            quotas: cachedQuotas,
            alerts: alerts,
            capturedAt: now
        )
    }

    private func capacityThresholds() -> CapacityThresholds {
        let defaults = UserDefaults.standard
        let warningPercent = defaults.object(forKey: "capacityWarningThreshold") as? Double ?? 20
        let criticalPercent = defaults.object(forKey: "capacityCriticalThreshold") as? Double ?? 10

        return CapacityThresholds(
            warningFreeFraction: warningPercent / 100,
            criticalFreeFraction: criticalPercent / 100
        )
    }

    private func nfsUserThresholds() -> NFSUserAlertThresholds {
        let defaults = UserDefaults.standard
        let writeMegabytesPerSecond = defaults.object(forKey: "nfsUserWriteBurstMBps") as? Double ?? 100
        let requestsPerSecond = defaults.object(forKey: "nfsUserRequestBurstPerSecond") as? Double ?? 1_000

        return NFSUserAlertThresholds(
            writeBytesPerSecond: writeMegabytesPerSecond * 1_000_000,
            requestsPerSecond: requestsPerSecond
        )
    }
}
