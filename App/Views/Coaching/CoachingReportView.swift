// Tab "Coaching" — root composer: khai báo struct, state, body, lifecycle, navigation.
// Dependency direction: CoachingReportView ← all Coaching/* extensions + sub-views.

import SwiftUI
import AppKit
import ClaudeWatchCore

struct CoachingReportView: View {
    // Internal (not private) — cross-file extensions in Coaching/ need access.
    @Environment(BookmarkStore.self) var bookmarks
    @Environment(CoachingDataStore.self) var data
    @FocusState var searchFocused: Bool
    @State var scope: ScopeKind = .day
    @State var anchor: Date = Date()
    @State var sourceFilter: SourceFilter = .all
    @State var searchQuery: String = ""
    @State var projectFilter: String = ""    // "" = all projects
    @State var modelFilter: String = ""      // "" = all models
    @State var viewMode: ViewMode = .all
    @State var sessionSort: SessionSort = .recent
    @State var selectedRecord: PromptRecord?
    @State var selectedSession: SessionSummary?
    @State var promptPageSize: Int = 25

    // Pagination — 15 mỗi trang đủ rộng để xem mà không cuộn quá dài.
    @State var sessionPage: Int = 0
    @State var promptPage: Int = 0
    let pageSize: Int = 15

    // MARK: - Enums

    enum ViewMode: String, CaseIterable, Identifiable {
        case all = "Tất cả"
        case bookmarks = "Mẫu hay"
        var id: String { rawValue }
    }

    enum ScopeKind: String, CaseIterable, Identifiable {
        case day = "Ngày"
        case week = "Tuần"
        case month = "Tháng"
        var id: String { rawValue }
    }

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "Tất cả"
        case claude = "Claude"
        case codex = "Codex"
        case piagent = "PiAgent"
        var id: String { rawValue }

        func matches(_ source: SessionSource) -> Bool {
            switch self {
            case .all:     return true
            case .claude:  return source.vendor == .claude
            case .codex:   return source.vendor == .codex
            case .piagent: return source.vendor == .piagent
            }
        }
    }

    enum SessionSort: String, CaseIterable, Identifiable {
        case recent = "Mới nhất"
        case risk = "Risk"
        case cost = "Cost"
        case tokens = "Token"
        var id: String { rawValue }
    }

    // MARK: - Derived data từ store (shared, persist across tab switch)

    var allRecords: [PromptRecord] { data.allRecords }
    var allSessions: [SessionSummary] { data.allSessions }
    var previousAggregate: InventoryAggregate { data.previousAggregate }
    var previousAvgStars: Double { data.previousAvgStars }
    var previousPromptCount: Int { data.previousPromptCount }
    var dailyCostTrend: [DailyCostBucket] { data.dailyCostTrend }
    var isLoading: Bool { data.isLoading }
    var lastRefreshAt: Date { data.lastRefreshAt }

    // MARK: - Filtered collections

    /// Records sau khi áp tất cả filter (source + project + search + bookmark mode).
    var records: [PromptRecord] {
        let base: [PromptRecord]
        if viewMode == .bookmarks {
            let ids = Set(bookmarks.items.map(\.id))
            base = allRecords.filter { ids.contains($0.id) }
        } else {
            base = allRecords
        }
        let q = searchQuery.lowercased()
        let filtered = base.filter { r in
            guard sourceFilter.matches(r.source) else { return false }
            if !projectFilter.isEmpty && r.projectDisplay != projectFilter { return false }
            if !q.isEmpty && !r.text.lowercased().contains(q) { return false }
            return true
        }
        return dedupedPromptRecords(filtered)
    }

    var filteredSessions: [SessionSummary] {
        allSessions.filter { s in
            guard sourceFilter.matches(s.source) else { return false }
            if !projectFilter.isEmpty && s.projectDisplay != projectFilter { return false }
            if !modelFilter.isEmpty && s.model != modelFilter { return false }
            return true
        }
    }

    var sessions: [SessionSummary] {
        sortedSessions(filteredSessions)
    }

    /// List unique project names cho project filter dropdown.
    var projectOptions: [String] {
        let names = Set(allRecords.map(\.projectDisplay))
            .union(Set(allSessions.map(\.projectDisplay)))
        return names.sorted()
    }

    /// List unique model names có data trong scope hiện tại.
    var modelOptions: [String] {
        Set(allSessions.map(\.model)).filter { !$0.isEmpty }.sorted()
    }

    var inventory: InventoryAggregate {
        SessionInventory.aggregate(sessions)
    }

    /// Session id outlier theo cost (>2σ avg) — view tô badge cảnh báo.
    var outlierIds: Set<String> {
        CoachingInsights.outlierSessions(sessions)
    }

    /// Session bị spawn quá nhiều subagent → suspect agent loop.
    var agentLoopIds: Set<String> {
        CoachingInsights.agentLoopSessions(sessions)
    }

    /// Chưa từng load lần nào (mount lần đầu, hoặc app vừa mở).
    var hasNeverLoaded: Bool { lastRefreshAt == .distantPast }

    /// True khi scope hiện tại empty SAU KHI đã load xong ít nhất 1 lần.
    /// KHÔNG check `isLoading` ở đây — auto-refresh tick set isLoading=true
    /// trong vài ms gây flash UI giữa "cards 0" và "empty hero".
    var isScopeEmpty: Bool {
        !hasNeverLoaded && allSessions.isEmpty && allRecords.isEmpty
    }

    var stats: ReportStats {
        ReportGenerator.stats(for: records)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                filterCard
                if hasNeverLoaded {
                    coachingLoadingHero
                } else if isScopeEmpty {
                    coachingEmptyHero
                } else {
                    // VendorBreakdownCard len dau de thay Total/Claude/Codex/PiAgent.
                    VendorBreakdownCard(sessions: sessions)
                    ProjectCostBreakdownCard(sessions: sessions)
                    DailyGoalCard(
                        records: records,
                        sessions: sessions,
                        outlierIds: outlierIds,
                        agentLoopIds: agentLoopIds
                    )
                    summaryCard
                    riskCard
                    anomalyCard
                    tokenCostCard
                    trendCard
                    if dailyCostTrend.contains(where: { $0.cost > 0 }) { forecastCard }
                    if !sessions.isEmpty { topSessionsCard }
                    if !records.isEmpty { distributionCard }
                    if !stats.topMissingSections.isEmpty { gapsCard }
                    if !stats.projectBreakdown.isEmpty { projectCard }
                    promptListCard
                }
            }
            .padding(20)
        }
        .background(Claude.backgroundGradient)
        .background {
            // Invisible hotkeys: ⌘R refresh, ⌘F focus search.
            VStack {
                Button { reload() } label: { EmptyView() }
                    .keyboardShortcut("r", modifiers: .command).opacity(0)
                Button { searchFocused = true } label: { EmptyView() }
                    .keyboardShortcut("f", modifiers: .command).opacity(0)
            }
            .frame(width: 0, height: 0)
        }
        .onAppear {
            if !data.isFresh(for: scopeFingerprint) {
                data.reload(scope: currentScope, fingerprint: scopeFingerprint)
            } else {
                data.setActive(scope: currentScope, fingerprint: scopeFingerprint)
            }
            data.startAutoRefresh()
        }
        .onDisappear { data.stopAutoRefresh() }
        .onChange(of: scope) { _, _ in
            resetPages()
            data.reload(scope: currentScope, fingerprint: scopeFingerprint)
        }
        .onChange(of: anchor) { _, _ in
            resetPages()
            data.reload(scope: currentScope, fingerprint: scopeFingerprint)
        }
        .onChange(of: sourceFilter) { _, _ in resetPages() }
        .onChange(of: searchQuery) { _, _ in resetPages() }
        .onChange(of: projectFilter) { _, _ in resetPages() }
        .onChange(of: modelFilter) { _, _ in resetPages() }
        .onChange(of: viewMode) { _, _ in resetPages() }
        .onChange(of: sessionSort) { _, _ in sessionPage = 0 }
        .onChange(of: promptPageSize) { _, _ in promptPage = 0 }
        .sheet(item: $selectedRecord) { record in
            PromptDetailSheet(record: record)
        }
        .sheet(item: $selectedSession) { session in
            SessionDetailSheet(session: session)
        }
    }

    private func dedupedPromptRecords(_ input: [PromptRecord]) -> [PromptRecord] {
        var lastTimestampByKey: [String: Date] = [:]
        return input.filter { record in
            let key = "\(record.source.rawValue)|\(record.sessionUuid)|\(normalizedPromptText(record.text))"
            defer { lastTimestampByKey[key] = record.timestamp }
            guard let previous = lastTimestampByKey[key] else { return true }
            return abs(record.timestamp.timeIntervalSince(previous)) > 3
        }
    }

    private func sortedSessions(_ input: [SessionSummary]) -> [SessionSummary] {
        switch sessionSort {
        case .recent:
            return input.sorted(by: recencySort)
        case .risk:
            let risks = riskBySession
            return input.sorted { a, b in
                let ar = risks[a.id]
                let br = risks[b.id]
                let aSeverity = ar?.severity.rawValue ?? 0
                let bSeverity = br?.severity.rawValue ?? 0
                if aSeverity != bSeverity { return aSeverity > bSeverity }
                let aScore = ar?.score ?? -1
                let bScore = br?.score ?? -1
                if aScore != bScore { return aScore > bScore }
                return recencySort(a, b)
            }
        case .cost:
            return input.sorted { a, b in
                if a.cost != b.cost { return a.cost > b.cost }
                if a.totalTokens != b.totalTokens { return a.totalTokens > b.totalTokens }
                return recencySort(a, b)
            }
        case .tokens:
            return input.sorted { a, b in
                if a.totalTokens != b.totalTokens { return a.totalTokens > b.totalTokens }
                if a.cost != b.cost { return a.cost > b.cost }
                return recencySort(a, b)
            }
        }
    }

    private func recencySort(_ a: SessionSummary, _ b: SessionSummary) -> Bool {
        let ad = a.lastTimestamp ?? a.firstTimestamp ?? .distantPast
        let bd = b.lastTimestamp ?? b.firstTimestamp ?? .distantPast
        if ad != bd { return ad > bd }
        return a.id < b.id
    }

    private func normalizedPromptText(_ text: String) -> String {
        let compact = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return String(compact.prefix(800))
    }
}
