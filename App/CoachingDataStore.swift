// Store giữ data Coaching tab persistent giữa các lần switch tab.
// Manual snapshot mode: mở tab/đổi scope không scan Claude/Codex/PiAgent.
// App chỉ đọc agent logs khi user bấm Đọc log hoặc khi export report.

import Foundation
import Observation
import ClaudeWatchCore

/// 1 cột trong 7-day cost chart. `date` = ngày của cột (0h00 local), `cost` = tổng cost.
struct DailyCostBucket: Sendable, Equatable {
    let date: Date
    let cost: Double
}

struct CoachingScanAudit: Sendable {
    static let accountingVersion = "usage-v2"

    let reason: String
    let scope: ReportScope
    let startedAt: Date
    let finishedAt: Date
    let candidateFileCount: Int
    let sessionCount: Int
    let promptCount: Int
    let totalTokens: Int
    let reportedCost: Double
    let estimatedCost: Double
    let unavailableCostSessions: Int
    let partialRangeSessions: Int
    let dataWarningCount: Int
    let sourceSessionCounts: [String: Int]
}

@Observable
@MainActor
final class CoachingDataStore {
    var allRecords: [PromptRecord] = []
    var allSessions: [SessionSummary] = []
    var previousAggregate: InventoryAggregate = .zero
    var previousAvgStars: Double = 0
    var previousPromptCount: Int = 0
    /// 7 bucket gần nhất, từ cũ → mới. Mỗi bucket là (ngày, cost) để chart
    /// hiển thị weekday label đúng theo từng cột.
    var dailyCostTrend: [DailyCostBucket] = []
    var lastRefreshAt: Date = .distantPast
    var isLoading: Bool = false

    /// Pet mascot state — derive từ aggregate signals (avg★ delta, outlier
    /// count, agent loop count). Update mỗi lần reload xong.
    var petState: PetState = .sleepy

    /// Scope tham chiếu đến reload gần nhất — nếu user đổi scope/anchor,
    /// data cũ không match → buộc reload.
    var lastScopeFingerprint: String = ""

    /// Scope/fingerprint đang được chọn — dùng để bỏ kết quả load cũ nếu user
    /// đổi filter trong lúc snapshot scan chưa xong.
    private var activeScope: ReportScope?
    private var activeFingerprint: String = ""

    /// Callback được gọi sau mỗi reload thành công — dùng để inject XP vào
    /// PetCollectionStore mà không tạo tight coupling giữa hai store.
    /// Capture [weak petCollection] ở call site để tránh retain cycle.
    var onReloadComplete: ((_ records: [PromptRecord], _ sessions: [SessionSummary],
                            _ outlierIds: Set<String>, _ agentLoopIds: Set<String>) -> Void)?
    var onScanStarted: ((_ reason: String, _ scope: ReportScope) -> Void)?
    var onScanCompleted: ((CoachingScanAudit) -> Void)?

    private var loadTask: Task<Void, Never>?

    /// True nếu đã có snapshot cho đúng scope. Đổi scope không tự scan; view
    /// dùng giá trị này để show màn "Chưa đọc snapshot".
    func isFresh(for fingerprint: String) -> Bool {
        guard fingerprint == lastScopeFingerprint else { return false }
        return lastRefreshAt != .distantPast
    }

    /// Cập nhật scope đang chọn MÀ KHÔNG trigger reload — dùng khi onAppear
    /// thấy data còn fresh nhưng vẫn cần giữ fingerprint hiện tại.
    func setActive(scope: ReportScope, fingerprint: String) {
        if activeFingerprint != fingerprint {
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
        }
        activeScope = scope
        activeFingerprint = fingerprint
    }

    /// Reload sử dụng scope mới nhất. Cancel in-flight load để tránh stale data
    /// được ghi đè lên UI sau khi user đã đổi filter.
    func reload(scope: ReportScope, fingerprint: String, showLoading: Bool = true) {
        setActive(scope: scope, fingerprint: fingerprint)
        loadTask?.cancel()
        let shouldShowLoading = showLoading || (lastRefreshAt == .distantPast && allRecords.isEmpty && allSessions.isEmpty)
        if shouldShowLoading {
            isLoading = true
        }
        lastScopeFingerprint = fingerprint
        let currentRange = Self.dateRange(for: scope)
        let startedAt = Date()
        onScanStarted?("manual", scope)

        loadTask = Task.detached(priority: showLoading ? .userInitiated : .utility) { [weak self] in
            let result = await CoachingScan.scan(in: currentRange)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                _ = self?.applyScanResult(
                    result,
                    scope: scope,
                    fingerprint: fingerprint,
                    reason: "manual",
                    startedAt: startedAt
                )
            }
        }
    }

    @discardableResult
    func reloadForExport(scope: ReportScope, fingerprint: String) async -> Bool {
        setActive(scope: scope, fingerprint: fingerprint)
        loadTask?.cancel()
        isLoading = true
        lastScopeFingerprint = fingerprint
        let currentRange = Self.dateRange(for: scope)
        let startedAt = Date()
        onScanStarted?("export", scope)
        let result = await Task.detached(priority: .userInitiated) {
            // Export must include bytes appended after the last UI snapshot.
            // Unchanged files still use the cache.
            await CoachingScan.scan(in: currentRange, allowRecentGrowth: false)
        }.value
        return applyScanResult(
            result,
            scope: scope,
            fingerprint: fingerprint,
            reason: "export",
            startedAt: startedAt
        )
    }

    private func applyScanResult(_ result: CoachingScanResult,
                                 scope: ReportScope,
                                 fingerprint: String,
                                 reason: String,
                                 startedAt: Date) -> Bool {
        // Nếu user đã đổi scope/filter trước khi scan xong → bỏ kết quả này,
        // tránh data cũ ghi đè lên data mới.
        guard activeFingerprint == fingerprint else { return false }
        let curP = result.prompts
        let curS = result.sessions
        let curAgg = SessionInventory.aggregate(curS)
        let curStats = ReportGenerator.stats(for: curP)

        allRecords = curP
        allSessions = curS.sorted {
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            return $0.totalTokens > $1.totalTokens
        }
        // Keep delta chips neutral. Period comparisons and trends are intentionally
        // not inferred from whole-session totals; each report snapshot is exact.
        previousAggregate = curAgg
        previousAvgStars = curStats.avgStars
        previousPromptCount = curStats.totalPrompts
        dailyCostTrend = []
        let signals = PetSignals(
            hasActivity: !curS.isEmpty,
            outlierCount: CoachingInsights.outlierSessions(curS).count,
            agentLoopCount: CoachingInsights.agentLoopSessions(curS).count,
            avgStarsDelta: 0)
        petState = PetMood.resolve(signals)
        lastRefreshAt = Date()
        isLoading = false
        loadTask = nil
        let outlierIds = CoachingInsights.outlierSessions(curS)
        let loopIds = CoachingInsights.agentLoopSessions(curS)
        let sourceSessionCounts = Dictionary(grouping: curS, by: { $0.source.vendor.label })
            .mapValues(\.count)
        onReloadComplete?(curP, curS, outlierIds, loopIds)
        onScanCompleted?(CoachingScanAudit(
            reason: reason,
            scope: scope,
            startedAt: startedAt,
            finishedAt: Date(),
            candidateFileCount: result.candidateFileCount,
            sessionCount: curS.count,
            promptCount: curP.count,
            totalTokens: curAgg.totalTokens,
            reportedCost: curAgg.reportedCost,
            estimatedCost: curAgg.estimatedCost,
            unavailableCostSessions: curAgg.unavailableCostSessionCount,
            partialRangeSessions: curS.filter { $0.usageScope == .partialRange }.count,
            dataWarningCount: curS.reduce(0) { $0 + $1.dataWarnings.count },
            sourceSessionCounts: sourceSessionCounts
        ))
        return true
    }

    // MARK: - Range helpers (nonisolated để dùng từ Task.detached)

    nonisolated static func dateRange(for scope: ReportScope) -> ClosedRange<Date> {
        let cal = ReportTime.calendar
        switch scope {
        case .day(let d):
            let start = cal.startOfDay(for: d)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
            return start...end.addingTimeInterval(-1)
        case .week(let start):
            let end = PromptHistory.currentMondayBased
                .date(byAdding: .day, value: 7, to: start) ?? start
            return start...end.addingTimeInterval(-1)
        case .custom(let s, let e, _):
            return s...e
        }
    }

}
