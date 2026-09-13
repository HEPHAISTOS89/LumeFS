import XCTest
@testable import LumeFS

final class SnapshotExporterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testJSONExportRoundTripsEveryProvenance() throws {
        let export = makeExport(maskAddresses: true)
        let data = try SnapshotExporter().data(for: export, format: .json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MonitoringExport.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.exportedAt, t0)
        XCTAssertEqual(decoded.volumes, export.volumes)
        XCTAssertEqual(decoded.deviceSamples.map(\.provenance), [.live])
        XCTAssertEqual(decoded.nfsClient.provenance, .unavailable)
        XCTAssertEqual(decoded.nfsUsers.users.map(\.address), ["192.0.·.·"])
        XCTAssertEqual(decoded.processIO.samples.map(\.workloadHint), ["ollama"])
        XCTAssertEqual(decoded.quotas.map(\.provenance), [.live])
        XCTAssertEqual(decoded.quotaCoverage.scope, "current-user")
        XCTAssertEqual(decoded.quotaCoverage.administratorCommand, "sudo repquota -a -v")
        XCTAssertEqual(decoded.activeAlerts.map(\.id), ["capacity-data"])
        XCTAssertEqual(decoded.alertHistory.map(\.state), [.active, .cleared])

        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"provenance\" : \"LIVE\""))
        XCTAssertTrue(text.contains("\"provenance\" : \"UNAVAILABLE\""))
        XCTAssertFalse(text.contains("192.0.2.10"), "masked exports never carry the full client address")
    }

    func testCSVHasOneMeasurementPerRowWithProvenance() throws {
        let export = makeExport(maskAddresses: false)
        let csv = SnapshotExporter().csv(for: export)
        let lines = csv.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(lines.first, "captured_at,category,identifier,metric,value,unit,provenance")
        XCTAssertEqual(lines.last, "", "CRLF-terminated final row")

        func rows(_ category: String) -> [String] { lines.filter { $0.split(separator: ",").dropFirst().first == Substring(category) } }
        XCTAssertEqual(rows("export").count, 2)
        XCTAssertEqual(rows("volume").count, 10)
        XCTAssertTrue(lines.contains("2027-01-15T08:00:00.000Z,volume,/Volumes/Data,apfs_container,,,UNAVAILABLE"), "no diskutil answer in the fixture")
        XCTAssertEqual(rows("device").count, 4)
        XCTAssertEqual(rows("nfs_client").count, 9)
        XCTAssertEqual(rows("nfs_mount").count, 5)
        XCTAssertEqual(rows("nfs_user").count, 4)
        XCTAssertEqual(rows("process").count, 5 + 3)
        XCTAssertEqual(rows("quota").count, 4 + 2)
        XCTAssertTrue(lines.contains("2027-01-15T08:00:00.000Z,quota,coverage,scope,current-user,,LIVE"))
        XCTAssertTrue(lines.contains("2027-01-15T08:00:00.000Z,quota,coverage,administrator_command,sudo repquota -a -v,,LIVE"))
        XCTAssertEqual(rows("alert").count, 4)
        XCTAssertEqual(rows("alert_history").count, 12)

        XCTAssertTrue(lines.contains("2027-01-15T08:00:00.000Z,volume,/Volumes/Data,available_bytes,250,bytes,LIVE"))
        XCTAssertTrue(lines.contains("2027-01-15T08:00:00.000Z,device,disk0,read_bytes_per_second,1048576,bytes/s,LIVE"))
        // `.unavailable` carries `.distantPast`, so only the tail of the row is stable.
        XCTAssertTrue(lines.contains { $0.hasSuffix(",nfs_client,client,requests,0,count,UNAVAILABLE") })
        XCTAssertTrue(lines.contains("2027-01-15T08:00:00.000Z,nfs_user,/srv/models|alice@192.0.2.10,write_bytes,4096,bytes,LIVE"))
        XCTAssertTrue(lines.contains("2027-01-15T08:00:00.000Z,process,4242 ollama,write_bytes_per_second,2048.500,bytes/s,LIVE"))
        XCTAssertTrue(lines.contains("2027-01-15T08:00:00.000Z,process,coverage,denied_processes,12,count,LIVE"))
        XCTAssertTrue(lines.contains("2027-01-15T08:00:00.000Z,export,LumeFS,addresses_masked,false,,LIVE"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("2027-01-15T08:00:00.000Z,alert_history,capacity-data#1,state,Active,,LIVE") })
        XCTAssertTrue(lines.contains { $0.contains(",alert_history,nfs-timeout#0,cleared_at,2027-01-15T08:00:10.000Z,,LIVE") })
    }

    func testCSVEscapesSeparatorsQuotesAndNewlines() {
        XCTAssertEqual(SnapshotExporter.escape("plain"), "plain")
        XCTAssertEqual(SnapshotExporter.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(SnapshotExporter.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(SnapshotExporter.escape("line\nbreak"), "\"line\nbreak\"")

        let export = makeExport(maskAddresses: false, alertTitle: "Capacity, \"critically\" low")
        let csv = SnapshotExporter().csv(for: export)
        XCTAssertTrue(csv.contains(",alert,capacity-data,title,\"Capacity, \"\"critically\"\" low\",,LIVE"))
    }

    func testNumbersAreCompactAndFiniteOnly() {
        XCTAssertEqual(SnapshotExporter.number(0), "0")
        XCTAssertEqual(SnapshotExporter.number(1_048_576), "1048576")
        XCTAssertEqual(SnapshotExporter.number(2_048.5), "2048.500")
        XCTAssertEqual(SnapshotExporter.number(.infinity), "")
        XCTAssertEqual(SnapshotExporter.number(.nan), "")
    }

    func testSuggestedFileNameIsTimestampedAndUsesTheFormatExtension() {
        let name = SnapshotExporter.suggestedFileName(at: t0, format: .csv)
        XCTAssertTrue(name.hasPrefix("LumeFS-snapshot-2027"), name)
        XCTAssertTrue(name.hasSuffix(".csv"), name)
        XCTAssertEqual(name.count, "LumeFS-snapshot-yyyyMMdd-HHmmss.csv".count)
        XCTAssertTrue(SnapshotExporter.suggestedFileName(at: t0, format: .json).hasSuffix(".json"))
    }

    func testMaskingKeepsNetworkPrefixInIdAndAddress() {
        let user = makeUser(address: "192.0.2.10")
        let masked = user.masked()
        XCTAssertEqual(masked.address, "192.0.·.·")
        XCTAssertEqual(masked.id, "/srv/models|alice@192.0.·.·")
        XCTAssertEqual(masked.writeBytes, user.writeBytes)

        let snapshot = NFSUserActivitySnapshot(users: [user], serverState: .running, capturedAt: t0, provenance: .live, message: nil)
        XCTAssertEqual(snapshot.maskingAddresses().users.map(\.address), ["192.0.·.·"])
        XCTAssertEqual(snapshot.maskingAddresses().serverState, .running)
    }

    @MainActor
    func testStoreExportMasksAddressesUnlessTheUserOptedIn() async throws {
        let defaults = UserDefaults.standard
        let key = "showFullNFSClientAddresses"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let value = SystemSnapshot(
            volumes: [],
            deviceSamples: [],
            nfsMetrics: .unavailable,
            nfsUsers: NFSUserActivitySnapshot(users: [makeUser(address: "192.0.2.10")], serverState: .running, capturedAt: t0, provenance: .live, message: nil),
            quotas: [],
            alerts: [makeAlert(id: "nfs-timeout", severity: .critical, title: "NFS server stopped responding")],
            capturedAt: t0
        )
        let store = MonitoringStore { value }
        await store.refreshNow()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumeFSTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        defaults.set(false, forKey: key)
        let maskedURL = directory.appendingPathComponent("masked.json")
        store.exportSnapshot(format: .json, to: maskedURL, at: t0)
        XCTAssertNil(store.exportError)
        XCTAssertEqual(store.lastExportURL, maskedURL)
        let maskedText = try String(contentsOf: maskedURL, encoding: .utf8)
        XCTAssertTrue(maskedText.contains("\"addressesMasked\" : true"))
        XCTAssertFalse(maskedText.contains("192.0.2.10"))
        XCTAssertTrue(maskedText.contains("\"alertHistory\""))
        XCTAssertTrue(store.activity.contains { $0.eventDescription.hasPrefix("Exported a JSON snapshot") })

        defaults.set(true, forKey: key)
        let fullURL = directory.appendingPathComponent("full.csv")
        store.exportSnapshot(format: .csv, to: fullURL, at: t0)
        XCTAssertNil(store.exportError)
        let fullText = try String(contentsOf: fullURL, encoding: .utf8)
        XCTAssertTrue(fullText.contains("192.0.2.10"))
        XCTAssertTrue(fullText.hasPrefix("captured_at,category,identifier,metric,value,unit,provenance\r\n"))

        let unwritable = URL(fileURLWithPath: "/nonexistent-lumefs-dir/\(UUID().uuidString).json")
        store.exportSnapshot(format: .json, to: unwritable, at: t0)
        XCTAssertNotNil(store.exportError)
        XCTAssertEqual(store.lastExportURL, fullURL, "a failed export does not replace the last successful location")
    }

    // MARK: Fixtures (synthetic; RFC 5737 addresses)

    private func makeExport(maskAddresses: Bool, alertTitle: String = "Capacity is critically low") -> MonitoringExport {
        let volume = VolumeSnapshot(
            id: "vol-data", name: "Data", mountPoint: "/Volumes/Data", source: "disk3s1",
            fileSystem: .apfs, fileSystemName: "apfs", totalBytes: 1_000, availableBytes: 250,
            isReadOnly: false, isLocal: true, capturedAt: t0, smartStatus: "Verified"
        )
        let device = DeviceIOSample(
            deviceName: "disk0", timestamp: t0, readBytesPerSecond: 1_048_576, writeBytesPerSecond: 0,
            readOperationsPerSecond: 10, writeOperationsPerSecond: 0, readErrors: 0, writeErrors: 0,
            readRetries: 0, writeRetries: 0
        )
        let mount = NFSMountInfo.unavailable(mountPoint: "/Volumes/models", source: "server:/srv/models", message: "not collected", at: t0)
        let users = NFSUserActivitySnapshot(users: [makeUser(address: "192.0.2.10")], serverState: .running, capturedAt: t0, provenance: .live, message: nil)
        let process = ProcessIOSample(
            id: "4242-1", pid: 4242, name: "ollama", uid: 501, userName: "alice",
            readBytesPerSecond: 0, writeBytesPerSecond: 2_048.5, cumulativeReadBytes: 0, cumulativeWriteBytes: 8_192,
            intervalSeconds: 2, workloadHint: "ollama", timestamp: t0, provenance: .live
        )
        let processIO = ProcessIOSnapshot(samples: [process], totalProcessCount: 40, readableProcessCount: 28, deniedProcessCount: 12, capturedAt: t0, provenance: .live, message: nil)
        let quota = QuotaSnapshot(id: "q1", subject: "alice", mountPoint: "/Volumes/Data", usedBytes: 100, softLimitBytes: 500, hardLimitBytes: 1_000, message: "", capturedAt: t0, provenance: .live)
        let active = makeAlert(id: "capacity-data", severity: .critical, title: alertTitle)
        let history = [
            AlertHistoryEntry(id: "capacity-data#1", alert: active, raisedAt: t0, lastSeenAt: t0, acknowledgedAt: nil, clearedAt: nil),
            AlertHistoryEntry(id: "nfs-timeout#0", alert: makeAlert(id: "nfs-timeout", severity: .critical, title: "NFS server stopped responding"), raisedAt: t0 - 60, lastSeenAt: t0, acknowledgedAt: t0 - 30, clearedAt: t0 + 10)
        ]
        return MonitoringExport(
            exportedAt: t0,
            appVersion: "1.0.0 (1)",
            addressesMasked: maskAddresses,
            volumes: [volume],
            deviceSamples: [device],
            nfsClient: .unavailable,
            nfsMounts: [mount],
            nfsUsers: maskAddresses ? users.maskingAddresses() : users,
            processIO: processIO,
            quotas: [quota],
            quotaCoverage: .current(subject: "alice"),
            activeAlerts: [active],
            alertHistory: history
        )
    }

    private func makeUser(address: String) -> NFSUserActivity {
        NFSUserActivity(
            id: "/srv/models|alice@\(address)", export: "/srv/models", user: "alice", uid: 501, address: address,
            requests: 12, readBytes: 0, writeBytes: 4_096, idleSeconds: 3, capturedAt: t0, provenance: .live
        )
    }

    private func makeAlert(id: String, severity: HealthSeverity, title: String) -> MonitoringAlert {
        MonitoringAlert(
            id: id, ruleID: "test.rule", severity: severity, title: title, message: "message",
            evidence: "evidence", recommendation: "recommendation", relatedVolumeID: nil, createdAt: t0, provenance: .live
        )
    }
}
