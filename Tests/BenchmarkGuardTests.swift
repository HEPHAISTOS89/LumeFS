import XCTest
@testable import LumeFS

final class BenchmarkGuardTests: XCTestCase {
    private let guardrail = BenchmarkGuard()

    func testRejectsSizesOutsideBoundedRange() {
        XCTAssertThrowsError(try guardrail.byteCount(for: 0))
        XCTAssertThrowsError(try guardrail.byteCount(for: 257))
    }

    func testConvertsMaximumSizeToBytes() throws {
        XCTAssertEqual(
            try guardrail.byteCount(for: 256),
            256 * 1_048_576
        )
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
