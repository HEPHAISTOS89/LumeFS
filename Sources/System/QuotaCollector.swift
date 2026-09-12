import Foundation

struct QuotaCollector: Sendable {
    let commandRunner: SystemCommandRunner

    func collect(at date: Date = Date()) async -> [QuotaSnapshot] {
        do {
            let output = try await commandRunner.run(
                .quota,
                arguments: ["-uv"]
            )
            return parse(output: output.standardOutputString, at: date)
        } catch {
            return [unavailableSnapshot(message: error.localizedDescription, at: date)]
        }
    }

    func parse(output: String, at date: Date = Date()) -> [QuotaSnapshot] {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized.lowercased() == "none" || normalized.lowercased().hasSuffix(": none") {
            return [
                unavailableSnapshot(
                    message: "No file-system quota is configured for the current user.",
                    at: date
                )
            ]
        }

        let structured = parseQuotaRows(from: normalized, at: date)
        if !structured.isEmpty {
            return structured
        }

        return [
            QuotaSnapshot(
                id: "current-user-quota",
                subject: NSUserName(),
                mountPoint: "All mounted file systems",
                usedBytes: nil,
                softLimitBytes: nil,
                hardLimitBytes: nil,
                message: normalized,
                capturedAt: date,
                provenance: .live
            )
        ]
    }

    private func parseQuotaRows(
        from output: String,
        at date: Date
    ) -> [QuotaSnapshot] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var snapshots: [QuotaSnapshot] = []
        var pendingFileSystem: String?

        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !fields.isEmpty else { continue }

            if fields[0].hasPrefix("/") || fields[0].contains(":") {
                if fields.count >= 4,
                   let snapshot = makeSnapshot(
                       fileSystem: fields[0],
                       numericFields: Array(fields.dropFirst()),
                       originalLine: line,
                       at: date
                   ) {
                    snapshots.append(snapshot)
                    pendingFileSystem = nil
                } else {
                    pendingFileSystem = fields[0]
                }
                continue
            }

            if let fileSystem = pendingFileSystem,
               let snapshot = makeSnapshot(
                   fileSystem: fileSystem,
                   numericFields: fields,
                   originalLine: line,
                   at: date
                ) {
                snapshots.append(snapshot)
                pendingFileSystem = nil
            }
        }

        return snapshots
    }

    private func makeSnapshot(
        fileSystem: String,
        numericFields: [String],
        originalLine: String,
        at date: Date
    ) -> QuotaSnapshot? {
        guard numericFields.count >= 3,
              let usedBlocks = blockCount(numericFields[0]),
              let softBlocks = blockCount(numericFields[1]),
              let hardBlocks = blockCount(numericFields[2]) else {
            return nil
        }

        return QuotaSnapshot(
            id: "current-user-quota-\(fileSystem)",
            subject: NSUserName(),
            mountPoint: fileSystem,
            usedBytes: bytes(fromKiBBlocks: usedBlocks),
            softLimitBytes: softBlocks > 0 ? bytes(fromKiBBlocks: softBlocks) : nil,
            hardLimitBytes: hardBlocks > 0 ? bytes(fromKiBBlocks: hardBlocks) : nil,
            message: originalLine.trimmingCharacters(in: .whitespaces),
            capturedAt: date,
            provenance: .live
        )
    }

    private func blockCount(_ field: String) -> Int64? {
        let digits = field.trimmingCharacters(
            in: CharacterSet(charactersIn: "*+")
        )
        return Int64(digits)
    }

    private func bytes(fromKiBBlocks blocks: Int64) -> Int64? {
        let result = blocks.multipliedReportingOverflow(by: 1_024)
        return result.overflow ? nil : result.partialValue
    }

    private func unavailableSnapshot(
        message: String,
        at date: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "current-user-quota-unavailable",
            subject: NSUserName(),
            mountPoint: "All mounted file systems",
            usedBytes: nil,
            softLimitBytes: nil,
            hardLimitBytes: nil,
            message: message,
            capturedAt: date,
            provenance: .unavailable
        )
    }
}
