import Foundation

struct WorkloadReadinessCalculator: Sendable {
    private let safetyMargin = 0.20

    func evaluate(
        volume: VolumeSnapshot,
        workloadGibibytes: Int
    ) -> WorkloadReadiness {
        let workloadBytes = Int64(max(0, workloadGibibytes)) * 1_073_741_824
        let marginBytes = Int64(Double(workloadBytes) * safetyMargin)
        let required = addingSafely(workloadBytes, marginBytes)
        let headroom = volume.availableBytes - workloadBytes

        return WorkloadReadiness(
            workloadBytes: workloadBytes,
            requiredBytesWithMargin: required,
            headroomBytes: headroom,
            fits: volume.availableBytes >= required
        )
    }

    private func addingSafely(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}
