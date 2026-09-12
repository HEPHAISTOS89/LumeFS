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
        try validate(executable, arguments: arguments)

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = URL(fileURLWithPath: executable.rawValue)
        process.arguments = arguments
        process.environment = [
            "HOME": NSHomeDirectory(),
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/usr/sbin:/bin:/sbin"
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        guard !process.isRunning else {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(200))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw CommandRunnerError.timedOut(executable)
        }

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let maximumOutputBytes = 1_048_576
        guard outputData.count <= maximumOutputBytes,
              errorData.count <= maximumOutputBytes else {
            throw CommandRunnerError.outputTooLarge(executable)
        }

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
