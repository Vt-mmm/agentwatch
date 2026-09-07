// Heuristics phát hiện session bất thường + cost forecast cho coaching dashboard.
// Pure logic — no UI dependency, có thể test riêng.

import Foundation

public enum CoachingInsights {

    public static let agentLoopThreshold: Int = 10

    /// Cost outliers are compared only inside a homogeneous cohort:
    /// vendor + model family + cost basis. Mixing reported Pi cost with an
    /// API-equivalent Codex estimate makes a shared baseline meaningless.
    public static func outlierSessions(_ sessions: [SessionSummary]) -> Set<String> {
        let eligible = sessions.filter {
            $0.costBasis != .unavailable && $0.cost > 0
        }
        let cohorts = Dictionary(grouping: eligible) {
            CostCohort(
                vendor: $0.source.vendor,
                modelFamily: $0.modelFamily,
                costBasis: $0.costBasis
            )
        }
        var outliers: Set<String> = []
        for cohort in cohorts.values where cohort.count >= 3 {
            let costs = cohort.map(\.cost)
            let cohortMedian = median(costs)
            let mad = median(costs.map { abs($0 - cohortMedian) })
            // 1.4826 makes MAD comparable to standard deviation for a normal
            // distribution. A multiplicative floor handles identical low-cost
            // baselines without dividing by zero.
            let threshold = mad > 0
                ? cohortMedian + 3 * 1.4826 * mad
                : max(cohortMedian * 3, cohortMedian + 1)
            outliers.formUnion(
                cohort
                    .filter { $0.cost > threshold && $0.cost > 1.0 }
                    .map(\.auditKey)
            )
        }
        return outliers
    }

    /// Session có ≥ N lần spawn Agent → loop nguy hiểm. Trả về source-aware key.
    public static func agentLoopSessions(_ sessions: [SessionSummary]) -> Set<String> {
        Set(sessions.filter { $0.agentCount >= agentLoopThreshold }.map(\.auditKey))
    }

    /// Burn rate trung bình $/ngày từ 7 bucket daily cost.
    public static func dailyBurnRate(_ buckets: [Double]) -> Double {
        guard !buckets.isEmpty else { return 0 }
        return buckets.reduce(0, +) / Double(buckets.count)
    }

    /// Project chi phí tháng (30 ngày) từ burn rate hiện tại.
    public static func monthlyForecast(_ buckets: [Double]) -> Double {
        dailyBurnRate(buckets) * 30
    }

    private struct CostCohort: Hashable {
        let vendor: AgentVendor
        let modelFamily: ModelFamily
        let costBasis: UsageCostBasis
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
