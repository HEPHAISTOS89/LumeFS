import Foundation

struct NFSCollector: Sendable {
    let commandRunner: SystemCommandRunner

    func collect(at date: Date = Date()) async -> NFSClientMetrics {
        do {
            let output = try await commandRunner.run(
                .nfsstat,
                arguments: ["-f", "JSON", "-c"]
            )
            return try parse(data: output.standardOutput, at: date)
        } catch {
            return .unavailable
        }
    }

    func parse(
        data: Data,
        at date: Date = Date(),
        provenance: DataProvenance = .live
    ) throws -> NFSClientMetrics {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let client = root["Client Info"] as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        let rpc = dictionary("RPC Info", in: client)
        let version3 = dictionary("NFSv3 RPC Counts", in: client)
        let version4 = dictionary("NFSv4 Operation Counts", in: client)
        let version41 = dictionary("NFSv4.1 Operation Counts", in: client)

        return NFSClientMetrics(
            requests: integer("Requests", in: rpc),
            retries: integer("Retries", in: rpc),
            timedOut: integer("TimedOut", in: rpc),
            invalidReplies: integer("Invalid", in: rpc),
            readOperations: integer("Read", in: version3) + integer("Read", in: version4),
            writeOperations: integer("Write", in: version3) + integer("Write", in: version4),
            layoutGets: integer("Layoutget", in: version41),
            layoutCommits: integer("Layoutcommit", in: version41),
            layoutReturns: integer("Layoutreturn", in: version41),
            deviceInfoRequests: integer("Getdevinfo", in: version41),
            capturedAt: date,
            provenance: provenance
        )
    }

    private func dictionary(
        _ key: String,
        in parent: [String: Any]
    ) -> [String: Any] {
        parent[key] as? [String: Any] ?? [:]
    }

    private func integer(_ key: String, in parent: [String: Any]) -> UInt64 {
        if let number = parent[key] as? NSNumber {
            return number.uint64Value
        }
        return 0
    }
}
