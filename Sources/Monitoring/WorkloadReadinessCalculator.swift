import Foundation

struct WorkloadReadinessCalculator: Sendable {
    private let safetyMargin = 0.20

    func evaluate(
        volume: VolumeSnapshot,
        workloadGibibytes: Int,
        quota: QuotaSnapshot? = nil
    ) -> WorkloadReadiness {
        let workloadBytes = Int64(max(0, workloadGibibytes)) * 1_073_741_824
        let marginBytes = Int64(Double(workloadBytes) * safetyMargin)
        let required = addingSafely(workloadBytes, marginBytes)
        let quotaRemaining = quota.flatMap { $0.applies(to: volume) ? $0.remainingBytes : nil }
        let available = min(max(0, volume.availableBytes), quotaRemaining ?? Int64.max)
        let headroom = available - workloadBytes

        return WorkloadReadiness(
            workloadBytes: workloadBytes,
            requiredBytesWithMargin: required,
            headroomBytes: headroom,
            availableBytes: available,
            quotaLimited: quotaRemaining.map { $0 < volume.availableBytes } ?? false,
            fits: !volume.isReadOnly && volume.totalBytes > 0 && available >= required
        )
    }

    private func addingSafely(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}
