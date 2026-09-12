import XCTest
@testable import LumeFS

final class QuotaCollectorTests: XCTestCase {
    func testNoQuotaIsExplicitlyUnavailable() {
        let collector = QuotaCollector(commandRunner: SystemCommandRunner())
        let snapshots = collector.parse(
            output: "Disk quotas for user example (uid 501): none"
        )

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.provenance, .unavailable)
        XCTAssertTrue(snapshots.first?.message.contains("No file-system quota") == true)
    }

    func testUnexpectedQuotaOutputIsPreservedAsLiveEvidence() {
        let collector = QuotaCollector(commandRunner: SystemCommandRunner())
        let snapshots = collector.parse(output: "quota report from mounted server")

        XCTAssertEqual(snapshots.first?.provenance, .live)
        XCTAssertEqual(snapshots.first?.message, "quota report from mounted server")
    }

    func testParsesStructuredQuotaRowIntoBytes() {
        let output = """
        Disk quotas for user example (uid 501):
          Filesystem  usage  quota  limit  grace  files  quota  limit  grace
          server:/models  1024  2048  4096  0  3  0  0  0
        """
        let snapshots = QuotaCollector(
            commandRunner: SystemCommandRunner()
        ).parse(output: output)

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].mountPoint, "server:/models")
        XCTAssertEqual(snapshots[0].usedBytes, 1_048_576)
        XCTAssertEqual(snapshots[0].softLimitBytes, 2_097_152)
        XCTAssertEqual(snapshots[0].hardLimitBytes, 4_194_304)
    }

    func testNoneInsideFilesystemNameDoesNotHideQuota() {
        let snapshots = QuotaCollector(commandRunner: SystemCommandRunner()).parse(
            output: "server:/nonempty 1024 2048 4096 0 3 0 0 0"
        )
        XCTAssertEqual(snapshots.first?.provenance, .live)
        XCTAssertEqual(snapshots.first?.usedBytes, 1_048_576)
    }

    func testParsesWrappedRemoteQuotaRow() {
        let output = """
        Disk quotas for user example (uid 501):
          Filesystem  usage  quota  limit  grace  files  quota  limit  grace
          127.0.0.1:/private/very-long-export-name
                       64*    128    256          1      0      0
        """
        let snapshots = QuotaCollector(
            commandRunner: SystemCommandRunner()
        ).parse(output: output)

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].usedBytes, 65_536)
        XCTAssertEqual(snapshots[0].softLimitBytes, 131_072)
        XCTAssertEqual(snapshots[0].hardLimitBytes, 262_144)
    }
}
