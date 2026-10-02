import SwiftUI
import AppKit
import AgentWatchCore

enum StudioSection: String, CaseIterable, Identifiable {
    case tools = "Công cụ", usage = "Usage", diagnostics = "Chẩn đoán"
    var id: String { rawValue }
}

/// Employee client for Studio: one status line, then tools, usage or diagnostics.
/// Administrative actions intentionally live only in the Studio web console.
struct StudioConnectionView: View {
    @Environment(StudioConnectionStore.self) private var studio
    @State private var sync: StudioSyncStore
    @State private var section: StudioSection
    @State private var logs: StudioLocalLogStore
    @State private var origin = ""
    @State private var key = ""
    @State private var editingKey = false
    @State private var showFolders = false
    @State private var disconnectReview: DisconnectReview?
    @State private var disconnecting = false
    @State private var notice: String?

    init(sync: StudioSyncStore = .shared, section: StudioSection = .tools, logReader: any StudioLocalLogReading = StudioLocalLogReader()) {
        _sync = State(initialValue: sync)
        _section = State(initialValue: section)
        _logs = State(initialValue: StudioLocalLogStore(reader: logReader))
    }

    private struct DisconnectReview: Identifiable {
        let profile: StudioProfile
        let inventory: StudioProcessSnapshot
        var id: String { profile.id }
    }

    private var connected: Bool { studio.profile != nil && !editingKey }
    private var failedTools: Int { sync.results.filter { !$0.success && sync.selected.contains($0.target) }.count }
    private var employeeStatus: StudioEmployeeStatus {
        StudioEmployeeStatus.evaluate(hasProfile: studio.profile != nil, state: studio.state, error: studio.error, key: sync.keyInfo,
                                      quota: StudioQuotaSummary.from(studio.dashboard?.quota), failedTools: failedTools)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if connected {
                    statusStrip
                    Picker("Nội dung Studio", selection: $section) {
                        ForEach(StudioSection.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if disconnecting { ProgressView("Đang ngắt kết nối…").controlSize(.small) }
                    if let notice {
                        Text(notice).font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted).textSelection(.enabled)
                    }
                    if !connected {
                        StudioConnectForm(origin: $origin, key: $key, editingKey: editingKey, sync: sync) { submitted in
                            editingKey = false; section = .tools; notice = nil
                            _ = submitted
                        }
                    } else {
                        switch section {
                        case .tools: StudioToolsTab(sync: sync, openUsage: { section = .usage })
                        case .usage: StudioDashboardView()
                        case .diagnostics: StudioDiagnosticsTab(sync: sync, logs: logs, status: employeeStatus)
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            origin = studio.profile?.origin.value ?? ""
            if studio.state == .saved { await studio.refresh(allowInteraction: false) }
        }
        .onChange(of: studio.profile?.id) { _, _ in logs.clear(); sync.activateProfile() }
        .onDisappear { key = ""; editingKey = false }
        .disabled(disconnecting)
        .sheet(isPresented: $showFolders) { StudioFoldersSheet(sync: sync) }
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

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Studio").font(ClaudeFont.heading(24))
            Spacer()
            if !studio.availableProfiles.isEmpty {
                Menu {
                    ForEach(studio.availableProfiles, id: \.id) { profile in
                        Button {
                            Task {
                                key = ""; editingKey = false
                                await studio.selectProfile(profile.id)
                                sync.activateProfile()
                                if studio.state == .connected && sync.enabled { await sync.synchronize() }
                            }
                        } label: {
                            if profile.id == studio.profile?.id { Label(profileTitle(profile), systemImage: "checkmark") }
                            else { Text(profileTitle(profile)) }
                        }
                    }
                } label: { Text(studio.profile.map(profileTitle) ?? "Chọn key đã lưu").lineLimit(1) }
                .fixedSize().disabled(studio.state == .checking || sync.busy)
                .accessibilityLabel("Key Studio đang dùng")
            }
            if studio.profile != nil {
                Button {
                    Task {
                        await studio.refresh()
                        if studio.state == .connected && sync.enabled { await sync.synchronize() }
                    }
                } label: {
                    if studio.state == .checking { ProgressView().controlSize(.small).frame(width: 22, height: 22) }
                    else { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
                }
                .help("Kiểm tra kết nối, usage và cấu hình công cụ").accessibilityLabel("Kiểm tra lại kết nối")
                .disabled(studio.state == .checking)
                Menu {
                    Button(editingKey ? "Hủy thêm key" : "Thêm key…") { key = ""; origin = studio.profile?.origin.value ?? ""; editingKey.toggle() }
                    Button("Thư mục & khôi phục cấu hình…") { showFolders = true }
                    Button("Sao chép thông tin hỗ trợ") { copySupport() }
                    Divider()
                    Button("Ngắt kết nối…", role: .destructive) {
                        guard let profile = studio.profile else { return }
                        key = ""; editingKey = false; notice = nil
                        disconnectReview = DisconnectReview(profile: profile, inventory: StudioProcessRegistry().snapshot(connection: profile))
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 22, height: 22) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Quản lý kết nối Studio")
            }
        }
    }

    private func profileTitle(_ profile: StudioProfile) -> String {
        let kind = profile.credentialMode == .managed ? "Piagent công ty" : "CLI trực tiếp"
        return kind + " · " + (profile.keyID.map { String($0.uuidString.lowercased().prefix(8)) } ?? "key hiện có")
    }

    /// Identity, key and the single combined state. Everything else is one click away.
    private var statusStrip: some View {
        let status = employeeStatus
        return HStack(alignment: .center, spacing: 12) {
            Text(String((studio.snapshot?.identity.user.displayName ?? "S").prefix(1)).uppercased())
                .font(ClaudeFont.heading(14)).foregroundStyle(Claude.orange)
                .frame(width: 34, height: 34).background(Claude.orange.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(studio.snapshot?.identity.user.displayName ?? "Tài khoản công ty").font(ClaudeFont.heading(15)).lineLimit(1)
                    if let team = studio.snapshot?.identity.user.teamName {
                        Text("· " + team).font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted).lineLimit(1)
                    }
                }
                Text(keyLine).font(ClaudeFont.mono(10.5)).foregroundStyle(Claude.textMuted).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                StudioPill(title: status.title, tone: StudioTone(status.tone))
                if let detail = status.detail, !(status.action == .showTools && section == .tools) {
                    Text(detail).font(ClaudeFont.body(11)).foregroundStyle(Claude.textMuted).multilineTextAlignment(.trailing).lineLimit(2)
                }
            }
            if status.action == .allowKeychain {
                Button("Cho phép Keychain") { Task { await studio.refresh() } }.controlSize(.small)
            } else if status.action == .replaceKey {
                Button("Thay key") { key = ""; editingKey = true }.controlSize(.small)
            } else if status.action == .showTools, section != .tools {
                Button("Xem") { section = .tools }.controlSize(.small)
            }
        }.studioCard(padding: 12)
    }

    private var keyLine: String {
        var parts: [String] = []
        if let info = sync.keyInfo {
            parts.append([info.label, info.prefix + "…"].compactMap { $0 }.joined(separator: " · "))
            parts.append("hết hạn " + StudioFormat.day(info.expiresAt))
        }
        if parts.isEmpty, let profile = studio.profile { parts.append(StudioFormat.host(profile.origin.value)) }
        return parts.joined(separator: " · ")
    }

    private func copySupport() {
        let bundle = Bundle.main.infoDictionary, os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = ["Agent Watch \(bundle?["CFBundleShortVersionString"] as? String ?? "?") (\(bundle?["CFBundleVersion"] as? String ?? "?")) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"]
        if let profile = studio.profile { lines.append("Studio: " + profile.origin.value) }
        if let user = studio.snapshot?.identity.user {
            lines.append("Thành viên: \(user.id.uuidString.lowercased()) · Team: \(user.teamName ?? "—")")
        }
        if let info = sync.keyInfo { lines.append("Key: \(info.prefix) · hết hạn \(info.expiresAt.formatted(.iso8601))") }
        let tools = sync.lastReport?.tools.filter { $0.status != "not_selected" }.map { "\($0.target) \($0.status)\($0.cli_version.map { " " + $0 } ?? "")\($0.error_code.map { " [" + $0 + "]" } ?? "")" } ?? []
        if !tools.isEmpty { lines.append("Công cụ: " + tools.joined(separator: ", ")) }
        lines.append("Trạng thái: " + employeeStatus.title)
        lines.append("Thời điểm: " + Date().formatted(.iso8601))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        notice = "Đã sao chép thông tin hỗ trợ (không gồm key)."
    }

    private func disconnect(_ review: DisconnectReview, choice: StudioDisconnectChoice) {
        disconnectReview = nil; disconnecting = true
        Task { @MainActor in
            defer { disconnecting = false }
            do {
                sync.reset(); logs.clear()
                let result = try await StudioDisconnect.perform(store: studio, expected: review.profile, choice: choice)
                notice = result.message
            } catch StudioProcessError.busy {
                notice = "CLI đang khởi động. Chưa ngắt kết nối; thử lại khi CLI mở xong."
            } catch {
                notice = (error as? StudioError)?.localizedDescription ?? "Chưa ngắt kết nối: không đọc được danh sách phiên CLI an toàn."
            }
        }
    }
}

/// First connection or key replacement: two fields, tool choice, one button.
struct StudioConnectForm: View {
    @Environment(StudioConnectionStore.self) private var studio
    @Binding var origin: String
    @Binding var key: String
    let editingKey: Bool
    let sync: StudioSyncStore
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text(editingKey ? "Thêm key Studio" : "Kết nối Studio").font(ClaudeFont.heading(17))
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { originField; keyField }
                    VStack(alignment: .leading, spacing: 12) { originField; keyField }
                }
                Label("Key lưu trong Keychain của máy.", systemImage: "lock.shield")
                    .font(ClaudeFont.body(11)).foregroundStyle(Claude.textMuted)
                if let error = studio.error {
                    Text(error.localizedDescription).font(ClaudeFont.body(12)).foregroundStyle(Claude.orange).fixedSize(horizontal: false, vertical: true)
                }
            }.studioCard()
            StudioConfigurationView(showApply: false, sync: sync)
            Button {
                let submittedOrigin = origin, submittedKey = key
                let submittedTargets = sync.selected, submittedDirectories = sync.directories
                key = ""
                Task {
                    await studio.connect(origin: submittedOrigin, key: submittedKey)
                    if studio.state == .connected {
                        sync.activateProfile()
                        sync.selected = studio.profile?.credentialMode == .managed ? submittedTargets.intersection([.pi, .piagent]) : submittedTargets
                        sync.directories = submittedDirectories
                        sync.enabled = true
                        StudioBackgroundService.shared.start()
                        done(true)
                        await sync.synchronize(force: true)
                    }
                }
            } label: {
                HStack {
                    if studio.state == .checking || sync.busy { ProgressView().controlSize(.small) }
                    Text(studio.state == .checking ? "Đang xác minh…" : editingKey ? "Lưu key và áp dụng" : "Kết nối và áp dụng")
                }.frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).tint(Claude.orange)
            .disabled(origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key.isEmpty || studio.state == .checking || sync.busy || sync.selected.isEmpty)
        }
    }
    private var originField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Địa chỉ Studio").font(ClaudeFont.label())
            TextField("https://studio.congty.vn hoặc mã kết nối", text: $origin)
                .textFieldStyle(.roundedBorder).disabled(studio.profile != nil).accessibilityLabel("Địa chỉ API Studio")
                .help("Dán mã kết nối (địa chỉ#key) để điền cả hai ô.")
                .onChange(of: origin) { _, value in fill(value) }
        }
    }
    /// A pasted connection code fills both fields; the origin is only
    /// replaced when no profile is saved yet (key replacement keeps it).
    private func fill(_ value: String) {
        guard let code = StudioConnectionCode.split(value) else { return }
        if studio.profile == nil { origin = code.origin }
        key = code.key
    }
    private var keyField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Key được cấp").font(ClaudeFont.label())
            SecureField("Dán key do quản trị viên gửi", text: $key)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Key nhân viên Studio")
                .onChange(of: key) { _, value in fill(value) }
        }
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Ngắt kết nối Studio").font(ClaudeFont.heading(20))
            Text(origin).font(ClaudeFont.mono(12)).foregroundStyle(Claude.textMuted).textSelection(.enabled)
            HStack(spacing: 8) {
                StudioPill(title: "\(running) CLI đang chạy", tone: running > 0 ? .warning : .neutral)
                if unverified > 0 { StudioPill(title: "\(unverified) chưa xác minh", tone: .warning) }
            }
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in Text(session).font(ClaudeFont.mono(11)).lineLimit(1) }
                }
            }
            if incomplete {
                Text("Chưa đọc đủ danh sách phiên. Kiểm tra thêm các cửa sổ Terminal.").font(ClaudeFont.body(12)).foregroundStyle(Claude.orange)
            }
            Text("Key trên máy sẽ bị xóa. Log, project và cấu hình cá nhân được giữ.").font(ClaudeFont.body(12))
            HStack {
                Button("Hủy", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Ngắt, giữ CLI") { choose(.keepCLI) }
                    .help("Phiên đang chạy vẫn giữ key trong bộ nhớ. Muốn chặn ngay, nhờ quản trị viên thu hồi key.")
                Button("Ngắt và đóng CLI", role: .destructive) { choose(.closeCLI) }
                    .help("Chỉ đóng các CLI do launcher ghi nhận. CLI mở bằng cách khác cần kiểm tra trong Terminal.")
            }
        }.padding(22).frame(width: 520)
    }
}

/// Folder overrides and restore live in a sheet: rarely used, never in the main flow.
struct StudioFoldersSheet: View {
    let sync: StudioSyncStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Thư mục & khôi phục").font(ClaudeFont.heading(18))
            Text("Bỏ chọn công cụ chỉ dừng đồng bộ. Khôi phục trả lại cấu hình trước khi Agent Watch thay đổi.")
                .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            ForEach(StudioSyncTarget.allCases) { target in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.title).font(ClaudeFont.label(12))
                        Text(sync.directory(target).path).font(ClaudeFont.mono(10.5)).foregroundStyle(Claude.textMuted)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Đổi…") { choose(target) }.controlSize(.small)
                    Button("Khôi phục") { sync.restore(target) }.controlSize(.small)
                }
                if target != StudioSyncTarget.allCases.last { Divider() }
            }
            Text(sync.status).font(ClaudeFont.body(11)).foregroundStyle(Claude.textMuted)
            HStack { Spacer(); Button("Xong") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 560)
    }
    private func choose(_ target: StudioSyncTarget) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = sync.directory(target)
        if panel.runModal() == .OK, let url = panel.url { sync.directories[target.rawValue] = url.path }
    }
}
