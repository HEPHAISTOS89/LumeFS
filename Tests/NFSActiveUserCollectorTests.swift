import XCTest
@testable import LumeFS

/// Fixtures follow the JSON emitted by Apple's `nfsstat -u -f JSON`
/// (apple-oss-distributions/NFS: `nfsstat.c` `do_active_users_normal`,
/// `printer.c` `json_active_users`). They are derived from that source and
/// anonymized (RFC 5737 / 3849 addresses); they are not production captures.
final class NFSActiveUserCollectorTests: XCTestCase {
    private let collector = NFSActiveUserCollector(commandRunner: SystemCommandRunner())

    private let twoUsers = """
    {
      "NFS Active User Info": {
        "/export/models": {
          "alice@192.0.2.10": {"User": "alice", "Requests": 1200, "Read Bytes": 4096, "Write Bytes": 1073741824, "Idle": "0:00:02"},
          "501@2001:db8::7": {"Uuid": 501, "Requests": 40, "Read Bytes": 8192, "Write Bytes": 0, "Idle": "1:02:03"}
        },
        "/export/scratch": {
          "bob@192.0.2.11": {"User": "bob", "Requests": 10, "Read Bytes": 0, "Write Bytes": 512, "Idle": "0:00:45"}
        }
      }
    }
    """

    func testParsesUsersPerExportWithNamesUidsAndIdle() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try collector.parse(
            data: Data(twoUsers.utf8), serverState: .running, at: date
        )

        XCTAssertEqual(snapshot.provenance, .live)
        XCTAssertEqual(snapshot.serverState, .running)
        XCTAssertEqual(snapshot.capturedAt, date)
        XCTAssertNil(snapshot.message)
        XCTAssertEqual(snapshot.users.map(\.id), [
            "/export/models|alice@192.0.2.10",
            "/export/models|uid 501@2001:db8::7",
            "/export/scratch|bob@192.0.2.11"
        ])

        let alice = snapshot.users[0]
        XCTAssertEqual(alice.user, "alice")
        XCTAssertNil(alice.uid)
        XCTAssertEqual(alice.address, "192.0.2.10")
        XCTAssertEqual(alice.requests, 1_200)
        XCTAssertEqual(alice.readBytes, 4_096)
        XCTAssertEqual(alice.writeBytes, 1_073_741_824)
        XCTAssertEqual(alice.idleSeconds, 2)

        let unknown = snapshot.users[1]
        XCTAssertEqual(unknown.user, "uid 501")
        XCTAssertEqual(unknown.uid, 501)
        XCTAssertEqual(unknown.address, "2001:db8::7", "IPv6 literal after the last @")
        XCTAssertEqual(unknown.idleSeconds, 3_723)
    }

    func testNoStatisticsMarkerIsLiveAndEmptyWithServerAwareMessage() throws {
        // nfsstat prints the sentence, then json_dump prints the empty root dictionary.
        let output = Data("No NFS active user statistics found.\n{}\n".utf8)

        let onClient = try collector.parse(data: output, serverState: .notRunning)
        XCTAssertEqual(onClient.provenance, .live)
        XCTAssertTrue(onClient.users.isEmpty)
        XCTAssertTrue(onClient.message?.contains("nfsd is not running") == true, onClient.message ?? "")

        let idleServer = try collector.parse(data: output, serverState: .running)
        XCTAssertEqual(idleServer.provenance, .live)
        XCTAssertTrue(idleServer.message?.contains("no active NFS user") == true, idleServer.message ?? "")
    }

    func testJSONWithoutActiveUserSectionIsNotSilentlyEmpty() {
        XCTAssertThrowsError(try collector.parse(data: Data("{}".utf8), serverState: .running)) { error in
            guard case NFSActiveUserParseError.noActiveUserSection = error else {
                return XCTFail("Expected noActiveUserSection, got \(error)")
            }
        }
        XCTAssertThrowsError(try collector.parse(data: Data(), serverState: .running))
        XCTAssertThrowsError(try collector.parse(data: Data("nfsstat: nfssvc failed".utf8), serverState: .unknown))
    }

    func testServerStateParsing() {
        XCTAssertEqual(
            NFSActiveUserCollector.serverState(from: "nfsd service is enabled\nnfsd is running (pid 812, 8 threads)\n"),
            .running
        )
        XCTAssertEqual(
            NFSActiveUserCollector.serverState(from: "nfsd service is disabled\nnfsd is not running\n"),
            .notRunning
        )
        XCTAssertEqual(NFSActiveUserCollector.serverState(from: ""), .unknown)
    }

    func testIdleParsing() {
        XCTAssertEqual(NFSActiveUserCollector.idleSeconds(from: "0:00:00"), 0)
        XCTAssertEqual(NFSActiveUserCollector.idleSeconds(from: "12:30:15"), 45_015)
        XCTAssertNil(NFSActiveUserCollector.idleSeconds(from: "soon"))
        XCTAssertNil(NFSActiveUserCollector.idleSeconds(from: nil))
    }

    func testAddressMaskingKeepsOnlyNetworkPrefix() {
        XCTAssertEqual(NFSUserActivity.mask("192.0.2.10"), "192.0.·.·")
        XCTAssertEqual(NFSUserActivity.mask("2001:db8::7"), "2001:db8:…")
        XCTAssertEqual(NFSUserActivity.mask(""), "unknown")
        XCTAssertEqual(NFSUserActivity.mask("host.example"), "…")
    }

    func testRatesUseNonNegativeDeltasBetweenLiveSamples() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let previous = try collector.parse(data: Data(twoUsers.utf8), serverState: .running, at: start)
        let later = twoUsers
            .replacingOccurrences(of: "\"Write Bytes\": 1073741824", with: "\"Write Bytes\": 1373741824")
            .replacingOccurrences(of: "\"Requests\": 1200", with: "\"Requests\": 4200")
            .replacingOccurrences(of: "\"Requests\": 40,", with: "\"Requests\": 5,")
        let current = try collector.parse(
            data: Data(later.utf8), serverState: .running, at: start.addingTimeInterval(3)
        )

        let rates = NFSUserActivityRate.rates(current: current, previous: previous)
        XCTAssertEqual(rates.count, 3)
        let alice = try XCTUnwrap(rates.first { $0.activity.user == "alice" })
        XCTAssertEqual(alice.intervalSeconds, 3)
        XCTAssertEqual(alice.writeBytesPerSecond, 100_000_000, accuracy: 0.5)
        XCTAssertEqual(alice.requestsPerSecond, 1_000, accuracy: 0.001)
        XCTAssertEqual(alice.readBytesPerSecond, 0)

        let reset = try XCTUnwrap(rates.first { $0.activity.user == "uid 501" })
        XCTAssertEqual(reset.requestsPerSecond, 0, "a reclaimed record that restarted must not go negative")
    }

    func testRatesRequireTwoLiveSamplesAndPositiveInterval() throws {
        let date = Date()
        let live = try collector.parse(data: Data(twoUsers.utf8), serverState: .running, at: date)
        XCTAssertTrue(NFSUserActivityRate.rates(current: live, previous: nil).isEmpty)
        XCTAssertTrue(NFSUserActivityRate.rates(current: live, previous: .unavailable).isEmpty)
        XCTAssertTrue(NFSUserActivityRate.rates(current: live, previous: live).isEmpty, "zero interval")
        let unavailable = NFSUserActivitySnapshot.unavailable(message: "x", serverState: .unknown, at: date)
        XCTAssertTrue(NFSUserActivityRate.rates(current: unavailable, previous: live).isEmpty)
    }

    func testUnavailableSnapshotExplainsServerState() {
        let error = CommandRunnerError.nonZeroExit(.nfsstat, 1, "nfsstat: nfssvc failed: Operation not permitted")
        let message = NFSActiveUserCollector.unavailableMessage(for: error, serverState: .notRunning)
        XCTAssertTrue(message.contains("Operation not permitted"))
        XCTAssertTrue(message.contains("nfsd is not running"))

        let snapshot = NFSUserActivitySnapshot.unavailable(message: message, serverState: .notRunning, at: Date())
        XCTAssertEqual(snapshot.provenance, .unavailable)
        XCTAssertTrue(snapshot.users.isEmpty)
        XCTAssertEqual(NFSUserActivitySnapshot.unavailable.provenance, .unavailable)
    }

    func testThresholdsClampToSaneMinimums() {
        let thresholds = NFSUserAlertThresholds(writeBytesPerSecond: 0, requestsPerSecond: 0)
        XCTAssertEqual(thresholds.writeBytesPerSecond, 1_000_000)
        XCTAssertEqual(thresholds.requestsPerSecond, 10)
        XCTAssertEqual(NFSUserAlertThresholds.default.writeBytesPerSecond, 100_000_000)
        XCTAssertEqual(NFSUserAlertThresholds.default.requestsPerSecond, 1_000)
    }
}
