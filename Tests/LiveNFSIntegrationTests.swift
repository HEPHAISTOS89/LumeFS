import Foundation
import Darwin
import XCTest
@testable import LumeFS

final class LiveNFSIntegrationTests: XCTestCase {
    private var requiredLabMount: String {
        get throws {
            let mount = ProcessInfo.processInfo.environment["LUMEFS_NFS_LAB_MOUNT"]
                ?? "/private/var/tmp/com.hephaistos.LumeFS.nfs-lab.\(getuid())/mount"

            guard mount.hasPrefix("/private/var/tmp/"),
                  !mount.contains(".."),
                  MountCollector().collect().contains(where: { $0.mountPoint == mount }) else {
                throw XCTSkip(
                    "Start the opt-in localhost NFS lab to run the live NFS integration checks."
                )
            }
            return mount
        }
    }

    func testLoopbackNFSv3LabIsDiscoveredAndServerRejectsWrites() throws {
        let mount = try requiredLabMount
        let volume = MountCollector().collect().first { $0.mountPoint == mount }
        let writeProbe = URL(fileURLWithPath: mount)
            .appendingPathComponent(".lumefs-write-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: writeProbe) }

        XCTAssertNotNil(volume)
        XCTAssertEqual(volume?.fileSystem, .nfs)
        XCTAssertEqual(volume?.fileSystemName.lowercased(), "nfs")
        XCTAssertEqual(volume?.isLocal, false)
        XCTAssertTrue(volume?.source.hasPrefix("127.0.0.1:") == true)
        XCTAssertThrowsError(try Data("probe".utf8).write(to: writeProbe))
    }

    func testLiveNFSClientCountersIncludeLabRead() async throws {
        let mount = try requiredLabMount
        let fixture = URL(fileURLWithPath: mount)
            .appendingPathComponent("README.txt")

        _ = try Data(contentsOf: fixture)

        let metrics = await NFSCollector(
            commandRunner: SystemCommandRunner()
        ).collect()

        XCTAssertEqual(metrics.provenance, .live)
        XCTAssertGreaterThan(metrics.requests, 0)
        XCTAssertGreaterThan(metrics.readOperations, 0)
        XCTAssertFalse(metrics.pNFSObserved)
    }

    func testLiveMountInformationDescribesTheLabMount() async throws {
        let mount = try requiredLabMount
        let volumes = MountCollector().collect().filter { $0.mountPoint == mount }

        let mounts = await NFSMountCollector(
            commandRunner: SystemCommandRunner()
        ).collect(volumes: volumes)

        XCTAssertEqual(mounts.count, 1)
        let info = try XCTUnwrap(mounts.first)
        XCTAssertEqual(info.provenance, .live, info.message ?? "")
        XCTAssertEqual(info.mountPoint, mount)
        XCTAssertEqual(info.displayServer, "127.0.0.1")
        XCTAssertEqual(info.nfsVersion, "3")
        XCTAssertEqual(info.transport, "tcp")
        XCTAssertTrue(info.parameters.contains("soft"), "\(info.parameters)")
        XCTAssertTrue(info.isResponding, "\(info.statusFlags)")
    }
}
