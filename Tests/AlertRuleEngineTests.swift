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

    private func makeVolume(total: Int64, available: Int64, smartStatus: String? = "Verified") -> VolumeSnapshot {
        VolumeSnapshot(
            id: "test",
            name: "Test",
            mountPoint: "/Volumes/Test",
            source: "/dev/disk99",
            fileSystem: .apfs,
            fileSystemName: "apfs",
            totalBytes: total,
            availableBytes: available,
            isReadOnly: false,
            isLocal: true,
            capturedAt: Date(),
            smartStatus: smartStatus,
            apfsVolumeQuotaBytes: nil,
            apfsVolumeReserveBytes: nil
        )
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
