// Cached reads appear first; local sources refresh automatically in the background.

import Foundation
import Observation
import AgentWatchCore

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
    var aggregateGroups: [CoachingAggregateKey: InventoryAggregate] = [:]
    var previousAvgStars: Double = 0
    var previousPromptCount: Int = 0
    /// 7 bucket gần nhất, từ cũ → mới. Mỗi bucket là (ngày, cost) để chart
    /// hiển thị weekday label đúng theo từng cột.
    var dailyCostTrend: [DailyCostBucket] = []
    var lastRefreshAt: Date = .distantPast
    var isLoading: Bool = false
    var scanProgress: String = ""
    private var scanGeneration = UUID()

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
    private var restoreTask: Task<Void, Never>?

    /// Whether the displayed snapshot belongs to the selected range.
    func isFresh(for fingerprint: String) -> Bool {
        guard fingerprint == lastScopeFingerprint else { return false }
        return lastRefreshAt != .distantPast
    }

    /// Restore a saved scope first, then refresh local sources automatically.
    func setActive(scope: ReportScope, fingerprint: String) {
        if activeFingerprint != fingerprint {
            scanGeneration = UUID()
            restoreTask?.cancel()
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
        }
        activeScope = scope
        activeFingerprint = fingerprint
        guard !isFresh(for: fingerprint), loadTask == nil else { return }
        restoreTask?.cancel()
        let generation = scanGeneration
        let range = Self.dateRange(for: scope)
        restoreTask = Task { [weak self] in
            let snapshot = await CoachingQueryStore.shared.snapshot(in: range)
            guard !Task.isCancelled, let self, self.scanGeneration == generation,
                  self.activeFingerprint == fingerprint else { return }
            if let snapshot {
                _ = self.applyScanResult(snapshot.result, scope: scope, fingerprint: fingerprint,
                    reason: "snapshot", startedAt: snapshot.capturedAt, capturedAt: snapshot.capturedAt, notify: false)
            }
            self.reload(scope: scope, fingerprint: fingerprint, showLoading: snapshot == nil, reason: "automatic")
        }
    }

    /// Reload sử dụng scope mới nhất. Cancel in-flight load để tránh stale data
    /// được ghi đè lên UI sau khi user đã đổi filter.
    func reload(scope: ReportScope, fingerprint: String, showLoading: Bool = true, reason: String = "manual") {
        if activeFingerprint != fingerprint { setActive(scope: scope, fingerprint: fingerprint) }
        restoreTask?.cancel()
        loadTask?.cancel()
        let shouldShowLoading = showLoading || (lastRefreshAt == .distantPast && allRecords.isEmpty && allSessions.isEmpty)
        if shouldShowLoading {
            isLoading = true
        }
        scanGeneration = UUID()
        let generation = scanGeneration
        scanProgress = "Đang tìm file log…"
        let currentRange = Self.dateRange(for: scope)
        let startedAt = Date()
        onScanStarted?(reason, scope)

        loadTask = Task.detached(priority: showLoading ? .userInitiated : .utility) { [weak self] in
            let result = await CoachingScan.scan(in: currentRange, progress: { [weak self] completed, total in
                await MainActor.run { [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.scanProgress = "Đã đọc \(completed)/\(total) file log. Lần đầu có thể lâu nếu lịch sử lớn."
                }
            })
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard self?.scanGeneration == generation else { return }
                _ = self?.applyScanResult(
                    result,
                    scope: scope,
                    fingerprint: fingerprint,
                    reason: reason,
                    startedAt: startedAt
                )
            }
        }
    }

    func cancelScan() {
        scanGeneration = UUID()
        restoreTask?.cancel()
        loadTask?.cancel(); loadTask = nil; isLoading = false
        scanProgress = "Đã dừng đọc log."
    }

    @discardableResult
    func reloadForExport(scope: ReportScope, fingerprint: String) async -> Bool {
        if activeFingerprint != fingerprint { setActive(scope: scope, fingerprint: fingerprint) }
        restoreTask?.cancel()
        loadTask?.cancel()
        scanGeneration = UUID()
        let generation = scanGeneration
        isLoading = true
        let currentRange = Self.dateRange(for: scope)
        let startedAt = Date()
        onScanStarted?("export", scope)
        let result = await Task.detached(priority: .userInitiated) {
            // Evidence exports read authoritative source bytes, including rewrites.
            await CoachingScan.scan(in: currentRange, forceFullRead: true)
        }.value
        guard scanGeneration == generation, !Task.isCancelled else { return false }
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
                                 startedAt: Date,
                                 capturedAt: Date = Date(), notify: Bool = true) -> Bool {
        // Nếu user đã đổi scope/filter trước khi scan xong → bỏ kết quả này,
        // tránh data cũ ghi đè lên data mới.
        guard activeFingerprint == fingerprint else { return false }
        let curP = result.prompts
        let curS = result.sessions
        let curAgg = result.aggregate ?? SessionInventory.aggregate(curS)
        let curStats = ReportGenerator.stats(for: curP)

        allRecords = curP
        allSessions = curS
        // Keep delta chips neutral. Period comparisons and trends are intentionally
        // not inferred from whole-session totals; each report snapshot is exact.
        previousAggregate = curAgg
        aggregateGroups = result.aggregateGroups
        previousAvgStars = curStats.avgStars
        previousPromptCount = curStats.totalPrompts
        dailyCostTrend = []
        let signals = PetSignals(
            hasActivity: !curS.isEmpty,
            outlierCount: CoachingInsights.outlierSessions(curS).count,
            agentLoopCount: CoachingInsights.agentLoopSessions(curS).count,
            avgStarsDelta: 0)
        petState = PetMood.resolve(signals)
        lastScopeFingerprint = fingerprint
        lastRefreshAt = capturedAt
        isLoading = false
        loadTask = nil
        let outlierIds = CoachingInsights.outlierSessions(curS)
        let loopIds = CoachingInsights.agentLoopSessions(curS)
        let sourceSessionCounts = Dictionary(grouping: curS, by: { $0.source.vendor.label })
            .mapValues(\.count)
        // Restoring a snapshot must not award XP or record a new source scan.
        guard notify else { return true }
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

    nonisolated static func dateRange(for scope: ReportScope) -> Range<Date> {
        ReportTime.range(for: scope)
    }

}
