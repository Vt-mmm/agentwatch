import SwiftUI
import AppKit
import AgentWatchCore

struct ProviderQuotaCard: View {
    @AppStorage("quota.codexExecutablePath") private var executablePath = ""
    @State private var snapshots: [QuotaSnapshot] = []
    @State private var refreshing = false
    @State private var storageError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quota tài khoản").font(.headline)
                Spacer()
                Button("Đọc snapshot") { load() }
                Button(refreshing ? "Đang đọc…" : "Làm mới Codex") { refreshInstalled() }
                    .disabled(refreshing)
                Button("Chọn Codex khác…") { selectAndRefresh() }.disabled(refreshing)
            }
            Text("Quota dùng chung theo tài khoản/provider; không phải số liệu riêng của nhân viên hay dung lượng context.")
                .font(.caption).foregroundStyle(.secondary)
            if snapshots.isEmpty {
                Text("Chưa có dữ liệu quota. Claude được thu khi chạy status line AgentWatch; Codex cần làm mới theo yêu cầu.")
                    .font(.callout)
            }
            ForEach(snapshots) { snapshot in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(snapshot.provider) · \(snapshot.source)").font(.subheadline.bold())
                    Text("Thu lúc \(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.isStale(at: Date()) ? "Dữ liệu cũ" : "Snapshot gần đây")")
                        .font(.caption).foregroundStyle(.secondary)
                    if snapshot.availability != .available { Text("Chưa có quota khả dụng").font(.caption) }
                    ForEach(snapshot.windows) { window in
                        HStack {
                            Text(window.id)
                            Spacer()
                            Text(window.usedPercent.map { String(format: "Đã dùng %.1f%%", $0) } ?? "Chưa có dữ liệu")
                            if let reset = window.resetsAt { Text("Reset \(reset.formatted(date: .abbreviated, time: .shortened))") }
                        }.font(.caption)
                    }
                    ForEach(snapshot.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text("Pi: chọn provider và ánh xạ tài khoản ở cấu hình nhóm; không có quota Pi chung.")
                .font(.caption).foregroundStyle(.secondary)
            if let storageError { Text(storageError).font(.caption).foregroundStyle(.red) }
        }
        .claudeCard()
        .onAppear { load() }
    }

    private func load() {
        do {
            let all = try QuotaSnapshotStore.local.load()
            snapshots = ReportQuotaGrouping.latest(all, organizationID: UserDefaults.standard.string(forKey: "dailyReport.organizationID") ?? "",
                                                  mappings: try ReportAccountMappingStore.local.all())
            storageError = nil
        } catch { storageError = "Không đọc được snapshot quota đã lưu." }
    }
    private func refreshInstalled() {
        let saved = executablePath.isEmpty ? [] : [URL(fileURLWithPath: executablePath)]
        guard let executable = CodexQuotaClient.installedExecutable(candidates: saved + CodexQuotaClient.installedCandidates) else {
            storageError = "Chưa tìm thấy Codex đã cài. Dùng Chọn Codex khác để chọn file chạy Codex CLI."
            return
        }
        refresh(executable)
    }
    private func selectAndRefresh() {
        let panel = NSOpenPanel()
        panel.title = "Chọn Codex CLI đã cài để đọc quota tài khoản đang đăng nhập"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let executable = panel.url else { return }
        executablePath = executable.path
        refresh(executable)
    }
    private func refresh(_ executable: URL) {
        refreshing = true
        storageError = nil
        Task {
            let snapshot = await Task.detached(priority: .utility) { CodexQuotaClient.read(executable: executable) }.value
            do { try QuotaSnapshotStore.local.save(snapshot); load() }
            catch { snapshots.insert(snapshot, at: 0); storageError = "Đã đọc nhưng không lưu được snapshot quota." }
            refreshing = false
        }
    }
}
