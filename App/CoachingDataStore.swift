// Store giữ data Coaching tab persistent giữa các lần switch tab.
// Khi user đổi Sessions ↔ Coaching, data không reload nếu đã có snapshot đúng scope.
// Không auto-refresh: app chỉ đọc log theo snapshot khi mở tab, đổi scope,
// hoặc user bấm refresh.

import Foundation
import Observation
import ClaudeWatchCore

/// 1 cột trong 7-day cost chart. `date` = ngày của cột (0h00 local), `cost` = tổng cost.
struct DailyCostBucket: Sendable, Equatable {
    let date: Date
    let cost: Double
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

    private var loadTask: Task<Void, Never>?

    /// True nếu đã có snapshot cho đúng scope → skip reload khi switch tab về
    /// Coaching. User bấm Refresh hoặc đổi scope mới scan lại.
    func isFresh(for fingerprint: String) -> Bool {
        guard fingerprint == lastScopeFingerprint else { return false }
        return lastRefreshAt != .distantPast
    }

    /// Cập nhật scope đang chọn MÀ KHÔNG trigger reload — dùng khi onAppear
    /// thấy data còn fresh nhưng vẫn cần giữ fingerprint hiện tại.
    func setActive(scope: ReportScope, fingerprint: String) {
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
        let prevRange = Self.previousPeriodRange(matching: scope)
        let trendRange = Self.trendWindowRange(endingAt: scope)
        let combined = Self.unionRange(currentRange, prevRange, trendRange)

        loadTask = Task.detached(priority: showLoading ? .userInitiated : .utility) { [weak self] in
            let result = await CoachingScan.scan(in: combined)
            // Nếu user đã đổi filter trước khi scan xong → bỏ kết quả này,
            // tránh data cũ ghi đè lên data mới.
            if Task.isCancelled { return }
            let curP = result.prompts.filter { currentRange.contains($0.timestamp) }
            let curS = result.sessions.filter { Self.intersect(currentRange, $0) }
            let prevP = result.prompts.filter { prevRange.contains($0.timestamp) }
            let prevS = result.sessions.filter { Self.intersect(prevRange, $0) }
            let prevAgg = SessionInventory.aggregate(prevS)
            let prevStats = ReportGenerator.stats(for: prevP)
            let trend = Self.bucketDailyCost(sessions: result.sessions, endingAt: scope)

            await MainActor.run { [weak self] in
                guard let self else { return }
                // Double-check: chỉ apply nếu fingerprint của lần load này vẫn
                // khớp với active hiện tại. Nếu user đổi filter trong lúc đang
                // await MainActor.run, vẫn bỏ qua.
                guard self.activeFingerprint == fingerprint else { return }
                self.allRecords = curP
                self.allSessions = curS.sorted {
                    if $0.cost != $1.cost { return $0.cost > $1.cost }
                    return $0.totalTokens > $1.totalTokens
                }
                self.previousAggregate = prevAgg
                self.previousAvgStars = prevStats.avgStars
                self.previousPromptCount = prevStats.totalPrompts
                self.dailyCostTrend = trend
                // Compute pet state từ aggregate đã có — outlier/agent loop dùng
                // CoachingInsights logic, avgStarsDelta lấy từ ReportGenerator stats.
                let curStats = ReportGenerator.stats(for: curP)
                let signals = PetSignals(
                    hasActivity: !curS.isEmpty,
                    outlierCount: CoachingInsights.outlierSessions(curS).count,
                    agentLoopCount: CoachingInsights.agentLoopSessions(curS).count,
                    avgStarsDelta: curStats.avgStars - prevStats.avgStars)
                self.petState = PetMood.resolve(signals)
                self.lastRefreshAt = Date()
                self.isLoading = false
                self.loadTask = nil
                // XP hook — gọi sau khi allRecords/allSessions đã apply, trên MainActor.
                // outlierIds/agentLoopIds được tính lại ở đây để truyền cùng snapshot.
                let outlierIds = CoachingInsights.outlierSessions(curS)
                let loopIds = CoachingInsights.agentLoopSessions(curS)
                self.onReloadComplete?(curP, curS, outlierIds, loopIds)
            }
        }
    }

    // MARK: - Range helpers (nonisolated để dùng từ Task.detached)

    nonisolated static func dateRange(for scope: ReportScope) -> ClosedRange<Date> {
        let cal = Calendar.current
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

    nonisolated static func previousPeriodRange(matching scope: ReportScope) -> ClosedRange<Date> {
        let cal = Calendar.current
        switch scope {
        case .day(let d):
            let prev = cal.date(byAdding: .day, value: -1, to: d) ?? d
            let start = cal.startOfDay(for: prev)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
            return start...end.addingTimeInterval(-1)
        case .week(let start):
            let prevStart = PromptHistory.currentMondayBased
                .date(byAdding: .day, value: -7, to: start) ?? start
            let prevEnd = PromptHistory.currentMondayBased
                .date(byAdding: .day, value: 7, to: prevStart) ?? prevStart
            return prevStart...prevEnd.addingTimeInterval(-1)
        case .custom(let s, let e, _):
            let span = e.timeIntervalSince(s)
            return s.addingTimeInterval(-span)...s.addingTimeInterval(-1)
        }
    }

    nonisolated static func trendWindowRange(endingAt scope: ReportScope) -> ClosedRange<Date> {
        let cal = Calendar.current
        let endAnchor: Date
        switch scope {
        case .day(let d):          endAnchor = d
        case .week(let s):         endAnchor = cal.date(byAdding: .day, value: 6, to: s) ?? s
        case .custom(_, let e, _): endAnchor = e
        }
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: endAnchor) ?? endAnchor)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endAnchor)) ?? endAnchor
        return start...end.addingTimeInterval(-1)
    }

    nonisolated static func unionRange(_ ranges: ClosedRange<Date>...) -> ClosedRange<Date> {
        let starts = ranges.map(\.lowerBound)
        let ends = ranges.map(\.upperBound)
        return (starts.min() ?? Date())...(ends.max() ?? Date())
    }

    nonisolated static func intersect(_ range: ClosedRange<Date>, _ s: SessionSummary) -> Bool {
        let last = s.lastTimestamp ?? .distantPast
        let first = s.firstTimestamp ?? .distantFuture
        return last >= range.lowerBound && first <= range.upperBound
    }

    nonisolated static func bucketDailyCost(sessions: [SessionSummary],
                                            endingAt scope: ReportScope) -> [DailyCostBucket] {
        let cal = Calendar.current
        let endAnchor: Date
        switch scope {
        case .day(let d):          endAnchor = d
        case .week(let s):         endAnchor = cal.date(byAdding: .day, value: 6, to: s) ?? s
        case .custom(_, let e, _): endAnchor = e
        }
        var out: [DailyCostBucket] = []
        for offset in (0..<7).reversed() {
            guard let day = cal.date(byAdding: .day, value: -offset, to: endAnchor) else {
                out.append(DailyCostBucket(date: endAnchor, cost: 0)); continue
            }
            let start = cal.startOfDay(for: day)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
            let r = start...end.addingTimeInterval(-1)
            let dayCost = sessions
                .filter { intersect(r, $0) }
                .map(\.cost).reduce(0, +)
            out.append(DailyCostBucket(date: start, cost: dayCost))
        }
        return out
    }
}
