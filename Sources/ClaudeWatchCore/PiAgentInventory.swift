import Foundation

public enum PiAgentInventory {
    public static let defaultRoot = NSHomeDirectory() + "/.pi/agent/sessions"

    public static func list(in range: ClosedRange<Date>, root: String = defaultRoot) -> [SessionSummary] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root),
              let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else {
            return []
        }

        var out: [SessionSummary] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if ProjectPath.mtime(of: url) < range.lowerBound { continue }
            if let summary = PiAgentJsonlParser.summarize(file: url, range: range) {
                out.append(summary)
            }
        }
        return out
    }
}

public enum PiAgentJsonlParser {
    public static func summarize(file: URL, range: ClosedRange<Date>) -> SessionSummary? {
        let parsed = parse(file: file, includeEvents: false)
        let mtime = ProjectPath.mtime(of: file)
        let first = parsed.firstTimestamp ?? mtime
        let last = parsed.lastTimestamp ?? mtime
        guard last >= range.lowerBound, first <= range.upperBound else { return nil }

        let family = ModelFamily.from(modelId: parsed.model)
        let estimatedCost = Pricing.cost(
            family: family,
            inputTokens: parsed.inputTokens,
            outputTokens: parsed.outputTokens + parsed.reasoningTokens,
            cacheReadTokens: parsed.cacheReadTokens,
            cacheWriteTokens: parsed.cacheWriteTokens
        )

        return SessionSummary(
            id: parsed.sessionId,
            sessionTitle: parsed.sessionTitle,
            projectDisplay: parsed.projectDisplay,
            source: .piagent,
            model: parsed.model,
            modelFamily: family,
            inputTokens: parsed.inputTokens,
            outputTokens: parsed.outputTokens,
            reasoningTokens: parsed.reasoningTokens,
            cacheReadTokens: parsed.cacheReadTokens,
            cacheWriteTokens: parsed.cacheWriteTokens,
            cost: parsed.exactCost > 0 ? parsed.exactCost : estimatedCost,
            firstTimestamp: parsed.firstTimestamp,
            lastTimestamp: parsed.lastTimestamp,
            promptCount: parsed.promptCount,
            toolCallCount: parsed.toolCalls,
            fileURL: file,
            agentCount: parsed.agentCount,
            thinkingLevel: parsed.thinkingLevel
        )
    }

    public static func parseSession(at file: URL) -> SessionStats {
        let parsed = parse(file: file, includeEvents: true)
        var stats = SessionStats(
            sessionId: parsed.sessionId,
            projectSlug: parsed.projectSlug,
            filePath: file
        )
        stats.sessionName = parsed.sessionTitle
        stats.model = parsed.model
        stats.thinkingLevel = parsed.thinkingLevel
        stats.startedAt = parsed.firstTimestampString
        stats.lastEventAt = parsed.lastTimestampString
        stats.messageCount = parsed.messageCount
        stats.inputTokens = parsed.inputTokens
        stats.outputTokens = parsed.outputTokens
        stats.reasoningTokens = parsed.reasoningTokens
        stats.cacheReadTokens = parsed.cacheReadTokens
        stats.cacheWriteTokens = parsed.cacheWriteTokens
        stats.toolCalls = parsed.toolCalls
        stats.events = parsed.events
        if stats.events.count > SessionStats.eventWindowSize {
            stats.events = Array(stats.events.suffix(SessionStats.eventWindowSize))
        }
        return stats
    }

    public static func extractPrompts(from file: URL,
                                      range: ClosedRange<Date>) -> [PromptRecord] {
        guard !isSubagentFile(file) else { return [] }
        let parsed = parse(file: file, includeEvents: false)
        return parsed.prompts.filter { range.contains($0.timestamp) }
    }

    private struct Parsed {
        var sessionId: String
        var sessionTitle: String?
        var projectSlug: String
        var projectDisplay: String
        var model: String
        var thinkingLevel: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var firstTimestampString: String
        var lastTimestampString: String
        var messageCount: Int
        var inputTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var exactCost: Double
        var promptCount: Int
        var toolCalls: Int
        var agentCount: Int
        var events: [SessionEvent]
        var prompts: [PromptRecord]
    }

    private static func parse(file: URL, includeEvents: Bool) -> Parsed {
        let fallbackId = file.deletingPathExtension().lastPathComponent
        var sessionId = fallbackId
        var sessionTitle: String?
        var cwd: String?
        var projectName: String?
        var model = ""
        var thinkingLevel: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var firstTimestampString = ""
        var lastTimestampString = ""
        var messageCount = 0
        var inputTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0
        var exactCost = 0.0
        var promptCount = 0
        var toolCalls = 0
        var agentCount = isSubagentFile(file) ? 1 : 0
        var events: [SessionEvent] = []
        var prompts: [PromptRecord] = []
        var pendingTools: [String: Int] = [:]
        var eventCounter = 0
        var lineIndex = 0

        JsonlLineReader.forEachLineData(at: file) { lineData in
            lineIndex += 1
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }

            let tsString = obj["timestamp"] as? String ?? ""
            if let ts = parseISO(tsString) {
                if firstTimestamp == nil || ts < firstTimestamp! {
                    firstTimestamp = ts
                    firstTimestampString = tsString
                }
                if lastTimestamp == nil || ts > lastTimestamp! {
                    lastTimestamp = ts
                    lastTimestampString = tsString
                }
            }

            switch obj["type"] as? String {
            case "session":
                if let id = obj["id"] as? String, !id.isEmpty { sessionId = id }
                if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }

            case "model_change":
                if let m = obj["modelId"] as? String, !m.isEmpty { model = m }

            case "thinking_level_change":
                if let level = obj["thinkingLevel"] as? String, !level.isEmpty {
                    thinkingLevel = level
                }

            case "session_info":
                if let name = obj["name"] as? String, !name.isEmpty {
                    sessionTitle = normalizedSessionTitle(name)
                    if name.hasPrefix("pi:") {
                        projectName = String(name.dropFirst(3))
                    } else if name.hasPrefix("subagent-") {
                        agentCount = max(agentCount, 1)
                    }
                }

            case "message":
                guard let msg = obj["message"] as? [String: Any],
                      let role = msg["role"] as? String else { return }
                if model.isEmpty, let m = msg["model"] as? String, !m.isEmpty {
                    model = m
                }

                switch role {
                case "user":
                    let text = extractText(from: msg["content"])
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    promptCount += 1
                    messageCount += 1
                    if includeEvents {
                        eventCounter += 1
                        events.append(SessionEvent(
                            id: "pi-user-\(eventCounter)",
                            timestamp: tsString,
                            kind: .userMessage,
                            summary: short(trimmed, max: 160)
                        ))
                    }
                    if !isSubagentFile(file),
                       let ts = parseISO(tsString),
                       !CoachingScan.isLikelySystemInjection(trimmed) {
                        prompts.append(PromptRecord(
                            id: "pi-\(sessionId)-\(lineIndex)",
                            timestamp: ts,
                            projectSlug: cwd ?? projectName ?? file.deletingLastPathComponent().lastPathComponent,
                            projectDisplay: displayProject(cwd: cwd, projectName: projectName),
                            sessionTitle: sessionTitle,
                            sessionUuid: sessionId,
                            text: trimmed,
                            score: PromptScorer.score(trimmed),
                            source: .piagent
                        ))
                    }

                case "assistant":
                    messageCount += 1
                    if let usage = msg["usage"] as? [String: Any] {
                        inputTokens += intValue(usage["input"])
                        outputTokens += intValue(usage["output"])
                        reasoningTokens += intValue(usage["reasoning"])
                        cacheReadTokens += intValue(usage["cacheRead"])
                        cacheWriteTokens += intValue(usage["cacheWrite"])
                        if let cost = usage["cost"] as? [String: Any] {
                            exactCost += doubleValue(cost["total"])
                        }
                    }
                    applyAssistantContent(
                        msg["content"],
                        timestamp: tsString,
                        includeEvents: includeEvents,
                        toolCalls: &toolCalls,
                        agentCount: &agentCount,
                        events: &events,
                        pendingTools: &pendingTools,
                        eventCounter: &eventCounter
                    )

                case "toolResult":
                    guard includeEvents,
                          let id = msg["toolCallId"] as? String,
                          let idx = pendingTools[id] else { return }
                    events[idx].completed = true
                    events[idx].completedAt = tsString
                    events[idx].resultPreview = extractResult(from: msg["content"])
                    pendingTools.removeValue(forKey: id)

                default:
                    break
                }

            default:
                break
            }
        }

        return Parsed(
            sessionId: sessionId,
            sessionTitle: sessionTitle,
            projectSlug: cwd ?? projectName ?? file.deletingLastPathComponent().lastPathComponent,
            projectDisplay: displayProject(cwd: cwd, projectName: projectName),
            model: model,
            thinkingLevel: thinkingLevel,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            firstTimestampString: firstTimestampString,
            lastTimestampString: lastTimestampString,
            messageCount: messageCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            exactCost: exactCost,
            promptCount: promptCount,
            toolCalls: toolCalls,
            agentCount: agentCount,
            events: events,
            prompts: prompts.map { $0.withSessionTitle(sessionTitle) }
        )
    }

    private static func normalizedSessionTitle(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("pi:") {
            name = String(name.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? nil : name
    }

    private static func applyAssistantContent(_ raw: Any?,
                                              timestamp: String,
                                              includeEvents: Bool,
                                              toolCalls: inout Int,
                                              agentCount: inout Int,
                                              events: inout [SessionEvent],
                                              pendingTools: inout [String: Int],
                                              eventCounter: inout Int) {
        guard let blocks = raw as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                guard includeEvents, !text.isEmpty else { continue }
                eventCounter += 1
                events.append(SessionEvent(
                    id: "pi-text-\(eventCounter)",
                    timestamp: timestamp,
                    kind: .assistantText,
                    summary: short(text, max: 160)
                ))

            case "thinking":
                guard includeEvents else { continue }
                let thinking = block["thinking"] as? String ?? ""
                eventCounter += 1
                events.append(SessionEvent(
                    id: "pi-think-\(eventCounter)",
                    timestamp: timestamp,
                    kind: .assistantThinking,
                    summary: thinking.isEmpty ? "Thinking..." : short(thinking, max: 160)
                ))

            case "toolCall":
                toolCalls += 1
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? "Tool"
                if name == "subagent" { agentCount += 1 }
                guard includeEvents else { continue }
                eventCounter += 1
                let eventId = id.isEmpty ? "pi-tool-\(eventCounter)" : id
                events.append(SessionEvent(
                    id: eventId,
                    timestamp: timestamp,
                    kind: .toolUse,
                    toolName: name,
                    toolUseId: id,
                    summary: summarizeTool(name: name, arguments: block["arguments"]),
                    completed: false
                ))
                if !id.isEmpty { pendingTools[id] = events.count - 1 }

            default:
                break
            }
        }
    }

    private static func displayProject(cwd: String?, projectName: String?) -> String {
        if let cwd, !cwd.isEmpty { return cwd }
        if let projectName, !projectName.isEmpty { return "PiAgent: \(projectName)" }
        return "(unknown)"
    }

    private static func extractText(from raw: Any?) -> String {
        if let s = raw as? String { return s }
        guard let blocks = raw as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String,
                  !text.isEmpty else { return nil }
            return text
        }.joined(separator: "\n")
    }

    private static func extractResult(from raw: Any?) -> String? {
        let text = extractText(from: raw)
        if !text.isEmpty { return short(text, max: 600) }
        if let s = raw as? String, !s.isEmpty { return short(s, max: 600) }
        return nil
    }

    private static func summarizeTool(name: String, arguments: Any?) -> String {
        if let dict = arguments as? [String: Any] {
            for key in ["command", "path", "file_path", "query", "prompt", "task", "url", "text", "message"] {
                if let value = dict[key] as? String, !value.isEmpty {
                    return short(value, max: 400)
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return short(text, max: 400)
            }
        }
        if let text = arguments as? String, !text.isEmpty { return short(text, max: 400) }
        return name
    }

    private static func isSubagentFile(_ file: URL) -> Bool {
        file.pathComponents.contains("subagent")
    }

    private static func short(_ s: String, max n: Int) -> String {
        String(s.replacingOccurrences(of: "\n", with: " ").prefix(n))
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? Int { return n }
        if let n = raw as? Double { return Int(n) }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String, let n = Int(s) { return n }
        return 0
    }

    private static func doubleValue(_ raw: Any?) -> Double {
        if let n = raw as? Double { return n }
        if let n = raw as? Int { return Double(n) }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String, let n = Double(s) { return n }
        return 0
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
