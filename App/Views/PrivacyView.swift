// Privacy & data access panel — transparent với user về việc app đọc file gì,
// có/không gửi data đi đâu. Enumerate live folder để user thấy CHÍNH XÁC
// danh sách file app sẽ đọc khi compute coaching stats.

import SwiftUI

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cliEntries: [FileEntry] = []
    @State private var desktopEntries: [FileEntry] = []

    private let cliRoot = NSHomeDirectory() + "/.claude/projects"
    private let desktopRoot = NSHomeDirectory() +
        "/Library/Application Support/Claude/local-agent-mode-sessions"

    struct FileEntry: Identifiable, Hashable {
        let id: String   // absolute path
        let display: String
        let sizeBytes: Int64
        let mtime: Date
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Claude.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    networkPolicyCard
                    pathCard(title: "CLI sessions (Claude Code terminal)",
                             path: cliRoot, entries: cliEntries)
                    pathCard(title: "Desktop computer-use sessions",
                             path: desktopRoot, entries: desktopEntries)
                    noUploadCard
                }
                .padding(20)
            }
        }
        .frame(width: 720, height: 640)
        .background(Claude.background)
        .task { await loadEntries() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Claude.orange)
            Text("Privacy & Data Access")
                .font(ClaudeFont.heading())
                .foregroundStyle(Claude.textPrimary)
            Spacer()
            Button("Đóng") { dismiss() }
                .keyboardShortcut(.escape)
        }
        .padding(16)
        .background(Claude.surface)
    }

    private var networkPolicyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Network policy")
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("Không có outbound network call NÀO ngoài check update.")
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textPrimary)
            }
            Text("Chỉ Sparkle update fetch `appcast.xml` + download zip từ GitHub Releases (HTTPS, EdDSA verify).")
                .font(ClaudeFont.body(11))
                .foregroundStyle(Claude.textMuted)
            Text("Không telemetry, không analytics, không gửi prompt / cost / project name đi đâu.")
                .font(ClaudeFont.body(11))
                .foregroundStyle(Claude.textMuted)
        }
        .claudeCard()
    }

    private var noUploadCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "icloud.slash.fill")
                    .foregroundStyle(Claude.orange)
                Text("Data stays local")
                    .font(ClaudeFont.heading(13))
                    .foregroundStyle(Claude.textPrimary)
            }
            Text("Tất cả file ở 2 thư mục trên được parse ngay trong process app. Kết quả render local trên UI. Không có ổ đĩa cloud, không có server backend. Anh bấm Export MD/HTML/CSV → file save trực tiếp xuống máy anh chọn.")
                .font(ClaudeFont.body(11))
                .foregroundStyle(Claude.textMuted)
        }
        .claudeCard()
    }

    private func pathCard(title: String, path: String, entries: [FileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "\(title) (\(entries.count) file)")
            Text(path)
                .font(ClaudeFont.mono(10))
                .foregroundStyle(Claude.textMuted)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Divider().background(Claude.border)
            if entries.isEmpty {
                Text("(không có file)")
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
            } else {
                ForEach(entries.prefix(50)) { e in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                            .foregroundStyle(Claude.textMuted)
                        Text(e.display)
                            .font(ClaudeFont.mono(10))
                            .foregroundStyle(Claude.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(formatBytes(e.sizeBytes))
                            .font(ClaudeFont.mono(10))
                            .foregroundStyle(Claude.textMuted)
                            .frame(width: 70, alignment: .trailing)
                        Text(formatDate(e.mtime))
                            .font(ClaudeFont.mono(10))
                            .foregroundStyle(Claude.textMuted)
                            .frame(width: 110, alignment: .trailing)
                    }
                }
                if entries.count > 50 {
                    Text("…và \(entries.count - 50) file nữa")
                        .font(ClaudeFont.body(10))
                        .foregroundStyle(Claude.textMuted)
                        .padding(.top, 4)
                }
            }
        }
        .claudeCard()
    }

    // MARK: - Loading

    private func loadEntries() async {
        let cli = await Task.detached(priority: .userInitiated) {
            Self.enumerate(rootPath: Self.staticCliRoot, filename: nil)
        }.value
        let desk = await Task.detached(priority: .userInitiated) {
            Self.enumerate(rootPath: Self.staticDesktopRoot, filename: "audit.jsonl")
        }.value
        await MainActor.run {
            self.cliEntries = cli
            self.desktopEntries = desk
        }
    }

    nonisolated static let staticCliRoot = NSHomeDirectory() + "/.claude/projects"
    nonisolated static let staticDesktopRoot = NSHomeDirectory() +
        "/Library/Application Support/Claude/local-agent-mode-sessions"

    /// `filename`: nếu nil → match `*.jsonl`. Nếu set → chỉ collect file đúng tên đó.
    nonisolated static func enumerate(rootPath: String, filename: String?) -> [FileEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootPath),
              let enumerator = fm.enumerator(at: URL(fileURLWithPath: rootPath),
                                              includingPropertiesForKeys: [
                                                .fileSizeKey, .contentModificationDateKey
                                              ]) else { return [] }
        var out: [FileEntry] = []
        for case let url as URL in enumerator {
            if let want = filename {
                if url.lastPathComponent != want { continue }
            } else {
                if url.pathExtension != "jsonl" { continue }
            }
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(vals?.fileSize ?? 0)
            let mtime = vals?.contentModificationDate ?? Date.distantPast
            // Display = path relative to root (e.g. "myproject/abc-123.jsonl")
            let rel = url.path.hasPrefix(rootPath + "/")
                ? String(url.path.dropFirst(rootPath.count + 1))
                : url.lastPathComponent
            out.append(FileEntry(id: url.path, display: rel, sizeBytes: size, mtime: mtime))
        }
        return out.sorted { $0.mtime > $1.mtime }
    }

    // MARK: - Formatters

    private func formatBytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        f.timeZone = .current
        return f.string(from: d)
    }
}
