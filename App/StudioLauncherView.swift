import AppKit
import SwiftUI
import AgentWatchCore

struct StudioLauncherView: View {
    @Environment(StudioConnectionStore.self) private var studio
    @State private var modelID = ""
    @State private var project: URL?
    @State private var binary: URL?
    @State private var resume = ""
    @State private var busy = false
    @State private var message = ""
    @State private var failed = false

    private var models: [StudioModel] {
        guard case .available(let values) = studio.snapshot?.models else { return [] }
        return values.filter { StudioCLIProvider(rawValue: $0.ownedBy)?.nativeProtocol == $0.nativeProtocol }
    }
    private var selected: StudioModel? { models.first(where: { $0.id == modelID }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "CLI công ty")
            Text("Mở project bằng tài khoản Studio").font(ClaudeFont.heading())
            Text("Chọn model và thư mục làm việc. CLI dùng profile riêng; anh đăng nhập Studio một lần bằng key đã lưu trong Keychain.")
                .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            if models.isEmpty {
                Text("Chưa có model CLI khả dụng. Kiểm tra lại kết nối và quyền được cấp.").font(ClaudeFont.body())
            } else {
                Picker("Model", selection: $modelID) {
                    Text("Chọn model…").tag("")
                    ForEach(models) { model in Text("\(model.ownedBy == "claude" ? "Claude" : "Codex") · \(model.displayName.isEmpty ? model.id : model.displayName)").tag(model.id) }
                }
                HStack {
                    Button("Chọn thư mục project") { chooseProject() }
                    Text(project?.path ?? "Chưa chọn thư mục").lineLimit(2).textSelection(.enabled)
                        .font(ClaudeFont.mono(11)).foregroundStyle(Claude.textMuted)
                }
                DisclosureGroup("Phiên bản CLI và mở lại phiên") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Đã kiểm chứng: Claude Code 2.1.181 · Codex CLI 0.155.1.").font(ClaudeFont.body(12))
                        HStack {
                            Button("Chọn file CLI…") { chooseBinary() }
                            if binary != nil { Button("Tự tìm") { binary = nil; message = "" } }
                        }
                        Text(binary?.path ?? "Tự tìm CLI độc lập đã cài trên máy.")
                            .font(ClaudeFont.mono(11)).foregroundStyle(Claude.textMuted).textSelection(.enabled)
                        TextField("ID phiên cần mở lại (không bắt buộc)", text: $resume).textFieldStyle(.roundedBorder)
                    }.padding(.top, 8)
                }.font(ClaudeFont.body(12))
                HStack {
                    Button("Kiểm tra CLI") { Task { await prepare(openTerminal: false) } }
                    Button("Mở CLI trong Terminal") { Task { await prepare(openTerminal: true) } }
                        .buttonStyle(.borderedProminent).tint(Claude.orange)
                    if busy { ProgressView().controlSize(.small) }
                }
                .disabled(busy || studio.state != .connected || selected == nil || project == nil)
            }
            if !message.isEmpty { Text(message).font(ClaudeFont.body(12)).foregroundStyle(failed ? Claude.orange : Claude.textMuted) }
            Text("Kiểm tra CLI không gửi yêu cầu AI. Phiên Terminal dùng key hiện tại và vẫn chạy khi anh đóng app.")
                .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
        }
        .claudeCard()
        .onChange(of: modelID) { _, _ in binary = nil; resume = ""; message = "" }
        .onChange(of: studio.profile?.id) { _, _ in modelID = ""; project = nil; binary = nil; resume = ""; message = "" }
        .onChange(of: models) { _, values in if !values.contains(where: { $0.id == modelID }) { modelID = "" } }
    }
    private func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Chọn project"
        if panel.runModal() == .OK { project = panel.url; message = "" }
    }
    private func chooseBinary() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.prompt = "Chọn CLI"
        if panel.runModal() == .OK { binary = panel.url; message = "" }
    }
    @MainActor private func prepare(openTerminal: Bool) async {
        guard !busy, let selected, let project, let connection = studio.profile,
              let provider = StudioCLIProvider(rawValue: selected.ownedBy) else { return }
        let selectedBinary = binary, resumeText = resume.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; failed = false; message = "Đang kiểm tra tài khoản và CLI…"
        defer { busy = false }
        do {
            let resumeID = resumeText.isEmpty ? nil : UUID(uuidString: resumeText)
            guard resumeText.isEmpty || resumeID != nil else { throw StudioCLIError.invalidArguments }
            await studio.refresh()
            guard studio.profile == connection, studio.state == .connected,
                  models.contains(selected) else { throw studio.error ?? StudioError.identityChanged }
            let executable = try StudioCLIExecutable.resolve(provider, explicit: selectedBinary)
            let profile = try StudioCLIProfiles.prepare(connection: connection, provider: provider)
            let plan = try StudioCLILaunchPlan(executable: executable, profile: profile, project: project, model: selected, resumeID: resumeID)
            try await StudioCLIPreflight.verify(plan)
            guard studio.profile == connection, studio.state == .connected, models.contains(selected), modelID == selected.id,
                  self.project == project, binary == selectedBinary, resume.trimmingCharacters(in: .whitespacesAndNewlines) == resumeText else { throw StudioError.identityChanged }
            if openTerminal {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agentwatch")
                let command = try StudioTerminalCommand.create(plan: plan, helper: helper)
                try await StudioTerminalOpener.open(command)
                message = "Đã mở Terminal. CLI sẽ xác minh lại đúng tài khoản trước khi bắt đầu; lỗi khởi chạy, nếu có, sẽ hiện trong Terminal."
            } else { message = "Đã kiểm tra \(provider.rawValue) · \(provider.qualifiedVersion). Chưa gửi yêu cầu AI." }
        } catch {
            failed = true
            message = (error as? StudioCLIError)?.localizedDescription ?? (error as? StudioError)?.localizedDescription ?? "Chưa chuẩn bị được phiên CLI. Thử kiểm tra lại."
        }
    }
}
