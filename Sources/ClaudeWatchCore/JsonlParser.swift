// Read a JSONL transcript line-by-line and aggregate into SessionStats.
// Mirrors the logic in Python claude_watch.parser.parse_session.

import Foundation

public enum JsonlParser {

    /// Parse one JSONL transcript into a SessionStats.
    /// Malformed lines are skipped (Claude Code can write partial lines while
    /// a session is in flight — never abort the whole parse on one bad line).
    public static func parseSession(at url: URL,
                                    range: ClosedRange<Date>? = nil,
                                    eventLimit: Int? = SessionStats.eventWindowSize) -> SessionStats {
        var stats = SessionStats(
            sessionId: url.deletingPathExtension().lastPathComponent,
            projectSlug: url.deletingLastPathComponent().lastPathComponent,
            filePath: url
        )

        guard let handle = try? FileHandle(forReadingFrom: url) else { return stats }
        defer { try? handle.close() }

        var pendingAgentIds: Set<String> = []
        var pendingToolUseIds: [String: Int] = [:]  // tool_use_id → events[index]
        var eventCounter = 0

        // Streaming: đọc từng chunk 64 KB thay vì readToEnd() toàn bộ file.
        // Peak memory = O(64 KB buffer + 1-2 dòng) thay vì O(filesize).
        let chunkSize = 64 * 1024
        var buffer = Data()
        buffer.reserveCapacity(chunkSize * 2)
        let newlineByte = Data([0x0A])

        var endOfFile = false
        while !endOfFile {
            autoreleasepool {
                // Đọc chunk tiếp theo từ file handle.
                let chunk: Data
                if #available(macOS 10.15.4, *) {
                    chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
                } else {
                    chunk = handle.readData(ofLength: chunkSize)
                }
                if chunk.isEmpty {
                    endOfFile = true
                    return
                }
                buffer.append(chunk)

                // Xử lý mọi dòng hoàn chỉnh trong buffer (kết thúc bằng 0x0A).
                while let nlRange = buffer.firstRange(of: newlineByte) {
                    let lineData = buffer[buffer.startIndex..<nlRange.lowerBound]
                    if !lineData.isEmpty {
                        applyLine(lineData, to: &stats,
                                  pendingAgents: &pendingAgentIds,
                                  pendingTools: &pendingToolUseIds,
                                  counter: &eventCounter,
                                  range: range)
                    }
                    buffer.removeSubrange(buffer.startIndex...nlRange.lowerBound)
                }
            }
        }

        // Flush phần cuối file nếu không kết thúc bằng newline.
        if !buffer.isEmpty {
            applyLine(buffer, to: &stats,
                      pendingAgents: &pendingAgentIds,
                      pendingTools: &pendingToolUseIds,
                      counter: &eventCounter,
                      range: range)
        }

        // Interactive detail uses a bounded window. Export passes nil to retain
        // every tool action in the selected report range.
        if let eventLimit, stats.events.count > eventLimit {
            stats.events = Array(stats.events.suffix(max(0, eventLimit)))
        }
        return stats
    }

    /// Convenience: parse the most-recently-modified session for a folder.
    public static func parseLatestSession(for cwd: URL) -> SessionStats? {
        guard let url = ProjectPath.latestSession(for: cwd) else { return nil }
        return parseSession(at: url)
    }

    // MARK: - Per-line application

    private static func applyLine(_ data: Data,
                                  to stats: inout SessionStats,
                                  pendingAgents: inout Set<String>,
                                  pendingTools: inout [String: Int],
                                  counter: inout Int,
                                  range: ClosedRange<Date>?) {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let type = raw["type"] as? String
        // CLI dùng "timestamp"; Desktop audit JSONL dùng "_audit_timestamp".
        let ts = (raw["timestamp"] as? String)
            ?? (raw["_audit_timestamp"] as? String) ?? ""
        let timestamp = parseISO(ts)
        let belongsToRange = range == nil
            || timestamp.map { range!.contains($0) } == true
        let visibleAtRangeEnd = range == nil
            || timestamp.map { $0 <= range!.upperBound } == true
        if !ts.isEmpty, belongsToRange {
            if stats.startedAt.isEmpty { stats.startedAt = ts }
            stats.lastEventAt = ts
        }

        guard let msg = raw["message"] as? [String: Any] else { return }
        if visibleAtRangeEnd,
           stats.model.isEmpty,
           let model = msg["model"] as? String {
            stats.model = model
        }
        guard belongsToRange else { return }

        switch type {
        case "assistant":
            stats.messageCount += 1
            if let usage = msg["usage"] as? [String: Any] {
                stats.inputTokens      += intValue(usage["input_tokens"])
                stats.outputTokens     += intValue(usage["output_tokens"])
                stats.cacheReadTokens  += intValue(usage["cache_read_input_tokens"])
                stats.cacheWriteTokens += intValue(usage["cache_creation_input_tokens"])
            }
            if let content = msg["content"] as? [[String: Any]] {
                applyAssistantContent(content, to: &stats,
                                       pendingAgents: &pendingAgents,
                                       pendingTools: &pendingTools,
                                       counter: &counter, timestamp: ts)
            }

        case "user":
            if let content = msg["content"] as? [[String: Any]] {
                if content.contains(where: {
                    ($0["type"] as? String) == "text"
                        && !(($0["text"] as? String) ?? "").isEmpty
                }) {
                    stats.promptCount += 1
                }
                applyUserContent(content, to: &stats,
                                  pendingAgents: &pendingAgents,
                                  pendingTools: &pendingTools,
                                  counter: &counter, timestamp: ts)
            } else if let text = msg["content"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stats.promptCount += 1
                counter += 1
                stats.events.append(SessionEvent(
                    id: "user-\(counter)",
                    timestamp: ts,
                    kind: .userMessage,
                    summary: String(text.prefix(160))
                ))
            }

        default:
            break
        }
    }

    private static func applyAssistantContent(_ content: [[String: Any]],
                                              to stats: inout SessionStats,
                                              pendingAgents: inout Set<String>,
                                              pendingTools: inout [String: Int],
                                              counter: inout Int,
                                              timestamp: String) {
        for block in content {
            guard let blockType = block["type"] as? String else { continue }
            switch blockType {
            case "text":
                let text = (block["text"] as? String) ?? ""
                if !text.isEmpty {
                    counter += 1
                    stats.events.append(SessionEvent(
                        id: "txt-\(counter)",
                        timestamp: timestamp,
                        kind: .assistantText,
                        summary: String(text.prefix(160))
                    ))
                }
            case "thinking":
                counter += 1
                stats.events.append(SessionEvent(
                    id: "think-\(counter)",
                    timestamp: timestamp,
                    kind: .assistantThinking,
                    summary: "Thinking…"
                ))
            case "tool_use":
                stats.toolCalls += 1
                let id = (block["id"] as? String) ?? ""
                let name = (block["name"] as? String) ?? "Tool"
                let input = (block["input"] as? [String: Any]) ?? [:]

                // Event for every tool_use so the live feed shows them.
                counter += 1
                let evt = SessionEvent(
                    id: id.isEmpty ? "tool-\(counter)" : id,
                    timestamp: timestamp,
                    kind: .toolUse,
                    toolName: name,
                    toolUseId: id,
                    summary: summarizeTool(name: name, input: input),
                    completed: false
                )
                stats.events.append(evt)
                if !id.isEmpty {
                    pendingTools[id] = stats.events.count - 1
                }

                // Subagent bookkeeping continues separately so existing UI keeps working.
                if name == "Agent" {
                    let subagentType = (input["subagent_type"] as? String) ?? "default"
                    let description = (input["description"] as? String) ?? ""
                    let prompt = (input["prompt"] as? String) ?? ""
                    stats.agents.append(AgentSpawn(
                        id: id, subagentType: subagentType,
                        description: description, prompt: prompt,
                        timestamp: timestamp, completed: false
                    ))
                    if !id.isEmpty { pendingAgents.insert(id) }
                }
            default:
                break
            }
        }
    }

    private static func applyUserContent(_ content: [[String: Any]],
                                         to stats: inout SessionStats,
                                         pendingAgents: inout Set<String>,
                                         pendingTools: inout [String: Int],
                                         counter: inout Int,
                                         timestamp: String) {
        for block in content {
            let blockType = block["type"] as? String

            // Raw text user message — only when the entire block isn't a tool_result.
            if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                counter += 1
                stats.events.append(SessionEvent(
                    id: "user-\(counter)",
                    timestamp: timestamp,
                    kind: .userMessage,
                    summary: String(text.prefix(160))
                ))
                continue
            }

            guard blockType == "tool_result",
                  let id = block["tool_use_id"] as? String else { continue }

            // Mark matching tool_use event as completed + extract result content
            // (text snippet + image attachment nếu có).
            if let idx = pendingTools[id] {
                stats.events[idx].completed = true
                stats.events[idx].completedAt = timestamp
                let extracted = extractResult(from: block["content"])
                stats.events[idx].resultPreview = extracted.text
                stats.events[idx].imageBase64 = extracted.imageBase64
                stats.events[idx].imageMimeType = extracted.imageMimeType
                stats.events[idx].imageURL = extracted.imageURL
                pendingTools.removeValue(forKey: id)
            }

            // Keep subagent bookkeeping in sync too.
            if pendingAgents.contains(id),
               let aIdx = stats.agents.firstIndex(where: { $0.id == id }) {
                stats.agents[aIdx].completed = true
                stats.agents[aIdx].completedAt = timestamp
                stats.agents[aIdx].resultSnippet = extractResult(from: block["content"]).text
                pendingAgents.remove(id)
            }
        }

        // Fallback: a user message stored as `content: "string"` instead of blocks.
        // (Some Claude Code versions write user prompts this way.)
        // We can't see it from blocks iteration; nothing to do here.
    }

    /// Produce a ≤400-char human description for a tool invocation. Larger cap
    /// than trước (120) để giữ FULL Bash command + Edit diff snippet cho user
    /// drill-down xem session làm gì.
    private static func summarizeTool(name: String, input: [String: Any]) -> String {
        func short(_ s: String, max n: Int = 400) -> String {
            let trimmed = s.replacingOccurrences(of: "\n", with: " ")
            return String(trimmed.prefix(n))
        }
        switch name {
        case "Bash":
            if let cmd = input["command"] as? String { return short(cmd) }
        case "Read":
            if let p = input["file_path"] as? String { return short(p) }
        case "Write":
            let p = (input["file_path"] as? String) ?? ""
            let content = (input["content"] as? String) ?? ""
            return short("\(p) — write \(content.count) chars")
        case "Edit":
            let p = (input["file_path"] as? String) ?? ""
            let old = short(input["old_string"] as? String ?? "", max: 100)
            let new = short(input["new_string"] as? String ?? "", max: 100)
            return short("\(p) • '\(old)' → '\(new)'")
        case "MultiEdit":
            let p = (input["file_path"] as? String) ?? ""
            let n = (input["edits"] as? [[String: Any]])?.count ?? 0
            return short("\(p) — \(n) edits")
        case "NotebookEdit":
            if let p = input["file_path"] as? String { return short(p) }
        case "Glob":
            if let p = input["pattern"] as? String { return short(p) }
        case "Grep":
            let q = (input["pattern"] as? String) ?? ""
            let path = (input["path"] as? String) ?? ""
            return short(path.isEmpty ? q : "\(q)  in  \(path)")
        case "Agent":
            let sub  = (input["subagent_type"] as? String) ?? "default"
            let desc = (input["description"] as? String) ?? ""
            let prompt = short(input["prompt"] as? String ?? "", max: 200)
            return short("\(sub): \(desc) — \(prompt)")
        case "WebFetch":
            if let u = input["url"] as? String { return short(u) }
        case "WebSearch":
            if let q = input["query"] as? String { return short(q) }
        case "AskUserQuestion":
            if let qs = input["questions"] as? [[String: Any]],
               let first = qs.first?["question"] as? String {
                return short(first)
            }
            return "Awaiting user response"
        case "TodoWrite":
            if let todos = input["todos"] as? [[String: Any]] {
                let active = todos.compactMap { ($0["content"] as? String) }
                    .prefix(3).joined(separator: " · ")
                return short("\(todos.count) todos: \(active)")
            }
            return "Updated todo list"
        case "TaskCreate":
            let title = (input["title"] as? String) ?? ""
            let desc = (input["description"] as? String) ?? ""
            return short(title.isEmpty ? desc : "\(title) — \(desc)")
        case "TaskUpdate":
            let id = (input["taskId"] as? String) ?? ""
            let status = (input["status"] as? String) ?? ""
            return short("Task \(id) → \(status)")
        default:
            // mcp__server__tool và các custom tools: ưu tiên các key thường gặp,
            // không thì lấy first non-empty string.
            for key in ["query", "prompt", "url", "command", "text", "input", "path", "file_path", "message"] {
                if let s = input[key] as? String, !s.isEmpty { return short(s) }
            }
            break
        }
        for v in input.values {
            if let s = v as? String, !s.isEmpty { return short(s) }
        }
        return name
    }

    /// Trả về (text snippet ≤600ch, image base64, mime type, image URL) — full
    /// payload từ tool_result. Để renderer (UI) decide hiện gì.
    /// Cap base64 5MB để tránh OOM khi screenshot 4K bị embed.
    private static func extractResult(from raw: Any?)
        -> (text: String?, imageBase64: String?, imageMimeType: String?, imageURL: String?) {
        // String đơn giản — chỉ có text.
        if let s = raw as? String {
            return (String(s.prefix(600)), nil, nil, nil)
        }
        guard let arr = raw as? [[String: Any]] else {
            return (nil, nil, nil, nil)
        }
        // Gom text blocks + tìm image block đầu tiên (nếu có).
        var textPieces: [String] = []
        var imgB64: String?
        var imgMime: String?
        var imgUrl: String?
        for block in arr {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String, !t.isEmpty {
                    textPieces.append(t)
                }
            case "image":
                guard imgB64 == nil && imgUrl == nil,
                      let source = block["source"] as? [String: Any] else { continue }
                if let kind = source["type"] as? String {
                    switch kind {
                    case "base64":
                        if let data = source["data"] as? String, data.count < 5_000_000 {
                            imgB64 = data
                            imgMime = (source["media_type"] as? String) ?? "image/png"
                        }
                    case "url":
                        imgUrl = source["url"] as? String
                    default: break
                    }
                }
            default: break
            }
        }
        let text = textPieces.joined(separator: "\n")
        let textOut = text.isEmpty ? nil : String(text.prefix(600))
        return (textOut, imgB64, imgMime, imgUrl)
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? Int { return n }
        if let n = raw as? Double { return Int(n) }
        if let n = raw as? NSNumber { return n.intValue }
        return 0
    }

    private static func parseISO(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        if let date = isoFractional.date(from: raw) { return date }
        return isoPlain.date(from: raw)
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
