// Modal sheet show ALL detail của 1 session: cost breakdown theo loại token,
// events timeline (user msg / assistant / tool calls), tool usage stats.
// Lazy parse JSONL khi sheet appear → không block list.

import SwiftUI
import AppKit
import ClaudeWatchCore

struct SessionDetailSheet: View {
    let session: SessionSummary
    @Environment(\.dismiss) private var dismiss

    @State private var stats: SessionStats?
    @State private var loading: Bool = true
    @State private var page: Int = 0
    @State private var expandedTools: Set<String> = []
    @State private var toolFilter: String = ""   // "" = all, else specific tool/kind
    private let pageSize: Int = 30

    /// Events sau khi reverse + áp filter: mới nhất ở đầu.
    private var events: [SessionEvent] {
        guard let s = stats else { return [] }
        let reversed = Array(s.events.reversed())
        guard !toolFilter.isEmpty else { return reversed }
        return reversed.filter { e in
            switch toolFilter {
            case "_user":      return e.kind == .userMessage
            case "_assistant": return e.kind == .assistantText
            case "_thinking":  return e.kind == .assistantThinking
            case "_tool":      return e.kind == .toolUse
            default:           return e.toolName == toolFilter
            }
        }
    }

    /// Distinct tool names trong session, sorted theo count giảm dần.
    private var availableToolNames: [String] {
        guard let s = stats else { return [] }
        var counts: [String: Int] = [:]
        for e in s.events where e.kind == .toolUse {
            if let n = e.toolName { counts[n, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    private var toolBreakdown: [(name: String, count: Int)] {
        guard let s = stats else { return [] }
        var map: [String: Int] = [:]
        for e in s.events where e.kind == .toolUse {
            let n = e.toolName ?? "?"
            map[n, default: 0] += 1
        }
        return map.sorted { $0.value > $1.value }.map { (name: $0.key, count: $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Claude.border)
            if loading {
                loadingView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        overviewCard
                        tokenBreakdownCard
                        if !toolBreakdown.isEmpty { toolsCard }
                        if !events.isEmpty { eventsCard }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 760, height: 720)
        .background(Claude.background)
        .task { await loadDetail() }
    }

    // MARK: - Async load

    private func loadDetail() async {
        guard let url = session.fileURL else {
            loading = false; return
        }
        let s = await Task.detached(priority: .userInitiated) {
            JsonlParser.parseSession(at: url)
        }.value
        await MainActor.run {
            self.stats = s
            self.loading = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(Claude.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectDisplay)
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.id)
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Đóng") { dismiss() }
                .keyboardShortcut(.escape)
        }
        .padding(16)
        .background(Claude.surface)
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Đang đọc session JSONL…")
                .font(ClaudeFont.body(12))
                .foregroundStyle(Claude.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Overview card

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    sourcePill
                    Text(session.model.isEmpty ? "Unknown model" : session.model)
                        .font(ClaudeFont.mono(12, weight: .semibold))
                        .foregroundStyle(Claude.textPrimary)
                    Text(timeRangeFull)
                        .font(ClaudeFont.mono(11))
                        .foregroundStyle(Claude.textMuted)
                    Text("Kéo dài: \(durationLabel)")
                        .font(ClaudeFont.mono(11))
                        .foregroundStyle(Claude.textMuted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(TokenFormatter.usd(session.cost))
                        .font(ClaudeFont.display(28).monospacedDigit())
                        .foregroundStyle(Claude.orange)
                    Text("\(session.promptCount) prompt · \(session.toolCallCount) tool")
                        .font(ClaudeFont.mono(11))
                        .foregroundStyle(Claude.textMuted)
                }
            }
        }
        .claudeCard()
    }

    private var sourcePill: some View {
        let isCli = session.source == .cli
        return Text(isCli ? "⌨︎ CLI" : "🖥 Desktop")
            .font(ClaudeFont.mono(10))
            .fontWeight(.bold)
            .foregroundStyle(isCli ? Claude.Chip.infoFg : Claude.Chip.warningFg)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(isCli ? Claude.Chip.infoBg : Claude.Chip.warningBg)
            .clipShape(Capsule())
    }

    private var timeRangeFull: String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm:ss"; f.timeZone = .current
        let first = session.firstTimestamp.map(f.string(from:)) ?? "?"
        let last = session.lastTimestamp.map(f.string(from:)) ?? "?"
        return "\(first) → \(last)"
    }

    private var durationLabel: String {
        guard let f = session.firstTimestamp, let l = session.lastTimestamp else { return "?" }
        let secs = Int(l.timeIntervalSince(f))
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    // MARK: - Token breakdown

    private var tokenBreakdownCard: some View {
        let price = Pricing.price(for: session.modelFamily)
        let inCost  = Double(session.inputTokens)      / 1_000_000 * price.input
        let outCost = Double(session.outputTokens)     / 1_000_000 * price.output
        let crCost  = Double(session.cacheReadTokens)  / 1_000_000 * price.cacheRead
        let cwCost  = Double(session.cacheWriteTokens) / 1_000_000 * price.cacheWrite
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Breakdown chi phí token")
            tokenRow("Input",       session.inputTokens,      inCost,  Color.blue)
            tokenRow("Output",      session.outputTokens,     outCost, Color.green)
            tokenRow("Cache read",  session.cacheReadTokens,  crCost,  Color.purple)
            tokenRow("Cache write", session.cacheWriteTokens, cwCost,  Color.orange)
            Divider().background(Claude.border)
            HStack {
                Text("Tổng")
                    .font(ClaudeFont.mono(12, weight: .semibold))
                Spacer()
                Text(TokenFormatter.compact(session.totalTokens))
                    .font(ClaudeFont.mono(12, weight: .semibold))
                    .foregroundStyle(Claude.textPrimary)
                Text(TokenFormatter.usd(session.cost))
                    .font(ClaudeFont.mono(12, weight: .semibold))
                    .foregroundStyle(Claude.orange)
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .claudeCard()
    }

    private func tokenRow(_ label: String, _ tokens: Int, _ cost: Double, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(ClaudeFont.body(12))
                .foregroundStyle(Claude.textPrimary)
                .frame(width: 110, alignment: .leading)
            Spacer()
            Text(TokenFormatter.compact(tokens))
                .font(ClaudeFont.mono(12))
                .foregroundStyle(Claude.textMuted)
            Text(TokenFormatter.usd(cost))
                .font(ClaudeFont.mono(12))
                .foregroundStyle(Claude.orange)
                .frame(width: 80, alignment: .trailing)
        }
    }

    // MARK: - Tools

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Tools used (\(toolBreakdown.count))")
            Text("Click tên tool để xem chi tiết từng lần invoke.")
                .font(ClaudeFont.body(11))
                .foregroundStyle(Claude.textMuted)
            ForEach(Array(toolBreakdown.enumerated()), id: \.offset) { _, t in
                toolGroup(name: t.name, count: t.count)
            }
        }
        .claudeCard()
    }

    /// Disclosure 1 tool: header row clickable → expand list invocations.
    @ViewBuilder
    private func toolGroup(name: String, count: Int) -> some View {
        let expanded = expandedTools.contains(name)
        Button {
            if expanded { expandedTools.remove(name) } else { expandedTools.insert(name) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Claude.textMuted)
                    .frame(width: 12)
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11))
                    .foregroundStyle(Claude.orange)
                Text(name)
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(ClaudeFont.mono(12, weight: .semibold))
                    .foregroundStyle(Claude.textPrimary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if expanded { toolInvocations(name: name) }
    }

    /// List các SessionEvent có toolName == name (capped 30 để không quá dài).
    @ViewBuilder
    private func toolInvocations(name: String) -> some View {
        let calls = (stats?.events ?? []).filter { $0.kind == .toolUse && $0.toolName == name }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(calls.prefix(30).enumerated()), id: \.offset) { idx, e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("#\(idx + 1)")
                            .font(ClaudeFont.mono(9, weight: .bold))
                            .foregroundStyle(Claude.textMuted)
                            .frame(width: 24, alignment: .leading)
                        Text(shortTime(e.timestamp))
                            .font(ClaudeFont.mono(9))
                            .foregroundStyle(Claude.textMuted)
                        if !e.completed {
                            Text("⏳").font(.system(size: 9))
                        }
                    }
                    Text(e.summary)
                        .font(ClaudeFont.mono(11))
                        .foregroundStyle(Claude.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                    if let r = e.resultPreview, !r.isEmpty {
                        Text(r)
                            .font(ClaudeFont.mono(10))
                            .foregroundStyle(Claude.textMuted)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                    attachmentView(for: e)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Claude.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if calls.count > 30 {
                Text("…và \(calls.count - 30) lần invoke nữa (events window cap = 500)")
                    .font(ClaudeFont.body(10))
                    .foregroundStyle(Claude.textMuted)
                    .padding(.leading, 32)
            }
        }
        .padding(.leading, 24)
        .padding(.bottom, 4)
    }

    // MARK: - Events

    private var eventsCard: some View {
        let info = Pagination.info(items: events, page: page, pageSize: pageSize)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Timeline events (\(events.count))")
                Spacer()
                Paginator(page: info.page, totalPages: info.totalPages) { page = $0 }
            }
            eventFilterPicker
            ForEach(Array(info.slice)) { e in
                eventRow(e)
            }
        }
        .claudeCard()
    }

    /// Dropdown filter — All / kind / specific tool. Reset page về 0 khi đổi.
    private var eventFilterPicker: some View {
        Menu {
            Button("Tất cả events") { toolFilter = ""; page = 0 }
            Divider()
            Section("By kind") {
                Button("User messages")      { toolFilter = "_user"; page = 0 }
                Button("Assistant replies")  { toolFilter = "_assistant"; page = 0 }
                Button("Thinking")           { toolFilter = "_thinking"; page = 0 }
                Button("All tool calls")     { toolFilter = "_tool"; page = 0 }
            }
            if !availableToolNames.isEmpty {
                Divider()
                Section("By tool name") {
                    ForEach(availableToolNames, id: \.self) { name in
                        Button(name) { toolFilter = name; page = 0 }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Claude.textMuted)
                Text(filterDisplayLabel)
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Claude.textMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Claude.surfaceAlt)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Claude.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var filterDisplayLabel: String {
        switch toolFilter {
        case "":           return "Filter: Tất cả"
        case "_user":      return "Filter: User"
        case "_assistant": return "Filter: Reply"
        case "_thinking":  return "Filter: Thinking"
        case "_tool":      return "Filter: Tools"
        default:           return "Filter: \(toolFilter)"
        }
    }

    private func eventRow(_ e: SessionEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            eventIcon(e.kind)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(eventKindLabel(e.kind))
                        .font(ClaudeFont.mono(10, weight: .bold))
                        .foregroundStyle(eventKindColor(e.kind))
                    if let tool = e.toolName {
                        Text(tool)
                            .font(ClaudeFont.mono(10))
                            .foregroundStyle(Claude.textPrimary)
                    }
                    Spacer()
                    Text(shortTime(e.timestamp))
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                }
                Text(e.summary)
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textPrimary)
                    .lineLimit(3)
                if let r = e.resultPreview, !r.isEmpty {
                    Text(r)
                        .font(ClaudeFont.mono(11))
                        .foregroundStyle(Claude.textMuted)
                        .lineLimit(2)
                }
            }
        }
        .padding(8)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func eventIcon(_ k: SessionEventKind) -> some View {
        let sys: String
        switch k {
        case .userMessage:       sys = "person.fill"
        case .assistantText:     sys = "text.bubble.fill"
        case .assistantThinking: sys = "brain"
        case .toolUse:           sys = "wrench.fill"
        }
        return Image(systemName: sys)
            .font(.system(size: 11))
            .foregroundStyle(eventKindColor(k))
    }

    private func eventKindLabel(_ k: SessionEventKind) -> String {
        switch k {
        case .userMessage:       return "USER"
        case .assistantText:     return "REPLY"
        case .assistantThinking: return "THINK"
        case .toolUse:           return "TOOL"
        }
    }

    private func eventKindColor(_ k: SessionEventKind) -> Color {
        switch k {
        case .userMessage:       return .blue
        case .assistantText:     return .green
        case .assistantThinking: return .purple
        case .toolUse:           return Claude.orange
        }
    }

    /// Render image attachment nếu tool_result có chứa screenshot/image.
    /// + nút Save As… để export ra file .png.
    @ViewBuilder
    private func attachmentView(for e: SessionEvent) -> some View {
        if let b64 = e.imageBase64,
           let data = Data(base64Encoded: b64),
           let img = NSImage(data: data) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Claude.orange)
                    Text("Attached image (\(e.imageMimeType ?? "image"))")
                        .font(ClaudeFont.label(9))
                        .foregroundStyle(Claude.textMuted)
                    Spacer()
                    Button("Save…") { saveImage(data: data, mime: e.imageMimeType) }
                        .buttonStyle(.borderless)
                        .font(ClaudeFont.body(10))
                        .foregroundStyle(Claude.orange)
                }
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.top, 4)
        } else if let url = e.imageURL, let urlObj = URL(string: url) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 10))
                    .foregroundStyle(Claude.orange)
                Link("Image URL: \(url)", destination: urlObj)
                    .font(ClaudeFont.mono(10))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.top, 4)
        }
    }

    private func saveImage(data: Data, mime: String?) {
        let ext: String = {
            switch mime {
            case "image/jpeg": return "jpg"
            case "image/gif":  return "gif"
            case "image/webp": return "webp"
            default:           return "png"
            }
        }()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "screenshot-\(Int(Date().timeIntervalSince1970)).\(ext)"
        panel.allowedContentTypes = [.init(filenameExtension: ext)].compactMap { $0 }
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    /// Parse ISO timestamp → "HH:mm:ss" local. Best-effort; fallback empty.
    private func shortTime(_ iso: String) -> String {
        let p = ISO8601DateFormatter()
        p.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = p.date(from: iso) ?? {
            let p2 = ISO8601DateFormatter()
            p2.formatOptions = [.withInternetDateTime]
            return p2.date(from: iso)
        }()
        guard let date = d else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"; f.timeZone = .current
        return f.string(from: date)
    }
}
