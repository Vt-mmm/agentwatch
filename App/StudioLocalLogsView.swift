import SwiftUI
import AgentWatchCore

struct StudioLocalLogsView: View {
    @Environment(StudioConnectionStore.self) private var studio
    @State private var logs: StudioLocalLogStore
    init(reader: any StudioLocalLogReading = StudioLocalLogReader()) {
        _logs = State(initialValue: StudioLocalLogStore(reader: reader))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Nguồn: log trên máy")
                    Text("Phiên CLI công ty · tháng này").font(ClaudeFont.heading())
                }
                Spacer()
                Button("Đọc lại log") { Task { await refresh() } }.disabled(logs.loading || studio.profile == nil)
                if logs.loading { ProgressView().controlSize(.small) }
            }
            Text("Các phiên CLI của tài khoản Studio đang chọn, lưu trên máy này. Token local chưa đối soát với Studio và không được cộng vào usage/quota phía trên.")
                .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            if let snapshot = logs.snapshot, snapshot.connection == studio.profile {
                ForEach(snapshot.registrations, id: \.provider) { registration in
                    HStack {
                        Text(registration.provider == .claude ? "Claude Code" : "Codex CLI").font(ClaudeFont.body(12))
                        Spacer()
                        Text(registration.issues.isEmpty ? (registration.profile == nil ? "Chưa thiết lập" : "Sẵn sàng đọc log") : "Cần kiểm tra cấu hình")
                            .font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
                    }
                }
                if snapshot.sessions.isEmpty {
                    Text(snapshot.partial ? "Chưa đọc đủ log để xác nhận danh sách phiên." : "Chưa tìm thấy phiên có dữ liệu trong tháng này.")
                        .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
                } else {
                    Text("\(snapshot.sessions.count) phiên · hiển thị tối đa 20 phiên gần nhất").font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
                    ForEach(Array(snapshot.sessions.prefix(20))) { session in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(session.provider == .claude ? "Claude Code" : "Codex CLI").font(ClaudeFont.body(12))
                                Spacer()
                                Text(session.knownTokens.map { $0.formatted(.number.locale(Locale(identifier: "vi_VN"))) + " token local" } ?? "Token chưa rõ")
                                    .font(ClaudeFont.mono(12))
                            }
                            Text(session.summary.projectDisplay).font(ClaudeFont.body(12)).lineLimit(2)
                            Text(session.sessionID).font(ClaudeFont.mono(10)).textSelection(.enabled)
                            Text("\(session.summary.model.isEmpty ? "Model chưa rõ" : session.summary.model) · \(session.partial ? "Dữ liệu chưa đủ" : "Theo log") · Chưa đối soát")
                                .font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
                        }.padding(.vertical, 5)
                        Divider()
                    }
                }
                ForEach(snapshot.issues, id: \.self) { issue in Text(issue.label).font(ClaudeFont.body(12)).foregroundStyle(Claude.orange) }
                Text("Đọc lúc \(snapshot.observedAt.formatted(date: .abbreviated, time: .standard)). Thời gian theo múi giờ của máy. Không dùng chi phí ước tính local để sửa số liệu Studio.")
                    .font(ClaudeFont.body(11)).foregroundStyle(Claude.textMuted)
            }
        }.claudeCard()
        .task(id: studio.profile?.id) { logs.clear(); await refresh() }
        .onDisappear { logs.clear() }
    }
    @MainActor private func refresh() async {
        guard let connection = studio.profile, let range = try? StudioReportingRange(now: Date(), timezone: .current) else { logs.clear(); return }
        await logs.refresh(connection: connection, range: range.month..<range.until)
        if studio.profile != connection { logs.clear() }
    }
}
