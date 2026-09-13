import Foundation

struct AlertRuleEngine: Sendable {
    func evaluate(
        volumes: [VolumeSnapshot],
        samples: [DeviceIOSample],
        nfs: NFSClientMetrics,
        previousNFS: NFSClientMetrics?,
        capacityThresholds: CapacityThresholds = .default,
        quotas: [QuotaSnapshot] = [],
        nfsMounts: [NFSMountInfo] = [],
        nfsUserRates: [NFSUserActivityRate] = [],
        nfsUserThresholds: NFSUserAlertThresholds = .default
    ) -> [MonitoringAlert] {
        var alerts = volumeAlerts(volumes, thresholds: capacityThresholds)
        alerts.append(contentsOf: deviceAlerts(samples))
        alerts.append(contentsOf: nfsMountAlerts(nfsMounts, volumes: volumes))
        alerts.append(contentsOf: nfsUserAlerts(nfsUserRates, thresholds: nfsUserThresholds))
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
        var alerts = volumes.compactMap(smartAlert)

        // macOS normally mounts a protected System volume and its writable Data
        // partner from the same APFS container. They share capacity, so reporting
        // both as separate incidents makes one full disk look like two failures.
        let capacityGroups = Dictionary(grouping: volumes) { volume in
            if volume.fileSystem == .apfs, let container = volume.apfs?.containerReference {
                return "apfs-container:\(container)"
            }
            return "volume:\(volume.id)"
        }

        for group in capacityGroups.values {
            guard let representative = group.sorted(by: capacityRepresentativeOrder).first else { continue }
            let severity = group.map { $0.capacitySeverity(thresholds: thresholds) }.max() ?? .healthy
            let threshold: String
            switch severity {
            case .critical:
                threshold = MetricFormatter.percentage(thresholds.criticalFreeFraction)
            case .warning:
                threshold = MetricFormatter.percentage(thresholds.warningFreeFraction)
            case .healthy, .notice:
                continue
            }
            alerts.append(capacityAlert(
                for: representative,
                affectedVolumes: group,
                severity: severity,
                threshold: threshold
            ))
        }
        return alerts
    }

    private func capacityRepresentativeOrder(_ lhs: VolumeSnapshot, _ rhs: VolumeSnapshot) -> Bool {
        if lhs.availableFraction != rhs.availableFraction { return lhs.availableFraction < rhs.availableFraction }
        if lhs.isReadOnly != rhs.isReadOnly { return !lhs.isReadOnly }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// Absence of SMART data ("Not Supported", empty) is not a fault. Only explicit
    /// failure wording is critical; unknown wording is surfaced as a notice so an
    /// operator can look at it without a false red alert.
    private func smartAlert(for volume: VolumeSnapshot) -> MonitoringAlert? {
        switch volume.smartAssessment {
        case let .degraded(raw):
            return MonitoringAlert(
                id: "smart-\(volume.id)",
                ruleID: "device.smart.unhealthy",
                severity: .critical,
                title: "Storage health requires attention",
                message: "\(volume.name) reports SMART status \(raw).",
                evidence: "SMART status: \(raw)",
                recommendation: "Pause write-heavy workloads and inspect the device before continuing.",
                relatedVolumeID: volume.id,
                createdAt: volume.capturedAt,
                provenance: .live
            )
        case let .unrecognized(raw):
            return MonitoringAlert(
                id: "smart-unrecognized-\(volume.id)",
                ruleID: "device.smart.unrecognized",
                severity: .notice,
                title: "SMART status not recognized",
                message: "\(volume.name) reports an unfamiliar SMART status.",
                evidence: "SMART status: \(raw)",
                recommendation: "Check the device with Disk Utility. LumeFS does not treat unknown wording as a failure.",
                relatedVolumeID: volume.id,
                createdAt: volume.capturedAt,
                provenance: .live
            )
        case .verified, .notSupported:
            return nil
        }
    }

    private func capacityAlert(
        for volume: VolumeSnapshot,
        affectedVolumes: [VolumeSnapshot],
        severity: HealthSeverity,
        threshold: String
    ) -> MonitoringAlert {
        let container = volume.apfs?.containerReference
        let sharedContainer = affectedVolumes.count > 1 ? container : nil
        let alertID = sharedContainer.map { "capacity-container-\($0)" } ?? "capacity-\(volume.id)"
        let message: String
        let evidence: String
        if let sharedContainer {
            let names = affectedVolumes.map(\.name).sorted().joined(separator: ", ")
            message = "APFS container \(sharedContainer) has \(MetricFormatter.bytes(volume.availableBytes)) available across \(affectedVolumes.count) mounted volumes."
            evidence = "\(MetricFormatter.percentage(volume.availableFraction)) free; threshold: \(threshold); affects \(names)"
        } else {
            message = "\(volume.name) has \(MetricFormatter.bytes(volume.availableBytes)) available."
            evidence = "\(MetricFormatter.percentage(volume.availableFraction)) free; threshold: \(threshold)"
        }
        return MonitoringAlert(
            id: alertID,
            ruleID: "volume.capacity.\(severity.label.lowercased())",
            severity: severity,
            title: severity == .critical ? "Capacity is critically low" : "Capacity is running low",
            message: message,
            evidence: evidence,
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

    /// Kernel-reported mount state from `nfsstat -m`. Only LIVE records with an
    /// explicit flag raise anything; an UNAVAILABLE record is missing evidence.
    private func nfsMountAlerts(
        _ mounts: [NFSMountInfo],
        volumes: [VolumeSnapshot]
    ) -> [MonitoringAlert] {
        mounts.compactMap { mount -> MonitoringAlert? in
            guard mount.provenance == .live else { return nil }
            let volumeID = volumes.first { $0.mountPoint == mount.mountPoint }?.id
            let target = "\(mount.displayServer):\(mount.displayExport)"
            let flags = mount.statusFlags.joined(separator: ", ")

            if mount.isDead {
                return MonitoringAlert(
                    id: "nfs-mount-dead-\(mount.id)",
                    ruleID: "nfs.mount.dead",
                    severity: .critical,
                    title: "NFS mount is dead",
                    message: "\(mount.mountPoint) (\(target)) was marked dead by the kernel.",
                    evidence: "Status flags: \(flags)",
                    recommendation: "Operations on this mount will fail. Unmount it, restore the server, and mount again.",
                    relatedVolumeID: volumeID,
                    createdAt: mount.capturedAt,
                    provenance: .live
                )
            }
            if mount.isNotResponding {
                return MonitoringAlert(
                    id: "nfs-mount-notresp-\(mount.id)",
                    ruleID: "nfs.mount.not_responding",
                    severity: .critical,
                    title: "NFS server not responding",
                    message: "\(mount.mountPoint) (\(target)) is not responding.",
                    evidence: "Status flags: \(flags)",
                    recommendation: "Pause checkpoint writes to this mount and check the server and network path.",
                    relatedVolumeID: volumeID,
                    createdAt: mount.capturedAt,
                    provenance: .live
                )
            }
            if mount.inRecovery {
                return MonitoringAlert(
                    id: "nfs-mount-recovery-\(mount.id)",
                    ruleID: "nfs.mount.recovery",
                    severity: .warning,
                    title: "NFS mount is recovering",
                    message: "\(mount.mountPoint) (\(target)) is in state recovery.",
                    evidence: "Status flags: \(flags)",
                    recommendation: "Expect latency until recovery completes. Avoid starting new large writes.",
                    relatedVolumeID: volumeID,
                    createdAt: mount.capturedAt,
                    provenance: .live
                )
            }
            return nil
        }
    }

    /// Server-side per-user bursts from `nfsstat -u` deltas. Alert text carries the
    /// masked client address; the full address stays in the Attribution view.
    private func nfsUserAlerts(
        _ rates: [NFSUserActivityRate],
        thresholds: NFSUserAlertThresholds
    ) -> [MonitoringAlert] {
        rates.flatMap { rate -> [MonitoringAlert] in
            guard rate.activity.provenance == .live else { return [] }
            let who = "\(rate.activity.user) from \(rate.activity.maskedAddress)"
            let window = rate.intervalSeconds.formatted(.number.precision(.fractionLength(0...1)))
            var alerts: [MonitoringAlert] = []

            if rate.writeBytesPerSecond >= thresholds.writeBytesPerSecond {
                alerts.append(MonitoringAlert(
                    id: "nfs-user-write-\(rate.id)",
                    ruleID: "nfs.user.write_burst",
                    severity: .warning,
                    title: "NFS user write burst",
                    message: "\(who) is writing \(MetricFormatter.throughput(rate.writeBytesPerSecond)) to \(rate.activity.export).",
                    evidence: "\(MetricFormatter.throughput(rate.writeBytesPerSecond)) over \(window) s; threshold \(MetricFormatter.throughput(thresholds.writeBytesPerSecond))",
                    recommendation: "Confirm this job is expected. If not, contact the user before the export fills up; LumeFS does not stop clients.",
                    relatedVolumeID: nil,
                    createdAt: rate.activity.capturedAt,
                    provenance: .live
                ))
            }
            if rate.requestsPerSecond >= thresholds.requestsPerSecond {
                alerts.append(MonitoringAlert(
                    id: "nfs-user-requests-\(rate.id)",
                    ruleID: "nfs.user.request_burst",
                    severity: .warning,
                    title: "NFS user request burst",
                    message: "\(who) is issuing \(rate.requestsPerSecond.formatted(.number.precision(.fractionLength(0)))) requests/s on \(rate.activity.export).",
                    evidence: "\(rate.requestsPerSecond.formatted(.number.precision(.fractionLength(0)))) requests/s over \(window) s; threshold \(thresholds.requestsPerSecond.formatted(.number.precision(.fractionLength(0))))",
                    recommendation: "Metadata storms (many small files, retries in a loop) look like this. Check the client's job before it degrades the server.",
                    relatedVolumeID: nil,
                    createdAt: rate.activity.capturedAt,
                    provenance: .live
                ))
            }
            return alerts
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
