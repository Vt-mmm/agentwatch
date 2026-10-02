import SwiftUI
import AgentWatchCore

/// Diagnostics: connection facts, what this Mac shares with Studio, and an
/// on-demand comparison of local CLI logs. Nothing here runs automatically.
struct StudioDiagnosticsTab: View {
    @Environment(StudioConnectionStore.self) private var studio
    let sync: StudioSyncStore
    let logs: StudioLocalLogStore
    let status: StudioEmployeeStatus

    var body: some View {
        StudioColumns(trailingWidth: 320) {
            connection
            StudioLocalLogsView(logs: logs)
        } trailing: {
            shared
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Kết nối")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if let user = studio.snapshot?.identity.user {
                    row("Vai trò", role(user.role))
                    row("Team", user.teamName ?? "Chưa có team")
                }
                if let info = sync.keyInfo {
                    row("Key", [info.label, info.prefix].compactMap { $0 }.joined(separator: " · "))
                    row("Hết hạn", "\(StudioFormat.day(info.expiresAt)) · còn \(max(0, info.daysLeft())) ngày")
                }
                if let profile = studio.profile { row("Máy chủ", profile.origin.value) }
                if let at = studio.snapshot?.observedAt { row("Xác minh", StudioFormat.time(at)) }
                row("Trạng thái", status.title)
            }
            if let error = studio.error {
                Text(error.localizedDescription).font(ClaudeFont.body(11.5)).foregroundStyle(Claude.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.studioCard(padding: 12)
    }
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(ClaudeFont.label(11)).foregroundStyle(Claude.textMuted)
            Text(value).font(ClaudeFont.body(12)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }
    private func role(_ value: String) -> String {
        switch value { case "owner": "Chủ workspace"; case "admin": "Quản trị viên"; case "viewer": "Chỉ xem"; default: "Thành viên" }
    }

    /// Exactly the last report sent: codes and versions, never paths or prompts.
    private var shared: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Chia sẻ với Studio")
                Spacer()
                Image(systemName: "questionmark.circle").foregroundStyle(Claude.textMuted)
                    .help("Sau mỗi lần đồng bộ, Agent Watch gửi phiên bản app/CLI và kết quả đồng bộ từng công cụ để quản trị viên hỗ trợ. Không gửi prompt, đường dẫn, tên máy hay usage trên máy.")
            }
            switch sync.reportState {
            case .unsupported:
                Text("Studio này chưa nhận trạng thái máy.").font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            case .failed where sync.lastReport == nil:
                Text("Chưa gửi được; thử lại ở lần đồng bộ sau.").font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            default:
                if let report = sync.lastReport {
                    Text("Agent Watch \(report.app.version) · macOS \(report.os.version ?? "—")").font(ClaudeFont.body(12))
                    ForEach(report.tools.filter { $0.status != "not_selected" }, id: \.target) { tool in
                        HStack {
                            Text(StudioSyncTarget(rawValue: tool.target)?.title ?? tool.target).font(ClaudeFont.body(11.5))
                            if let v = tool.cli_version { Text(v).font(ClaudeFont.mono(10.5)).foregroundStyle(Claude.textMuted) }
                            Spacer()
                            Text(tool.status == "failed" ? StudioSyncReason.label(tool.error_code) : tool.status == "synced" ? "Đã đồng bộ" : "Chờ áp dụng")
                                .font(ClaudeFont.body(11)).foregroundStyle(tool.status == "failed" ? StudioTone.danger.inline : Claude.textMuted)
                                .help(tool.error_code.map { "Mã gửi Studio: " + $0 } ?? "")
                        }
                    }
                    if let at = sync.lastReportAt {
                        Text("Gửi lúc \(StudioFormat.time(at))").font(ClaudeFont.body(10.5)).foregroundStyle(Claude.textMuted)
                    }
                } else {
                    Text("Sẽ gửi sau lần đồng bộ kế tiếp.").font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
                }
            }
        }.studioCard(padding: 12)
    }
}

/// Local CLI logs compared with Studio totals, only when asked. Reading logs
/// scans files on this Mac, so it never runs on tab open or refresh.
struct StudioLocalLogsView: View {
    @Environment(StudioConnectionStore.self) private var studio
    let logs: StudioLocalLogStore
    @State private var expanded: Bool
    init(logs: StudioLocalLogStore, expanded: Bool = false) { self.logs = logs; _expanded = State(initialValue: expanded) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(logs.snapshot == nil ? "Đọc log tháng này" : "Đọc lại") { Task { await refresh() } }
                        .controlSize(.small).disabled(logs.loading || logs.comparing || studio.profile == nil)
                    if logs.loading || logs.comparing { ProgressView().controlSize(.small) }
                    Spacer()
                    if let snapshot = logs.snapshot { Text("Đọc lúc \(StudioFormat.time(snapshot.observedAt))").font(ClaudeFont.body(10.5)).foregroundStyle(Claude.textMuted) }
                }
                if let snapshot = logs.snapshot, snapshot.connection == studio.profile {
                    if snapshot.sessions.isEmpty {
                        Text(snapshot.partial ? "Chưa đọc đủ log để xác nhận." : "Không có phiên CLI công ty trong tháng này.")
                            .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
                    } else {
                        Text("\(snapshot.sessions.count) phiên · hiện 10 phiên gần nhất").font(ClaudeFont.label(10)).foregroundStyle(Claude.textMuted)
                        ForEach(Array(snapshot.sessions.prefix(10))) { session in
                            HStack(spacing: 8) {
                                Text(session.provider == .claude ? "Claude" : "Codex").font(ClaudeFont.label(10.5)).frame(width: 44, alignment: .leading)
                                Text(session.summary.projectDisplay).font(ClaudeFont.body(11.5)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(session.knownTokens.map { StudioFormat.tokens(Int64($0)) } ?? "—").font(ClaudeFont.mono(11)).monospacedDigit()
                                if let comparison = logs.comparisons[session.id] {
                                    Image(systemName: comparison.status == .matched ? "checkmark.circle" : "questionmark.circle")
                                        .foregroundStyle(comparison.status == .matched ? Claude.live : Claude.textMuted).font(.system(size: 11))
                                        .help(comparison.reason.label + (comparison.serverTokens.map { " · Studio: " + $0.formatted + " token" } ?? ""))
                                }
                            }.help(session.sessionID)
                        }
                    }
                    ForEach(snapshot.issues, id: \.self) { issue in Text(issue.label).font(ClaudeFont.body(11)).foregroundStyle(Claude.orange) }
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                SectionLabel(text: "Đối soát log CLI trên máy")
                Image(systemName: "questionmark.circle").foregroundStyle(Claude.textMuted)
                    .help("So sánh phiên CLI công ty lưu trên máy với số liệu Studio. Không cộng token local vào hạn mức.")
            }
        }
        .studioCard(padding: 12)
    }

    @MainActor private func refresh() async {
        guard let connection = studio.profile, let range = try? StudioReportingRange(now: Date(), timezone: .current) else { logs.clear(); return }
        await logs.refresh(connection: connection, range: range.month..<range.until)
        if studio.profile != connection { logs.clear() }
        else if studio.state == .connected { await logs.compare(using: studio) }
    }
}
