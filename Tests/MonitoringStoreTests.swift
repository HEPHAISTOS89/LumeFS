import AppKit
import SwiftUI
import XCTest
@testable import LumeFS

@MainActor
final class MonitoringStoreTests: XCTestCase {
    func testAppearancePreferenceResolution() {
        XCTAssertEqual(AppAppearance.resolve("unknown"), .system)
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.resolve("light").colorScheme, .light)
        XCTAssertEqual(AppAppearance.resolve("dark").colorScheme, .dark)
        XCTAssertEqual(AppAppearance.allCases.count, 3)
    }

    func testNavigationIconsUseAvailableSFSymbols() {
        for section in AppSection.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: section.symbolName, accessibilityDescription: nil),
                "Missing SF Symbol: \(section.symbolName)"
            )
        }
    }

    func testRefreshRepairsSelectionsWhenItemsDisappear() async {
        let snapshots = SnapshotQueue([
            snapshot(volumes: [volume("first"), volume("second")]),
            snapshot(volumes: [volume("second")]),
            snapshot(volumes: [])
        ])
        let store = MonitoringStore { await snapshots.next() }

        await store.refreshNow()
        XCTAssertEqual(store.selectedVolumeID, "first")
        store.selectedAlertID = "missing-alert"
        await store.refreshNow()
        XCTAssertEqual(store.selectedVolumeID, "second")
        XCTAssertNil(store.selectedAlertID)
        await store.refreshNow()
        XCTAssertNil(store.selectedVolumeID)
    }

    func testMissingWatchFolderShowsErrorWithoutRecordingSuccess() {
        let store = MonitoringStore()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store.watchFolder(missing)
        XCTAssertNotNil(store.fileActivityError)
        XCTAssertNil(store.watchedFolderLabel)
        XCTAssertTrue(store.activity.isEmpty)
    }

    func testUnavailableIOHasNoLiveHistory() async {
        let value = snapshot(volumes: [])
        let store = MonitoringStore { value }
        await store.refreshNow()
        XCTAssertEqual(store.ioProvenance, .unavailable)
        XCTAssertTrue(store.ioHistory.isEmpty)
        XCTAssertNotNil(store.lastUpdated)
    }

    func testRefreshDoesNotOverlap() async {
        let gate = SnapshotGate(snapshot: snapshot(volumes: []))
        let store = MonitoringStore { await gate.collect() }
        let first = Task { await store.refreshNow() }
        while !store.isRefreshing { await Task.yield() }

        await store.refreshNow()
        await gate.release()
        await first.value

        let calls = await gate.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(store.isRefreshing)
    }

    func testCancelledRefreshDoesNotApplySnapshot() async {
        let gate = SnapshotGate(snapshot: snapshot(volumes: [volume("late")]))
        let store = MonitoringStore { await gate.collect() }
        let refresh = Task { await store.refreshNow() }
        while !store.isRefreshing { await Task.yield() }
        refresh.cancel()
        await gate.release()
        await refresh.value
        XCTAssertTrue(store.volumes.isEmpty)
        XCTAssertNil(store.lastUpdated)
        XCTAssertFalse(store.isRefreshing)
    }

    func testCollectionFreshnessDistinguishesMissingStaleAndPausedData() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(CollectionFreshness.evaluate(isMonitoring: true, lastUpdated: nil, now: now), .connecting)
        XCTAssertEqual(CollectionFreshness.evaluate(isMonitoring: true, lastUpdated: now, now: now), .current)
        XCTAssertEqual(CollectionFreshness.evaluate(isMonitoring: true, lastUpdated: now.addingTimeInterval(-11), now: now), .delayed)
        XCTAssertEqual(CollectionFreshness.evaluate(isMonitoring: false, lastUpdated: now, now: now), .paused)
    }

    private func snapshot(volumes: [VolumeSnapshot]) -> SystemSnapshot {
        SystemSnapshot(volumes: volumes, deviceSamples: [], nfsMetrics: .unavailable,
                       quotas: [], alerts: [], capturedAt: Date())
    }

    private func volume(_ id: String) -> VolumeSnapshot {
        VolumeSnapshot(id: id, name: id, mountPoint: "/Volumes/\(id)", source: id,
                       fileSystem: .apfs, fileSystemName: "apfs", totalBytes: 1000,
                       availableBytes: 500, isReadOnly: false, isLocal: true, capturedAt: Date())
    }
}

private actor SnapshotQueue {
    private var snapshots: [SystemSnapshot]
    init(_ snapshots: [SystemSnapshot]) { self.snapshots = snapshots }
    func next() -> SystemSnapshot { snapshots.removeFirst() }
}

private actor SnapshotGate {
    let snapshot: SystemSnapshot
    private(set) var callCount = 0
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(snapshot: SystemSnapshot) { self.snapshot = snapshot }

    func collect() async -> SystemSnapshot {
        callCount += 1
        if !isReleased {
            await withCheckedContinuation { continuation = $0 }
        }
        return snapshot
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
