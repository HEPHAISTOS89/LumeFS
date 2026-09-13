import Darwin
import Foundation

/// Cumulative disk I/O counters of one process as read from `proc_pid_rusage`.
struct ProcessCounters: Sendable {
    let pid: Int32
    let startTime: Int64
    let name: String
    let uid: UInt32
    let bytesRead: UInt64
    let bytesWritten: UInt64
    let capturedAt: Date

    /// PID plus start time: a recycled PID never inherits another process's counters.
    var identity: String { "\(pid)-\(startTime)" }
}

/// Per-process disk I/O attribution through `sysctl(KERN_PROC_ALL)` and libproc's
/// `proc_pid_rusage(RUSAGE_INFO_V4)`.
///
/// XNU (`bsd/kern/proc_info.c`, `proc_pid_rusage` → `proc_security_policy` with
/// `CHECK_SAME_USER`) only returns counters for processes owned by the calling
/// user unless the caller is root or holds `PRIV_GLOBAL_PROC_INFO`. LumeFS never
/// asks for root, so other users' processes are counted as denied and shown as
/// such rather than as zero activity. Only the executable name and PID are read:
/// no arguments, environment, open files or paths.
actor ProcessIOCollector {
    static let rusageInfoV4: Int32 = 4
    static let maximumSamples = 40

    private typealias ProcPidRusage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32
    private typealias ProcName = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32

    // libproc is not part of Swift's Darwin module map; resolve the two symbols from
    // the already-linked libSystem instead of adding a bridging header.
    private static let procPidRusage: ProcPidRusage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage") else { return nil }
        return unsafeBitCast(symbol, to: ProcPidRusage.self)
    }()

    private static let procName: ProcName? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_name") else { return nil }
        return unsafeBitCast(symbol, to: ProcName.self)
    }()

    private var previousCounters: [String: ProcessCounters] = [:]
    private var userNames: [UInt32: String] = [:]

    func collect(at date: Date = Date()) -> ProcessIOSnapshot {
        guard Self.procPidRusage != nil else {
            return Self.unavailable(at: date, message: "proc_pid_rusage is not available in this process.")
        }
        guard let processes = Self.listProcesses() else {
            return Self.unavailable(at: date, message: "sysctl(KERN_PROC_ALL) failed: \(String(cString: strerror(errno)))")
        }

        var current: [String: ProcessCounters] = [:]
        var denied = 0
        for process in processes {
            switch Self.readCounters(for: process, at: date) {
            case let .success(counters):
                current[counters.identity] = counters
            case .failure(.denied):
                denied += 1
            case .failure(.gone), .failure(.other):
                continue
            }
        }
        defer { previousCounters = current }

        let samples = Self.samples(current: current, previous: previousCounters, userName: userName(for:))
        return ProcessIOSnapshot(
            samples: Array(samples.prefix(Self.maximumSamples)),
            totalProcessCount: processes.count,
            readableProcessCount: current.count,
            deniedProcessCount: denied,
            capturedAt: date,
            provenance: .live,
            message: nil
        )
    }

    /// Rates need two ordered observations of the same process identity. A counter
    /// that went backwards is reported as zero for that interval, never negative.
    static func samples(
        current: [String: ProcessCounters],
        previous: [String: ProcessCounters],
        userName: (UInt32) -> String
    ) -> [ProcessIOSample] {
        current.values.compactMap { now -> ProcessIOSample? in
            guard let before = previous[now.identity] else { return nil }
            let interval = now.capturedAt.timeIntervalSince(before.capturedAt)
            guard interval > 0 else { return nil }
            let readDelta = now.bytesRead >= before.bytesRead ? now.bytesRead - before.bytesRead : 0
            let writeDelta = now.bytesWritten >= before.bytesWritten ? now.bytesWritten - before.bytesWritten : 0
            guard readDelta > 0 || writeDelta > 0 else { return nil }

            return ProcessIOSample(
                id: now.identity,
                pid: now.pid,
                name: now.name,
                uid: now.uid,
                userName: userName(now.uid),
                readBytesPerSecond: Double(readDelta) / interval,
                writeBytesPerSecond: Double(writeDelta) / interval,
                cumulativeReadBytes: now.bytesRead,
                cumulativeWriteBytes: now.bytesWritten,
                intervalSeconds: interval,
                workloadHint: WorkloadHint.token(forProcessName: now.name),
                timestamp: now.capturedAt,
                provenance: .live
            )
        }
        .sorted {
            if $0.totalBytesPerSecond != $1.totalBytesPerSecond {
                return $0.totalBytesPerSecond > $1.totalBytesPerSecond
            }
            return $0.pid < $1.pid
        }
    }

    // MARK: - Kernel access

    struct ProcessIdentity: Sendable {
        let pid: Int32
        let uid: UInt32
        let startTime: Int64
        let shortName: String
    }

    enum ReadFailure: Error {
        case denied
        case gone
        case other(Int32)
    }

    static func listProcesses() -> [ProcessIdentity]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buffer.count * stride
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        return buffer.prefix(size / stride).compactMap { info in
            let pid = info.kp_proc.p_pid
            guard pid > 0 else { return nil }
            let comm = withUnsafePointer(to: info.kp_proc.p_comm) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            return ProcessIdentity(
                pid: pid,
                uid: info.kp_eproc.e_ucred.cr_uid,
                startTime: Int64(info.kp_proc.p_starttime.tv_sec),
                shortName: comm
            )
        }
    }

    static func readCounters(
        for process: ProcessIdentity,
        at date: Date
    ) -> Result<ProcessCounters, ReadFailure> {
        guard let procPidRusage else { return .failure(.other(ENOSYS)) }
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            procPidRusage(process.pid, rusageInfoV4, UnsafeMutableRawPointer(pointer))
        }
        guard status == 0 else {
            switch errno {
            case EPERM, EACCES: return .failure(.denied)
            case ESRCH: return .failure(.gone)
            default: return .failure(.other(errno))
            }
        }
        return .success(ProcessCounters(
            pid: process.pid,
            startTime: process.startTime,
            name: fullName(for: process),
            uid: process.uid,
            bytesRead: info.ri_diskio_bytesread,
            bytesWritten: info.ri_diskio_byteswritten,
            capturedAt: date
        ))
    }

    /// `p_comm` is truncated to 16 bytes; `proc_name` returns the full executable name
    /// for processes the caller may inspect.
    private static func fullName(for process: ProcessIdentity) -> String {
        guard let procName else { return process.shortName }
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = buffer.withUnsafeMutableBytes { raw in
            procName(process.pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return process.shortName }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) } ?? process.shortName
        }
    }

    private func userName(for uid: UInt32) -> String {
        if let cached = userNames[uid] { return cached }
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1_024)
        let name: String
        if getpwuid_r(uid, &record, &buffer, buffer.count, &result) == 0,
           result != nil,
           let pointer = record.pw_name {
            name = String(cString: pointer)
        } else {
            name = "uid \(uid)"
        }
        userNames[uid] = name
        return name
    }

    private static func unavailable(at date: Date, message: String) -> ProcessIOSnapshot {
        ProcessIOSnapshot(
            samples: [],
            totalProcessCount: 0,
            readableProcessCount: 0,
            deniedProcessCount: 0,
            capturedAt: date,
            provenance: .unavailable,
            message: message
        )
    }
}
