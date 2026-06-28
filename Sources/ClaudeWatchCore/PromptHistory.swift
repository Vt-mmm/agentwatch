// Quét toàn bộ ~/.claude/projects/<slug>/*.jsonl, trích full user prompt
// (KHÔNG truncate như JsonlParser) để feed vào PromptScorer.
//
// JsonlParser tối ưu cho live view event list nên cắt text về 160 char.
// Coaching report cần full prompt → phải có 1 lối scan riêng.

import Foundation

/// 1 prompt đã được chấm điểm + metadata.
public struct PromptRecord: Identifiable, Sendable, Equatable {
    public let id: String           // hash uuid+timestamp+text-prefix
    public let timestamp: Date
    public let projectSlug: String  // tên thư mục dưới ~/.claude/projects/
    public let projectDisplay: String   // path đã decode lại
    public let sessionUuid: String  // file uuid.jsonl
    public let text: String         // full prompt
    public let score: PromptScore
    public let source: SessionSource  // CLI hay Desktop

    public init(id: String, timestamp: Date, projectSlug: String,
                projectDisplay: String, sessionUuid: String,
                text: String, score: PromptScore,
                source: SessionSource = .cli) {
        self.id = id
        self.timestamp = timestamp
        self.projectSlug = projectSlug
        self.projectDisplay = projectDisplay
        self.sessionUuid = sessionUuid
        self.text = text
        self.score = score
        self.source = source
    }
}

public enum PromptHistory {

    /// Đọc toàn bộ user prompts trong khoảng [start, end) từ tất cả nguồn:
    /// - ~/.claude/projects/<slug>/<uuid>.jsonl — phân loại CLI hay Desktop dựa
    ///   trên DesktopOriginIndex (cross-ref với claude-code-sessions/).
    /// - ~/Library/Application Support/Claude/local-agent-mode-sessions/.../audit.jsonl
    ///   — Desktop Computer Use mode.
    /// Trả về theo thứ tự thời gian tăng dần.
    public static func loadPrompts(in range: ClosedRange<Date>) -> [PromptRecord] {
        let index = DesktopOriginIndex.shared()
        var out: [PromptRecord] = []
        out.append(contentsOf: loadProjectsPrompts(in: range, index: index))
        out.append(contentsOf: loadDesktopPrompts(in: range))
        // v0.8.0: parity với Claude — Codex prompts cũng vào history cho pet XP +
        // scoring + anomaly. Skip subagent rollouts (machine-injected, không phải
        // user input thực).
        out.append(contentsOf: loadCodexPrompts(in: range))
        return out.sorted { $0.timestamp < $1.timestamp }
    }

    /// Scan Codex rollout JSONL → user_message events → PromptRecord.
    /// Mirror logic CodexInventory.list nhưng load prompts thay session metadata.
    private static func loadCodexPrompts(in range: ClosedRange<Date>) -> [PromptRecord] {
        let root = NSHomeDirectory() + "/.codex/sessions"
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        var out: [PromptRecord] = []
        guard let years = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        for year in years {
            let yearPath = root + "/" + year
            guard let months = try? fm.contentsOfDirectory(atPath: yearPath) else { continue }
            for month in months {
                let monthPath = yearPath + "/" + month
                guard let days = try? fm.contentsOfDirectory(atPath: monthPath) else { continue }
                for day in days {
                    let dayPath = monthPath + "/" + day
                    guard let files = try? fm.contentsOfDirectory(
                        at: URL(fileURLWithPath: dayPath),
                        includingPropertiesForKeys: [.contentModificationDateKey]
                    ) else { continue }
                    for file in files where file.pathExtension == "jsonl" {
                        let mt = ProjectPath.mtime(of: file)
                        if mt < range.lowerBound { continue }
                        out.append(contentsOf: extractCodexPrompts(from: file, range: range))
                    }
                }
            }
        }
        return out
    }

    /// Parse 1 Codex rollout. Skip nếu thread_source == "subagent".
    private static func extractCodexPrompts(from file: URL,
                                            range: ClosedRange<Date>) -> [PromptRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let raw = String(decoding: data, as: UTF8.self)
        let sessionUuid = file.deletingPathExtension().lastPathComponent

        // Parse session_meta line 1 để biết cwd + check subagent.
        var isSubagent = false
        var cwd: String = "(unknown)"
        var sessionId: String? = nil

        var records: [PromptRecord] = []
        var lineIndex = 0
        raw.enumerateLines { line, _ in
            lineIndex += 1
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return }

            let kind = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any] ?? [:]

            if kind == "session_meta" {
                if (payload["thread_source"] as? String) == "subagent" { isSubagent = true }
                if let c = payload["cwd"] as? String { cwd = c }
                if let id = payload["id"] as? String { sessionId = id }
                return
            }

            // Skip prompts của subagent rollouts.
            if isSubagent { return }

            guard kind == "event_msg",
                  (payload["type"] as? String) == "user_message" else { return }

            // Codex timestamp ISO8601Z trên top-level.
            guard let timestampStr = obj["timestamp"] as? String,
                  let timestamp = parseISO(timestampStr),
                  range.contains(timestamp) else { return }

            // Codex user_message text trong payload.message hoặc payload.content.
            let promptText: String = {
                if let m = payload["message"] as? String { return m }
                if let c = payload["content"] as? String { return c }
                return ""
            }()
            let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // v0.8.1: dùng full cwd path để merge project breakdown với Claude.
            let displayProject = cwd
            let id = "codex-\(sessionUuid)-\(lineIndex)"
            let score = PromptScorer.score(trimmed)
            records.append(PromptRecord(
                id: id, timestamp: timestamp,
                projectSlug: cwd, projectDisplay: displayProject,
                sessionUuid: sessionId ?? sessionUuid,
                text: trimmed, score: score,
                source: .codex
            ))
        }
        return records
    }

    private static func loadProjectsPrompts(in range: ClosedRange<Date>,
                                            index: DesktopOriginIndex) -> [PromptRecord] {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return []
        }
        var out: [PromptRecord] = []
        for slug in projectDirs {
            let projectURL = URL(fileURLWithPath: projectsDir).appendingPathComponent(slug)
            guard let files = try? fm.contentsOfDirectory(at: projectURL,
                                                          includingPropertiesForKeys: nil) else {
                continue
            }
            let display = ProjectPath.displayPath(for: slug)
            for file in files where file.pathExtension == "jsonl" {
                let uuid = file.deletingPathExtension().lastPathComponent
                let source = index.classify(uuid: uuid)
                out.append(contentsOf:
                    extractPrompts(from: file, projectSlug: slug,
                                   projectDisplay: display, source: source, range: range))
            }
        }
        return out
    }

    /// Desktop layout: nested 3-4 levels deep with audit.jsonl as leaf.
    /// Use FileManager.enumerator để đi sâu, dừng khi gặp audit.jsonl.
    private static func loadDesktopPrompts(in range: ClosedRange<Date>) -> [PromptRecord] {
        let desktopRoot = NSHomeDirectory()
            + "/Library/Application Support/Claude/local-agent-mode-sessions"
        let fm = FileManager.default
        guard fm.fileExists(atPath: desktopRoot),
              let enumerator = fm.enumerator(at: URL(fileURLWithPath: desktopRoot),
                                              includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [PromptRecord] = []
        for case let url as URL in enumerator where url.lastPathComponent == "audit.jsonl" {
            // Dùng parent folder name "local_<uuid>" làm sessionUuid để hiển thị,
            // grandparent làm "project" display.
            let parent = url.deletingLastPathComponent()
            let sessionUuid = parent.lastPathComponent
            let displayPath = "Desktop · " + parent.deletingLastPathComponent().lastPathComponent
            out.append(contentsOf:
                extractPrompts(from: url, projectSlug: sessionUuid,
                               projectDisplay: displayPath, source: .desktop, range: range))
        }
        return out
    }

    /// Convenience: prompts trong 1 ngày dương lịch local timezone.
    public static func loadPrompts(forDay day: Date,
                                   calendar: Calendar = .current) -> [PromptRecord] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return loadPrompts(in: start...end.addingTimeInterval(-1))
    }

    /// Convenience: prompts trong tuần (Mon-Sun) chứa `day`.
    public static func loadPrompts(forWeekContaining day: Date,
                                   calendar: Calendar = currentMondayBased) -> [PromptRecord] {
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
        guard let weekStart = calendar.date(from: comps),
              let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else {
            return []
        }
        return loadPrompts(in: weekStart...weekEnd.addingTimeInterval(-1))
    }

    // MARK: - Internals

    private static func extractPrompts(from file: URL,
                                       projectSlug: String,
                                       projectDisplay: String,
                                       source: SessionSource,
                                       range: ClosedRange<Date>) -> [PromptRecord] {
        guard let data = try? Data(contentsOf: file),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        let sessionUuid = file.deletingPathExtension().lastPathComponent

        var records: [PromptRecord] = []
        var lineIndex = 0
        raw.enumerateLines { line, _ in
            lineIndex += 1
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return }

            guard (obj["type"] as? String) == "user" else { return }
            // CLI dùng "timestamp", Desktop audit JSONL dùng "_audit_timestamp".
            let ts = (obj["timestamp"] as? String)
                ?? (obj["_audit_timestamp"] as? String)
            guard let timestampStr = ts,
                  let timestamp = parseISO(timestampStr),
                  range.contains(timestamp) else { return }

            let promptText = extractUserText(from: obj["message"])
            let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let id = "\(sessionUuid)-\(lineIndex)"
            let score = PromptScorer.score(trimmed)
            records.append(PromptRecord(
                id: id, timestamp: timestamp,
                projectSlug: projectSlug, projectDisplay: projectDisplay,
                sessionUuid: sessionUuid, text: trimmed, score: score,
                source: source
            ))
        }
        return records
    }

    /// `message` field có 2 dạng: { content: "string" } hoặc
    /// { content: [{type: "text", text: ...}, {type:"tool_result", ...}] }.
    /// Chỉ lấy text user thực, bỏ tool_result.
    private static func extractUserText(from message: Any?) -> String {
        guard let dict = message as? [String: Any] else { return "" }
        if let raw = dict["content"] as? String { return raw }
        guard let blocks = dict["content"] as? [[String: Any]] else { return "" }
        var pieces: [String] = []
        for block in blocks {
            guard (block["type"] as? String) == "text",
                  let txt = block["text"] as? String, !txt.isEmpty else { continue }
            pieces.append(txt)
        }
        return pieces.joined(separator: "\n")
    }

    private static func parseISO(_ s: String) -> Date? {
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

    /// Tuần bắt đầu thứ Hai, locale Việt Nam.
    public static let currentMondayBased: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        cal.firstWeekday = 2 // Monday
        return cal
    }()
}
