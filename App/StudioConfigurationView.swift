import SwiftUI
import AppKit
import AgentWatchCore

struct StudioConfigurationView: View {
    @Environment(StudioConnectionStore.self) private var studio
    @State private var tool: StudioConfiguredTool = .claude
    @State private var modelID = ""
    @State private var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    @State private var plan: StudioConfigurationPlan?
    @State private var message = ""
    @State private var busy = false
    private var models: [StudioModel] {
        guard case .available(let values) = studio.snapshot?.models else { return [] }
        return values.filter { tool == .pi || $0.ownedBy == tool.rawValue }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Cấu hình công cụ")
            Text("Thiết lập một lần, mở CLI như thường").font(ClaudeFont.heading())
            Picker("Công cụ", selection: $tool) {
                Text("Claude Code").tag(StudioConfiguredTool.claude)
                Text("Codex CLI").tag(StudioConfiguredTool.codex)
                Text("Pi").tag(StudioConfiguredTool.pi)
            }
            Picker("Model mặc định", selection: $modelID) {
                Text("Chọn model được cấp…").tag("")
                ForEach(models) { Text($0.displayName.isEmpty ? $0.id : $0.displayName).tag($0.id) }
            }
            HStack {
                Button("Chọn thư mục cấu hình") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { directory = url; plan = nil; message = "" }
                }
                Text(directory.path).font(ClaudeFont.mono(11)).textSelection(.enabled)
            }
            Text("Context theo mặc định model. Key giữ trong Keychain. Có bản sao lưu trước khi áp dụng.")
                .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            HStack {
                Button("Kiểm tra cấu hình") { Task { await check() } }.disabled(busy || modelID.isEmpty)
                Button("Áp dụng") { apply() }.disabled(busy || plan == nil)
                Button("Khôi phục") {
                    do { try StudioClientConfiguration.restoreReceipt(at: StudioClientConfiguration.receiptURL(tool: tool, directory: directory)); plan = nil; message = "Đã khôi phục cấu hình trước khi áp dụng." }
                    catch { message = error.localizedDescription }
                }.disabled(busy)
            }
            if let plan { ForEach(plan.edits, id: \.file) { Text($0.file.lastPathComponent).font(ClaudeFont.mono(11)) } }
            if !message.isEmpty { Text(message).font(ClaudeFont.body(12)).textSelection(.enabled) }
        }.claudeCard()
        .onChange(of: models) { _, values in
            plan = nil
            if !values.contains(where: { $0.id == modelID }) { modelID = values.count == 1 ? values[0].id : "" }
        }
        .onAppear { if models.count == 1 { modelID = models[0].id } }
        .onChange(of: tool) { _, value in
            directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(value == .pi ? ".pi/agent" : "." + value.rawValue)
            modelID = ""; plan = nil; message = ""
        }
        .onChange(of: modelID) { _, _ in plan = nil; message = "" }
        .onChange(of: studio.profile?.id) { _, _ in plan = nil; modelID = "" }
    }
    @MainActor private func check() async {
        busy = true; plan = nil; defer { busy = false }
        await studio.refresh()
        do {
            guard studio.state == .connected, let connection = studio.profile,
                  let model = models.first(where: { $0.id == modelID }) else { throw StudioConfigurationError.invalid }
            guard let helper = Bundle.main.executableURL else { throw StudioCLIError.helperMissing }
            guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw StudioCLIError.helperMissing }
            let catalog = tool == .pi ? try StudioClientConfiguration.catalogModel(for: model, piExecutable: StudioClientConfiguration.piExecutable()) : nil
            plan = try StudioClientConfiguration.prepare(tool: tool, directory: directory, connection: connection, model: model, helper: helper, piCatalogModel: catalog)
            message = "Đã chuẩn bị cấu hình. Áp dụng sẽ thay model/provider mặc định trong các file bên dưới. Chưa gửi yêu cầu AI."
        } catch { message = error.localizedDescription }
    }
    @MainActor private func apply() {
        guard let plan else { return }
        do {
            let receipt = StudioClientConfiguration.receiptURL(tool: tool, directory: directory)
            try StudioClientConfiguration.apply(plan, receipt: receipt)
            self.plan = nil
            message = "Đã ghi cấu hình. Mở terminal mới để dùng CLI; cấu hình project hoặc môi trường riêng vẫn có thể ghi đè."
        } catch { message = error.localizedDescription }
    }
}
