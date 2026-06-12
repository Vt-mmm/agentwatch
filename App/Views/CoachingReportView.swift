// Tab "Coaching" — chấm prompt theo SDD/VSDD/CoDD, xuất daily/weekly report.

import SwiftUI
import AppKit
import ClaudeWatchCore

struct CoachingReportView: View {
    @Environment(BookmarkStore.self) private var bookmarks
    @Environment(CoachingDataStore.self) private var data
    @FocusState private var searchFocused: Bool
    @State private var scope: ScopeKind = .day
    @State private var anchor: Date = Date()
    @State private var sourceFilter: SourceFilter = .all
    @State private var searchQuery: String = ""
    @State private var projectFilter: String = ""    // "" = all projects
    @State private var viewMode: ViewMode = .all
    @State private var selectedRecord: PromptRecord?

    /// Derived data từ store (shared, persist across tab switch).
    private var allRecords: [PromptRecord] { data.allRecords }
    private var allSessions: [SessionSummary] { data.allSessions }
    private var previousAggregate: InventoryAggregate { data.previousAggregate }
    private var previousAvgStars: Double { data.previousAvgStars }
    private var previousPromptCount: Int { data.previousPromptCount }
    private var dailyCostTrend: [DailyCostBucket] { data.dailyCostTrend }
    private var isLoading: Bool { data.isLoading }
    private var lastRefreshAt: Date { data.lastRefreshAt }

    enum ViewMode: String, CaseIterable, Identifiable {
        case all = "Tất cả"
        case bookmarks = "Mẫu hay"
        var id: String { rawValue }
    }

    // Pagination — 15 mỗi trang đủ rộng để xem mà không cuộn quá dài.
    @State private var sessionPage: Int = 0
    @State private var promptPage: Int = 0
    private let pageSize: Int = 15

    enum ScopeKind: String, CaseIterable, Identifiable {
        case day = "Ngày"
        case week = "Tuần"
        var id: String { rawValue }
    }

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "Tất cả"
        case cli = "CLI"
        case desktop = "Desktop"
        var id: String { rawValue }

        func matches(_ source: SessionSource) -> Bool {
            switch self {
            case .all:     return true
            case .cli:     return source == .cli
            case .desktop: return source == .desktop
            }
        }
    }

    /// Records sau khi áp tất cả filter (source + project + search + bookmark mode).
    private var records: [PromptRecord] {
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

    private var sessions: [SessionSummary] {
        allSessions.filter { s in
            guard sourceFilter.matches(s.source) else { return false }
            if !projectFilter.isEmpty && s.projectDisplay != projectFilter { return false }
            return true
        }
    }

    /// List unique project names cho project filter dropdown.
    private var projectOptions: [String] {
        let names = Set(allRecords.map(\.projectDisplay))
            .union(Set(allSessions.map(\.projectDisplay)))
        return names.sorted()
    }

    private var inventory: InventoryAggregate {
        SessionInventory.aggregate(sessions)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                filterCard
                summaryCard
                tokenCostCard
                trendCard
                if !sessions.isEmpty { topSessionsCard }
                if !records.isEmpty { distributionCard }
                if !stats.topMissingSections.isEmpty { gapsCard }
                if !stats.projectBreakdown.isEmpty { projectCard }
                promptListCard
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
            // Chỉ reload nếu data cũ (>5s) hoặc scope đổi từ lần load trước.
            if !data.isFresh(for: scopeFingerprint) {
                data.reload(scope: currentScope, fingerprint: scopeFingerprint)
            }
            data.startAutoRefresh(scope: currentScope, fingerprint: scopeFingerprint)
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
        .onChange(of: viewMode) { _, _ in resetPages() }
        .sheet(item: $selectedRecord) { record in
            PromptDetailSheet(record: record)
        }
    }

    // MARK: - Cards

    private var filterCard: some View {
        VStack(spacing: 10) {
            // Hiển thị rõ range đang được filter — user không bị "nhảy" khi đổi
            // scope/anchor mà không hiểu hệ thống đang đọc data ngày nào.
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .foregroundStyle(Claude.orange)
                Text("Đang xem:")
                    .font(ClaudeFont.label(11))
                    .foregroundStyle(Claude.textMuted)
                Text(scopeRangeLabel)
                    .font(ClaudeFont.mono(13, weight: .semibold))
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
            }

            HStack(spacing: 10) {
                Picker("", selection: $scope) {
                    ForEach(ScopeKind.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                // Prev/next nav: 1 ngày khi scope=day, 7 ngày khi scope=week.
                Button { shiftAnchor(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .help(scope == .day ? "Ngày trước" : "Tuần trước")

                DatePicker("", selection: $anchor, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .fixedSize()

                Button { shiftAnchor(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .help(scope == .day ? "Ngày sau" : "Tuần sau")

                Button("Hôm nay") { anchor = Date() }
                    .buttonStyle(.bordered)

                Spacer(minLength: 8)

                Button { exportMarkdown() } label: {
                    Image(systemName: "doc.text")
                    Text("MD")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("e", modifiers: [.command])

                Button { exportCSV() } label: {
                    Image(systemName: "tablecells")
                    Text("CSV")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button { exportHTML() } label: {
                    Image(systemName: "globe")
                    Text("HTML")
                }
                .buttonStyle(.borderedProminent)
                .tint(Claude.orange)
            }

            HStack(spacing: 10) {
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { m in
                        Text("\(m.rawValue)\(m == .bookmarks ? " (\(bookmarks.items.count))" : "")").tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Picker("", selection: $sourceFilter) {
                    ForEach(SourceFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
                Text(filterCountLabel)
                    .font(ClaudeFont.mono(11))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                searchField
                projectPicker
                Spacer()
            }
        }
        .claudeCard()
    }

    /// Đếm hiển thị bên phải segmented, ngắn gọn — KHÔNG nằm trong segmented
    /// để chip không bị crop khi window hẹp.
    private var filterCountLabel: String {
        let s = sessions.count, p = records.count
        return "\(s) session · \(p) prompt"
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill").foregroundStyle(Claude.orange)
                Text("Coaching · \(currentScope.label)")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(Claude.live).frame(width: 6, height: 6)
                        Text("auto · cập nhật \(TokenFormatter.clockTime(from: isoStringNow))")
                            .font(ClaudeFont.label(10))
                            .foregroundStyle(Claude.textMuted)
                    }
                }
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Refresh ngay")
            }
            statGridWithDelta([
                ("Sessions", "\(inventory.sessionCount)",
                  delta: Double(inventory.sessionCount - previousAggregate.sessionCount)),
                ("Prompts",  "\(stats.totalPrompts)",
                  delta: Double(stats.totalPrompts - previousPromptCount)),
                ("Task ★",   "\(stats.taskPrompts)",
                  delta: 0),
                ("Avg ★",    String(format: "%.1f", stats.avgStars),
                  delta: stats.avgStars - previousAvgStars),
            ])
        }
        .claudeCard()
    }

    private var tokenCostCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Claude.orange)
                Text("Token & cost · \(currentScope.label)")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
                Text(TokenFormatter.usd(inventory.totalCost))
                    .font(ClaudeFont.display(22).monospacedDigit())
                    .foregroundStyle(Claude.orange)
            }
            statGridWithDelta([
                ("Input",      TokenFormatter.compact(inventory.inputTokens),
                  delta: Double(inventory.inputTokens - previousAggregate.inputTokens)),
                ("Output",     TokenFormatter.compact(inventory.outputTokens),
                  delta: Double(inventory.outputTokens - previousAggregate.outputTokens)),
                ("Cache R",    TokenFormatter.compact(inventory.cacheReadTokens),
                  delta: 0),
                ("Cache W",    TokenFormatter.compact(inventory.cacheWriteTokens),
                  delta: 0),
                ("Total tok",  TokenFormatter.compact(inventory.totalTokens),
                  delta: Double(inventory.totalTokens - previousAggregate.totalTokens)),
                ("Tool calls", "\(inventory.totalToolCalls)",
                  delta: Double(inventory.totalToolCalls - previousAggregate.totalToolCalls)),
                ("Follow-up",  "\(stats.followUpPrompts)", delta: 0),
                ("Msg/sess",
                 inventory.sessionCount > 0
                 ? "\(stats.totalPrompts / max(inventory.sessionCount, 1))"
                 : "0", delta: 0),
            ])
        }
        .claudeCard()
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(Claude.orange)
                Text("Cost 7 ngày gần nhất")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
                if dailyCostTrend.contains(where: { $0.cost > 0 }) {
                    Text(TokenFormatter.usd(dailyCostTrend.reduce(0) { $0 + $1.cost }))
                        .font(ClaudeFont.mono(13, weight: .semibold))
                        .foregroundStyle(Claude.orange)
                }
            }
            CostTrendChart(buckets: dailyCostTrend)
                .frame(height: 70)
        }
        .claudeCard()
    }

    /// Adaptive grid với delta optional. Delta != 0 sẽ hiện arrow + giá trị.
    private func statGridWithDelta(_ items: [(String, String, delta: Double)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)],
                  alignment: .leading, spacing: 10) {
            ForEach(items, id: \.0) { item in
                statCellWithDelta(item.0, item.1, delta: item.2)
            }
        }
    }

    /// Layout: label trên (full width, không wrap) — value + delta dưới cùng hàng.
    /// Delta đẩy sang phải, value lineLimit để không xô delta xuống dòng.
    private func statCellWithDelta(_ label: String, _ value: String,
                                   delta: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(ClaudeFont.mono(18, weight: .medium))
                    .foregroundStyle(Claude.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.4), value: value)
                Spacer(minLength: 4)
                if delta != 0 {
                    deltaChip(delta)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func deltaChip(_ delta: Double) -> some View {
        let positive = delta > 0
        let color: Color = positive ? .green : .red
        let arrow = positive ? "arrow.up" : "arrow.down"
        let absVal = abs(delta)
        // Format compact: <1 → 0.x, <1000 → integer, ≥1000 → 1.2k/3.4M.
        let str: String
        if absVal < 1 {
            str = String(format: "%.1f", absVal)
        } else if absVal < 1000 {
            str = "\(Int(absVal))"
        } else {
            str = TokenFormatter.compact(Int(absVal))
        }
        return HStack(spacing: 2) {
            Image(systemName: arrow).font(.system(size: 8, weight: .bold))
            Text(str).font(ClaudeFont.mono(9, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
        .fixedSize()
    }

    private var topSessionsCard: some View {
        let info = Pagination.info(items: sessions, page: sessionPage, pageSize: pageSize)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Sessions theo cost (\(sessions.count))")
                Spacer()
                Paginator(page: info.page, totalPages: info.totalPages) { sessionPage = $0 }
            }
            ForEach(Array(info.slice)) { s in sessionRow(s) }
        }
        .claudeCard()
    }

    private func sessionRow(_ s: SessionSummary) -> some View {
        HStack(spacing: 10) {
            sessionSourcePill(s.source)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.projectDisplay)
                    .font(ClaudeFont.body(12))
                    .fontWeight(.medium)
                    .foregroundStyle(Claude.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sessionTimeRange(s))
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textPrimary.opacity(0.75))
                    .lineLimit(1)
                Text("\(s.model.isEmpty ? "?" : s.model) · \(TokenFormatter.compact(s.totalTokens)) tok · \(s.toolCallCount) tools")
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(TokenFormatter.usd(s.cost))
                .font(ClaudeFont.mono(12, weight: .semibold))
                .foregroundStyle(Claude.orange)
        }
        .padding(.vertical, 3)
    }

    /// Format: nếu cùng 1 ngày → "12/06 10:23 → 14:55", khác ngày → "12/06 10:23 → 13/06 14:55".
    /// Đây là local time (Asia/Saigon nếu user ở VN).
    private func sessionTimeRange(_ s: SessionSummary) -> String {
        let cal = Calendar.current
        let first = s.firstTimestamp ?? s.lastTimestamp ?? Date()
        let last = s.lastTimestamp ?? first
        let sameDay = cal.isDate(first, inSameDayAs: last)
        let dayHm = DateFormatter()
        dayHm.dateFormat = "dd/MM HH:mm"; dayHm.timeZone = .current
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"; hm.timeZone = .current
        if sameDay {
            return "\(dayHm.string(from: first)) → \(hm.string(from: last))"
        }
        return "\(dayHm.string(from: first)) → \(dayHm.string(from: last))"
    }

    private func resetPages() {
        sessionPage = 0
        promptPage = 0
    }

    /// ISO string từ lastRefreshAt — feed vào TokenFormatter.clockTime để ra
    /// time string local.
    private var isoStringNow: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: lastRefreshAt)
    }

    private func sessionSourcePill(_ src: SessionSource) -> some View {
        let isCli = src == .cli
        return Text(isCli ? "CLI" : "Desk")
            .font(ClaudeFont.mono(9))
            .fontWeight(.bold)
            .foregroundStyle(isCli ? Claude.Chip.infoFg : Claude.Chip.warningFg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isCli ? Claude.Chip.infoBg : Claude.Chip.warningBg)
            .clipShape(Capsule())
    }

    private var distributionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Phân bổ chất lượng (task prompts)")
            ForEach((0...5).reversed(), id: \.self) { star in
                let n = stats.starCounts[star] ?? 0
                let pct: Double = stats.taskPrompts > 0
                    ? Double(n) / Double(stats.taskPrompts) : 0
                HStack(spacing: 10) {
                    Text(starString(star))
                        .font(ClaudeFont.mono(13))
                        .foregroundStyle(Claude.textPrimary)
                        .frame(width: 60, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Claude.surfaceAlt)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Claude.orange)
                                .frame(width: max(2, geo.size.width * pct))
                        }
                    }
                    .frame(height: 8)
                    Text("\(n)")
                        .font(ClaudeFont.mono(12))
                        .foregroundStyle(Claude.textMuted)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
        .claudeCard()
    }

    private var gapsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Section hay thiếu nhất")
            ForEach(Array(stats.topMissingSections.enumerated()), id: \.offset) { _, item in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(item.0.label)
                        .font(ClaudeFont.body(13))
                        .fontWeight(.medium)
                        .foregroundStyle(Claude.textPrimary)
                    Spacer()
                    Text("\(item.1) prompt")
                        .font(ClaudeFont.mono(12))
                        .foregroundStyle(Claude.textMuted)
                }
                .padding(.vertical, 4)
            }
        }
        .claudeCard()
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Theo project")
            ForEach(Array(stats.projectBreakdown.prefix(8).enumerated()), id: \.offset) { _, p in
                HStack {
                    Text(p.project)
                        .font(ClaudeFont.body(13))
                        .foregroundStyle(Claude.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(p.count) prompts")
                        .font(ClaudeFont.mono(12))
                        .foregroundStyle(Claude.textMuted)
                    Text(String(format: "%.1f★", p.avgStars))
                        .font(ClaudeFont.mono(12, weight: .medium))
                        .foregroundStyle(Claude.orange)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
        .claudeCard()
    }

    private var promptListCard: some View {
        let info = Pagination.info(items: records, page: promptPage, pageSize: pageSize)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Prompts (\(records.count))")
                Spacer()
                Paginator(page: info.page, totalPages: info.totalPages) { promptPage = $0 }
            }
            if records.isEmpty {
                Text("Không có prompt nào trong khoảng này.")
                    .font(ClaudeFont.body(13))
                    .foregroundStyle(Claude.textMuted)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(Array(info.slice)) { r in
                    Button {
                        selectedRecord = r
                    } label: {
                        PromptRow(record: r)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .claudeCard()
    }

    // MARK: - Components

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
            Text(value)
                .font(ClaudeFont.display(22).monospacedDigit())
                .foregroundStyle(Claude.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func starString(_ s: Int) -> String {
        String(repeating: "★", count: s) + String(repeating: "☆", count: 5 - s)
    }

    // MARK: - Data

    /// Label đầy đủ cho range đang filter — show ở top filterCard.
    /// Day: "Thứ 5, 12/06/2026" — Week: "Tuần 09/06/2026 → 15/06/2026"
    private var scopeRangeLabel: String {
        switch scope {
        case .day:
            let f = DateFormatter()
            f.dateFormat = "EEEE, dd/MM/yyyy"
            f.locale = Locale(identifier: "vi_VN")
            return f.string(from: anchor).capitalized
        case .week:
            let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"
            let cal = PromptHistory.currentMondayBased
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)
            let start = cal.date(from: comps) ?? anchor
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
            return "Tuần \(f.string(from: start)) → \(f.string(from: end))"
        }
    }

    /// Dịch anchor: ngày → ±1 day, tuần → ±7 day.
    private func shiftAnchor(by direction: Int) {
        let cal = Calendar.current
        let days = scope == .day ? direction : direction * 7
        anchor = cal.date(byAdding: .day, value: days, to: anchor) ?? anchor
    }

    private var currentScope: ReportScope {
        switch scope {
        case .day:
            return .day(anchor)
        case .week:
            let cal = PromptHistory.currentMondayBased
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)
            let start = cal.date(from: comps) ?? anchor
            return .week(start: start)
        }
    }

    private var stats: ReportStats {
        ReportGenerator.stats(for: records)
    }

    /// Search box theme Claude — không xài system .roundedBorder vì lệch tông cream.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Claude.textMuted)
            TextField("Search prompt text…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(ClaudeFont.body(12))
                .focused($searchFocused)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Claude.textMuted)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Claude.surfaceAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searchFocused ? Claude.orange : Claude.border,
                              lineWidth: searchFocused ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 320)
    }

    /// Project picker: Menu button thay vì Picker để có style match theme.
    private var projectPicker: some View {
        Menu {
            Button("Mọi project") { projectFilter = "" }
            Divider()
            ForEach(projectOptions, id: \.self) { p in
                Button(p) { projectFilter = p }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(Claude.textMuted)
                Text(projectFilter.isEmpty ? "Mọi project" : truncateMid(projectFilter, max: 28))
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Claude.textMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Claude.surfaceAlt)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Claude.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func truncateMid(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let half = (max - 1) / 2
        let prefix = s.prefix(half)
        let suffix = s.suffix(half)
        return "\(prefix)…\(suffix)"
    }

    /// Fingerprint scope+anchor để store biết khi nào cần re-fetch.
    private var scopeFingerprint: String {
        "\(scope.rawValue)|\(Int(anchor.timeIntervalSinceReferenceDate))"
    }

    private func reload() {
        data.reload(scope: currentScope, fingerprint: scopeFingerprint)
    }

    // MARK: - Export

    private func exportMarkdown() {
        let md = ReportGenerator.markdown(scope: currentScope, records: records)
        save(content: md, defaultName: "coaching-\(slugify(currentScope.label)).md",
             types: ["md", "markdown"])
    }

    private func exportHTML() {
        let html = ReportGenerator.html(scope: currentScope, records: records)
        save(content: html, defaultName: "coaching-\(slugify(currentScope.label)).html",
             types: ["html", "htm"])
    }

    private func exportCSV() {
        let csv = ReportGenerator.csv(records: records)
        save(content: csv, defaultName: "coaching-\(slugify(currentScope.label)).csv",
             types: ["csv"])
    }

    private func save(content: String, defaultName: String, types: [String]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) }
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func slugify(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }
}

// MARK: - Row

private struct PromptRow: View {
    let record: PromptRecord
    @Environment(BookmarkStore.self) private var bookmarks

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(timeLabel.string(from: record.timestamp))
                        .font(ClaudeFont.mono(11))
                        .foregroundStyle(Claude.textMuted)
                    sourceBadge
                    Text(record.projectDisplay)
                        .font(ClaudeFont.body(11))
                        .foregroundStyle(Claude.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(record.text.prefix(140))
                    .font(ClaudeFont.body(13))
                    .foregroundStyle(Claude.textPrimary)
                    .lineLimit(2)
                if record.score.isTaskPrompt && !record.score.sectionsMissing.isEmpty {
                    Text("Thiếu: " + record.score.sectionsMissing.prefix(4).map(\.label).joined(separator: ", "))
                        .font(ClaudeFont.body(11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                bookmarks.toggle(record)
            } label: {
                Image(systemName: bookmarks.contains(record.id) ? "star.fill" : "star")
                    .foregroundStyle(bookmarks.contains(record.id) ? .yellow : Claude.textMuted)
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help(bookmarks.contains(record.id) ? "Bỏ bookmark" : "Đánh dấu mẫu hay")
        }
        .padding(10)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var sourceBadge: some View {
        let isCli = record.source == .cli
        Text(isCli ? "⌨︎ CLI" : "🖥 Desktop")
            .font(ClaudeFont.mono(10))
            .fontWeight(.semibold)
            .foregroundStyle(isCli ? Claude.Chip.infoFg : Claude.Chip.warningFg)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(isCli ? Claude.Chip.infoBg : Claude.Chip.warningBg)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var badge: some View {
        if record.score.isTaskPrompt {
            ZStack {
                Circle().fill(Claude.orangeSoft).frame(width: 40, height: 40)
                Text("\(record.score.stars)★")
                    .font(ClaudeFont.mono(13, weight: .semibold))
                    .foregroundStyle(Claude.orange)
            }
        } else {
            ZStack {
                Circle().fill(Claude.surface).frame(width: 40, height: 40)
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Claude.textMuted)
            }
        }
    }

    private var timeLabel: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = .current
        return f
    }
}

// MARK: - Detail sheet

private struct PromptDetailSheet: View {
    let record: PromptRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(Claude.orange)
                Text("Prompt detail")
                    .font(ClaudeFont.heading())
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.escape)
            }

            HStack(spacing: 8) {
                if record.score.isTaskPrompt {
                    chip("\(record.score.stars)★", Claude.Chip.warningBg, Claude.Chip.warningFg)
                } else {
                    chip("Follow-up", Claude.Chip.infoBg, Claude.Chip.infoFg)
                }
                chip("\(record.score.charCount) chars", Claude.Chip.infoBg, Claude.Chip.infoFg)
                Spacer()
                Text(record.projectDisplay)
                    .font(ClaudeFont.mono(11))
                    .foregroundStyle(Claude.textMuted)
            }

            if record.score.isTaskPrompt {
                checklistSection
            }

            SectionLabel(text: "Nội dung prompt")
            ScrollView {
                Text(record.text)
                    .font(ClaudeFont.mono(12))
                    .foregroundStyle(Claude.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Claude.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .frame(width: 660, height: 680)
        .background(Claude.background)
    }

    /// Checklist 11 section. Mục PRESENT chỉ show 1 dòng; mục MISSING expand
    /// thành coaching tip card với template + ví dụ Anthropic-grounded.
    private var checklistSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Checklist Spec + coaching tips")
                ForEach(SpecSection.allCases, id: \.self) { sec in
                    if record.score.sectionsPresent.contains(sec) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(sec.label)
                                .font(ClaudeFont.body(12))
                                .foregroundStyle(Claude.textPrimary)
                        }
                    } else {
                        TipExpander(tip: CoachingTips.tip(for: sec))
                    }
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private func chip(_ text: String, _ bg: Color, _ fg: Color) -> some View {
        Text(text)
            .font(ClaudeFont.body(11))
            .fontWeight(.semibold)
            .foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg).clipShape(Capsule())
    }
}

// MARK: - Coaching tip expander

private struct TipExpander: View {
    let tip: CoachingTip
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.orange)
                    Text("Thiếu: \(tip.section.label)")
                        .font(ClaudeFont.body(12))
                        .fontWeight(.medium)
                        .foregroundStyle(Claude.textPrimary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Claude.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tip.reason)
                        .font(ClaudeFont.body(11))
                        .foregroundStyle(Claude.textMuted)

                    sectionHeader("Template (copy + sửa)")
                    codeBlock(tip.template)
                        .overlay(alignment: .topTrailing) { copyButton(tip.template) }

                    sectionHeader("Ví dụ pass")
                    codeBlock(tip.example).background(Claude.Chip.successBg.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                        Link(destination: URL(string: tip.sourceUrl)!) {
                            Text("Anthropic source")
                                .font(ClaudeFont.label(10))
                        }
                    }
                    .foregroundStyle(Claude.orange)
                }
                .padding(10)
                .background(Claude.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(ClaudeFont.label(9))
            .tracking(0.6)
            .foregroundStyle(Claude.textMuted)
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(ClaudeFont.mono(11))
            .foregroundStyle(Claude.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Claude.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
                .padding(6)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Claude.orange)
        .help("Copy template")
    }
}
