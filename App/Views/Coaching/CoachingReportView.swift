// Tab "Coaching" — root composer: khai báo struct, state, body, lifecycle, navigation.
// Dependency direction: CoachingReportView ← all Coaching/* extensions + sub-views.

import SwiftUI
import AppKit
import ClaudeWatchCore

struct CoachingDerivedData {
    var records: [PromptRecord] = []
    var filteredSessions: [SessionSummary] = []
    var sessions: [SessionSummary] = []
    var projectOptions: [String] = []
    var modelOptions: [String] = []
    var inventory: InventoryAggregate = .zero
    var outlierIds: Set<String> = []
    var agentLoopIds: Set<String> = []
    var stats: ReportStats = ReportGenerator.stats(for: [])
    var riskFindings: [RiskFinding] = []
    var riskSummary: RiskSummary = RiskScorer.summary(for: [])
    var riskBySession: [String: RiskFinding] = [:]
    var riskByPrompt: [String: RiskFinding] = [:]
    var anomalies: [Anomaly] = []
    var sessionIntents: [String: SessionIntent] = [:]
}

struct CoachingReportView: View {
    // Internal (not private) — cross-file extensions in Coaching/ need access.
    @Environment(BookmarkStore.self) var bookmarks
    @Environment(CoachingDataStore.self) var data
    @Environment(SupervisorLockStore.self) var supervisorLock
    @FocusState var searchFocused: Bool
    @State var scope: ScopeKind = .day
    @State var anchor: Date = Date()
    @State var sourceFilter: SourceFilter = .all
    @State var searchQuery: String = ""
    @State var projectFilter: String = ""    // "" = all task/session titles + projects
    @State var modelFilter: String = ""      // "" = all models
    @State var viewMode: ViewMode = .all
    @State var sessionSort: SessionSort = .recent
    @State var selectedRecord: PromptRecord?
    @State var selectedSession: SessionSummary?
    @State var showLockAuditLog: Bool = false
    @State var promptPageSize: Int = 25
    @State var derived = CoachingDerivedData()

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
    var records: [PromptRecord] { derived.records }
    var filteredSessions: [SessionSummary] { derived.filteredSessions }
    var sessions: [SessionSummary] { derived.sessions }

    /// List unique project names cho project filter dropdown.
    var projectOptions: [String] { derived.projectOptions }

    /// List unique model names có data trong scope hiện tại.
    var modelOptions: [String] { derived.modelOptions }

    var inventory: InventoryAggregate { derived.inventory }

    /// Source-aware session key vượt robust cost baseline — view tô cảnh báo.
    var outlierIds: Set<String> { derived.outlierIds }

    /// Session bị spawn quá nhiều subagent → suspect agent loop.
    var agentLoopIds: Set<String> { derived.agentLoopIds }

    /// Chưa từng load lần nào (mount lần đầu, hoặc app vừa mở).
    var hasNeverLoaded: Bool { lastRefreshAt == .distantPast }

    /// Snapshot hiện tại có khớp scope đang chọn không. Đổi ngày/tuần/tháng
    /// không tự scan để giữ app nhẹ; user bấm Đọc log hoặc Export mới đọc.
    var hasCurrentSnapshot: Bool {
        data.isFresh(for: scopeFingerprint)
    }

    /// True khi scope hiện tại empty SAU KHI đã load xong ít nhất 1 lần.
    /// KHÔNG check `isLoading` ở đây — manual refresh vẫn có thể đang chạy
    /// nhưng dữ liệu cũ còn hợp lệ để giữ layout ổn định.
    var isScopeEmpty: Bool {
        !hasNeverLoaded && allSessions.isEmpty && allRecords.isEmpty && lockAuditEvents.isEmpty
    }

    var stats: ReportStats { derived.stats }

    var lockAuditEvents: [SupervisorLockAuditEvent] {
        supervisorLock.events(in: currentScope)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                filterCard
                if isLoading && !hasCurrentSnapshot {
                    coachingLoadingHero
                } else if !hasCurrentSnapshot {
                    coachingSnapshotHero
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
                    lockAuditCard
                    riskCard
                    anomalyCard
                    tokenCostCard
                    if !dailyCostTrend.isEmpty { trendCard }
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
            data.setActive(scope: currentScope, fingerprint: scopeFingerprint)
            rebuildDerivedData()
        }
        .onChange(of: scope) { _, _ in
            resetPages()
            data.setActive(scope: currentScope, fingerprint: scopeFingerprint)
        }
        .onChange(of: anchor) { _, _ in
            resetPages()
            data.setActive(scope: currentScope, fingerprint: scopeFingerprint)
        }
        .onChange(of: sourceFilter) { _, _ in resetPages(); rebuildDerivedData() }
        .onChange(of: searchQuery) { _, _ in resetPages(); rebuildDerivedData() }
        .onChange(of: projectFilter) { _, _ in resetPages(); rebuildDerivedData() }
        .onChange(of: modelFilter) { _, _ in resetPages(); rebuildDerivedData() }
        .onChange(of: viewMode) { _, _ in resetPages(); rebuildDerivedData() }
        .onChange(of: sessionSort) { _, _ in sessionPage = 0; rebuildDerivedData() }
        .onChange(of: data.lastRefreshAt) { _, _ in rebuildDerivedData() }
        .onChange(of: bookmarks.items) { _, _ in rebuildDerivedData() }
        .onChange(of: promptPageSize) { _, _ in promptPage = 0 }
        .sheet(item: $selectedRecord) { record in
            PromptDetailSheet(record: record)
        }
        .sheet(item: $selectedSession) { session in
            SessionDetailSheet(session: session)
        }
        .sheet(isPresented: $showLockAuditLog) {
            LockAuditLogSheet(
                scopeLabel: scopeRangeLabel,
                events: lockAuditEvents,
                findings: supervisorLock.complianceFindings(scope: currentScope, sessions: allSessions)
            )
        }
    }

    func dedupedPromptRecords(_ input: [PromptRecord]) -> [PromptRecord] {
        var lastTimestampByKey: [String: Date] = [:]
        return input.filter { record in
            let key = "\(record.source.rawValue)|\(record.sessionUuid)|\(normalizedPromptText(record.text))"
            defer { lastTimestampByKey[key] = record.timestamp }
            guard let previous = lastTimestampByKey[key] else { return true }
            return abs(record.timestamp.timeIntervalSince(previous)) > 3
        }
    }

    func sortedSessions(_ input: [SessionSummary]) -> [SessionSummary] {
        sortedSessions(input, risks: derived.riskBySession)
    }

    private func sortedSessions(_ input: [SessionSummary],
                                risks: [String: RiskFinding]) -> [SessionSummary] {
        switch sessionSort {
        case .recent:
            return input.sorted(by: recencySort)
        case .risk:
            return input.sorted { a, b in
                let ar = risks[RiskScorer.sessionKey(source: a.source, id: a.id)]
                let br = risks[RiskScorer.sessionKey(source: b.source, id: b.id)]
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

    private func rebuildDerivedData() {
        let bookmarkIds = Set(bookmarks.items.map(\.id))
        let base = viewMode == .bookmarks
            ? allRecords.filter { bookmarkIds.contains($0.id) }
            : allRecords
        let query = searchQuery.lowercased()
        let records = dedupedPromptRecords(base.filter { record in
            guard sourceFilter.matches(record.source) else { return false }
            if !projectFilter.isEmpty && !matchesTaskOrProject(record, projectFilter) {
                return false
            }
            return query.isEmpty || record.text.lowercased().contains(query)
        })
        .sorted { $0.timestamp > $1.timestamp }
        let filteredSessions = allSessions.filter { session in
            guard sourceFilter.matches(session.source) else { return false }
            if !projectFilter.isEmpty && !matchesTaskOrProject(session, projectFilter) {
                return false
            }
            return modelFilter.isEmpty || session.model == modelFilter
        }
        let riskFindings = RiskScorer.evaluate(
            records: records,
            sessions: filteredSessions,
            limit: 50
        )
        let riskBySession = RiskScorer.highestBySession(riskFindings)
        let sessions = sortedSessions(filteredSessions, risks: riskBySession)
        let projectNames = Set(allRecords.map(\.projectDisplay))
            .union(Set(allRecords.map(\.displayTitle)))
            .union(Set(allSessions.map(\.projectDisplay)))
            .union(Set(allSessions.map(\.displayTitle)))
        var recordsBySession: [String: [PromptRecord]] = [:]
        for record in allRecords {
            recordsBySession[record.sessionAuditKey, default: []].append(record)
        }
        var sessionIntents: [String: SessionIntent] = [:]
        for (sessionKey, sessionRecords) in recordsBySession {
            let prompts = sessionRecords
                .sorted { $0.timestamp < $1.timestamp }
                .prefix(3)
                .map(\.text)
            sessionIntents[sessionKey] = SessionIntentClassifier.classify(prompts: prompts)
        }
        derived = CoachingDerivedData(
            records: records,
            filteredSessions: filteredSessions,
            sessions: sessions,
            projectOptions: projectNames.sorted(),
            modelOptions: Set(allSessions.map(\.model)).filter { !$0.isEmpty }.sorted(),
            inventory: SessionInventory.aggregate(sessions),
            outlierIds: CoachingInsights.outlierSessions(sessions),
            agentLoopIds: CoachingInsights.agentLoopSessions(sessions),
            stats: ReportGenerator.stats(for: records),
            riskFindings: riskFindings,
            riskSummary: RiskScorer.summary(for: riskFindings),
            riskBySession: riskBySession,
            riskByPrompt: RiskScorer.highestByPrompt(riskFindings),
            anomalies: AnomalyScorer.detect(in: records, limit: 3),
            sessionIntents: sessionIntents
        )
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

    private func matchesTaskOrProject(_ record: PromptRecord, _ filter: String) -> Bool {
        record.projectDisplay == filter || record.displayTitle == filter || record.sessionTitle == filter
    }

    private func matchesTaskOrProject(_ session: SessionSummary, _ filter: String) -> Bool {
        session.projectDisplay == filter || session.displayTitle == filter || session.sessionTitle == filter
    }
}
