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
    @State var selectedRecord: PromptRecord?
    @State var selectedSession: SessionSummary?

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
        case cli = "CLI"
        case desktop = "Desktop"
        var id: String { rawValue }

        func matches(_ source: SessionSource) -> Bool {
            switch self {
            case .all:     return true
            case .claude:  return source.vendor == .claude
            case .codex:   return source.vendor == .codex
            case .cli:     return source == .cli
            case .desktop: return source == .desktop
            }
        }
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
        return base.filter { r in
            guard sourceFilter.matches(r.source) else { return false }
            if !projectFilter.isEmpty && r.projectDisplay != projectFilter { return false }
            if !q.isEmpty && !r.text.lowercased().contains(q) { return false }
            return true
        }
    }

    var sessions: [SessionSummary] {
        allSessions.filter { s in
            guard sourceFilter.matches(s.source) else { return false }
            if !projectFilter.isEmpty && s.projectDisplay != projectFilter { return false }
            if !modelFilter.isEmpty && s.model != modelFilter { return false }
            return true
        }
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
                    // v0.8.1: VendorBreakdownCard LÊN ĐẦU theo yêu cầu —
                    // user thấy Total/Claude/Codex breakdown trước hết.
                    VendorBreakdownCard(sessions: sessions)
                    ProjectCostBreakdownCard(sessions: sessions)
                    DailyGoalCard(
                        records: records,
                        sessions: sessions,
                        outlierIds: outlierIds,
                        agentLoopIds: agentLoopIds
                    )
                    summaryCard
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
        .sheet(item: $selectedRecord) { record in
            PromptDetailSheet(record: record)
        }
        .sheet(item: $selectedSession) { session in
            SessionDetailSheet(session: session)
        }
    }
}
