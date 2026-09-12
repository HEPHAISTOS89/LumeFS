import Darwin
@preconcurrency import Foundation

enum SystemExecutable: String, Sendable {
    case diskutil = "/usr/sbin/diskutil"
    case nfsstat = "/usr/bin/nfsstat"
    case quota = "/usr/bin/quota"
}

struct CommandOutput: Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitCode: Int32

    var standardOutputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var standardErrorString: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

enum CommandRunnerError: LocalizedError {
    case invalidArgument
    case timedOut(SystemExecutable)
    case outputTooLarge(SystemExecutable)
    case nonZeroExit(SystemExecutable, Int32, String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument:
            "A system command argument was invalid."
        case let .timedOut(executable):
            "\(executable.rawValue) did not finish within five seconds."
        case let .outputTooLarge(executable):
            "\(executable.rawValue) returned more than one MiB of output."
        case let .nonZeroExit(executable, code, message):
            "\(executable.rawValue) exited with status \(code): \(message)"
        }
    }
}

actor SystemCommandRunner {
    func run(
        _ executable: SystemExecutable,
        arguments: [String]
    ) async throws -> CommandOutput {
        try Task.checkCancellation()
        try validate(executable, arguments: arguments)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable.rawValue)
        process.arguments = arguments
        process.environment = [
            "HOME": NSHomeDirectory(),
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/usr/sbin:/bin:/sbin"
        ]
        return try await runProcess(process, executable: executable)
    }

    // Kept separate so lifecycle tests can use harmless, disposable child processes.
    // Production callers enter through run(_:arguments:) and its strict allowlist.
    func runProcess(
        _ process: Process,
        executable: SystemExecutable,
        timeout: Duration = .seconds(5)
    ) async throws -> CommandOutput {
        try Task.checkCancellation()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        let outputReader = try BoundedCommandOutputReader(handle: standardOutput.fileHandleForReading)
        let errorReader = try BoundedCommandOutputReader(handle: standardError.fileHandleForReading)
        defer {
            try? standardOutput.fileHandleForReading.close()
            try? standardError.fileHandleForReading.close()
        }

        try process.run()
        defer {
            // Cancellation, timeout and oversized output must not leave a collector running.
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // Foundation owns child reaping. Never block a cooperative executor here.
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        var outputData = Data()
        var errorData = Data()
        while true {
            try Task.checkCancellation()
            try outputReader.drain(into: &outputData, executable: executable)
            try errorReader.drain(into: &errorData, executable: executable)
            guard process.isRunning else { break }
            guard ContinuousClock.now < deadline else {
                throw CommandRunnerError.timedOut(executable)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Capture bytes written between the last drain and process exit.
        try outputReader.drain(into: &outputData, executable: executable)
        try errorReader.drain(into: &errorData, executable: executable)

        let output = CommandOutput(
            standardOutput: outputData,
            standardError: errorData,
            exitCode: process.terminationStatus
        )

        guard output.exitCode == 0 else {
            throw CommandRunnerError.nonZeroExit(
                executable,
                output.exitCode,
                output.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return output
    }

    func validate(
        _ executable: SystemExecutable,
        arguments: [String]
    ) throws {
        guard arguments.allSatisfy(isSafeArgument) else {
            throw CommandRunnerError.invalidArgument
        }

        switch executable {
        case .diskutil:
            guard arguments.count == 3,
                  arguments[0] == "info",
                  arguments[1] == "-plist",
                  arguments[2].hasPrefix("/") else {
                throw CommandRunnerError.invalidArgument
            }
        case .nfsstat:
            guard arguments == ["-f", "JSON", "-c"] else {
                throw CommandRunnerError.invalidArgument
            }
        case .quota:
            guard arguments == ["-uv"] else {
                throw CommandRunnerError.invalidArgument
            }
        }
    }

    private func isSafeArgument(_ argument: String) -> Bool {
        guard !argument.isEmpty, argument.utf8.count <= 4_096 else { return false }
        return !argument.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

/// Drains a pipe without blocking the actor or growing memory beyond the fixed limit.
struct BoundedCommandOutputReader {
    let handle: FileHandle
    let maximumBytes: Int

    init(handle: FileHandle, maximumBytes: Int = 1_048_576) throws {
        self.handle = handle
        self.maximumBytes = maximumBytes
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func drain(into data: inout Data, executable: SystemExecutable) throws {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard data.count <= maximumBytes - count else {
                throw CommandRunnerError.outputTooLarge(executable)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
