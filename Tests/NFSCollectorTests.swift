import XCTest
@testable import LumeFS

final class NFSCollectorTests: XCTestCase {
    func testParsesClientAndPNFSCounters() throws {
        let json = """
        {
          "Client Info": {
            "RPC Info": {"Requests": 100, "Retries": 3, "TimedOut": 1, "Invalid": 2},
            "NFSv3 RPC Counts": {"Read": 7, "Write": 5},
            "NFSv4 Operation Counts": {"Read": 11, "Write": 13},
            "NFSv4.1 Operation Counts": {
              "Layoutget": 2,
              "Layoutcommit": 1,
              "Layoutreturn": 1,
              "Getdevinfo": 4
            }
          }
        }
        """

        let metrics = try NFSCollector(
            commandRunner: SystemCommandRunner()
        ).parse(data: Data(json.utf8), provenance: .replay)

        XCTAssertEqual(metrics.requests, 100)
        XCTAssertEqual(metrics.readOperations, 18)
        XCTAssertEqual(metrics.writeOperations, 18)
        XCTAssertTrue(metrics.pNFSObserved)
        XCTAssertEqual(metrics.provenance, .replay)
    }

    func testMissingOptionalCountersDefaultToZero() throws {
        let json = #"{"Client Info": {}}"#
        let metrics = try NFSCollector(
            commandRunner: SystemCommandRunner()
        ).parse(data: Data(json.utf8))

        XCTAssertEqual(metrics.requests, 0)
        XCTAssertFalse(metrics.pNFSObserved)
    }
}
