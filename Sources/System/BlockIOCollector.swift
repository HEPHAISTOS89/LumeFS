import Foundation
import IOKit

private struct DeviceCounters: Sendable {
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

actor BlockIOCollector {
    private var previousCounters: [String: DeviceCounters] = [:]

    func collect(at date: Date = Date()) -> [DeviceIOSample] {
        let currentCounters = readCounters(at: date)
        defer { previousCounters = currentCounters }

        return currentCounters.compactMap { deviceName, current in
            guard let previous = previousCounters[deviceName] else {
                return zeroSample(deviceName: deviceName, counters: current)
            }

            let interval = current.capturedAt.timeIntervalSince(previous.capturedAt)
            guard interval > 0 else {
                return zeroSample(deviceName: deviceName, counters: current)
            }

            return DeviceIOSample(
                deviceName: deviceName,
                timestamp: date,
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
        .sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
    }

    private func readCounters(at date: Date) -> [String: DeviceCounters] {
        guard let matching = IOServiceMatching("IOMedia") else { return [:] }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        )

        guard result == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var counters: [String: DeviceCounters] = [:]
        var media = IOIteratorNext(iterator)

        while media != 0 {
            defer {
                IOObjectRelease(media)
                media = IOIteratorNext(iterator)
            }

            guard let properties = properties(for: media) else { continue }
            guard (properties["Whole"] as? Bool) == true else { continue }
            guard let deviceName = properties["BSD Name"] as? String else { continue }
            guard let statistics = statistics(for: media) else { continue }

            counters[deviceName] = DeviceCounters(
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
        }

        return counters
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

    private func rate(_ current: UInt64, _ previous: UInt64, _ interval: TimeInterval) -> Double {
        guard current >= previous else { return 0 }
        return Double(current - previous) / interval
    }

    private func zeroSample(
        deviceName: String,
        counters: DeviceCounters
    ) -> DeviceIOSample {
        DeviceIOSample(
            deviceName: deviceName,
            timestamp: counters.capturedAt,
            readBytesPerSecond: 0,
            writeBytesPerSecond: 0,
            readOperationsPerSecond: 0,
            writeOperationsPerSecond: 0,
            readErrors: counters.readErrors,
            writeErrors: counters.writeErrors,
            readRetries: counters.readRetries,
            writeRetries: counters.writeRetries
        )
    }
}
