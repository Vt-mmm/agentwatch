// Heuristics phát hiện session bất thường + cost forecast cho coaching dashboard.
// Pure logic — no UI dependency, có thể test riêng.

import Foundation

public enum CoachingInsights {

    public static let agentLoopThreshold: Int = 10

    /// Outlier: cost của session > mean + 2σ TRONG TẬP đang xem. Trả về set
    /// session id để view tô badge cảnh báo. Cần ≥3 session để có ý nghĩa
    /// thống kê (nhỏ hơn dễ false positive).
    public static func outlierSessions(_ sessions: [SessionSummary]) -> Set<String> {
        guard sessions.count >= 3 else { return [] }
        let costs = sessions.map(\.cost)
        let mean = costs.reduce(0, +) / Double(costs.count)
        let variance = costs
            .map { pow($0 - mean, 2) }
            .reduce(0, +) / Double(costs.count)
        let stddev = sqrt(variance)
        let threshold = mean + 2 * stddev
        return Set(sessions.filter { $0.cost > threshold && $0.cost > 1.0 }.map(\.id))
    }

    /// Session có ≥ N lần spawn Agent → loop nguy hiểm. Trả về set id.
    public static func agentLoopSessions(_ sessions: [SessionSummary]) -> Set<String> {
        Set(sessions.filter { $0.agentCount >= agentLoopThreshold }.map(\.id))
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
}
