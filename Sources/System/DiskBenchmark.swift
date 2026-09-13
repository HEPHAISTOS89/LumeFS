import Darwin
import Foundation

enum BenchmarkError: LocalizedError, Equatable {
    case invalidSize
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case unsafePath
    case incompleteRead(expectedBytes: Int64, actualBytes: Int64)
    case ioFailure(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidSize:
            "Benchmark size must be between 1 and \(BenchmarkGuard.maximumMebibytes) MiB."
        case let .insufficientSpace(requiredBytes, availableBytes):
            "The benchmark needs \(MetricFormatter.bytes(requiredBytes)) free; \(MetricFormatter.bytes(availableBytes)) is available."
        case .unsafePath:
            "The benchmark refused to use a path outside its temporary workspace."
        case let .incompleteRead(expectedBytes, actualBytes):
            "The benchmark read \(MetricFormatter.bytes(actualBytes)) of \(MetricFormatter.bytes(expectedBytes))."
        case let .ioFailure(operation, code):
            "The benchmark \(operation) failed: \(String(cString: strerror(code))) (\(code))."
        }
    }
}

struct BenchmarkGuard: Sendable {
    /// 1 GiB ceiling: at several GB/s a 128 MiB pass lasts tens of milliseconds,
    /// too short for a stable rate; 1 GiB keeps a fast SSD busy for a few hundred
    /// milliseconds while the 2× free-space rule below still bounds the footprint.
    static let maximumMebibytes = 1_024
    /// Sizes offered in the UI; the default stays 128 MiB.
    static let selectableMebibytes = [128, 256, 512, 1_024]
    static let defaultMebibytes = 128

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

/// Bounded temporary-file benchmark with three labeled passes.
///
/// 1. Write with `F_NOCACHE` so the data does not stay resident in the unified
///    buffer cache, then `F_FULLFSYNC` (drive cache flushed; falls back to
///    `fsync(2)` where the file system refuses).
/// 2. Uncached read: `F_NOCACHE` + read-ahead off on a file whose pages are not
///    resident, so the bytes come from the device (the drive's own cache can
///    still help; this is not a raw-media number).
/// 3. Cached read: two consecutive normal reads; the second one is reported and
///    is served by the buffer cache.
///
/// Cancellation is checked between 4 MiB chunks; the workspace is removed on
/// every exit path.
actor DiskBenchmark {
    static let chunkSize = 4 * 1_048_576
    /// Page alignment lets the kernel take the direct path for uncached I/O on
    /// both 4 KiB and 16 KiB page systems.
    static let bufferAlignment = 16_384

    private let fileManager = FileManager.default
    private let guardrail = BenchmarkGuard()

    func run(mebibytes: Int) async throws -> BenchmarkResult {
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
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: workspace) }

        let values = try workspace.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let availableBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
        try guardrail.validateSpace(requiredBytes: byteCount, availableBytes: availableBytes)

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.chunkSize, alignment: Self.bufferAlignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0xA5)

        try Task.checkCancellation()
        let writeStart = ContinuousClock.now
        let sync = try write(byteCount: byteCount, to: fileURL, buffer: buffer)
        let writeDuration = writeStart.duration(to: .now).seconds

        try Task.checkCancellation()
        let uncachedStart = ContinuousClock.now
        let uncachedBytes = try read(from: fileURL, bypassCache: true, buffer: buffer)
        let uncachedDuration = uncachedStart.duration(to: .now).seconds
        guard uncachedBytes == byteCount else {
            throw BenchmarkError.incompleteRead(expectedBytes: byteCount, actualBytes: uncachedBytes)
        }

        // First normal pass warms the cache; only the second pass is reported.
        try Task.checkCancellation()
        let warmStart = ContinuousClock.now
        _ = try read(from: fileURL, bypassCache: false, buffer: buffer)
        let warmDuration = warmStart.duration(to: .now).seconds

        try Task.checkCancellation()
        let cachedStart = ContinuousClock.now
        let cachedBytes = try read(from: fileURL, bypassCache: false, buffer: buffer)
        let cachedDuration = cachedStart.duration(to: .now).seconds
        guard cachedBytes == byteCount else {
            throw BenchmarkError.incompleteRead(expectedBytes: byteCount, actualBytes: cachedBytes)
        }

        try fileManager.removeItem(at: fileURL)
        try fileManager.removeItem(at: workspace)

        return BenchmarkResult(
            byteCount: byteCount,
            uncachedReadBytesPerSecond: rate(bytes: byteCount, duration: uncachedDuration),
            cachedReadBytesPerSecond: rate(bytes: byteCount, duration: cachedDuration),
            writeBytesPerSecond: rate(bytes: byteCount, duration: writeDuration),
            elapsedSeconds: writeDuration + uncachedDuration + warmDuration + cachedDuration,
            completedAt: Date(),
            provenance: .benchmark,
            writeWasSynchronized: true,
            writeUsedFullSync: sync == .full,
            writeBypassedCache: true,
            cleanupSucceeded: true
        )
    }

    private enum SyncMode { case full, fsyncOnly }

    private func write(byteCount: Int64, to fileURL: URL, buffer: UnsafeMutableRawBufferPointer) throws -> SyncMode {
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw BenchmarkError.ioFailure(operation: "open", code: errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        guard let base = buffer.baseAddress else { throw BenchmarkError.ioFailure(operation: "buffer", code: ENOMEM) }
        var remaining = byteCount
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(Int64(Self.chunkSize), remaining))
            var offset = 0
            while offset < count {
                let written = Darwin.write(fd, base + offset, count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw BenchmarkError.ioFailure(operation: "write", code: errno)
                }
                offset += written
            }
            remaining -= Int64(count)
        }

        if fcntl(fd, F_FULLFSYNC) == 0 {
            return .full
        }
        guard fsync(fd) == 0 else { throw BenchmarkError.ioFailure(operation: "fsync", code: errno) }
        return .fsyncOnly
    }

    private func read(from fileURL: URL, bypassCache: Bool, buffer: UnsafeMutableRawBufferPointer) throws -> Int64 {
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else { throw BenchmarkError.ioFailure(operation: "open", code: errno) }
        defer { close(fd) }
        if bypassCache {
            _ = fcntl(fd, F_NOCACHE, 1)
            _ = fcntl(fd, F_RDAHEAD, 0)
        }

        guard let base = buffer.baseAddress else { throw BenchmarkError.ioFailure(operation: "buffer", code: ENOMEM) }
        var total: Int64 = 0
        var checksum: UInt8 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, base, Self.chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw BenchmarkError.ioFailure(operation: "read", code: errno)
            }
            if count == 0 { break }
            checksum ^= buffer[0]
            total += Int64(count)
        }
        _ = checksum
        return total
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
