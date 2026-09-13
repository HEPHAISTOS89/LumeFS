import XCTest
@testable import LumeFS

/// Fixtures follow the JSON layout produced by Apple's `nfsstat -m -f JSON`
/// (apple-oss-distributions/NFS: `nfsstat/nfsstat.c` `print_mountinfo`,
/// `nfsstat/printer.c` `json_mount_header`, `json_open_array`, `json_add_locations`).
/// They are derived from that source and anonymized (RFC 5737 addresses, example
/// host names); they are not captures from a production server.
final class NFSMountCollectorTests: XCTestCase {
    private let collector = NFSMountCollector(commandRunner: SystemCommandRunner())

    private func fixture(
        source: String = "nas.lab.example:/export/models",
        mountPoint: String = "/Volumes/models",
        parameters: [String] = ["vers=4.1", "tcp", "port=2049", "hard", "nointr", "rsize=65536", "wsize=65536", "sec=sys"],
        statusFlags: [String] = [],
        statusBitmask: String = "0x0"
    ) -> Data {
        let quotedParameters = parameters.map { "\"\($0)\"" }.joined(separator: ", ")
        let quotedFlags = statusFlags.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {
          "\(source)": {
            "Mount Point": "\(mountPoint)",
            "Original mount options": {
              "General mount flags": {"Bitmask": "0x0", "Flags": []},
              "NFS parameters": [\(quotedParameters)],
              "File system locations": [
                {"Export": "/export/models", "Server": "nas.lab.example", "Locations": ["192.0.2.10"]}
              ]
            },
            "Current mount parameters": {
              "General mount flags": {"Bitmask": "0x40000", "Flags": ["nobrowse"]},
              "NFS parameters": [\(quotedParameters)],
              "File system locations": [
                {"Export": "/export/models", "Server": "nas.lab.example", "Locations": ["192.0.2.10"]}
              ]
            },
            "Status flags": {"Bitmask": "\(statusBitmask)", "Flags": [\(quotedFlags)]}
          }
        }
        """
        return Data(json.utf8)
    }

    func testParsesNestedMountDictionaryFromCurrentParameters() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let mount = try collector.parse(
            data: fixture(),
            mountPoint: "/Volumes/models",
            source: "nas.lab.example:/export/models",
            at: date
        )

        XCTAssertEqual(mount.id, "/Volumes/models")
        XCTAssertEqual(mount.mountPoint, "/Volumes/models")
        XCTAssertEqual(mount.server, "nas.lab.example")
        XCTAssertEqual(mount.export, "/export/models")
        XCTAssertEqual(mount.addresses, ["192.0.2.10"])
        XCTAssertEqual(mount.nfsVersion, "4.1")
        XCTAssertEqual(mount.transport, "tcp")
        XCTAssertEqual(mount.mountFlags, ["nobrowse"], "current parameters win over original options")
        XCTAssertTrue(mount.parameters.contains("rsize=65536"))
        XCTAssertEqual(mount.statusFlags, [])
        XCTAssertEqual(mount.provenance, .live)
        XCTAssertEqual(mount.capturedAt, date)
        XCTAssertTrue(mount.isResponding)
        XCTAssertEqual(mount.statusLabel, "Responding")
        XCTAssertNil(mount.message)
    }

    func testKernelStatusFlagsAreExposedVerbatim() throws {
        let notResponding = try collector.parse(
            data: fixture(statusFlags: ["not responding"], statusBitmask: "0x2"),
            mountPoint: "/Volumes/models",
            source: "nas.lab.example:/export/models"
        )
        XCTAssertTrue(notResponding.isNotResponding)
        XCTAssertFalse(notResponding.isResponding)
        XCTAssertEqual(notResponding.statusLabel, "Not responding")

        let dead = try collector.parse(
            data: fixture(statusFlags: ["dead"], statusBitmask: "0x1"),
            mountPoint: "/Volumes/models",
            source: "nas.lab.example:/export/models"
        )
        XCTAssertTrue(dead.isDead)
        XCTAssertEqual(dead.statusLabel, "Dead")

        let recovery = try collector.parse(
            data: fixture(statusFlags: ["recovery"], statusBitmask: "0x4"),
            mountPoint: "/Volumes/models",
            source: "nas.lab.example:/export/models"
        )
        XCTAssertTrue(recovery.inRecovery)
        XCTAssertTrue(recovery.isResponding, "recovery is degraded, not down")
        XCTAssertEqual(recovery.statusLabel, "Recovering")
    }

    func testParsesVersionThreeOverUDPAndOriginalOptionsFallback() throws {
        let json = """
        {
          "192.0.2.20:/srv/scratch": {
            "Mount Point": "/Volumes/scratch",
            "Original mount options": {
              "General mount flags": {"Bitmask": "0x0", "Flags": []},
              "NFS parameters": ["vers=3", "udp", "soft", "deadtimeout=15"],
              "File system locations": [
                {"Export": "/srv/scratch", "Server": "192.0.2.20", "Locations": ["192.0.2.20"]}
              ]
            },
            "Status flags": {"Bitmask": "0x0", "Flags": []}
          }
        }
        """
        let mount = try collector.parse(
            data: Data(json.utf8),
            mountPoint: "/Volumes/scratch",
            source: "192.0.2.20:/srv/scratch"
        )
        XCTAssertEqual(mount.nfsVersion, "3")
        XCTAssertEqual(mount.transport, "udp")
        XCTAssertEqual(mount.server, "192.0.2.20")
        XCTAssertEqual(mount.export, "/srv/scratch")
        XCTAssertTrue(mount.parameters.contains("soft"))
    }

    func testFlatLayoutWithMountPointAtRootIsAccepted() throws {
        let json = """
        {
          "Mount Point": "/Volumes/flat",
          "Current mount parameters": {
            "NFS parameters": ["vers=4", "tcp"],
            "Export": "/flat",
            "Server": "flat.example",
            "Locations": ["192.0.2.30", "192.0.2.31"]
          },
          "Status flags": {"Bitmask": "0x0", "Flags": []}
        }
        """
        let mount = try collector.parse(
            data: Data(json.utf8),
            mountPoint: "/Volumes/flat",
            source: "flat.example:/flat"
        )
        XCTAssertEqual(mount.server, "flat.example")
        XCTAssertEqual(mount.export, "/flat")
        XCTAssertEqual(mount.addresses, ["192.0.2.30", "192.0.2.31"])
        XCTAssertEqual(mount.nfsVersion, "4")
    }

    func testSelectsEntryMatchingRequestedMountPoint() throws {
        let json = """
        {
          "a.example:/one": {"Mount Point": "/Volumes/one", "Status flags": {"Bitmask": "0x1", "Flags": ["dead"]}},
          "b.example:/two": {"Mount Point": "/Volumes/two", "Status flags": {"Bitmask": "0x0", "Flags": []}}
        }
        """
        let two = try collector.parse(
            data: Data(json.utf8),
            mountPoint: "/Volumes/two",
            source: "b.example:/two"
        )
        XCTAssertEqual(two.mountPoint, "/Volumes/two")
        XCTAssertTrue(two.isResponding)
        XCTAssertEqual(two.displayServer, "b.example")
        XCTAssertEqual(two.displayExport, "/two")
    }

    func testEmptyOrMountlessOutputIsNoMountInformation() {
        XCTAssertThrowsError(try collector.parse(data: Data(), mountPoint: "/Volumes/x", source: "x:/x")) { error in
            guard case NFSMountParseError.noMountInformation = error else {
                return XCTFail("Expected noMountInformation, got \(error)")
            }
        }
        XCTAssertThrowsError(try collector.parse(data: Data("{}".utf8), mountPoint: "/Volumes/x", source: "x:/x")) { error in
            guard case NFSMountParseError.noMountInformation = error else {
                return XCTFail("Expected noMountInformation, got \(error)")
            }
        }
    }

    func testMalformedOutputThrows() {
        XCTAssertThrowsError(
            try collector.parse(data: Data("not json".utf8), mountPoint: "/Volumes/x", source: "x:/x")
        )
        XCTAssertThrowsError(
            try collector.parse(data: Data("[1, 2]".utf8), mountPoint: "/Volumes/x", source: "x:/x")
        )
    }

    func testUnavailableRecordCarriesReasonAndNeverClaimsHealth() {
        let date = Date()
        let mount = NFSMountInfo.unavailable(
            mountPoint: "/Volumes/models",
            source: "nas.lab.example:/export/models",
            message: "nfsstat exited with status 1",
            at: date
        )
        XCTAssertEqual(mount.provenance, .unavailable)
        XCTAssertFalse(mount.isResponding)
        XCTAssertFalse(mount.isDead)
        XCTAssertEqual(mount.statusLabel, "Unavailable")
        XCTAssertEqual(mount.message, "nfsstat exited with status 1")
        XCTAssertEqual(mount.displayServer, "nas.lab.example")
        XCTAssertEqual(mount.displayExport, "/export/models")
        XCTAssertEqual(mount.capturedAt, date)
    }

    func testCollectorQueriesOnlyNFSVolumes() async {
        let apfs = VolumeSnapshot(
            id: "apfs", name: "Data", mountPoint: "/System/Volumes/Data", source: "/dev/disk3s5",
            fileSystem: .apfs, fileSystemName: "apfs", totalBytes: 1, availableBytes: 1,
            isReadOnly: false, isLocal: true, capturedAt: Date()
        )
        let mounts = await collector.collect(volumes: [apfs])
        XCTAssertTrue(mounts.isEmpty)
    }

    func testVersionAndTransportHelpers() {
        XCTAssertEqual(NFSMountCollector.version(from: ["hard", "vers=4.2", "tcp"]), "4.2")
        XCTAssertNil(NFSMountCollector.version(from: ["hard", "tcp"]))
        XCTAssertEqual(NFSMountCollector.transport(from: ["vers=3", "udp6"]), "udp6")
        XCTAssertNil(NFSMountCollector.transport(from: ["vers=3", "hard"]))
    }
}
