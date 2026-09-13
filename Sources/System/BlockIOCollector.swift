import Foundation
import IOKit

struct DeviceCounters: Sendable {
    let capturedAt: Date
    let bytesRead: UInt64
    let bytesWritten: UInt64
    let readOperations: UInt64
    let writeOperations: UInt64
    let readErrors: UInt64
    let writeErrors: UInt64
    let readRetries: UInt64
    let writeRetries: UInt64
}

/// One whole `IOMedia` object together with the identity of the driver that owns the
/// statistics it exposes. Several media can share one driver: an APFS container
/// (`disk3`) is synthesized above the physical store (`disk0`) and walking the IOKit
/// parent chain from either reaches the same `IOBlockStorageDriver`. Counting both
/// would double every byte.
struct MediaCandidate: Sendable {
    let bsdName: String
    /// `IORegistryEntryID` of the `IOBlockStorageDriver` that supplied the counters,
    /// or `nil` when no driver was found and the media is treated as its own source.
    let statisticsOwnerID: UInt64?
    /// Parent hops between the media and the statistics owner. The physical whole
    /// disk sits directly below its driver (depth 1); synthesized media are deeper.
    let depth: Int
    let counters: DeviceCounters
}

actor BlockIOCollector {
    private var previousCounters: [String: DeviceCounters] = [:]

    func collect(at date: Date = Date()) -> [DeviceIOSample] {
        let currentCounters = Self.deduplicate(readCandidates(at: date))
        defer { previousCounters = currentCounters }

        return currentCounters.compactMap { deviceName, current in
            Self.sample(deviceName: deviceName, current: current, previous: previousCounters[deviceName])
        }
        .sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
    }

    static func sample(
        deviceName: String,
        current: DeviceCounters,
        previous: DeviceCounters?
    ) -> DeviceIOSample? {
        // A rate requires two ordered observations, not an invented initial zero.
        guard let previous else { return nil }
        let interval = current.capturedAt.timeIntervalSince(previous.capturedAt)
        guard interval > 0,
              current.bytesRead >= previous.bytesRead,
              current.bytesWritten >= previous.bytesWritten else { return nil }

        return DeviceIOSample(
            deviceName: deviceName,
            timestamp: current.capturedAt,
            readBytesPerSecond: rate(current.bytesRead, previous.bytesRead, interval),
            writeBytesPerSecond: rate(current.bytesWritten, previous.bytesWritten, interval),
            readOperationsPerSecond: rate(current.readOperations, previous.readOperations, interval),
            writeOperationsPerSecond: rate(current.writeOperations, previous.writeOperations, interval),
            readErrors: current.readErrors,
            writeErrors: current.writeErrors,
            readRetries: current.readRetries,
            writeRetries: current.writeRetries
        )
    }

    /// Keeps one media per statistics owner: the shallowest candidate (the physical
    /// whole disk), with the BSD name as a deterministic tie-breaker. Candidates
    /// without an identified owner are kept as independent devices.
    static func deduplicate(_ candidates: [MediaCandidate]) -> [String: DeviceCounters] {
        var chosen: [UInt64: MediaCandidate] = [:]
        var result: [String: DeviceCounters] = [:]

        for candidate in candidates {
            guard let owner = candidate.statisticsOwnerID else {
                result[candidate.bsdName] = candidate.counters
                continue
            }
            if let existing = chosen[owner] {
                let isShallower = candidate.depth < existing.depth
                let isSameDepthButEarlier = candidate.depth == existing.depth
                    && candidate.bsdName.localizedStandardCompare(existing.bsdName) == .orderedAscending
                if isShallower || isSameDepthButEarlier {
                    chosen[owner] = candidate
                }
            } else {
                chosen[owner] = candidate
            }
        }

        for candidate in chosen.values {
            result[candidate.bsdName] = candidate.counters
        }
        return result
    }

    private func readCandidates(at date: Date) -> [MediaCandidate] {
        guard let matching = IOServiceMatching("IOMedia") else { return [] }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        )

        guard result == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var candidates: [MediaCandidate] = []
        var media = IOIteratorNext(iterator)

        while media != 0 {
            defer {
                IOObjectRelease(media)
                media = IOIteratorNext(iterator)
            }

            guard let properties = properties(for: media) else { continue }
            guard (properties["Whole"] as? Bool) == true else { continue }
            guard let deviceName = properties["BSD Name"] as? String else { continue }

            let statistics: [String: Any]
            let ownerID: UInt64?
            let depth: Int
            if let owner = statisticsOwner(for: media) {
                defer { IOObjectRelease(owner.entry) }
                guard let ownerStatistics = property("Statistics", of: owner.entry) as? [String: Any] else {
                    continue
                }
                statistics = ownerStatistics
                ownerID = registryEntryID(of: owner.entry)
                depth = owner.depth
            } else if let searched = self.statistics(for: media) {
                statistics = searched
                ownerID = nil
                depth = 0
            } else {
                continue
            }

            guard statistics["Bytes (Read)"] is NSNumber,
                  statistics["Bytes (Write)"] is NSNumber else { continue }

            candidates.append(MediaCandidate(
                bsdName: deviceName,
                statisticsOwnerID: ownerID,
                depth: depth,
                counters: DeviceCounters(
                    capturedAt: date,
                    bytesRead: value("Bytes (Read)", in: statistics),
                    bytesWritten: value("Bytes (Write)", in: statistics),
                    readOperations: value("Operations (Read)", in: statistics),
                    writeOperations: value("Operations (Write)", in: statistics),
                    readErrors: value("Errors (Read)", in: statistics),
                    writeErrors: value("Errors (Write)", in: statistics),
                    readRetries: value("Retries (Read)", in: statistics),
                    writeRetries: value("Retries (Write)", in: statistics)
                )
            ))
        }

        return candidates
    }

    /// Walks the service-plane parent chain until the first `IOBlockStorageDriver`.
    /// The returned entry is retained; the caller releases it.
    private func statisticsOwner(for media: io_registry_entry_t) -> (entry: io_registry_entry_t, depth: Int)? {
        var current = media
        IOObjectRetain(current)
        var depth = 0

        while depth < 16 {
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard result == KERN_SUCCESS, parent != 0 else { return nil }
            depth += 1
            if IOObjectConformsTo(parent, "IOBlockStorageDriver") != 0 {
                return (parent, depth)
            }
            current = parent
        }

        IOObjectRelease(current)
        return nil
    }

    private func registryEntryID(of entry: io_registry_entry_t) -> UInt64? {
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &identifier) == KERN_SUCCESS else { return nil }
        return identifier
    }

    private func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private func properties(for entry: io_registry_entry_t) -> [String: Any]? {
        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            entry,
            &unmanagedProperties,
            kCFAllocatorDefault,
            0
        )

        guard result == KERN_SUCCESS else { return nil }
        guard let dictionary = unmanagedProperties?.takeRetainedValue() else { return nil }
        return dictionary as NSDictionary as? [String: Any]
    }

    private func statistics(for entry: io_registry_entry_t) -> [String: Any]? {
        let options = IOOptionBits(
            kIORegistryIterateRecursively | kIORegistryIterateParents
        )

        guard let value = IORegistryEntrySearchCFProperty(
            entry,
            kIOServicePlane,
            "Statistics" as CFString,
            kCFAllocatorDefault,
            options
        ) else {
            return nil
        }

        return value as? [String: Any]
    }

    private func value(_ key: String, in statistics: [String: Any]) -> UInt64 {
        if let number = statistics[key] as? NSNumber {
            return number.uint64Value
        }
        return 0
    }

    private static func rate(_ current: UInt64, _ previous: UInt64, _ interval: TimeInterval) -> Double {
        guard current >= previous else { return 0 }
        return Double(current - previous) / interval
    }

}
