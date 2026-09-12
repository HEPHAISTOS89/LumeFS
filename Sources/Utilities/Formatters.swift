import Foundation

enum MetricFormatter {
    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        bytesFormatter.string(fromByteCount: value)
    }

    static func throughput(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }

        let gigabytes = bytesPerSecond / 1_000_000_000
        if gigabytes >= 0.1 {
            return String(format: "%.2f GB/s", gigabytes)
        }

        let megabytes = bytesPerSecond / 1_000_000
        if megabytes >= 0.1 {
            return String(format: "%.1f MB/s", megabytes)
        }

        let kilobytes = bytesPerSecond / 1_000
        return String(format: "%.0f KB/s", kilobytes)
    }

    static func percentage(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
