// Store giữ data Coaching tab persistent giữa các lần switch tab.
// Khi user đổi Live ↔ Coaching, data không reload nếu vừa load <5s.
// Auto-refresh chạy khi `isActive == true` (tab Coaching đang hiện).

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

    /// Scope tham chiếu đến reload gần nhất — nếu user đổi scope/anchor,
    /// data cũ không match → buộc reload.
    var lastScopeFingerprint: String = ""

    private var refreshTask: Task<Void, Never>?
    private let stalenessThreshold: TimeInterval = 5

    /// True nếu data còn fresh (<5s) VÀ scope match → có thể skip reload khi
    /// switch tab về Coaching.
    func isFresh(for fingerprint: String) -> Bool {
        guard fingerprint == lastScopeFingerprint else { return false }
        return Date().timeIntervalSince(lastRefreshAt) < stalenessThreshold
    }

    func reload(scope: ReportScope, fingerprint: String) {
        if isLoading { return }
        isLoading = true
        lastScopeFingerprint = fingerprint
        let currentRange = Self.dateRange(for: scope)
        let prevRange = Self.previousPeriodRange(matching: scope)
        let trendRange = Self.trendWindowRange(endingAt: scope)
        let combined = Self.unionRange(currentRange, prevRange, trendRange)

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = await CoachingScan.scan(in: combined)
            let curP = result.prompts.filter { currentRange.contains($0.timestamp) }
            let curS = result.sessions.filter { Self.intersect(currentRange, $0) }
            let prevP = result.prompts.filter { prevRange.contains($0.timestamp) }
            let prevS = result.sessions.filter { Self.intersect(prevRange, $0) }
            let prevAgg = SessionInventory.aggregate(prevS)
            let prevStats = ReportGenerator.stats(for: prevP)
            let trend = Self.bucketDailyCost(sessions: result.sessions, endingAt: scope)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.allRecords = curP
                self.allSessions = curS.sorted { $0.cost > $1.cost }
                self.previousAggregate = prevAgg
                self.previousAvgStars = prevStats.avgStars
                self.previousPromptCount = prevStats.totalPrompts
                self.dailyCostTrend = trend
                self.lastRefreshAt = Date()
                self.isLoading = false
            }
        }
    }

    /// Khởi động poll mỗi 5s khi tab Coaching active. Cancel khi disappear.
    func startAutoRefresh(scope: ReportScope, fingerprint: String) {
        stopAutoRefresh()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                self?.reload(scope: scope, fingerprint: fingerprint)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
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
