// Read a JSONL transcript line-by-line and aggregate into SessionStats.
// Mirrors the logic in Python claude_watch.parser.parse_session.

import Foundation

public enum JsonlParser {

    /// Parse one JSONL transcript into a SessionStats.
    /// Malformed lines are skipped (Claude Code can write partial lines while
    /// a session is in flight — never abort the whole parse on one bad line).
    public static func parseSession(at url: URL) -> SessionStats {
        var stats = SessionStats(
            sessionId: url.deletingPathExtension().lastPathComponent,
            projectSlug: url.deletingLastPathComponent().lastPathComponent,
            filePath: url
        )

        guard let handle = try? FileHandle(forReadingFrom: url) else { return stats }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd() else { return stats }

        var pendingAgentIds: Set<String> = []
        var pendingToolUseIds: [String: Int] = [:]  // tool_use_id → events[index]
        var eventCounter = 0

        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let bytes = buf.bindMemory(to: UInt8.self)
            var lineStart = 0
            for i in 0..<bytes.count {
                if bytes[i] == 0x0A {   // '\n'
                    if i > lineStart {
                        let slice = Data(bytes[lineStart..<i])
                        applyLine(slice, to: &stats,
                                  pendingAgents: &pendingAgentIds,
                                  pendingTools: &pendingToolUseIds,
                                  counter: &eventCounter)
                    }
                    lineStart = i + 1
                }
            }
            if lineStart < bytes.count {
                let slice = Data(bytes[lineStart..<bytes.count])
                applyLine(slice, to: &stats,
                          pendingAgents: &pendingAgentIds,
                          pendingTools: &pendingToolUseIds,
                          counter: &eventCounter)
            }
        }

        // Cap events to window size (keep most recent).
        if stats.events.count > SessionStats.eventWindowSize {
            stats.events = Array(stats.events.suffix(SessionStats.eventWindowSize))
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
                                  counter: inout Int) {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let type = raw["type"] as? String
        // CLI dùng "timestamp"; Desktop audit JSONL dùng "_audit_timestamp".
        let ts = (raw["timestamp"] as? String)
            ?? (raw["_audit_timestamp"] as? String) ?? ""
        if !ts.isEmpty {
            if stats.startedAt.isEmpty { stats.startedAt = ts }
            stats.lastEventAt = ts
        }

        guard let msg = raw["message"] as? [String: Any] else { return }

        switch type {
        case "assistant":
            stats.messageCount += 1
            if stats.model.isEmpty, let model = msg["model"] as? String {
                stats.model = model
            }
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
                applyUserContent(content, to: &stats,
                                  pendingAgents: &pendingAgents,
                                  pendingTools: &pendingTools,
                                  counter: &counter, timestamp: ts)
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

            // Mark matching tool_use event as completed.
            if let idx = pendingTools[id] {
                stats.events[idx].completed = true
                stats.events[idx].completedAt = timestamp
                stats.events[idx].resultPreview = extractResultSnippet(from: block["content"])
                pendingTools.removeValue(forKey: id)
            }

            // Keep subagent bookkeeping in sync too.
            if pendingAgents.contains(id),
               let aIdx = stats.agents.firstIndex(where: { $0.id == id }) {
                stats.agents[aIdx].completed = true
                stats.agents[aIdx].completedAt = timestamp
                stats.agents[aIdx].resultSnippet = extractResultSnippet(from: block["content"])
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

    /// `content` of a tool_result can be either a String or an array of
    /// `{type: "text", text: "..."}` blocks. Normalise to a short snippet.
    private static func extractResultSnippet(from raw: Any?) -> String? {
        if let s = raw as? String {
            return String(s.prefix(600))
        }
        if let arr = raw as? [[String: Any]] {
            let joined = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !joined.isEmpty { return String(joined.prefix(600)) }
        }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? Int { return n }
        if let n = raw as? Double { return Int(n) }
        if let n = raw as? NSNumber { return n.intValue }
        return 0
    }
}
