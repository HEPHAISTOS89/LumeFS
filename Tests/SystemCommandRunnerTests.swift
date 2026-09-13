import XCTest
@testable import LumeFS

final class SystemCommandRunnerTests: XCTestCase {
    private let runner = SystemCommandRunner()

    func testTimeoutTerminatesDisposableChildWithoutBlocking() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        let start = ContinuousClock.now
        do {
            _ = try await runner.runProcess(child, executable: .quota, timeout: .milliseconds(100))
            XCTFail("Expected timeout")
        } catch CommandRunnerError.timedOut {
            // Expected: this tests lifecycle, not the quota command itself.
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        try await assertChildTerminated(child)
    }

    func testCancellationTerminatesDisposableChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        let task = Task { try await runner.runProcess(child, executable: .quota) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !child.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(child.isRunning)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await assertChildTerminated(child)
    }

    private func assertChildTerminated(_ child: Process) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while child.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(child.isRunning, "Disposable child must not survive its operation")
    }

    func testPipeDrainReturnsWithoutWaitingForWriterToClose() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let reader = try BoundedCommandOutputReader(handle: pipe.fileHandleForReading)
        var output = Data()
        try reader.drain(into: &output, executable: .diskutil)
        XCTAssertTrue(output.isEmpty)
        try pipe.fileHandleForWriting.write(contentsOf: Data("first".utf8))
        try reader.drain(into: &output, executable: .diskutil)
        try pipe.fileHandleForWriting.write(contentsOf: Data("second".utf8))
        try reader.drain(into: &output, executable: .diskutil)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "firstsecond")
    }

    func testPipeDrainRejectsOutputBeyondBound() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let reader = try BoundedCommandOutputReader(handle: pipe.fileHandleForReading, maximumBytes: 8)
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: 9))
        var output = Data()
        XCTAssertThrowsError(try reader.drain(into: &output, executable: .diskutil)) { error in
            guard case CommandRunnerError.outputTooLarge = error else {
                return XCTFail("Expected an output limit error, got \(error)")
            }
        }
        XCTAssertLessThanOrEqual(output.count, 8)
    }

    func testAcceptsOnlyKnownCommandShapes() async {
        await XCTAssertNoThrowAsync {
            try await self.runner.validate(.diskutil, arguments: ["info", "-plist", "/"])
        }
        await XCTAssertNoThrowAsync {
            try await self.runner.validate(.nfsstat, arguments: ["-f", "JSON", "-c"])
        }
        await XCTAssertNoThrowAsync {
            try await self.runner.validate(.quota, arguments: ["-uv"])
        }
        await XCTAssertNoThrowAsync {
            try await self.runner.validate(.nfsstat, arguments: ["-m", "-f", "JSON", "/Volumes/models"])
        }
    }

    func testRejectsNFSMountQueriesOutsideTheSingleMountShape() async {
        await XCTAssertThrowsErrorAsync {
            try await self.runner.validate(.nfsstat, arguments: ["-m", "-f", "JSON"])
        }
        await XCTAssertThrowsErrorAsync {
            try await self.runner.validate(.nfsstat, arguments: ["-m", "-f", "JSON", "Volumes/models"])
        }
        await XCTAssertThrowsErrorAsync {
            try await self.runner.validate(.nfsstat, arguments: ["-m", "-f", "JSON", "/a", "/b"])
        }
        await XCTAssertThrowsErrorAsync {
            try await self.runner.validate(.nfsstat, arguments: ["-m", "-f", "JSON", "-z"])
        }
    }

    func testRejectsUnexpectedOptionsAndControlCharacters() async {
        await XCTAssertThrowsErrorAsync {
            try await self.runner.validate(.diskutil, arguments: ["eraseDisk", "APFS", "Test", "disk0"])
        }
        await XCTAssertThrowsErrorAsync {
            try await self.runner.validate(.diskutil, arguments: ["info", "-plist", "/Volumes/Test\nInjected"])
        }
        await XCTAssertThrowsErrorAsync {
            try await self.runner.validate(.nfsstat, arguments: ["-z"])
        }
    }
}

private func XCTAssertNoThrowAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        return
    }
}
