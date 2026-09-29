import SwiftUI
import AgentWatchCore

enum StudioSection: String, CaseIterable, Identifiable {
    case tools = "Công cụ", usage = "Usage", diagnostics = "Chẩn đoán"
    var id: String { rawValue }
}

struct StudioConnectionView: View {
    @Environment(StudioConnectionStore.self) private var studio
    @State private var sync: StudioSyncStore
    @State private var section: StudioSection
    private let logReader: any StudioLocalLogReading
    @State private var origin = ""
    @State private var key = ""
    @State private var editingKey = false
    @State private var disconnectReview: DisconnectReview?
    @State private var disconnecting = false
    @State private var disconnectMessage: String?

    init(sync: StudioSyncStore = .shared, section: StudioSection = .tools, logReader: any StudioLocalLogReading = StudioLocalLogReader()) {
        self.logReader = logReader
        _sync = State(initialValue: sync)
        _section = State(initialValue: section)
    }

    private struct DisconnectReview: Identifiable {
        let profile: StudioProfile
        let inventory: StudioProcessSnapshot
        var id: String { profile.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Studio").font(ClaudeFont.heading(26))
                    Spacer()
                    Text("Kết nối công cụ của bạn").font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
                }
                connectionCard
                if studio.profile != nil && !editingKey {
                    Picker("Nội dung Studio", selection: $section) {
                        ForEach(StudioSection.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                }
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if disconnecting { ProgressView("Đang ngắt kết nối và kiểm tra phiên CLI…") }
                    if let disconnectMessage { Text(disconnectMessage).font(ClaudeFont.body()).textSelection(.enabled) }
                    if studio.profile == nil || editingKey {
                        form
                    } else {
                        switch section {
                        case .tools:
                            StudioConfigurationView(sync: sync)
                            if let snapshot = studio.snapshot { models(snapshot) }
                        case .usage:
                            StudioDashboardView()
                        case .diagnostics:
                            if let snapshot = studio.snapshot { account(snapshot) }
                            DisclosureGroup("Mở CLI trong profile riêng") {
                                StudioLauncherView().padding(.top, 12)
                            }.font(ClaudeFont.body()).claudeCard()
                            StudioLocalLogsView(reader: logReader)
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            origin = studio.profile?.origin.value ?? ""
            if studio.state == .saved { await studio.refresh(allowInteraction: false) }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 22)).foregroundStyle(Claude.orange)
                    .frame(width: 40, height: 40).background(Claude.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    if let snapshot = studio.snapshot {
                        Text(snapshot.identity.user.displayName).font(ClaudeFont.heading(17)).textSelection(.enabled)
                        Text(snapshot.identity.user.teamName ?? "Chưa có team")
                            .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
                    } else {
                        Text("Tài khoản công ty").font(ClaudeFont.heading(17))
                        Text("Dùng địa chỉ Studio và key được cấp.").font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if studio.profile != nil {
                    Button {
                        Task {
                            await studio.refresh()
                            if studio.state == .connected && sync.enabled { await sync.synchronize() }
                        }
                    } label: {
                        if studio.error == .keychainApprovalRequired { Text("Cho phép Keychain").font(ClaudeFont.label(11)) }
                        else { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
                    }.help("Kiểm tra kết nối, usage và cấu hình đã chọn").accessibilityLabel(studio.error == .keychainApprovalRequired ? "Cho phép Keychain" : "Kiểm tra lại kết nối")
                        .disabled(studio.state == .checking)
                    Menu {
                        Button(editingKey ? "Hủy thay key" : "Thay key nhân viên") {
                            key = ""; origin = studio.profile?.origin.value ?? ""; editingKey.toggle()
                        }
                        Divider()
                        Button("Ngắt kết nối", role: .destructive) {
                            guard let profile = studio.profile else { return }
                            key = ""; editingKey = false; disconnectMessage = nil
                            disconnectReview = DisconnectReview(profile: profile, inventory: StudioProcessRegistry().snapshot(connection: profile))
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Quản lý kết nối Studio")
                }
            }
            HStack(alignment: .top, spacing: 6) {
                if studio.state == .checking { ProgressView().controlSize(.mini) }
                else { Image(systemName: studio.state == .connected ? "checkmark.circle.fill" : "circle.dotted") }
                Text(status).fixedSize(horizontal: false, vertical: true)
            }.font(ClaudeFont.body(12)).foregroundStyle(studio.state == .connected ? Claude.live : Claude.textMuted)
            if let profile = studio.profile {
                Text(profile.origin.value).font(ClaudeFont.mono(11)).foregroundStyle(Claude.textMuted)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            if let error = studio.error {
                Text(error.localizedDescription).font(ClaudeFont.body(12)).foregroundStyle(Claude.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.claudeCard()
    }
    private func disconnect(_ review: DisconnectReview, choice: StudioDisconnectChoice) {
        disconnectReview = nil; disconnecting = true
        Task { @MainActor in
            defer { disconnecting = false }
            do {
                sync.reset()
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(editingKey ? "Thay key nhân viên" : "1. Kết nối tài khoản").font(ClaudeFont.heading(17))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Địa chỉ API Studio").font(ClaudeFont.label())
                    TextField("http://127.0.0.1:17922", text: $origin)
                        .textFieldStyle(.roundedBorder).disabled(studio.profile != nil)
                        .accessibilityLabel("Địa chỉ API Studio")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Key nhân viên").font(ClaudeFont.label())
                    SecureField("Dán key do quản trị viên cấp", text: $key)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Key nhân viên Studio")
                }
                Label("Key được lưu trong Keychain trên máy.", systemImage: "lock.shield")
                    .font(ClaudeFont.body(11)).foregroundStyle(Claude.textMuted)
            }.claudeCard()
            StudioConfigurationView(showApply: false, sync: sync)
            Button {
                let submittedOrigin = origin, submittedKey = key
                key = ""
                Task {
                    await studio.connect(origin: submittedOrigin, key: submittedKey)
                    if studio.state == .connected {
                        editingKey = false; section = .tools; sync.enabled = true
                        StudioBackgroundService.shared.start()
                        await sync.synchronize(force: true)
                    }
                }
            } label: {
                HStack {
                    if studio.state == .checking || sync.busy { ProgressView().controlSize(.small) }
                    Text(studio.state == .checking ? "Đang xác minh…" : "Kết nối và áp dụng")
                }.frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).tint(Claude.orange)
            .disabled(origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key.isEmpty || studio.state == .checking || sync.busy || sync.selected.isEmpty)
        }
    }
    private func account(_ snapshot: StudioConnectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Tài khoản nhân viên")
            Text(snapshot.identity.user.displayName).font(ClaudeFont.heading(20))
            LabeledContent("Vai trò", value: role(snapshot.identity.user.role))
            if let team = snapshot.identity.user.teamName { LabeledContent("Team", value: team) }
            LabeledContent("ID tài khoản", value: snapshot.identity.user.id.uuidString.lowercased())
                .font(ClaudeFont.mono(11)).textSelection(.enabled)
            LabeledContent("Xác minh lần cuối", value: snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("API", value: snapshot.capabilities.apiVersion)
                .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
        }.claudeCard()
    }
    private func role(_ value: String) -> String {
        switch value { case "owner": "Chủ hệ thống"; case "admin": "Quản trị viên"; case "viewer": "Người xem"; default: "Thành viên" }
    }
    private func models(_ snapshot: StudioConnectionSnapshot) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                switch snapshot.models {
                case .available(let models):
                    if models.isEmpty { Text("Key này chưa được cấp model khả dụng.").foregroundStyle(Claude.textMuted) }
                    ForEach(models) { model in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName.isEmpty ? model.id : model.displayName).font(ClaudeFont.body())
                                Text(model.id).font(ClaudeFont.mono(11)).foregroundStyle(Claude.textMuted).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(model.ownedBy == "claude" ? "Claude" : model.ownedBy == "codex" ? "Codex" : model.ownedBy)
                                .font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
                        }
                    }
                case .unavailable(let error):
                    Text(error.localizedDescription).foregroundStyle(Claude.orange)
                }
            }.padding(.top, 12)
        } label: {
            HStack {
                Text("Model được cấp").font(ClaudeFont.heading(15))
                Spacer()
                if case .available(let models) = snapshot.models {
                    Text("\(models.count) model").font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
                }
            }
        }.font(ClaudeFont.body(12)).claudeCard()
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
