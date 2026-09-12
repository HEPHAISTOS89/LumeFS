import Foundation

actor MonitoringEngine {
    private let mountCollector = MountCollector()
    private let blockIOCollector = BlockIOCollector()
    private let commandRunner = SystemCommandRunner()
    private let alertEngine = AlertRuleEngine()

    private var cachedVolumes: [VolumeSnapshot] = []
    private var cachedNFS = NFSClientMetrics.unavailable
    private var cachedQuotas: [QuotaSnapshot] = []
    private var previousNFS: NFSClientMetrics?
    private var refreshCount = 0

    func refresh() async -> SystemSnapshot {
        let now = Date()
        refreshCount += 1

        async let samples = blockIOCollector.collect(at: now)

        if cachedVolumes.isEmpty || refreshCount.isMultiple(of: 10) {
            let volumes = mountCollector.collect(at: now)
            cachedVolumes = await APFSMetadataCollector(
                commandRunner: commandRunner
            ).enrich(volumes)
        }

        if refreshCount == 1 || refreshCount.isMultiple(of: 3) {
            previousNFS = cachedNFS.provenance == .live ? cachedNFS : nil
            cachedNFS = await NFSCollector(
                commandRunner: commandRunner
            ).collect(at: now)
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
            quotas: cachedQuotas
        )

        return SystemSnapshot(
            volumes: cachedVolumes,
            deviceSamples: currentSamples,
            nfsMetrics: cachedNFS,
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
}
