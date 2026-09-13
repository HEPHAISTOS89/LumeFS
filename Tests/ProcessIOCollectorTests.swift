import Darwin
import XCTest
@testable import LumeFS

final class ProcessIOCollectorTests: XCTestCase {
    func testWorkloadHintMatchesRuntimeNamesOnly() {
        XCTAssertEqual(WorkloadHint.token(forProcessName: "Python"), "python")
        XCTAssertEqual(WorkloadHint.token(forProcessName: "python3.12"), "python")
        XCTAssertEqual(WorkloadHint.token(forProcessName: "ollama"), "ollama")
        XCTAssertEqual(WorkloadHint.token(forProcessName: "ollama-runner"), "ollama")
        XCTAssertEqual(WorkloadHint.token(forProcessName: "exo"), "exo")
        XCTAssertEqual(WorkloadHint.token(forProcessName: "openclaw"), "openclaw")
        XCTAssertEqual(WorkloadHint.token(forProcessName: "mlx_lm.server"), "mlx")
        XCTAssertEqual(WorkloadHint.token(forProcessName: "llama-server"), "llama")

        XCTAssertNil(WorkloadHint.token(forProcessName: "exocortex"), "short tokens need an exact word")
        XCTAssertNil(WorkloadHint.token(forProcessName: "Safari"))
        XCTAssertNil(WorkloadHint.token(forProcessName: "kernel_task"))
        XCTAssertNil(WorkloadHint.token(forProcessName: "mds_stores"))
        XCTAssertNil(WorkloadHint.token(forProcessName: ""))
    }

    func testSamplesNeedSameIdentityAndNeverGoNegative() {
        let start = Date(timeIntervalSince1970: 1_000)
        let later = start.addingTimeInterval(2)
        func counters(pid: Int32, startTime: Int64 = 10, read: UInt64, written: UInt64, at date: Date) -> ProcessCounters {
            ProcessCounters(pid: pid, startTime: startTime, name: "proc\(pid)", uid: 501,
                            bytesRead: read, bytesWritten: written, capturedAt: date)
        }
        let previous = [
            counters(pid: 1, read: 100, written: 100, at: start),
            counters(pid: 2, read: 100, written: 100, at: start),
            counters(pid: 3, read: 100, written: 100, at: start),
            counters(pid: 4, read: 500, written: 500, at: start)
        ]
        let current = [
            counters(pid: 1, read: 300, written: 100, at: later),            // reads 100 B/s
            counters(pid: 2, startTime: 99, read: 900, written: 900, at: later), // recycled PID: no rate
            counters(pid: 3, read: 100, written: 5_100, at: later),          // writes 2,500 B/s
            counters(pid: 4, read: 10, written: 10, at: later),              // counters went backwards
            counters(pid: 5, read: 9, written: 9, at: later)                 // first observation
        ]
        let previousMap = Dictionary(uniqueKeysWithValues: previous.map { ($0.identity, $0) })
        let currentMap = Dictionary(uniqueKeysWithValues: current.map { ($0.identity, $0) })

        let samples = ProcessIOCollector.samples(current: currentMap, previous: previousMap) { "user\($0)" }

        XCTAssertEqual(samples.map(\.pid), [3, 1], "sorted by total rate, only processes with a rate")
        XCTAssertEqual(samples[0].writeBytesPerSecond, 2_500)
        XCTAssertEqual(samples[0].readBytesPerSecond, 0)
        XCTAssertEqual(samples[0].intervalSeconds, 2)
        XCTAssertEqual(samples[0].cumulativeWriteBytes, 5_100)
        XCTAssertEqual(samples[0].userName, "user501")
        XCTAssertEqual(samples[0].provenance, .live)
        XCTAssertEqual(samples[1].readBytesPerSecond, 100)
        XCTAssertTrue(ProcessIOCollector.samples(current: currentMap, previous: [:]) { _ in "" }.isEmpty)
    }

    func testZeroIntervalProducesNoRate() {
        let date = Date()
        let a = ProcessCounters(pid: 7, startTime: 1, name: "a", uid: 0, bytesRead: 0, bytesWritten: 0, capturedAt: date)
        let b = ProcessCounters(pid: 7, startTime: 1, name: "a", uid: 0, bytesRead: 10, bytesWritten: 10, capturedAt: date)
        XCTAssertTrue(ProcessIOCollector.samples(current: [b.identity: b], previous: [a.identity: a]) { _ in "" }.isEmpty)
    }

    func testProcessListIncludesCurrentProcess() throws {
        let processes = try XCTUnwrap(ProcessIOCollector.listProcesses())
        let me = try XCTUnwrap(processes.first { $0.pid == getpid() })
        XCTAssertEqual(me.uid, getuid())
        XCTAssertFalse(me.shortName.isEmpty)
        XCTAssertGreaterThan(me.startTime, 0)
    }

    func testKernelGrantsOwnCountersAndDeniesOtherUsersWithoutRoot() throws {
        let processes = try XCTUnwrap(ProcessIOCollector.listProcesses())
        let me = try XCTUnwrap(processes.first { $0.pid == getpid() })

        guard case let .success(counters) = ProcessIOCollector.readCounters(for: me, at: Date()) else {
            return XCTFail("Expected readable counters for the current process")
        }
        XCTAssertEqual(counters.pid, getpid())
        XCTAssertEqual(counters.uid, getuid())
        XCTAssertFalse(counters.name.isEmpty)

        guard getuid() != 0 else {
            throw XCTSkip("Running as root: every process is readable, so the denial path cannot be exercised.")
        }
        let launchd = try XCTUnwrap(processes.first { $0.pid == 1 })
        guard case .failure(.denied) = ProcessIOCollector.readCounters(for: launchd, at: Date()) else {
            return XCTFail("Expected EPERM for launchd (uid 0) when not root")
        }
    }

    func testLiveCollectionReportsCoverageHonestly() async {
        let collector = ProcessIOCollector()
        let first = await collector.collect()
        XCTAssertEqual(first.provenance, .live, first.message ?? "")
        XCTAssertGreaterThan(first.totalProcessCount, 0)
        XCTAssertGreaterThanOrEqual(first.readableProcessCount, 1)
        XCTAssertTrue(first.samples.isEmpty, "the first observation cannot have a rate")
        XCTAssertLessThanOrEqual(first.readableProcessCount + first.deniedProcessCount, first.totalProcessCount)
        if getuid() != 0 {
            XCTAssertGreaterThan(first.deniedProcessCount, 0, "system daemons run as other users")
        }

        let second = await collector.collect()
        XCTAssertEqual(second.provenance, .live)
        XCTAssertLessThanOrEqual(second.samples.count, ProcessIOCollector.maximumSamples)
        for sample in second.samples {
            XCTAssertGreaterThan(sample.totalBytesPerSecond, 0)
            XCTAssertGreaterThan(sample.intervalSeconds, 0)
            XCTAssertFalse(sample.name.isEmpty)
        }
    }
}
