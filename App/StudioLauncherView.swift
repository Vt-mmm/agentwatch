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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Mở CLI công ty")
                Spacer()
                Image(systemName: "questionmark.circle").foregroundStyle(Claude.textMuted)
                    .help("Mở Claude Code hoặc Codex trong Terminal bằng profile riêng của công ty. Kiểm tra không gửi yêu cầu AI; phiên Terminal vẫn chạy khi đóng app.")
            }
            if studio.profile?.credentialMode == .managed {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { Text("agent-watch-auto").font(ClaudeFont.body(12)); folderButton; Spacer(minLength: 0); managedAction }
                    VStack(alignment: .leading, spacing: 8) { Text("agent-watch-auto").font(ClaudeFont.body(12)); HStack { folderButton; Spacer(minLength: 0); managedAction } }
                }
            } else if models.isEmpty {
                Text("Chưa có model CLI khả dụng.").font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { modelPicker.fixedSize(); folderButton; Spacer(minLength: 0); actions }
                    VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { modelPicker; folderButton }; actions }
                }
                DisclosureGroup("Nâng cao") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Chọn file CLI…") { chooseBinary() }.controlSize(.small)
                            if binary != nil { Button("Tự tìm") { binary = nil; message = "" }.controlSize(.small) }
                            Text(binary?.path ?? "Tự tìm CLI đã cài").font(ClaudeFont.mono(10.5)).foregroundStyle(Claude.textMuted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        TextField("ID phiên cần mở lại (không bắt buộc)", text: $resume).textFieldStyle(.roundedBorder).controlSize(.small)
                        Text("Đã kiểm chứng: Claude Code 2.1.181 · Codex CLI 0.155.1").font(ClaudeFont.body(10.5)).foregroundStyle(Claude.textMuted)
                    }.padding(.top, 6)
                }.font(ClaudeFont.body(11.5))
            }
            if !message.isEmpty {
                Text(message).font(ClaudeFont.body(11.5)).foregroundStyle(failed ? Claude.orange : Claude.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .studioCard(padding: 12)
        .onChange(of: modelID) { _, _ in binary = nil; resume = ""; message = "" }
        .onChange(of: studio.profile?.id) { _, _ in modelID = ""; project = nil; binary = nil; resume = ""; message = "" }
        .onChange(of: models) { _, values in if !values.contains(where: { $0.id == modelID }) { modelID = "" } }
    }
    private var modelPicker: some View {
        Picker("Model", selection: $modelID) {
            Text("Chọn model…").tag("")
            ForEach(models) { model in Text("\(StudioFormat.provider(model.ownedBy)) · \(model.displayName.isEmpty ? model.id : model.displayName)").tag(model.id) }
        }.labelsHidden().controlSize(.small)
    }
    private var folderButton: some View {
        Button { chooseProject() } label: { Label(project?.lastPathComponent ?? "Thư mục…", systemImage: "folder").lineLimit(1) }
            .controlSize(.small).help(project?.path ?? "Chọn thư mục project")
    }
    private var actions: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Button("Kiểm tra") { Task { await prepare(openTerminal: false) } }.controlSize(.small)
            Button("Mở Terminal") { Task { await prepare(openTerminal: true) } }
                .buttonStyle(.borderedProminent).tint(Claude.orange).controlSize(.small)
        }.disabled(busy || studio.state != .connected || selected == nil || project == nil)
    }
    @MainActor private func openManaged(web: Bool = false) async {
        guard let project, let profile = studio.profile, profile.credentialMode == .managed else { return }
        busy = true; failed = false; defer { busy = false }
        do {
            let sync = StudioSyncStore.shared
            let target: StudioSyncTarget = sync.selected.contains(.piagent) ? .piagent : .pi
            guard sync.selected.contains(target) else { throw StudioCLIError.invalidArguments }
            let directory = sync.directory(target)
            message = "Đang kiểm tra quyền Piagent…"
            try await StudioManagedConfiguration.authorize(directory: directory, profileID: profile.id)
            guard studio.profile?.id == profile.id else { throw StudioError.identityChanged }
            let command = try StudioManagedConfiguration.terminal(directory: directory, project: project, profileID: profile.id, web: web)
            try await StudioTerminalOpener.open(command)
            message = "Đã mở Piagent. Chọn thinking trong phiên."
        } catch { failed = true; message = error.localizedDescription }
    }
    private var managedAction: some View {
        Menu("Mở Piagent") {
            Button("Terminal") { Task { await openManaged() } }
            Button("WebUI") { Task { await openManaged(web: true) } }
        }.tint(Claude.orange).controlSize(.small)
            .disabled(project == nil || busy || studio.state != .connected)
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
                message = "Đã mở Terminal. Lỗi khởi chạy, nếu có, hiện trong Terminal."
            } else { message = "Đã kiểm tra \(provider.rawValue) · \(provider.qualifiedVersion). Chưa gửi yêu cầu AI." }
        } catch {
            failed = true
            message = (error as? StudioCLIError)?.localizedDescription ?? (error as? StudioError)?.localizedDescription ?? "Chưa chuẩn bị được phiên CLI. Thử kiểm tra lại."
        }
    }
}
