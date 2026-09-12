import CoreServices
import XCTest
@testable import LumeFS

final class FileActivityCollectorTests: XCTestCase {
    func testMapsOperationsWithoutTreatingTypeHintsAsPaths() {
        let flags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemModified |
            kFSEventStreamEventFlagItemIsFile
        )

        let mapping = FileActivityCollector.map(flags: flags)

        XCTAssertEqual(mapping.operations, [.created, .contentModified])
        XCTAssertTrue(mapping.rescanReasons.isEmpty)
    }

    func testMapsEveryConditionThatRequiresARescan() {
        let flags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagRootChanged
        )

        let mapping = FileActivityCollector.map(flags: flags)

        XCTAssertEqual(
            mapping.rescanReasons,
            [
                .mustScanSubdirectories,
                .userQueueDroppedEvents,
                .kernelDroppedEvents,
                .watchedRootChanged
            ]
        )
        XCTAssertTrue(mapping.operations.contains(.rootChanged))
    }

    func testRedactionReturnsOnlyTheMostSpecificRootLabel() throws {
        let parent = try FileActivityRoot(
            url: URL(fileURLWithPath: "/private/tmp/LumeFS"),
            label: "Temporary Volume"
        )
        let child = try FileActivityRoot(
            url: URL(fileURLWithPath: "/private/tmp/LumeFS/Project"),
            label: "Project Root"
        )

        let label = FileActivityCollector.redactedRootLabel(
            forEventPath: "/private/tmp/LumeFS/Project/private-name.txt",
            roots: [parent, child]
        )

        XCTAssertEqual(label, "Project Root")
        XCTAssertFalse(label?.contains("private-name.txt") ?? true)
    }

    func testRejectsPathLikeLabels() {
        XCTAssertThrowsError(
            try FileActivityRoot(
                url: URL(fileURLWithPath: "/private/tmp"),
                label: "/Users/example/Secret"
            )
        )
    }

    func testBoundsDeliveryLatency() throws {
        let root = try FileActivityRoot(
            url: URL(fileURLWithPath: "/private/tmp"),
            label: "Temporary Volume"
        )

        XCTAssertEqual(
            FileActivityCollector(roots: [root], latency: -1).latency,
            FileActivityCollector.minimumLatency
        )
        XCTAssertEqual(
            FileActivityCollector(roots: [root], latency: 20).latency,
            FileActivityCollector.maximumLatency
        )
    }

    func testTemporaryDirectoryStreamIsBoundedAndRedacted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = try FileActivityRoot(
            url: directory,
            label: "Temporary Test Root"
        )
        let collector = FileActivityCollector(
            roots: [root],
            latency: 0.05
        )
        let eventReceived = expectation(description: "FSEvents callback")
        let stream = collector.events()

        let consumer = Task {
            do {
                for try await batch in stream {
                    guard let summary = batch.summaries.first else { continue }
                    XCTAssertEqual(summary.rootLabel, "Temporary Test Root")
                    XCTAssertFalse(summary.rootLabel.contains(directory.path))
                    XCTAssertGreaterThan(summary.eventCount, 0)
                    eventReceived.fulfill()
                    return
                }
            } catch {
                XCTFail("Unexpected stream failure: \(error)")
            }
        }

        let privateFile = directory.appendingPathComponent("private-name.txt")
        try Data("test".utf8).write(to: privateFile, options: .atomic)

        await fulfillment(of: [eventReceived], timeout: 3)
        collector.stop()
        consumer.cancel()
    }

    func testStopFinishesTheStreamWithoutWaitingForAnEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = try FileActivityRoot(
            url: directory,
            label: "Stop Test Root"
        )
        let collector = FileActivityCollector(roots: [root])
        let streamFinished = expectation(description: "Stream finished")
        let stream = collector.events()

        let consumer = Task {
            do {
                for try await _ in stream {}
                streamFinished.fulfill()
            } catch {
                XCTFail("Unexpected stream failure: \(error)")
            }
        }

        collector.stop()
        await fulfillment(of: [streamFinished], timeout: 1)
        consumer.cancel()
    }
}
