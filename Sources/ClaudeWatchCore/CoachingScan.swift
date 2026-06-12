// 1-pass scan trả về cả prompts + sessions cùng lúc, parallel parse với
// TaskGroup. Thay thế việc gọi PromptHistory.loadPrompts + SessionInventory.list
// + computeDailyCostTrend riêng (mỗi cái re-enumerate filesystem độc lập).
//
// Coaching reload trước: 9× scan dir (cur/prev/7×day × 1 source mỗi cái) →
// nay: 1× scan dir, slice trong memory. Tốc độ thực tế +5-10×.

import Foundation

/// Kết quả 1 lần scan rộng. Caller slice cho từng dimension (current/prev/daily).
public struct CoachingScanResult: Sendable {
    public let prompts: [PromptRecord]
    public let sessions: [SessionSummary]
}

public enum CoachingScan {

    /// Scan toàn bộ session file có khả năng chạm `range`. Parallel parse mỗi file.
    /// Trả về cả prompt list lẫn session summary từ CÙNG 1 pass đọc file.
    public static func scan(in range: ClosedRange<Date>) async -> CoachingScanResult {
        let index = DesktopOriginIndex.shared()
        let candidates = collectCandidateFiles(in: range)
        // Parallel parse — IO-bound trên SSD, CPU-bound bị JSON; TaskGroup
        // tận dụng cả 2.
        let results = await withTaskGroup(of: ScanOne?.self) { group in
            for c in candidates {
                group.addTask {
                    parseOne(file: c.url, slug: c.slug, display: c.display,
                             source: c.source(via: index), range: range)
                }
            }
            var collected: [ScanOne] = []
            for await r in group {
                if let r { collected.append(r) }
            }
            return collected
        }
        var prompts: [PromptRecord] = []
        var sessions: [SessionSummary] = []
        for r in results {
            prompts.append(contentsOf: r.prompts)
            if let s = r.summary { sessions.append(s) }
        }
        prompts.sort { $0.timestamp < $1.timestamp }
        sessions.sort { $0.cost > $1.cost }
        return CoachingScanResult(prompts: prompts, sessions: sessions)
    }

    // MARK: - File enumeration

    private struct Candidate {
        let url: URL
        let slug: String
        let display: String
        let isDesktopFolder: Bool  // true = local-agent-mode audit, false = projects/
        func source(via index: DesktopOriginIndex) -> SessionSource {
            if isDesktopFolder { return .desktop }
            let uuid = url.deletingPathExtension().lastPathComponent
            return index.classify(uuid: uuid)
        }
    }

    /// Liệt kê file có mtime ≥ range.lowerBound, từ cả CLI projects/ lẫn
    /// Desktop local-agent-mode-sessions/.
    private static func collectCandidateFiles(in range: ClosedRange<Date>) -> [Candidate] {
        var out: [Candidate] = []
        let fm = FileManager.default

        // CLI: ~/.claude/projects/<slug>/<uuid>.jsonl
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        if let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) {
            for slug in projectDirs {
                let projectURL = URL(fileURLWithPath: projectsDir).appendingPathComponent(slug)
                guard let files = try? fm.contentsOfDirectory(at: projectURL,
                                                              includingPropertiesForKeys: nil) else {
                    continue
                }
                let display = ProjectPath.displayPath(for: slug)
                for file in files where file.pathExtension == "jsonl" {
                    if ProjectPath.mtime(of: file) < range.lowerBound { continue }
                    out.append(Candidate(url: file, slug: slug, display: display,
                                         isDesktopFolder: false))
                }
            }
        }

        // Desktop: ~/Library/.../local-agent-mode-sessions/.../audit.jsonl
        let desktopRoot = NSHomeDirectory()
            + "/Library/Application Support/Claude/local-agent-mode-sessions"
        if fm.fileExists(atPath: desktopRoot),
           let enumerator = fm.enumerator(at: URL(fileURLWithPath: desktopRoot),
                                          includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == "audit.jsonl" {
                if ProjectPath.mtime(of: url) < range.lowerBound { continue }
                let parent = url.deletingLastPathComponent()
                let slug = parent.lastPathComponent
                let display = "Desktop · " + parent.deletingLastPathComponent().lastPathComponent
                out.append(Candidate(url: url, slug: slug, display: display,
                                     isDesktopFolder: true))
            }
        }
        return out
    }

    // MARK: - Per-file parse

    /// Output combined: prompts trong range + session summary (nếu session chạm range).
    private struct ScanOne {
        let prompts: [PromptRecord]
        let summary: SessionSummary?
    }

    /// Parse 1 file: lấy SessionStats (cho summary) + extract user prompts.
    /// JsonlParser.parseSession đã handle full schema CLI + Desktop audit.
    private static func parseOne(file: URL, slug: String, display: String,
                                 source: SessionSource,
                                 range: ClosedRange<Date>) -> ScanOne? {
        let stats = JsonlParser.parseSession(at: file)
        let mtime = ProjectPath.mtime(of: file)
        let firstTs = parseISO(stats.startedAt) ?? mtime
        let lastTs = parseISO(stats.lastEventAt) ?? mtime

        // Session summary nếu session chạm range.
        let summary: SessionSummary? = (lastTs >= range.lowerBound && firstTs <= range.upperBound)
            ? SessionSummary(
                id: stats.sessionId,
                projectDisplay: display,
                source: source,
                model: stats.model,
                modelFamily: stats.modelFamily,
                inputTokens: stats.inputTokens,
                outputTokens: stats.outputTokens,
                cacheReadTokens: stats.cacheReadTokens,
                cacheWriteTokens: stats.cacheWriteTokens,
                cost: stats.cost,
                firstTimestamp: firstTs,
                lastTimestamp: lastTs,
                promptCount: max(stats.events.filter { $0.kind == .userMessage }.count,
                                 stats.messageCount / 2),
                toolCallCount: stats.toolCalls,
                fileURL: file
            )
            : nil

        // Prompts trong range — bao giờ cũng parse file 2 lần nay → đọc thêm 1 lần
        // RIÊNG cho prompt extraction để giữ full text (JsonlParser cap 160ch).
        let prompts = extractPromptsInRange(file: file, slug: slug, display: display,
                                            source: source, range: range)

        if summary == nil && prompts.isEmpty { return nil }
        return ScanOne(prompts: prompts, summary: summary)
    }

    /// Extract CHỈ prompt ĐẦU TIÊN của session (earliest user message). Đánh giá
    /// coaching dựa trên cách user khởi đầu session — định hướng agent tốt hay
    /// chưa, có Spec/criteria không. Follow-up messages trong session không tính.
    ///
    /// Logic:
    /// 1. Quét MỌI user message trong file (full session, không filter range)
    /// 2. Lấy message có timestamp sớm nhất
    /// 3. Nếu timestamp đó rơi vào `range` → emit 1 PromptRecord; ngược lại bỏ qua
    private static func extractPromptsInRange(file: URL, slug: String, display: String,
                                              source: SessionSource,
                                              range: ClosedRange<Date>) -> [PromptRecord] {
        guard let data = try? Data(contentsOf: file),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        let sessionUuid = file.deletingPathExtension().lastPathComponent

        // Gom mọi user message hợp lệ (timestamp + text không rỗng) từ TOÀN BỘ file.
        struct UserMsg {
            let ts: Date
            let text: String
            let lineIndex: Int
        }
        var msgs: [UserMsg] = []
        var lineIndex = 0
        raw.enumerateLines { line, _ in
            lineIndex += 1
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return }
            guard (obj["type"] as? String) == "user" else { return }

            let tsStr = (obj["timestamp"] as? String)
                ?? (obj["_audit_timestamp"] as? String)
            guard let s = tsStr, let ts = parseISO(s) else { return }

            let text = extractUserText(from: obj["message"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            msgs.append(UserMsg(ts: ts, text: text, lineIndex: lineIndex))
        }

        // Skip auto-injected continuation prompts (Claude Code khi resume/compact
        // chèn tin ngắn như ".", ",", "Continue", <command-name>, <system-reminder>,
        // hoặc compaction summary). Lấy first message THỰC SỰ user gõ.
        let realMsgs = msgs.filter { !isLikelySystemInjection($0.text) }
        guard let first = realMsgs.min(by: { $0.ts < $1.ts }),
              range.contains(first.ts) else { return [] }

        return [PromptRecord(
            id: "\(sessionUuid)-\(first.lineIndex)",
            timestamp: first.ts, projectSlug: slug, projectDisplay: display,
            sessionUuid: sessionUuid, text: first.text,
            score: PromptScorer.score(first.text),
            source: source
        )]
    }

    /// True nếu text trông giống auto-injected message của Claude Code thay vì
    /// user's real prompt. Heuristic:
    /// - Pure punctuation / quá ngắn (< 3 alphanumeric chars) — vd ".", ",", "."
    /// - Bắt đầu bằng tag XML system (Claude Code dùng để wrap command output)
    /// - Compaction header standard
    /// - Slash command resume markers
    nonisolated static func isLikelySystemInjection(_ rawText: String) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quá ngắn — đếm alphanumeric chars, < 3 = noise (vd ".", "..", ",.")
        let alphaCount = text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.count
        if alphaCount < 3 { return true }

        // Claude Code wrapper tags — chèn tự động cho slash command / hook output.
        let systemPrefixes = [
            "<command-name>",
            "<command-message>",
            "<command-stdout>",
            "<command-args>",
            "<local-command-stdout>",
            "<local-command-stderr>",
            "<system-reminder>",
            "<bash-stdout>",
            "<bash-stderr>",
            "<user-prompt-submit-hook>",
        ]
        for prefix in systemPrefixes where text.hasPrefix(prefix) { return true }

        // Compaction continuation header — Claude Code generate khi context full.
        if text.hasPrefix("This session is being continued from a previous conversation") {
            return true
        }
        if text.hasPrefix("Caveat:") && text.contains("<local-command-stdout>") {
            return true
        }

        return false
    }

    private static func extractUserText(from message: Any?) -> String {
        guard let dict = message as? [String: Any] else { return "" }
        if let raw = dict["content"] as? String { return stripSystemTags(raw) }
        guard let blocks = dict["content"] as? [[String: Any]] else { return "" }
        var pieces: [String] = []
        for block in blocks {
            guard (block["type"] as? String) == "text",
                  let txt = block["text"] as? String, !txt.isEmpty else { continue }
            pieces.append(txt)
        }
        return stripSystemTags(pieces.joined(separator: "\n"))
    }

    /// Loại bỏ `<tag>...</tag>` của các wrapper system Claude Code chèn vào user
    /// message (hook output, command name, system reminder, stdout). Để text
    /// còn lại đại diện cho prompt user gõ thật sự.
    nonisolated static func stripSystemTags(_ text: String) -> String {
        let tags = [
            "command-name", "command-message", "command-stdout", "command-args",
            "local-command-stdout", "local-command-stderr",
            "system-reminder", "bash-stdout", "bash-stderr",
            "user-prompt-submit-hook",
        ]
        var s = text
        for tag in tags {
            let pattern = "<\(tag)>[\\s\\S]*?</\(tag)>"
            if let re = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(s.startIndex..., in: s)
                s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseISO(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        if let d = isoFractional.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
