import SwiftUI
import AppKit
import AgentWatchCore

struct StudioConfigurationView: View {
    var showApply = true
    @State private var sync = StudioSyncStore.shared
    @State private var background = StudioBackgroundService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Công cụ sử dụng Studio").font(ClaudeFont.heading())
            ForEach(StudioSyncTarget.allCases) { target in
                HStack {
                    Toggle(target.title, isOn: Binding(get: { sync.selected.contains(target) }, set: { value in
                        if value { sync.selected.insert(target) } else { sync.selected.remove(target) }
                    })).toggleStyle(.checkbox)
                    Spacer()
                    if let result = sync.results.first(where: { $0.target == target }) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(result.success ? Claude.live : Claude.orange)
                    }
                }
                if let result = sync.results.first(where: { $0.target == target }) {
                    Text(result.message).font(ClaudeFont.body(12)).foregroundStyle(result.success ? Claude.textMuted : Claude.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showApply {
                Button(sync.busy ? "Đang đồng bộ…" : "Áp dụng và đồng bộ tự động") {
                    sync.enabled = true; background.start()
                    Task { await sync.synchronize(force: true) }
                }.buttonStyle(.borderedProminent).tint(Claude.orange).disabled(sync.busy || sync.selected.isEmpty)
                Text(sync.status).font(ClaudeFont.body(12)).fixedSize(horizontal: false, vertical: true)
                if let at = sync.lastChecked {
                    Text("Cập nhật: \(at.formatted(date: .omitted, time: .standard))").font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
                }
            }
            Label(background.message.isEmpty ? "Đóng cửa sổ vẫn chạy nền." : background.message, systemImage: "arrow.triangle.2.circlepath")
                .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            if background.needsApproval { Button("Mở Login Items") { background.openSettings() } }
            DisclosureGroup("Thư mục và khôi phục") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(StudioSyncTarget.allCases.filter { sync.selected.contains($0) }) { target in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(target.title).font(ClaudeFont.label())
                            Text(sync.directory(target).path).font(ClaudeFont.mono(11)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Đổi thư mục") {
                                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                                    if panel.runModal() == .OK, let url = panel.url { sync.directories[target.rawValue] = url.path }
                                }
                                Button("Khôi phục") { sync.restore(target) }
                            }
                        }
                    }
                }.padding(.top, 8)
            }.font(ClaudeFont.body(12))
        }.claudeCard().disabled(sync.busy)
    }
}
