import CoreServices
import Foundation

enum FileActivityCollectorError: LocalizedError {
    case invalidLabel
    case noRoots
    case rootIsNotDirectory(String)
    case streamCreationFailed
    case streamStartFailed

    var errorDescription: String? {
        switch self {
        case .invalidLabel:
            "A watched-root label must be short and must not contain a path."
        case .noRoots:
            "At least one watched root is required."
        case let .rootIsNotDirectory(label):
            "The watched root named \(label) is not an accessible directory."
        case .streamCreationFailed:
            "The file activity stream could not be created."
        case .streamStartFailed:
            "The file activity stream could not be started."
        }
    }
}

struct FileActivityRoot: Hashable, Sendable {
    let url: URL
    let label: String

    init(url: URL, label: String) throws {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPrivateLabel(cleanLabel) else {
            throw FileActivityCollectorError.invalidLabel
        }

        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.label = cleanLabel
    }

    fileprivate var normalizedPath: String {
        var path = url.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func isPrivateLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 80 else { return false }
        guard !label.contains("/"), !label.contains("\\") else { return false }
        return label.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}

enum FileActivityOperation: String, CaseIterable, Codable, Hashable, Sendable {
    case changed
    case created
    case removed
    case renamed
    case contentModified
    case metadataModified
    case ownerChanged
    case extendedAttributesModified
    case finderInfoModified
    case cloned
    case mounted
    case unmounted
    case rootChanged
}

enum FileActivityRescanReason: String, CaseIterable, Codable, Hashable, Sendable {
    case mustScanSubdirectories
    case userQueueDroppedEvents
    case kernelDroppedEvents
    case watchedRootChanged
}

struct FileActivitySummary: Codable, Hashable, Sendable {
    let rootLabel: String
    let operations: Set<FileActivityOperation>
    let eventCount: Int
    let rescanReasons: Set<FileActivityRescanReason>

    var requiresRescan: Bool {
        !rescanReasons.isEmpty
    }
}

struct FileActivityBatch: Codable, Hashable, Sendable {
    let capturedAt: Date
    let summaries: [FileActivitySummary]
    let provenance: DataProvenance
}

struct FileActivityFlagMapping: Equatable, Sendable {
    let operations: Set<FileActivityOperation>
    let rescanReasons: Set<FileActivityRescanReason>
}

final class FileActivityCollector: @unchecked Sendable {
    static let minimumLatency: TimeInterval = 0.05
    static let maximumLatency: TimeInterval = 2.0

    let roots: [FileActivityRoot]
    let latency: TimeInterval

    private let lock = NSLock()
    private var activeSession: Session?

    init(
        roots: [FileActivityRoot],
        latency: TimeInterval = 0.5
    ) {
        self.roots = roots
        self.latency = Self.boundedLatency(latency)
    }

    deinit {
        stop()
    }

    func events() -> AsyncThrowingStream<FileActivityBatch, Error> {
        AsyncThrowingStream { continuation in
            do {
                let session = Session(
                    roots: roots,
                    latency: latency,
                    continuation: continuation
                )
                try session.start()
                replaceActiveSession(with: session)

                continuation.onTermination = { [weak self, weak session] _ in
                    guard let session else { return }
                    self?.stop(session: session) ?? session.stop()
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func stop() {
        let session = takeActiveSession()
        session?.stop()
    }

    static func boundedLatency(_ latency: TimeInterval) -> TimeInterval {
        guard latency.isFinite else { return 0.5 }
        return min(maximumLatency, max(minimumLatency, latency))
    }

    static func map(flags: FSEventStreamEventFlags) -> FileActivityFlagMapping {
        var operations: Set<FileActivityOperation> = []
        var rescanReasons: Set<FileActivityRescanReason> = []

        add(.created, when: kFSEventStreamEventFlagItemCreated, isSetIn: flags, to: &operations)
        add(.removed, when: kFSEventStreamEventFlagItemRemoved, isSetIn: flags, to: &operations)
        add(.renamed, when: kFSEventStreamEventFlagItemRenamed, isSetIn: flags, to: &operations)
        add(.contentModified, when: kFSEventStreamEventFlagItemModified, isSetIn: flags, to: &operations)
        add(.metadataModified, when: kFSEventStreamEventFlagItemInodeMetaMod, isSetIn: flags, to: &operations)
        add(.ownerChanged, when: kFSEventStreamEventFlagItemChangeOwner, isSetIn: flags, to: &operations)
        add(.extendedAttributesModified, when: kFSEventStreamEventFlagItemXattrMod, isSetIn: flags, to: &operations)
        add(.finderInfoModified, when: kFSEventStreamEventFlagItemFinderInfoMod, isSetIn: flags, to: &operations)
        add(.cloned, when: kFSEventStreamEventFlagItemCloned, isSetIn: flags, to: &operations)
        add(.mounted, when: kFSEventStreamEventFlagMount, isSetIn: flags, to: &operations)
        add(.unmounted, when: kFSEventStreamEventFlagUnmount, isSetIn: flags, to: &operations)
        add(.rootChanged, when: kFSEventStreamEventFlagRootChanged, isSetIn: flags, to: &operations)

        add(
            .mustScanSubdirectories,
            when: kFSEventStreamEventFlagMustScanSubDirs,
            isSetIn: flags,
            to: &rescanReasons
        )
        add(
            .userQueueDroppedEvents,
            when: kFSEventStreamEventFlagUserDropped,
            isSetIn: flags,
            to: &rescanReasons
        )
        add(
            .kernelDroppedEvents,
            when: kFSEventStreamEventFlagKernelDropped,
            isSetIn: flags,
            to: &rescanReasons
        )
        add(
            .watchedRootChanged,
            when: kFSEventStreamEventFlagRootChanged,
            isSetIn: flags,
            to: &rescanReasons
        )

        if operations.isEmpty {
            operations.insert(.changed)
        }

        return FileActivityFlagMapping(
            operations: operations,
            rescanReasons: rescanReasons
        )
    }

    static func redactedRootLabel(
        forEventPath eventPath: String,
        roots: [FileActivityRoot]
    ) -> String? {
        matchingRoot(forEventPath: eventPath, roots: roots)?.label
    }

    private static func matchingRoot(
        forEventPath eventPath: String,
        roots: [FileActivityRoot]
    ) -> FileActivityRoot? {
        let normalizedEventPath = URL(fileURLWithPath: eventPath)
            .standardizedFileURL
            .path

        return roots
            .filter { path(normalizedEventPath, isInside: $0.normalizedPath) }
            .max { $0.normalizedPath.count < $1.normalizedPath.count }
    }

    private static func path(_ eventPath: String, isInside rootPath: String) -> Bool {
        if rootPath == "/" { return eventPath.hasPrefix("/") }
        if eventPath == rootPath { return true }
        return eventPath.hasPrefix(rootPath + "/")
    }

    private static func add<Value: Hashable>(
        _ value: Value,
        when flag: Int,
        isSetIn flags: FSEventStreamEventFlags,
        to values: inout Set<Value>
    ) {
        guard flags & FSEventStreamEventFlags(flag) != 0 else { return }
        values.insert(value)
    }

    private func replaceActiveSession(with session: Session) {
        lock.lock()
        let previousSession = activeSession
        activeSession = session
        lock.unlock()

        previousSession?.stop()
    }

    private func takeActiveSession() -> Session? {
        lock.lock()
        let session = activeSession
        activeSession = nil
        lock.unlock()
        return session
    }

    private func stop(session: Session) {
        lock.lock()
        if activeSession === session {
            activeSession = nil
        }
        lock.unlock()

        session.stop()
    }
}

private extension FileActivityCollector {
    final class Session: @unchecked Sendable {
        typealias Continuation = AsyncThrowingStream<FileActivityBatch, Error>.Continuation

        private struct Aggregate {
            var operations: Set<FileActivityOperation> = []
            var eventCount = 0
            var rescanReasons: Set<FileActivityRescanReason> = []
        }

        private let roots: [FileActivityRoot]
        private let latency: TimeInterval
        private let queue = DispatchQueue(label: "com.hephaistos.LumeFS.FileActivity")
        private let queueKey = DispatchSpecificKey<UInt8>()

        private var continuation: Continuation?
        private var stream: FSEventStreamRef?

        init(
            roots: [FileActivityRoot],
            latency: TimeInterval,
            continuation: Continuation
        ) {
            self.roots = roots
            self.latency = latency
            self.continuation = continuation
            queue.setSpecific(key: queueKey, value: 1)
        }

        func start() throws {
            try performSynchronously {
                guard !roots.isEmpty else {
                    throw FileActivityCollectorError.noRoots
                }

                try validateRoots()

                var context = FSEventStreamContext(
                    version: 0,
                    info: Unmanaged.passUnretained(self).toOpaque(),
                    retain: nil,
                    release: nil,
                    copyDescription: nil
                )
                let flags = FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagUseCFTypes |
                    kFSEventStreamCreateFlagFileEvents |
                    kFSEventStreamCreateFlagWatchRoot
                )
                let paths = roots.map(\.normalizedPath) as CFArray

                guard let newStream = FSEventStreamCreate(
                    kCFAllocatorDefault,
                    Self.callback,
                    &context,
                    paths,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    latency,
                    flags
                ) else {
                    throw FileActivityCollectorError.streamCreationFailed
                }

                FSEventStreamSetDispatchQueue(newStream, queue)
                guard FSEventStreamStart(newStream) else {
                    FSEventStreamInvalidate(newStream)
                    FSEventStreamRelease(newStream)
                    throw FileActivityCollectorError.streamStartFailed
                }

                stream = newStream
            }
        }

        func stop() {
            performSynchronously {
                guard let stream else { return }

                self.stream = nil
                let continuation = self.continuation
                self.continuation = nil

                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                continuation?.finish()
            }
        }

        private func validateRoots() throws {
            for root in roots {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: root.normalizedPath,
                    isDirectory: &isDirectory
                )

                guard exists, isDirectory.boolValue else {
                    throw FileActivityCollectorError.rootIsNotDirectory(root.label)
                }
            }
        }

        private func handle(
            count: Int,
            pathsPointer: UnsafeMutableRawPointer,
            flagsPointer: UnsafePointer<FSEventStreamEventFlags>
        ) {
            let paths = unsafeBitCast(pathsPointer, to: NSArray.self)
            guard paths.count >= count else { return }

            var aggregates: [FileActivityRoot: Aggregate] = [:]
            for index in 0..<count {
                guard let eventPath = paths[index] as? String else { continue }

                let mapping = FileActivityCollector.map(flags: flagsPointer[index])
                let targets = targetRoots(
                    forEventPath: eventPath,
                    requiresRescan: !mapping.rescanReasons.isEmpty
                )

                for root in targets {
                    var aggregate = aggregates[root, default: Aggregate()]
                    aggregate.operations.formUnion(mapping.operations)
                    aggregate.eventCount += 1
                    aggregate.rescanReasons.formUnion(mapping.rescanReasons)
                    aggregates[root] = aggregate
                }
            }

            let summaries = roots.compactMap { root -> FileActivitySummary? in
                guard let aggregate = aggregates[root] else { return nil }
                return FileActivitySummary(
                    rootLabel: root.label,
                    operations: aggregate.operations,
                    eventCount: aggregate.eventCount,
                    rescanReasons: aggregate.rescanReasons
                )
            }
            guard !summaries.isEmpty else { return }

            continuation?.yield(
                FileActivityBatch(
                    capturedAt: Date(),
                    summaries: summaries,
                    provenance: .live
                )
            )
        }

        private func targetRoots(
            forEventPath eventPath: String,
            requiresRescan: Bool
        ) -> [FileActivityRoot] {
            if let root = FileActivityCollector.matchingRoot(
                forEventPath: eventPath,
                roots: roots
            ) {
                return [root]
            }

            return requiresRescan ? roots : []
        }

        private func performSynchronously<T>(_ work: () throws -> T) rethrows -> T {
            if DispatchQueue.getSpecific(key: queueKey) != nil {
                return try work()
            }
            return try queue.sync(execute: work)
        }

        private static let callback: FSEventStreamCallback = {
            _, callbackInfo, count, pathsPointer, flagsPointer, _ in
            guard let callbackInfo else { return }

            let session = Unmanaged<Session>
                .fromOpaque(callbackInfo)
                .takeUnretainedValue()
            session.handle(
                count: count,
                pathsPointer: pathsPointer,
                flagsPointer: flagsPointer
            )
        }
    }
}
