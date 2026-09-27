import SwiftUI
import AgentWatchCore

struct StudioConnectionView: View {
    @Environment(StudioConnectionStore.self) private var studio
    @State private var origin = ""
    @State private var key = ""
    @State private var editingKey = false
    @State private var disconnectReview: DisconnectReview?
    @State private var disconnecting = false
    @State private var disconnectMessage: String?

    private struct DisconnectReview: Identifiable {
        let profile: StudioProfile
        let inventory: StudioProcessSnapshot
        var id: String { profile.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Studio của bạn").font(ClaudeFont.display())
                        Text("Tài khoản và quyền sử dụng do Studio quản lý.")
                            .font(ClaudeFont.body()).foregroundStyle(Claude.textMuted)
                    }
                    Spacer()
                    Label("Nguồn: Studio", systemImage: "server.rack")
                        .font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
                }
                connectionCard
                if disconnecting { ProgressView("Đang ngắt kết nối và kiểm tra phiên CLI…") }
                if let disconnectMessage { Text(disconnectMessage).font(ClaudeFont.body()).textSelection(.enabled) }
                if studio.profile == nil || editingKey { form }
                if let snapshot = studio.snapshot {
                    DisclosureGroup("Tài khoản và model được cấp") {
                        VStack(spacing: 12) { account(snapshot); models(snapshot) }.padding(.top, 10)
                    }.font(ClaudeFont.body())
                }
                if studio.profile != nil { StudioLauncherView(); StudioDashboardView(); StudioLocalLogsView() }
                Text("Sessions, Tasks và báo cáo local vẫn dùng dữ liệu riêng trên máy. Kết nối Studio không thay key Supervisor hoặc tài khoản CLI cá nhân.")
                    .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .task {
            origin = studio.profile?.origin.value ?? ""
            if studio.state == .saved { await studio.refresh() }
        }
        .onDisappear { key = ""; editingKey = false }
        .disabled(disconnecting)
        .sheet(item: $disconnectReview) { review in
            StudioDisconnectSheet(origin: review.profile.origin.value,
                                  running: review.inventory.entries.filter { $0.state == .running }.count,
                                  unverified: review.inventory.entries.filter { $0.state == .unverified }.count,
                                  incomplete: review.inventory.incomplete,
                                  sessions: review.inventory.entries.filter { $0.state != .finished }.prefix(8).map { "\($0.process.provider.rawValue) · \($0.process.model)" },
                                  cancel: { disconnectReview = nil },
                                  choose: { choice in disconnect(review, choice: choice) })
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(status, systemImage: studio.state == .connected ? "checkmark.circle.fill" : "network")
                    .font(ClaudeFont.heading()).foregroundStyle(studio.state == .connected ? Claude.live : Claude.textPrimary)
                if studio.state == .checking { ProgressView().controlSize(.small) }
                Spacer()
                if studio.profile != nil {
                    Button("Kiểm tra lại") { Task { await studio.refresh() } }.disabled(studio.state == .checking)
                    Button("Ngắt kết nối", role: .destructive) {
                        guard let profile = studio.profile else { return }
                        key = ""; editingKey = false; disconnectMessage = nil
                        disconnectReview = DisconnectReview(profile: profile, inventory: StudioProcessRegistry().snapshot(connection: profile))
                    }
                }
            }
            if let profile = studio.profile {
                Text(profile.origin.value).font(ClaudeFont.mono(12)).textSelection(.enabled)
                Button(editingKey ? "Hủy thay key" : "Thay key nhân viên") {
                    key = ""; origin = profile.origin.value; editingKey.toggle()
                }.buttonStyle(.link)
            }
            if let error = studio.error {
                Text(error.localizedDescription).font(ClaudeFont.body()).foregroundStyle(Claude.orange)
            }
            if let snapshot = studio.snapshot {
                Text(snapshot.identity.user.displayName).font(ClaudeFont.heading())
                Text("Xác minh lần cuối: \(snapshot.observedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
            }
        }.claudeCard()
    }
    private func disconnect(_ review: DisconnectReview, choice: StudioDisconnectChoice) {
        disconnectReview = nil; disconnecting = true
        Task { @MainActor in
            defer { disconnecting = false }
            do {
                let result = try await StudioDisconnect.perform(store: studio, expected: review.profile, choice: choice)
                disconnectMessage = result.message
            } catch StudioProcessError.busy {
                disconnectMessage = "CLI đang khởi động. Chưa ngắt kết nối; thử lại khi CLI mở xong."
            } catch {
                disconnectMessage = (error as? StudioError)?.localizedDescription ?? "Chưa ngắt kết nối: không đọc được danh sách phiên CLI an toàn."
            }
        }
    }
    private var status: String {
        switch studio.state {
        case .disconnected: "Chưa kết nối Studio"
        case .saved: "Đã lưu kết nối · chưa xác minh lại"
        case .checking: "Đang xác minh với Studio…"
        case .connected: "Đã xác minh tài khoản"
        case .stale: "Chưa cập nhật · đang hiển thị dữ liệu cũ"
        case .failed: "Chưa thể xác minh kết nối"
        }
    }
    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kết nối bằng key nhân viên").font(ClaudeFont.heading())
            TextField("API origin · https://studio.example.com", text: $origin)
                .textFieldStyle(.roundedBorder).disabled(studio.profile != nil)
                .accessibilityLabel("Địa chỉ API Studio")
            SecureField("Key do quản trị viên Studio cấp", text: $key)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Key nhân viên Studio")
            Text("Key được lưu trong Keychain của máy sau khi xác minh tài khoản. Chỉ nhập địa chỉ gốc, không kèm đường dẫn.")
                .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            Button("Kiểm tra và kết nối") {
                let submittedOrigin = origin, submittedKey = key
                key = ""
                Task {
                    await studio.connect(origin: submittedOrigin, key: submittedKey)
                    if studio.state == .connected { editingKey = false }
                }
            }
            .buttonStyle(.borderedProminent).tint(Claude.orange)
            .disabled(origin.isEmpty || key.isEmpty || studio.state == .checking)
        }.claudeCard()
    }
    private func account(_ snapshot: StudioConnectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Tài khoản nhân viên")
            Text(snapshot.identity.user.displayName).font(ClaudeFont.heading(20))
            LabeledContent("Vai trò", value: role(snapshot.identity.user.role))
            LabeledContent("ID tài khoản", value: snapshot.identity.user.id.uuidString.lowercased())
                .font(ClaudeFont.mono(11)).textSelection(.enabled)
            LabeledContent("API", value: snapshot.capabilities.apiVersion)
                .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
        }.claudeCard()
    }
    private func role(_ value: String) -> String {
        switch value { case "owner": "Chủ hệ thống"; case "admin": "Quản trị viên"; case "viewer": "Người xem"; default: "Thành viên" }
    }
    private func models(_ snapshot: StudioConnectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Model được Studio cho phép")
            switch snapshot.models {
            case .available(let models):
                if models.isEmpty {
                    Text("Chưa có model khả dụng cho key này.").font(ClaudeFont.body())
                } else {
                    ForEach(models) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName.isEmpty ? model.id : model.displayName).font(ClaudeFont.body())
                                Text(model.id).font(ClaudeFont.mono(11)).foregroundStyle(Claude.textMuted)
                            }
                            Spacer()
                            Text(model.ownedBy == "claude" ? "Claude" : "Codex").font(ClaudeFont.label())
                        }
                    }
                }
                Text("Quyền và hạn mức được Studio kiểm tra lại cho mỗi lượt gọi.")
                    .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            case .unavailable(let error):
                Text("Tài khoản đã xác minh; danh sách model chưa sẵn sàng.").font(ClaudeFont.body())
                Text(error.localizedDescription).font(ClaudeFont.body(12)).foregroundStyle(Claude.orange)
            }
        }.claudeCard()
    }
}

struct StudioDisconnectSheet: View {
    let origin: String
    let running, unverified: Int
    let incomplete: Bool
    let sessions: [String]
    let cancel: () -> Void
    let choose: (StudioDisconnectChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ngắt kết nối Studio").font(ClaudeFont.heading(22))
            Text(origin).font(ClaudeFont.mono(12)).textSelection(.enabled)
            Text("CLI công ty đang chạy: \(running) · chưa xác minh: \(unverified)").font(ClaudeFont.body())
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in Text(session).font(ClaudeFont.mono(11)).lineLimit(2) }
                }
            }
            if incomplete {
                Text("Chưa đọc được đầy đủ danh sách phiên. Hãy kiểm tra thêm các cửa sổ Terminal.")
                    .font(ClaudeFont.body()).foregroundStyle(Claude.orange)
            }
            Text("Key lưu trên Mac sẽ được xóa. Log công ty, file dự án và cấu hình cá nhân được giữ lại.")
                .font(ClaudeFont.body())
            Text("Giữ CLI: phiên đang chạy vẫn có key trong bộ nhớ. Muốn thu hồi quyền ngay, hãy thu hồi key trên Studio.")
                .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            Text("Đóng CLI: chỉ yêu cầu các CLI chính được launcher ghi nhận kết thúc. CLI mở bằng bản cũ, công cụ con và phiên chưa xác minh cần được kiểm tra trong Terminal. Danh sách được kiểm tra lại khi xác nhận.")
                .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            HStack {
                Button("Hủy", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Ngắt kết nối, giữ CLI") { choose(.keepCLI) }
                Button("Ngắt kết nối và đóng CLI", role: .destructive) { choose(.closeCLI) }
            }
        }.padding(24).frame(width: 580)
    }
}
