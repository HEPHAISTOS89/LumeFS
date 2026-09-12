import Foundation

enum BenchmarkError: LocalizedError, Equatable {
    case invalidSize
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case unsafePath
    case incompleteRead(expectedBytes: Int64, actualBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidSize:
            "Benchmark size must be between 1 and 256 MiB."
        case let .insufficientSpace(requiredBytes, availableBytes):
            "The benchmark needs \(MetricFormatter.bytes(requiredBytes)) free; \(MetricFormatter.bytes(availableBytes)) is available."
        case .unsafePath:
            "The benchmark refused to use a path outside its temporary workspace."
        case let .incompleteRead(expectedBytes, actualBytes):
            "The benchmark read \(MetricFormatter.bytes(actualBytes)) of \(MetricFormatter.bytes(expectedBytes))."
        }
    }
}

struct BenchmarkGuard: Sendable {
    static let maximumMebibytes = 256

    func byteCount(for mebibytes: Int) throws -> Int64 {
        guard (1...Self.maximumMebibytes).contains(mebibytes) else {
            throw BenchmarkError.invalidSize
        }
        return Int64(mebibytes) * 1_048_576
    }

    func validateSpace(requiredBytes: Int64, availableBytes: Int64) throws {
        let headroom = requiredBytes.multipliedReportingOverflow(by: 2)
        guard !headroom.overflow, availableBytes >= headroom.partialValue else {
            throw BenchmarkError.insufficientSpace(
                requiredBytes: headroom.overflow ? Int64.max : headroom.partialValue,
                availableBytes: availableBytes
            )
        }
    }

    func validate(fileURL: URL, isInside directoryURL: URL) throws {
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(directoryPath + "/") else {
            throw BenchmarkError.unsafePath
        }
    }
}

actor DiskBenchmark {
    private let fileManager = FileManager.default
    private let guardrail = BenchmarkGuard()

    func run(mebibytes: Int) throws -> BenchmarkResult {
        let byteCount = try guardrail.byteCount(for: mebibytes)
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("LumeFS-Benchmark-\(UUID().uuidString)", isDirectory: true)
        let fileURL = workspace
            .appendingPathComponent("sample")
            .appendingPathExtension("bin")

        try guardrail.validate(fileURL: fileURL, isInside: workspace)
        guard !fileManager.fileExists(atPath: workspace.path) else {
            throw BenchmarkError.unsafePath
        }
        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: workspace) }

        let values = try workspace.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let availableBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
        try guardrail.validateSpace(
            requiredBytes: byteCount,
            availableBytes: availableBytes
        )

        guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
            throw BenchmarkError.unsafePath
        }

        let writeStart = ContinuousClock.now
        try write(byteCount: byteCount, to: fileURL)
        let writeDuration = writeStart.duration(to: .now).seconds

        let readStart = ContinuousClock.now
        let bytesRead = try read(from: fileURL)
        let readDuration = readStart.duration(to: .now).seconds

        guard bytesRead == byteCount else {
            throw BenchmarkError.incompleteRead(
                expectedBytes: byteCount,
                actualBytes: bytesRead
            )
        }

        try fileManager.removeItem(at: fileURL)
        try fileManager.removeItem(at: workspace)

        return BenchmarkResult(
            byteCount: byteCount,
            readBytesPerSecond: rate(bytes: byteCount, duration: readDuration),
            writeBytesPerSecond: rate(bytes: byteCount, duration: writeDuration),
            elapsedSeconds: writeDuration + readDuration,
            completedAt: Date(),
            provenance: .benchmark,
            writeWasSynchronized: true,
            readMayUseSystemCache: true,
            cleanupSucceeded: true
        )
    }

    private func write(byteCount: Int64, to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        let chunkSize = 4 * 1_048_576
        let chunk = Data(repeating: 0xA5, count: chunkSize)
        var remaining = byteCount

        while remaining > 0 {
            let count = min(Int64(chunkSize), remaining)
            try handle.write(contentsOf: chunk.prefix(Int(count)))
            remaining -= count
        }

        try handle.synchronize()
    }

    private func read(from fileURL: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var byteCount: Int64 = 0
        var checksum: UInt8 = 0

        while let data = try handle.read(upToCount: 4 * 1_048_576), !data.isEmpty {
            byteCount += Int64(data.count)
            checksum ^= data.first ?? 0
        }

        _ = checksum
        return byteCount
    }

    private func rate(bytes: Int64, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return Double(bytes) / duration
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
