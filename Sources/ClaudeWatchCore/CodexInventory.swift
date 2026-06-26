// Scan Codex rollout JSONL files trong ~/.codex/sessions/YYYY/MM/DD/.
// Mỗi rollout-{timestamp}-{uuid}.jsonl = 1 session — kể cả subagent threads,
// để gộp về 1 parent session cần lookup parent_thread_id (skip MVP).
//
// Format khác Claude:
//   line 1: {timestamp, type: "session_meta", payload: {id, cwd, originator,
//                                                       cli_version, model_provider, ...}}
//   sau:    type "turn_context" | "event_msg" | "response_item"
//
// Token usage: events kind "event_msg" với payload.type "token_count" chứa
// total_token_usage. Lấy max accumulating cumulative (last seen).

import Foundation

public enum CodexInventory {

    /// Default scan root. Override để test.
    public static let defaultRoot = NSHomeDirectory() + "/.codex/sessions"

    /// Liệt kê tất cả Codex session "chạm" vào khoảng [start, end].
    /// Filter cheap bằng mtime trước khi parse JSONL.
    public static func list(in range: ClosedRange<Date>, root: String = defaultRoot) -> [SessionSummary] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }

        // Walk year/month/day dirs để tìm rollout files. Skip files có mtime < range.lower
        // để không phải parse JSONL cũ.
        var out: [SessionSummary] = []
        guard let yearDirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        for year in yearDirs {
            let yearPath = root + "/" + year
            guard let monthDirs = try? fm.contentsOfDirectory(atPath: yearPath) else { continue }
            for month in monthDirs {
                let monthPath = yearPath + "/" + month
                guard let dayDirs = try? fm.contentsOfDirectory(atPath: monthPath) else { continue }
                for day in dayDirs {
                    let dayPath = monthPath + "/" + day
                    let dayURL = URL(fileURLWithPath: dayPath)
                    guard let files = try? fm.contentsOfDirectory(
                        at: dayURL,
                        includingPropertiesForKeys: [.contentModificationDateKey]
                    ) else { continue }
                    for file in files where file.pathExtension == "jsonl" {
                        let mt = ProjectPath.mtime(of: file)
                        if mt < range.lowerBound { continue }
                        if let s = CodexJsonlParser.summarize(file: file, range: range) {
                            out.append(s)
                        }
                    }
                }
            }
        }
        return out
    }
}

/// Parse 1 Codex rollout JSONL → SessionSummary. Stream từng line để tránh
/// load full file vào RAM (cap autorelease pool mỗi 64KB).
public enum CodexJsonlParser {

    /// Parse 1 file. Return nil nếu file không có activity trong range.
    public static func summarize(file: URL, range: ClosedRange<Date>) -> SessionSummary? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let text = String(decoding: data, as: UTF8.self)

        var sessionId: String?
        var cwd: String?
        var originator: String?
        var modelProvider: String?
        var cliVersion: String?

        var firstTs: Date?
        var lastTs: Date?
        var promptCount = 0
        var toolCallCount = 0

        // Token usage: dùng MAX(total_tokens) trên các snapshot, vì các snapshot
        // sau cộng dồn cả turn trước. Lấy max thay sum để không double-count.
        var maxInputTokens = 0
        var maxOutputTokens = 0
        var maxCacheReadTokens = 0

        // ISO8601 parser (UTC, fractional seconds).
        let isoFracs: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        var inRange = false

        text.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let raw = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                return
            }
            // Parse timestamp.
            let ts: Date? = {
                guard let s = obj["timestamp"] as? String else { return nil }
                return isoFracs.date(from: s) ?? iso.date(from: s)
            }()
            if let t = ts {
                if firstTs == nil || t < firstTs! { firstTs = t }
                if lastTs == nil || t > lastTs!   { lastTs = t }
                if range.contains(t) { inRange = true }
            }

            let kind = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any] ?? [:]

            switch kind {
            case "session_meta":
                sessionId = payload["id"] as? String ?? sessionId
                cwd = payload["cwd"] as? String ?? cwd
                originator = payload["originator"] as? String ?? originator
                modelProvider = payload["model_provider"] as? String ?? modelProvider
                cliVersion = payload["cli_version"] as? String ?? cliVersion

            case "event_msg":
                let pType = payload["type"] as? String
                switch pType {
                case "user_message":
                    promptCount += 1
                case "token_count":
                    if let info = payload["info"] as? [String: Any],
                       let total = info["total_token_usage"] as? [String: Any] {
                        if let v = total["input_tokens"] as? Int { maxInputTokens = max(maxInputTokens, v) }
                        if let v = total["output_tokens"] as? Int { maxOutputTokens = max(maxOutputTokens, v) }
                        if let v = total["cached_input_tokens"] as? Int { maxCacheReadTokens = max(maxCacheReadTokens, v) }
                    }
                default:
                    break
                }

            case "response_item":
                if (payload["type"] as? String) == "function_call" {
                    toolCallCount += 1
                }

            default:
                break
            }
        }

        // Skip files hoàn toàn ngoài range.
        guard inRange else { return nil }

        // Fallback: nếu không có session_meta, dùng file basename phần uuid.
        let id = sessionId
            ?? file.deletingPathExtension().lastPathComponent

        // Project display: từ cwd basename. "/Users/.../Working/proj" → "proj".
        // Nếu nil → "(unknown)".
        let projectDisplay: String = {
            guard let cwd, !cwd.isEmpty else { return "(unknown)" }
            return URL(fileURLWithPath: cwd).lastPathComponent
        }()

        // Codex là subscription — cost = 0. Token vẫn track để hiện usage.
        return SessionSummary(
            id: id,
            projectDisplay: projectDisplay,
            source: .codex,
            model: modelProvider ?? "openai",
            modelFamily: .gpt,
            inputTokens: maxInputTokens,
            outputTokens: maxOutputTokens,
            cacheReadTokens: maxCacheReadTokens,
            cacheWriteTokens: 0,
            cost: 0,
            firstTimestamp: firstTs,
            lastTimestamp: lastTs,
            promptCount: promptCount,
            toolCallCount: toolCallCount,
            fileURL: file,
            agentCount: 0
        )
    }
}
