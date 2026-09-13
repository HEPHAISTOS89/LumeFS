import XCTest
@testable import LumeFS

final class AlertHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Ledger

    func testReconcileOpensRefreshesAndClearsEntries() {
        var ledger = AlertHistoryLedger()

        let first = ledger.reconcile(activeAlerts: [alert("capacity-a", severity: .warning)], at: t0)
        XCTAssertEqual(first.raised.count, 1)
        XCTAssertTrue(first.cleared.isEmpty)
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].state, .active)
        XCTAssertEqual(ledger.entries[0].raisedAt, t0)

        // Same id, escalated payload: the open entry is refreshed, not duplicated.
        let second = ledger.reconcile(activeAlerts: [alert("capacity-a", severity: .critical)], at: t0 + 1)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].alert.severity, .critical)
        XCTAssertEqual(ledger.entries[0].lastSeenAt, t0 + 1)
        XCTAssertEqual(ledger.entries[0].raisedAt, t0)

        // Id disappears: closed with the refresh time; a new id opens on top.
        let third = ledger.reconcile(activeAlerts: [alert("nfs-timeout", severity: .critical)], at: t0 + 2)
        XCTAssertEqual(third.cleared.map(\.alert.id), ["capacity-a"])
        XCTAssertEqual(third.raised.map(\.alert.id), ["nfs-timeout"])
        XCTAssertEqual(ledger.entries.map(\.alert.id), ["nfs-timeout", "capacity-a"])
        XCTAssertEqual(ledger.entries[1].state, .cleared)
        XCTAssertEqual(ledger.entries[1].clearedAt, t0 + 2)

        // The same id coming back is a new occurrence, with a distinct entry id.
        let fourth = ledger.reconcile(activeAlerts: [alert("nfs-timeout"), alert("capacity-a")], at: t0 + 3)
        XCTAssertEqual(fourth.raised.map(\.alert.id), ["capacity-a"])
        XCTAssertEqual(ledger.entries.count, 3)
        XCTAssertNotEqual(ledger.entries[0].id, ledger.entries[2].id)
        XCTAssertEqual(ledger.openEntries.count, 2)
    }

    func testAcknowledgeAppliesOnlyToOpenUnacknowledgedEntries() {
        var ledger = AlertHistoryLedger()
        ledger.reconcile(activeAlerts: [alert("io-errors-disk0")], at: t0)
        let entryID = ledger.entries[0].id

        XCTAssertFalse(ledger.acknowledge(entryID: "missing", at: t0 + 1))
        XCTAssertTrue(ledger.acknowledge(entryID: entryID, at: t0 + 1))
        XCTAssertEqual(ledger.entries[0].state, .acknowledged)
        XCTAssertTrue(ledger.entries[0].isOpen, "acknowledgement must not close an alert that is still firing")
        XCTAssertFalse(ledger.acknowledge(entryID: entryID, at: t0 + 2), "second acknowledgement is a no-op")
        XCTAssertEqual(ledger.entries[0].acknowledgedAt, t0 + 1)

        // Still reported: stays open and acknowledged.
        ledger.reconcile(activeAlerts: [alert("io-errors-disk0")], at: t0 + 3)
        XCTAssertEqual(ledger.entries[0].state, .acknowledged)

        // Gone: cleared wins over acknowledged, and acknowledging a closed entry fails.
        ledger.reconcile(activeAlerts: [], at: t0 + 4)
        XCTAssertEqual(ledger.entries[0].state, .cleared)
        XCTAssertFalse(ledger.acknowledge(entryID: entryID, at: t0 + 5))
    }

    func testTrimDropsOldestClosedEntriesAndKeepsOpenOnes() {
        var ledger = AlertHistoryLedger()
        let overflow = 7
        for index in 0..<(AlertHistoryLedger.maximumEntries + overflow) {
            let date = t0 + TimeInterval(index * 2)
            ledger.reconcile(activeAlerts: [alert("flap-\(index)")], at: date)
            ledger.reconcile(activeAlerts: [], at: date + 1)
        }
        XCTAssertEqual(ledger.entries.count, AlertHistoryLedger.maximumEntries)
        XCTAssertEqual(ledger.entries.last?.alert.id, "flap-\(overflow)", "oldest closed entries are dropped first")

        // Open entries survive even when the closed ones fill the cap.
        let openIDs = (0..<3).map { "open-\($0)" }
        ledger.reconcile(activeAlerts: openIDs.map { alert($0) }, at: t0 + 10_000)
        for index in 0..<10 {
            let date = t0 + 20_000 + TimeInterval(index * 2)
            ledger.reconcile(activeAlerts: openIDs.map { alert($0) } + [alert("late-\(index)")], at: date)
            ledger.reconcile(activeAlerts: openIDs.map { alert($0) }, at: date + 1)
        }
        XCTAssertEqual(ledger.entries.count, AlertHistoryLedger.maximumEntries)
        XCTAssertEqual(Set(ledger.openEntries.map(\.alert.id)), Set(openIDs))
    }

    func testClearHistoryKeepsOpenEntriesByDefault() {
        var ledger = AlertHistoryLedger()
        ledger.reconcile(activeAlerts: [alert("a"), alert("b")], at: t0)
        ledger.reconcile(activeAlerts: [alert("a")], at: t0 + 1)
        ledger.clearHistory()
        XCTAssertEqual(ledger.entries.map(\.alert.id), ["a"])
        ledger.clearHistory(keepOpen: false)
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    // MARK: Persistence

    func testPersistenceRoundTripPreservesLifecycleFields() throws {
        let persistence = temporaryPersistence()
        var ledger = AlertHistoryLedger()
        ledger.reconcile(activeAlerts: [alert("a", severity: .critical), alert("b")], at: t0)
        XCTAssertTrue(ledger.acknowledge(entryID: ledger.entries.first { $0.alert.id == "a" }!.id, at: t0 + 1))
        ledger.reconcile(activeAlerts: [alert("a", severity: .critical)], at: t0 + 2)

        try persistence.save(ledger)
        let loaded = persistence.load()

        XCTAssertEqual(loaded, ledger)
        XCTAssertEqual(loaded.entries.count, 2)
        XCTAssertEqual(loaded.openEntries.map(\.alert.id), ["a"])
        XCTAssertEqual(loaded.entries.first { $0.alert.id == "b" }?.state, .cleared)

        let text = try String(contentsOf: persistence.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(text.contains("2027-01-15T08:00:00Z"), "dates are ISO-8601 so the file is inspectable")
    }

    func testMissingFileLoadsAnEmptyLedger() {
        let persistence = temporaryPersistence()
        XCTAssertEqual(persistence.load(), AlertHistoryLedger())
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.fileURL.path))
    }

    func testCorruptFileIsSetAsideInsteadOfDeleted() throws {
        let persistence = temporaryPersistence()
        try FileManager.default.createDirectory(at: persistence.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: persistence.fileURL)

        XCTAssertEqual(persistence.load(), AlertHistoryLedger())
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.fileURL.path))
        let damaged = persistence.fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
        XCTAssertEqual(try String(contentsOf: damaged, encoding: .utf8), "{not json")
    }

    func testForeignSchemaVersionIsSetAside() throws {
        let persistence = temporaryPersistence()
        try FileManager.default.createDirectory(at: persistence.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"schemaVersion\": 99, \"entries\": []}".utf8).write(to: persistence.fileURL)

        XCTAssertEqual(persistence.load(), AlertHistoryLedger())
        let damaged = persistence.fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path))
    }

    // MARK: Store integration

    @MainActor
    func testStoreReconcilesPersistsAndReloadsHistory() async throws {
        let persistence = temporaryPersistence()
        // Whole seconds only: the ledger is written with ISO-8601 dates without fractions.
        let queue = SnapshotSequence([
            snapshot(alerts: [alert("capacity-x", severity: .critical)], at: t0),
            snapshot(alerts: [alert("capacity-x", severity: .critical)], at: t0 + 10),
            snapshot(alerts: [], at: t0 + 20)
        ])
        let store = MonitoringStore(collectSnapshot: { await queue.next() }, alertHistoryPersistence: persistence)
        XCTAssertNil(store.criticalAlertNotifier, "tests never construct a notification bridge")

        await store.refreshNow()
        XCTAssertEqual(store.alertHistory.count, 1)
        XCTAssertEqual(store.alertHistory[0].state, .active)
        XCTAssertEqual(store.historyEntry(forAlertID: "capacity-x")?.raisedAt, t0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.fileURL.path), "a raise is persisted immediately")

        let entryID = store.alertHistory[0].id
        XCTAssertTrue(store.acknowledgeAlert(entryID: entryID, at: t0 + 5))
        XCTAssertEqual(store.alertHistory[0].state, .acknowledged)
        XCTAssertTrue(store.activity.contains { $0.eventDescription.hasPrefix("Acknowledged alert:") })

        await store.refreshNow()
        XCTAssertEqual(store.alertHistory[0].state, .acknowledged)
        XCTAssertEqual(store.alertHistory[0].lastSeenAt, t0 + 10)

        await store.refreshNow()
        XCTAssertEqual(store.alertHistory[0].state, .cleared)
        XCTAssertEqual(store.alertHistory[0].clearedAt, t0 + 20)
        XCTAssertNil(store.historyEntry(forAlertID: "capacity-x"))
        XCTAssertNil(store.alertHistoryError)

        // A second store, same file: the closed entry comes back with its dates.
        let reloaded = MonitoringStore(collectSnapshot: { await queue.next() }, alertHistoryPersistence: persistence)
        XCTAssertEqual(reloaded.alertHistory.count, 1)
        XCTAssertEqual(reloaded.alertHistory[0].id, entryID)
        XCTAssertEqual(reloaded.alertHistory[0].acknowledgedAt, t0 + 5)
        XCTAssertEqual(reloaded.alertHistory[0].clearedAt, t0 + 20)

        reloaded.clearClosedAlertHistory()
        XCTAssertTrue(reloaded.alertHistory.isEmpty)
        XCTAssertTrue(persistence.load().entries.isEmpty)
    }

    @MainActor
    func testStoreWithoutPersistenceKeepsHistoryInMemoryOnly() async {
        let snapshotValue = snapshot(alerts: [alert("a")], at: t0)
        let store = MonitoringStore { snapshotValue }
        XCTAssertNil(store.alertHistoryFileURL)
        await store.refreshNow()
        XCTAssertEqual(store.alertHistory.count, 1)
        XCTAssertNil(store.alertHistoryError)
    }

    // MARK: Notification planner

    func testPlannerNotifiesCriticalOnlyOncePerRefreshAndCoolsDownPerAlert() {
        var planner = CriticalAlertNotificationPlanner()
        let raised = [
            entry(alert("io-errors-disk0", severity: .critical, title: "Block-storage errors observed"), at: t0),
            entry(alert("capacity-a", severity: .warning, title: "Capacity is running low"), at: t0),
            entry(alert("nfs-timeout", severity: .critical, title: "NFS server stopped responding"), at: t0)
        ]

        let plan = planner.plan(raised: raised, at: t0)
        XCTAssertEqual(plan?.alertIDs, ["io-errors-disk0", "nfs-timeout"], "warnings never notify")
        XCTAssertEqual(plan?.title, "2 critical storage alerts")
        XCTAssertEqual(plan?.body, "Block-storage errors observed; NFS server stopped responding. Open LumeFS for evidence.")

        // Flapping: the same ids re-raised inside the cooldown stay silent.
        XCTAssertNil(planner.plan(raised: raised, at: t0 + 30))
        XCTAssertNil(planner.plan(raised: raised, at: t0 + CriticalAlertNotificationPlanner.cooldown - 1))

        // A new critical id inside the cooldown is announced alone.
        let fresh = entry(alert("nfs-mount-dead-x", severity: .critical, title: "NFS mount is dead"), at: t0 + 60)
        let second = planner.plan(raised: raised + [fresh], at: t0 + 60)
        XCTAssertEqual(second?.alertIDs, ["nfs-mount-dead-x"])
        XCTAssertEqual(second?.title, "Critical storage alert")
        XCTAssertEqual(second?.body, "NFS mount is dead. Open LumeFS for evidence.")

        // After the cooldown the original ids may notify again.
        let third = planner.plan(raised: raised, at: t0 + CriticalAlertNotificationPlanner.cooldown)
        XCTAssertEqual(third?.alertIDs, ["io-errors-disk0", "nfs-timeout"])
        XCTAssertNotEqual(plan?.identifier, third?.identifier)
    }

    func testPlannerBodyTruncatesLongLists() {
        var planner = CriticalAlertNotificationPlanner()
        let raised = (0..<5).map { entry(alert("c-\($0)", severity: .critical, title: "Title \($0)"), at: t0) }
        let plan = planner.plan(raised: raised, at: t0)
        XCTAssertEqual(plan?.title, "5 critical storage alerts")
        XCTAssertEqual(plan?.body, "Title 0; Title 1; Title 2; and 2 more. Open LumeFS for evidence.")
        XCTAssertNil(planner.plan(raised: [], at: t0))
    }

    // MARK: Helpers

    private func temporaryPersistence() -> AlertHistoryPersistence {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeFSTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AlertHistoryPersistence(fileURL: directory.appendingPathComponent("alert-history.json"))
    }

    private func alert(_ id: String, severity: HealthSeverity = .warning, title: String? = nil) -> MonitoringAlert {
        MonitoringAlert(
            id: id,
            ruleID: "test.rule",
            severity: severity,
            title: title ?? "Alert \(id)",
            message: "Message for \(id)",
            evidence: "evidence=\(id)",
            recommendation: "Look at \(id).",
            relatedVolumeID: nil,
            createdAt: t0,
            provenance: .live
        )
    }

    private func entry(_ alert: MonitoringAlert, at date: Date) -> AlertHistoryEntry {
        AlertHistoryEntry(id: "\(alert.id)#test", alert: alert, raisedAt: date, lastSeenAt: date, acknowledgedAt: nil, clearedAt: nil)
    }

    private func snapshot(alerts: [MonitoringAlert], at date: Date) -> SystemSnapshot {
        SystemSnapshot(volumes: [], deviceSamples: [], nfsMetrics: .unavailable, quotas: [], alerts: alerts, capturedAt: date)
    }
}

private actor SnapshotSequence {
    private var snapshots: [SystemSnapshot]
    init(_ snapshots: [SystemSnapshot]) { self.snapshots = snapshots }
    func next() -> SystemSnapshot {
        snapshots.isEmpty ? SystemSnapshot(volumes: [], deviceSamples: [], nfsMetrics: .unavailable, quotas: [], alerts: [], capturedAt: Date()) : snapshots.removeFirst()
    }
}
