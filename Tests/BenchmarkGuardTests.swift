import XCTest
@testable import LumeFS

final class BenchmarkGuardTests: XCTestCase {
    private let guardrail = BenchmarkGuard()

    func testRejectsSizesOutsideBoundedRange() {
        XCTAssertThrowsError(try guardrail.byteCount(for: 0))
        XCTAssertThrowsError(try guardrail.byteCount(for: BenchmarkGuard.maximumMebibytes + 1))
    }

    func testConvertsMaximumSizeToBytes() throws {
        XCTAssertEqual(BenchmarkGuard.maximumMebibytes, 1_024)
        XCTAssertEqual(
            try guardrail.byteCount(for: 1_024),
            1_024 * 1_048_576
        )
    }

    func testSelectableSizesStayInsideTheGuard() throws {
        XCTAssertEqual(BenchmarkGuard.defaultMebibytes, 128)
        XCTAssertTrue(BenchmarkGuard.selectableMebibytes.contains(BenchmarkGuard.defaultMebibytes))
        for size in BenchmarkGuard.selectableMebibytes {
            XCTAssertNoThrow(try guardrail.byteCount(for: size))
        }
        // The largest offered size still needs twice its bytes free.
        let largest = try guardrail.byteCount(for: BenchmarkGuard.selectableMebibytes.max()!)
        XCTAssertThrowsError(try guardrail.validateSpace(requiredBytes: largest, availableBytes: largest * 2 - 1))
        XCTAssertNoThrow(try guardrail.validateSpace(requiredBytes: largest, availableBytes: largest * 2))
    }

    func testCancelledRunThrowsCancellationAndLeavesNoWorkspace() async {
        let before = benchmarkWorkspaces()
        let task = Task { try await DiskBenchmark().run(mebibytes: 64) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled benchmark must not return a result")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(benchmarkWorkspaces(), before, "cancellation must remove the temporary workspace")
    }

    private func benchmarkWorkspaces() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("LumeFS-Benchmark-") })
    }

    func testRequiresTwoTimesFreeSpace() {
        XCTAssertThrowsError(
            try guardrail.validateSpace(
                requiredBytes: 100,
                availableBytes: 199
            )
        )
        XCTAssertNoThrow(
            try guardrail.validateSpace(
                requiredBytes: 100,
                availableBytes: 200
            )
        )
    }

    func testRejectsPathOutsideWorkspace() {
        let workspace = URL(fileURLWithPath: "/tmp/LumeFS-Benchmarks")
        let safeFile = workspace.appendingPathComponent("sample.bin")
        let unsafeFile = URL(fileURLWithPath: "/tmp/sample.bin")

        XCTAssertNoThrow(try guardrail.validate(fileURL: safeFile, isInside: workspace))
        XCTAssertThrowsError(try guardrail.validate(fileURL: unsafeFile, isInside: workspace))
    }
}
