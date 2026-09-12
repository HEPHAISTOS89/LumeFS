import XCTest
@testable import LumeFS

final class SystemCommandRunnerTests: XCTestCase {
    private let runner = SystemCommandRunner()

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
