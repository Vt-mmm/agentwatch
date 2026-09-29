import SwiftUI
import AppKit
import AgentWatchCore

struct StudioConfigurationView: View {
    var showApply = true
    @State private var sync: StudioSyncStore
    @State private var background = StudioBackgroundService.shared

    init(showApply: Bool = true, sync: StudioSyncStore = .shared) {
        self.showApply = showApply
        _sync = State(initialValue: sync)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(showApply ? "Công cụ trên máy" : "2. Chọn công cụ").font(ClaudeFont.heading(18))
                Spacer()
                Text("\(sync.selected.count)/4 đã chọn").font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(StudioSyncTarget.allCases) { target in toolCard(target) }
            }
            if showApply {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Button(sync.busy ? "Đang đồng bộ…" : "Áp dụng cấu hình") {
                            sync.enabled = true; background.start()
                            Task { await sync.synchronize(force: true) }
                        }.buttonStyle(.borderedProminent).tint(Claude.orange).controlSize(.large)
                            .disabled(sync.busy || sync.selected.isEmpty)
                        if sync.busy { ProgressView().controlSize(.small) }
                        Spacer(minLength: 0)
                        if let at = sync.lastChecked {
                            Text(at.formatted(date: .omitted, time: .shortened))
                                .font(ClaudeFont.label()).foregroundStyle(Claude.textMuted).help("Lần kiểm tra model gần nhất")
                        }
                    }
                    Text(sync.status).font(ClaudeFont.body(12))
                        .foregroundStyle(sync.lastError == nil ? Claude.textMuted : Claude.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Label(sync.enabled ? "Tự đồng bộ mỗi 5 phút" : "Tự đồng bộ chưa bật", systemImage: "arrow.triangle.2.circlepath")
                        .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
                    if !background.message.isEmpty {
                        Text(background.message).font(ClaudeFont.body(11)).foregroundStyle(Claude.textMuted)
                    }
                    if background.needsApproval { Button("Mở Login Items") { background.openSettings() } }
                }.claudeCard()
                DisclosureGroup("Thư mục và khôi phục") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Bỏ chọn chỉ dừng đồng bộ. Dùng Khôi phục để trả lại cấu hình trước đó.")
                            .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
                        ForEach(StudioSyncTarget.allCases) { target in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(target.title).font(ClaudeFont.label())
                                    Spacer()
                                    Button("Đổi thư mục") { chooseDirectory(target) }
                                    Button("Khôi phục") { sync.restore(target) }
                                }
                                Text(sync.directory(target).path).font(ClaudeFont.mono(11)).textSelection(.enabled)
                                    .foregroundStyle(Claude.textMuted).fixedSize(horizontal: false, vertical: true)
                            }
                            if target != StudioSyncTarget.allCases.last { Divider() }
                        }
                    }.padding(.top, 12)
                }.font(ClaudeFont.body(12)).claudeCard()
            }
        }.disabled(sync.busy)
    }

    private func toolCard(_ target: StudioSyncTarget) -> some View {
        let selected = sync.selected.contains(target)
        let result = sync.results.first { $0.target == target }
        let current = selected && result != nil && sync.lastError == nil && !sync.busy
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon(target)).font(.system(size: 19))
                    .foregroundStyle(selected ? Claude.orange : Claude.textMuted)
                    .frame(width: 30, height: 30)
                Toggle(target.title, isOn: Binding(get: { sync.selected.contains(target) }, set: { value in
                    if value { sync.selected.insert(target) } else { sync.selected.remove(target) }
                })).toggleStyle(.checkbox).font(ClaudeFont.label(13))
                Spacer(minLength: 0)
            }
            Label(!selected ? "Không đồng bộ" : !showApply ? "Đã chọn" : sync.busy ? "Đang kiểm tra…" : !current ? "Chưa xác minh cấu hình" : result!.success ? "Đã đồng bộ · \(result!.count) model" : "Cần xử lý",
                  systemImage: !selected ? "minus.circle" : !current ? "clock" : result!.success ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(ClaudeFont.body(12)).foregroundStyle(current && result!.success ? Claude.live : current ? Claude.orange : Claude.textMuted)
            if let result, !result.success, selected {
                DisclosureGroup("Xem lỗi") {
                    Text(result.message).font(ClaudeFont.body(11)).foregroundStyle(Claude.orange)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 4)
                }.font(ClaudeFont.body(11))
            } else {
                Text(target == .claude ? "Model Claude" : target == .codex ? "Model Codex" : "Model Claude và Codex")
                    .font(ClaudeFont.body(11)).foregroundStyle(Claude.textMuted)
            }
        }.frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .padding(14).background(Claude.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Claude.orange.opacity(0.55) : Claude.border, lineWidth: 1))
    }
    private func icon(_ target: StudioSyncTarget) -> String {
        switch target { case .claude: "sparkle"; case .codex: "terminal"; case .pi: "curlybraces"; case .piagent: "square.stack.3d.up" }
    }
    private func chooseDirectory(_ target: StudioSyncTarget) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = sync.directory(target)
        if panel.runModal() == .OK, let url = panel.url { sync.directories[target.rawValue] = url.path }
    }
}
