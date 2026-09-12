import Foundation

struct AlertRuleEngine: Sendable {
    func evaluate(
        volumes: [VolumeSnapshot],
        samples: [DeviceIOSample],
        nfs: NFSClientMetrics,
        previousNFS: NFSClientMetrics?,
        capacityThresholds: CapacityThresholds = .default,
        quotas: [QuotaSnapshot] = []
    ) -> [MonitoringAlert] {
        var alerts = volumeAlerts(volumes, thresholds: capacityThresholds)
        alerts.append(contentsOf: deviceAlerts(samples))
        alerts.append(contentsOf: quotas.compactMap { quota in
            guard let severity = quota.limitSeverity else { return nil }
            return MonitoringAlert(
                id: "quota-\(quota.id)",
                ruleID: "user.quota.\(severity == .critical ? "hard" : "soft")",
                severity: severity,
                title: severity == .critical ? "User quota reached" : "User soft quota reached",
                message: "\(quota.subject) on \(quota.mountPoint)",
                evidence: "Used \(MetricFormatter.bytes(quota.usedBytes ?? 0)); soft \(quota.softLimitBytes.map(MetricFormatter.bytes) ?? "none"); hard \(quota.hardLimitBytes.map(MetricFormatter.bytes) ?? "none")",
                recommendation: "Free files you own or ask the storage administrator about your limit. Soft-limit grace periods are not evaluated.",
                relatedVolumeID: volumes.first { quota.applies(to: $0) }?.id,
                createdAt: quota.capturedAt,
                provenance: quota.provenance
            )
        })
        alerts.append(contentsOf: nfsAlerts(current: nfs, previous: previousNFS))

        return alerts.sorted {
            if $0.severity != $1.severity {
                return $0.severity > $1.severity
            }
            return $0.createdAt > $1.createdAt
        }
    }

    private func volumeAlerts(
        _ volumes: [VolumeSnapshot],
        thresholds: CapacityThresholds
    ) -> [MonitoringAlert] {
        volumes.compactMap { volume in
            if let smartStatus = volume.smartStatus,
               smartStatus.caseInsensitiveCompare("Verified") != .orderedSame {
                return MonitoringAlert(
                    id: "smart-\(volume.id)",
                    ruleID: "device.smart.unhealthy",
                    severity: .critical,
                    title: "Storage health requires attention",
                    message: "\(volume.name) reports SMART status \(smartStatus).",
                    evidence: "SMART status: \(smartStatus)",
                    recommendation: "Pause write-heavy workloads and inspect the device before continuing.",
                    relatedVolumeID: volume.id,
                    createdAt: volume.capturedAt,
                    provenance: .live
                )
            }

            let capacitySeverity = volume.capacitySeverity(thresholds: thresholds)
            if capacitySeverity == .critical {
                return capacityAlert(
                    for: volume,
                    severity: .critical,
                    threshold: MetricFormatter.percentage(thresholds.criticalFreeFraction)
                )
            }

            if capacitySeverity == .warning {
                return capacityAlert(
                    for: volume,
                    severity: .warning,
                    threshold: MetricFormatter.percentage(thresholds.warningFreeFraction)
                )
            }

            return nil
        }
    }

    private func capacityAlert(
        for volume: VolumeSnapshot,
        severity: HealthSeverity,
        threshold: String
    ) -> MonitoringAlert {
        MonitoringAlert(
            id: "capacity-\(volume.id)",
            ruleID: "volume.capacity.\(severity.label.lowercased())",
            severity: severity,
            title: severity == .critical ? "Capacity is critically low" : "Capacity is running low",
            message: "\(volume.name) has \(MetricFormatter.bytes(volume.availableBytes)) available.",
            evidence: "\(MetricFormatter.percentage(volume.availableFraction)) free; threshold: \(threshold)",
            recommendation: "Free space or move the next model/checkpoint to another volume.",
            relatedVolumeID: volume.id,
            createdAt: volume.capturedAt,
            provenance: .live
        )
    }

    private func deviceAlerts(_ samples: [DeviceIOSample]) -> [MonitoringAlert] {
        samples.compactMap { sample in
            let errors = sample.readErrors + sample.writeErrors
            guard errors > 0 else { return nil }

            return MonitoringAlert(
                id: "io-errors-\(sample.deviceName)",
                ruleID: "device.io.errors",
                severity: .critical,
                title: "Block-storage errors observed",
                message: "\(sample.deviceName) reports \(errors) cumulative I/O errors.",
                evidence: "Read: \(sample.readErrors), write: \(sample.writeErrors)",
                recommendation: "Stop nonessential writes and inspect the physical device.",
                relatedVolumeID: nil,
                createdAt: sample.timestamp,
                provenance: .live
            )
        }
    }

    private func nfsAlerts(
        current: NFSClientMetrics,
        previous: NFSClientMetrics?
    ) -> [MonitoringAlert] {
        guard current.provenance == .live, let previous else { return [] }

        var alerts: [MonitoringAlert] = []
        if current.timedOut > previous.timedOut {
            alerts.append(
                MonitoringAlert(
                    id: "nfs-timeout",
                    ruleID: "nfs.rpc.timeout",
                    severity: .critical,
                    title: "NFS server stopped responding",
                    message: "New NFS RPC timeouts were observed.",
                    evidence: "+\(current.timedOut - previous.timedOut) timeout(s)",
                    recommendation: "Check server reachability and pause checkpoint writes.",
                    relatedVolumeID: nil,
                    createdAt: current.capturedAt,
                    provenance: .live
                )
            )
        }

        if current.retries > previous.retries {
            alerts.append(
                MonitoringAlert(
                    id: "nfs-retries",
                    ruleID: "nfs.rpc.retries",
                    severity: .warning,
                    title: "NFS requests are being retried",
                    message: "The client retried one or more NFS RPC requests.",
                    evidence: "+\(current.retries - previous.retries) retry/retries",
                    recommendation: "Inspect network loss, server load, and mount options.",
                    relatedVolumeID: nil,
                    createdAt: current.capturedAt,
                    provenance: .live
                )
            )
        }

        return alerts
    }
}
