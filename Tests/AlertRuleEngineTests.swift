import XCTest
@testable import LumeFS

final class AlertRuleEngineTests: XCTestCase {
    func testCreatesCriticalCapacityAlertBelowTenPercentFree() {
        let volume = makeVolume(total: 1_000, available: 90)
        let alerts = AlertRuleEngine().evaluate(
            volumes: [volume],
            samples: [],
            nfs: .unavailable,
            previousNFS: nil
        )

        XCTAssertEqual(alerts.first?.ruleID, "volume.capacity.critical")
        XCTAssertEqual(alerts.first?.severity, .critical)
    }

    func testSharedAPFSContainerCreatesOneCapacityIncident() {
        let system = makeVolume(
            id: "system", name: "Macintosh HD", mountPoint: "/",
            total: 1_000, available: 60, isReadOnly: true, container: "disk3"
        )
        let data = makeVolume(
            id: "data", name: "Macintosh HD - Data", mountPoint: "/System/Volumes/Data",
            total: 1_000, available: 60, container: "disk3"
        )

        let alerts = AlertRuleEngine().evaluate(
            volumes: [system, data], samples: [], nfs: .unavailable, previousNFS: nil
        ).filter { $0.ruleID == "volume.capacity.critical" }

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.id, "capacity-container-disk3")
        XCTAssertEqual(alerts.first?.relatedVolumeID, "data", "the action should open the writable volume")
        XCTAssertTrue(alerts.first?.message.contains("2 mounted volumes") == true)
        XCTAssertTrue(alerts.first?.evidence.contains("Macintosh HD - Data") == true)
    }

    func testCreatesNFSRetryAlertOnlyForNewRetries() {
        let previous = makeNFS(retries: 2)
        let current = makeNFS(retries: 4)
        let alerts = AlertRuleEngine().evaluate(
            volumes: [],
            samples: [],
            nfs: current,
            previousNFS: previous
        )

        XCTAssertEqual(alerts.first?.ruleID, "nfs.rpc.retries")
        XCTAssertEqual(alerts.first?.evidence, "+2 retry/retries")
    }

    func testUsesConfiguredCapacityThresholds() {
        let volume = makeVolume(total: 1_000, available: 240)
        let alerts = AlertRuleEngine().evaluate(
            volumes: [volume],
            samples: [],
            nfs: .unavailable,
            previousNFS: nil,
            capacityThresholds: CapacityThresholds(
                warningFreeFraction: 0.25,
                criticalFreeFraction: 0.05
            )
        )

        XCTAssertEqual(alerts.first?.ruleID, "volume.capacity.warning")
        XCTAssertEqual(alerts.first?.evidence, "24% free; threshold: 25%")
    }

    func testDisplayAndAlertUseSameCustomThreshold() {
        let volume = makeVolume(total: 1000, available: 240)
        let thresholds = CapacityThresholds(warningFreeFraction: 0.30, criticalFreeFraction: 0.25)
        let severity = volume.capacitySeverity(thresholds: thresholds)
        let alerts = AlertRuleEngine().evaluate(volumes: [volume], samples: [], nfs: .unavailable,
                                               previousNFS: nil, capacityThresholds: thresholds)
        XCTAssertEqual(severity, .critical)
        XCTAssertEqual(alerts.first?.severity, severity)
    }

    func testMissingCapacityIsNotHealthy() {
        let volume = makeVolume(total: 0, available: 0)
        XCTAssertEqual(volume.capacitySeverity(thresholds: .default), .notice)
    }

    func testQuotaLimitsProduceActionableAlerts() {
        for (used, rule, severity) in [(Int64(100), "user.quota.soft", HealthSeverity.warning),
                                       (Int64(200), "user.quota.hard", HealthSeverity.critical)] {
            let quota = QuotaSnapshot(id: "test", subject: "fixture", mountPoint: "/",
                                      usedBytes: used, softLimitBytes: 100, hardLimitBytes: 200,
                                      message: "fixture", capturedAt: Date(), provenance: .live)
            let alerts = AlertRuleEngine().evaluate(volumes: [], samples: [], nfs: .unavailable,
                                                    previousNFS: nil, quotas: [quota])
            XCTAssertEqual(alerts.first?.ruleID, rule)
            XCTAssertEqual(alerts.first?.severity, severity)
            XCTAssertFalse(alerts.first?.recommendation.isEmpty ?? true)
        }
    }

    func testUnavailableQuotaNeverCreatesLiveAlert() {
        let quota = QuotaSnapshot(id: "test", subject: "fixture", mountPoint: "/", usedBytes: 200,
                                  softLimitBytes: 100, hardLimitBytes: 200, message: "fixture",
                                  capturedAt: Date(), provenance: .unavailable)
        XCTAssertTrue(AlertRuleEngine().evaluate(volumes: [], samples: [], nfs: .unavailable,
                                                previousNFS: nil, quotas: [quota]).isEmpty)
    }

    func testSMARTAssessmentClassifiesDiskutilWording() {
        XCTAssertEqual(SMARTAssessment.assess("Verified"), .verified)
        XCTAssertEqual(SMARTAssessment.assess(" verified "), .verified)
        XCTAssertEqual(SMARTAssessment.assess("Not Supported"), .notSupported)
        XCTAssertEqual(SMARTAssessment.assess(""), .notSupported)
        XCTAssertEqual(SMARTAssessment.assess(nil), .notSupported)
        XCTAssertEqual(SMARTAssessment.assess("Unknown"), .notSupported)
        XCTAssertEqual(SMARTAssessment.assess("Failing"), .degraded("Failing"))
        XCTAssertEqual(SMARTAssessment.assess("Predictive Failure"), .degraded("Predictive Failure"))
        XCTAssertEqual(SMARTAssessment.assess("Zebra"), .unrecognized("Zebra"))
        XCTAssertFalse(SMARTAssessment.notSupported.isEvidence)
        XCTAssertTrue(SMARTAssessment.verified.isEvidence)
    }

    func testMissingOrUnsupportedSMARTNeverCreatesCriticalAlert() {
        for status in [nil, "", "Not Supported", "Unknown"] as [String?] {
            let volume = makeVolume(total: 1_000, available: 900, smartStatus: status)
            let alerts = AlertRuleEngine().evaluate(
                volumes: [volume], samples: [], nfs: .unavailable, previousNFS: nil
            )
            XCTAssertTrue(alerts.isEmpty, "Status \(String(describing: status)) produced \(alerts.map(\.ruleID))")
        }
    }

    func testOnlyExplicitlyDegradedSMARTIsCritical() {
        let failing = makeVolume(total: 1_000, available: 900, smartStatus: "Failing")
        let alerts = AlertRuleEngine().evaluate(
            volumes: [failing], samples: [], nfs: .unavailable, previousNFS: nil
        )
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.ruleID, "device.smart.unhealthy")
        XCTAssertEqual(alerts.first?.severity, .critical)
        XCTAssertEqual(alerts.first?.evidence, "SMART status: Failing")
    }

    func testUnrecognizedSMARTWordingIsOnlyANotice() {
        let odd = makeVolume(total: 1_000, available: 900, smartStatus: "Zebra")
        let alerts = AlertRuleEngine().evaluate(
            volumes: [odd], samples: [], nfs: .unavailable, previousNFS: nil
        )
        XCTAssertEqual(alerts.first?.ruleID, "device.smart.unrecognized")
        XCTAssertEqual(alerts.first?.severity, .notice)
    }

    func testSMARTNoticeDoesNotSuppressCapacityAlert() {
        // A volume can carry at most one volume-level alert per refresh; a degraded
        // device outranks capacity, but an unrecognized SMART string must not hide a
        // real capacity problem.
        let lowAndOdd = makeVolume(total: 1_000, available: 50, smartStatus: "Zebra")
        let alerts = AlertRuleEngine().evaluate(
            volumes: [lowAndOdd], samples: [], nfs: .unavailable, previousNFS: nil
        )
        XCTAssertTrue(alerts.contains { $0.ruleID == "volume.capacity.critical" })
    }

    func testNFSMountStatusFlagsRaiseKernelBackedAlerts() {
        let nfsVolume = VolumeSnapshot(
            id: "nfs-1", name: "models", mountPoint: "/Volumes/models", source: "nas.lab.example:/export/models",
            fileSystem: .nfs, fileSystemName: "nfs", totalBytes: 1_000, availableBytes: 900,
            isReadOnly: false, isLocal: false, capturedAt: Date()
        )
        let cases: [([String], String, HealthSeverity)] = [
            (["dead"], "nfs.mount.dead", .critical),
            (["not responding"], "nfs.mount.not_responding", .critical),
            (["dead", "not responding"], "nfs.mount.dead", .critical),
            (["recovery"], "nfs.mount.recovery", .warning)
        ]
        for (flags, rule, severity) in cases {
            let alerts = AlertRuleEngine().evaluate(
                volumes: [nfsVolume], samples: [], nfs: .unavailable, previousNFS: nil,
                nfsMounts: [makeMount(statusFlags: flags)]
            )
            XCTAssertEqual(alerts.count, 1, "flags \(flags)")
            XCTAssertEqual(alerts.first?.ruleID, rule)
            XCTAssertEqual(alerts.first?.severity, severity)
            XCTAssertEqual(alerts.first?.relatedVolumeID, "nfs-1")
            XCTAssertEqual(alerts.first?.evidence, "Status flags: \(flags.joined(separator: ", "))")
            XCTAssertEqual(alerts.first?.provenance, .live)
        }
    }

    func testRespondingOrUnavailableNFSMountRaisesNothing() {
        let healthy = makeMount(statusFlags: [])
        let unavailable = NFSMountInfo.unavailable(
            mountPoint: "/Volumes/models", source: "nas.lab.example:/export/models",
            message: "nfsstat exited with status 1", at: Date()
        )
        let alerts = AlertRuleEngine().evaluate(
            volumes: [], samples: [], nfs: .unavailable, previousNFS: nil,
            nfsMounts: [healthy, unavailable]
        )
        XCTAssertTrue(alerts.isEmpty, "got \(alerts.map(\.ruleID))")
    }

    func testNFSUserBurstsUseDocumentedThresholdsAndMaskedAddresses() {
        let thresholds = NFSUserAlertThresholds(writeBytesPerSecond: 100_000_000, requestsPerSecond: 1_000)

        let quiet = makeUserRate(writeBytesPerSecond: 99_999_999, requestsPerSecond: 999)
        XCTAssertTrue(AlertRuleEngine().evaluate(
            volumes: [], samples: [], nfs: .unavailable, previousNFS: nil,
            nfsUserRates: [quiet], nfsUserThresholds: thresholds
        ).isEmpty)

        let writer = makeUserRate(writeBytesPerSecond: 100_000_000, requestsPerSecond: 0)
        let writeAlerts = AlertRuleEngine().evaluate(
            volumes: [], samples: [], nfs: .unavailable, previousNFS: nil,
            nfsUserRates: [writer], nfsUserThresholds: thresholds
        )
        XCTAssertEqual(writeAlerts.map(\.ruleID), ["nfs.user.write_burst"])
        XCTAssertEqual(writeAlerts.first?.severity, .warning)
        XCTAssertTrue(writeAlerts.first?.message.contains("192.0.·.·") == true, writeAlerts.first?.message ?? "")
        XCTAssertFalse(writeAlerts.first?.message.contains("192.0.2.10") == true)
        XCTAssertTrue(
            writeAlerts.first?.evidence.contains("threshold \(MetricFormatter.throughput(100_000_000))") == true,
            writeAlerts.first?.evidence ?? ""
        )

        let storm = makeUserRate(writeBytesPerSecond: 500_000_000, requestsPerSecond: 5_000)
        let both = AlertRuleEngine().evaluate(
            volumes: [], samples: [], nfs: .unavailable, previousNFS: nil,
            nfsUserRates: [storm], nfsUserThresholds: thresholds
        )
        XCTAssertEqual(Set(both.map(\.ruleID)), ["nfs.user.write_burst", "nfs.user.request_burst"])
        XCTAssertTrue(both.allSatisfy { $0.provenance == .live && $0.relatedVolumeID == nil })
    }

    private func makeUserRate(writeBytesPerSecond: Double, requestsPerSecond: Double) -> NFSUserActivityRate {
        let activity = NFSUserActivity(
            id: "/export/models|alice@192.0.2.10", export: "/export/models", user: "alice", uid: nil,
            address: "192.0.2.10", requests: 10, readBytes: 0, writeBytes: 0, idleSeconds: 1,
            capturedAt: Date(), provenance: .live
        )
        return NFSUserActivityRate(
            activity: activity, intervalSeconds: 3, requestsPerSecond: requestsPerSecond,
            readBytesPerSecond: 0, writeBytesPerSecond: writeBytesPerSecond
        )
    }

    private func makeMount(statusFlags: [String]) -> NFSMountInfo {
        NFSMountInfo(
            id: "/Volumes/models", mountPoint: "/Volumes/models", source: "nas.lab.example:/export/models",
            server: "nas.lab.example", export: "/export/models", addresses: ["192.0.2.10"],
            nfsVersion: "4.1", transport: "tcp", parameters: ["vers=4.1", "tcp"], mountFlags: [],
            statusFlags: statusFlags, capturedAt: Date(), provenance: .live, message: nil
        )
    }

    private func makeVolume(
        id: String = "test",
        name: String = "Test",
        mountPoint: String = "/Volumes/Test",
        total: Int64,
        available: Int64,
        isReadOnly: Bool = false,
        container: String? = nil,
        smartStatus: String? = "Verified"
    ) -> VolumeSnapshot {
        var volume = VolumeSnapshot(
            id: id,
            name: name,
            mountPoint: mountPoint,
            source: "/dev/disk99",
            fileSystem: .apfs,
            fileSystemName: "apfs",
            totalBytes: total,
            availableBytes: available,
            isReadOnly: isReadOnly,
            isLocal: true,
            capturedAt: Date(),
            smartStatus: smartStatus,
            apfsVolumeQuotaBytes: nil,
            apfsVolumeReserveBytes: nil
        )
        if let container {
            volume.apfs = APFSVolumeDetails(containerReference: container)
        }
        return volume
    }

    private func makeNFS(retries: UInt64) -> NFSClientMetrics {
        NFSClientMetrics(
            requests: 10,
            retries: retries,
            timedOut: 0,
            invalidReplies: 0,
            readOperations: 0,
            writeOperations: 0,
            layoutGets: 0,
            layoutCommits: 0,
            layoutReturns: 0,
            deviceInfoRequests: 0,
            capturedAt: Date(),
            provenance: .live
        )
    }
}
