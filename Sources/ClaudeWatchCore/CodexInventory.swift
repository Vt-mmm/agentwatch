import Foundation

public enum CodexInventory {
    public static let defaultRoot = NSHomeDirectory() + "/.codex/sessions"
    public static let defaultArchivedRoot = NSHomeDirectory() + "/.codex/archived_sessions"

    public static func list(in range: ClosedRange<Date>, root: String = defaultRoot) -> [SessionSummary] {
        let roots = root == defaultRoot ? [defaultRoot, defaultArchivedRoot] : [root]
        return roots.flatMap { listOneRoot(in: range, root: $0) }
    }

    private static func listOneRoot(in range: ClosedRange<Date>, root: String) -> [SessionSummary] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root),
              let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else {
            return []
        }

        var out: [SessionSummary] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            if ProjectPath.mtime(of: file) < range.lowerBound { continue }
            if let summary = CodexJsonlParser.summarize(file: file, range: range) {
                out.append(summary)
            }
        }
        return out
    }
}

public enum CodexJsonlParser {
    public static func summarize(file: URL, range: ClosedRange<Date>) -> SessionSummary? {
        scan(file: file, range: range).summary
    }

    /// Decode summary and prompts in one streaming pass.
    public static func scan(file: URL,
                            range: ClosedRange<Date>) -> AgentLogScanResult {
        let parsed = parse(file: file, includeEvents: false, range: range)
        let summary = makeSummary(from: parsed, file: file)
        let prompts = parsed.isSubagent ? [] : parsed.prompts
        return AgentLogScanResult(summary: summary, prompts: prompts)
    }

    private static func makeSummary(from parsed: Parsed, file: URL) -> SessionSummary? {
        guard parsed.firstTimestamp != nil,
              parsed.lastTimestamp != nil else {
            return nil
        }

        let family: ModelFamily = parsed.model.lowercased() == "openai"
            ? .gpt
            : ModelFamily.from(modelId: parsed.model)
        let quote = Pricing.quote(forModelId: parsed.model)
        let cost = quote.map {
            Pricing.cost(
                quote: $0,
                inputTokens: max(0, parsed.inputTokens - parsed.cacheReadTokens),
                outputTokens: parsed.outputTokens,
                cacheReadTokens: parsed.cacheReadTokens,
                cacheWriteTokens: parsed.cacheWriteTokens
            )
        } ?? 0
        let costBasis: UsageCostBasis = quote == nil ? .unavailable : .estimated
        var warnings = parsed.dataWarnings
        if quote == nil {
            warnings.append("No versioned price quote for model '\(parsed.model)'; cost is unavailable.")
        }

        return SessionSummary(
            id: parsed.sessionId,
            projectDisplay: parsed.projectDisplay,
            source: .codex,
            model: parsed.model.isEmpty ? "openai" : parsed.model,
            modelFamily: family,
            inputTokens: parsed.inputTokens,
            outputTokens: parsed.outputTokens,
            reasoningTokens: parsed.reasoningTokens,
            cacheReadTokens: parsed.cacheReadTokens,
            cacheWriteTokens: parsed.cacheWriteTokens,
            cost: costBasis == .unavailable ? 0 : cost,
            firstTimestamp: parsed.firstTimestamp,
            lastTimestamp: parsed.lastTimestamp,
            promptCount: parsed.promptCount,
            toolCallCount: parsed.toolCalls,
            fileURL: file,
            agentCount: parsed.isSubagent ? 1 : 0,
            thinkingLevel: parsed.thinkingLevel,
            tokenAccountingRule: .inclusiveBreakdowns,
            costBasis: costBasis,
            usageScope: parsed.usageScope,
            dataWarnings: warnings
        )
    }

    public static func parseSession(
        at file: URL,
        range: ClosedRange<Date>? = nil,
        eventLimit: Int? = SessionStats.eventWindowSize
    ) -> SessionStats {
        let parsed = parse(file: file, includeEvents: true, range: range)
        var stats = SessionStats(
            sessionId: parsed.sessionId,
            projectSlug: parsed.projectDisplay,
            filePath: file
        )
        stats.model = parsed.model
        stats.thinkingLevel = parsed.thinkingLevel
        stats.startedAt = parsed.firstTimestampString
        stats.lastEventAt = parsed.lastTimestampString
        stats.messageCount = parsed.messageCount
        stats.promptCount = parsed.promptCount
        stats.inputTokens = parsed.inputTokens
        stats.outputTokens = parsed.outputTokens
        stats.reasoningTokens = parsed.reasoningTokens
        stats.cacheReadTokens = parsed.cacheReadTokens
        stats.cacheWriteTokens = parsed.cacheWriteTokens
        stats.toolCalls = parsed.toolCalls
        stats.tokenAccountingRule = .inclusiveBreakdowns
        stats.events = parsed.events
        if let eventLimit, stats.events.count > eventLimit {
            stats.events = Array(stats.events.suffix(max(0, eventLimit)))
        }
        return stats
    }

    public static func extractPrompts(from file: URL,
                                      range: ClosedRange<Date>) -> [PromptRecord] {
        scan(file: file, range: range).prompts
    }

    private struct Parsed {
        var sessionId: String
        var projectDisplay: String
        var model: String
        var thinkingLevel: String?
        var isSubagent: Bool
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
        var promptCount: Int
        var toolCalls: Int
        var events: [SessionEvent]
        var prompts: [PromptRecord]
        var usageScope: UsageScopePrecision
        var dataWarnings: [String]
    }

    private struct UsageCheckpoint {
        let timestamp: Date
        let input: Int
        let output: Int
        let reasoning: Int
        let cacheRead: Int
        let cacheWrite: Int
    }

    private static func parse(file: URL,
                              includeEvents: Bool,
                              range: ClosedRange<Date>? = nil) -> Parsed {
        let fallbackId = file.deletingPathExtension().lastPathComponent
        var sessionId = fallbackId
        var cwd = "(unknown)"
        var model = ""
        var thinkingLevel: String?
        var provider = ""
        var isSubagent = false
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var fullFirstTimestamp: Date?
        var firstTimestampString = ""
        var lastTimestampString = ""
        var messageCount = 0
        var promptCount = 0
        var toolCalls = 0
        var usageCheckpoints: [UsageCheckpoint] = []
        var events: [SessionEvent] = []
        var prompts: [PromptRecord] = []
        var pendingTools: [String: Int] = [:]
        var promptDedupe = PromptDedupeState()
        var lineIndex = 0
        var eventCounter = 0

        JsonlLineReader.forEachLineData(at: file) { lineData in
            lineIndex += 1
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }

            let tsString = obj["timestamp"] as? String ?? ""
            let timestamp = parseISO(tsString)
            if let ts = timestamp {
                if fullFirstTimestamp == nil || ts < fullFirstTimestamp! {
                    fullFirstTimestamp = ts
                }
            }
            let belongsToRange = range == nil
                || timestamp.map { range!.contains($0) } == true
            let visibleAtRangeEnd = range == nil
                || timestamp.map { $0 <= range!.upperBound } == true
            if let ts = timestamp, belongsToRange {
                if firstTimestamp == nil || ts < firstTimestamp! {
                    firstTimestamp = ts
                    firstTimestampString = tsString
                }
                if lastTimestamp == nil || ts > lastTimestamp! {
                    lastTimestamp = ts
                    lastTimestampString = tsString
                }
            }
            guard visibleAtRangeEnd else { return }

            let kind = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any] ?? [:]

            switch kind {
            case "session_meta":
                if let id = payload["id"] as? String, !id.isEmpty { sessionId = id }
                if let c = payload["cwd"] as? String, !c.isEmpty { cwd = c }
                if let p = payload["model_provider"] as? String, !p.isEmpty { provider = p }
                if (payload["thread_source"] as? String) == "subagent" { isSubagent = true }
                if let source = payload["source"] as? [String: Any],
                   source["subagent"] != nil {
                    isSubagent = true
                }

            case "turn_context":
                if let c = payload["cwd"] as? String, !c.isEmpty { cwd = c }
                if let m = payload["model"] as? String, !m.isEmpty { model = m }
                if let effort = thinkingEffort(from: payload) {
                    thinkingLevel = effort
                }

            case "event_msg":
                if payload["type"] as? String == "token_count",
                   let timestamp,
                   let checkpoint = usageCheckpoint(payload: payload, timestamp: timestamp) {
                    usageCheckpoints.append(checkpoint)
                } else {
                    applyEventMessage(
                        payload,
                        timestamp: tsString,
                        timestampDate: timestamp,
                        file: file,
                        sessionId: sessionId,
                        cwd: cwd,
                        lineIndex: lineIndex,
                        isSubagent: isSubagent,
                        capture: belongsToRange,
                        includeEvents: includeEvents,
                        promptCount: &promptCount,
                        events: &events,
                        prompts: &prompts,
                        promptDedupe: &promptDedupe,
                        eventCounter: &eventCounter
                    )
                }

            case "response_item":
                applyResponseItem(
                    payload,
                    timestamp: tsString,
                    timestampDate: timestamp,
                    file: file,
                    sessionId: sessionId,
                    cwd: cwd,
                    lineIndex: lineIndex,
                    isSubagent: isSubagent,
                    capture: belongsToRange,
                    includeEvents: includeEvents,
                    promptCount: &promptCount,
                    messageCount: &messageCount,
                    toolCalls: &toolCalls,
                    events: &events,
                    prompts: &prompts,
                    pendingTools: &pendingTools,
                    promptDedupe: &promptDedupe,
                    eventCounter: &eventCounter
                )

            default:
                break
            }
        }

        let scopedUsage = usage(
            from: usageCheckpoints,
            range: range,
            fullFirstTimestamp: fullFirstTimestamp
        )

        return Parsed(
            sessionId: sessionId,
            projectDisplay: cwd,
            model: model.isEmpty ? provider : model,
            thinkingLevel: thinkingLevel,
            isSubagent: isSubagent,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            firstTimestampString: firstTimestampString,
            lastTimestampString: lastTimestampString,
            messageCount: messageCount,
            inputTokens: scopedUsage.input,
            outputTokens: scopedUsage.output,
            reasoningTokens: scopedUsage.reasoning,
            cacheReadTokens: scopedUsage.cacheRead,
            cacheWriteTokens: scopedUsage.cacheWrite,
            promptCount: promptCount,
            toolCalls: toolCalls,
            events: events,
            prompts: prompts,
            usageScope: scopedUsage.precision,
            dataWarnings: scopedUsage.warning.map { [$0] } ?? []
        )
    }

    private static func applyEventMessage(_ payload: [String: Any],
                                          timestamp: String,
                                          timestampDate: Date?,
                                          file: URL,
                                          sessionId: String,
                                          cwd: String,
                                          lineIndex: Int,
                                          isSubagent: Bool,
                                          capture: Bool,
                                          includeEvents: Bool,
                                          promptCount: inout Int,
                                          events: inout [SessionEvent],
                                          prompts: inout [PromptRecord],
                                          promptDedupe: inout PromptDedupeState,
                                          eventCounter: inout Int) {
        switch payload["type"] as? String {
        case "user_message":
            let text = promptText(from: payload)
            recordUserPrompt(
                text: text,
                timestamp: timestamp,
                timestampDate: timestampDate,
                file: file,
                sessionId: sessionId,
                cwd: cwd,
                lineIndex: lineIndex,
                isSubagent: isSubagent,
                capture: capture,
                includeEvents: includeEvents && capture,
                promptCount: &promptCount,
                events: &events,
                prompts: &prompts,
                promptDedupe: &promptDedupe,
                eventCounter: &eventCounter
            )

        case "agent_message":
            guard capture, includeEvents else { return }
            let text = promptText(from: payload)
            guard !text.isEmpty else { return }
            eventCounter += 1
            events.append(SessionEvent(
                id: "codex-agent-\(eventCounter)",
                timestamp: timestamp,
                kind: .assistantText,
                summary: short(text, max: 160)
            ))

        default:
            break
        }
    }

    private static func applyResponseItem(_ payload: [String: Any],
                                          timestamp: String,
                                          timestampDate: Date?,
                                          file: URL,
                                          sessionId: String,
                                          cwd: String,
                                          lineIndex: Int,
                                          isSubagent: Bool,
                                          capture: Bool,
                                          includeEvents: Bool,
                                          promptCount: inout Int,
                                          messageCount: inout Int,
                                          toolCalls: inout Int,
                                          events: inout [SessionEvent],
                                          prompts: inout [PromptRecord],
                                          pendingTools: inout [String: Int],
                                          promptDedupe: inout PromptDedupeState,
                                          eventCounter: inout Int) {
        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String ?? ""
            let text = responseMessageText(from: payload)
            if role == "user" {
                recordUserPrompt(
                    text: text,
                    timestamp: timestamp,
                    timestampDate: timestampDate,
                    file: file,
                    sessionId: sessionId,
                    cwd: cwd,
                    lineIndex: lineIndex,
                    isSubagent: isSubagent,
                    capture: capture,
                    includeEvents: includeEvents && capture,
                    promptCount: &promptCount,
                    events: &events,
                    prompts: &prompts,
                    promptDedupe: &promptDedupe,
                    eventCounter: &eventCounter
                )
            } else if role == "assistant" {
                guard capture else { return }
                messageCount += 1
                guard includeEvents, !text.isEmpty else { return }
                eventCounter += 1
                events.append(SessionEvent(
                    id: "codex-text-\(eventCounter)",
                    timestamp: timestamp,
                    kind: .assistantText,
                    summary: short(text, max: 160)
                ))
            }

        case "reasoning":
            guard capture, includeEvents else { return }
            eventCounter += 1
            events.append(SessionEvent(
                id: "codex-think-\(eventCounter)",
                timestamp: timestamp,
                kind: .assistantThinking,
                summary: reasoningSummary(from: payload)
            ))

        case "function_call", "custom_tool_call":
            guard capture else { return }
            toolCalls += 1
            guard includeEvents else { return }
            let id = payload["call_id"] as? String
                ?? payload["id"] as? String
                ?? "codex-tool-\(lineIndex)"
            let name = payload["name"] as? String ?? "Tool"
            eventCounter += 1
            events.append(SessionEvent(
                id: id,
                timestamp: timestamp,
                kind: .toolUse,
                toolName: name,
                toolUseId: id,
                summary: summarizeTool(name: name, payload: payload),
                completed: false
            ))
            pendingTools[id] = events.count - 1

        case "function_call_output", "custom_tool_call_output":
            guard capture, includeEvents,
                  let id = payload["call_id"] as? String ?? payload["id"] as? String,
                  let idx = pendingTools[id] else { return }
            events[idx].completed = true
            events[idx].completedAt = timestamp
            events[idx].resultPreview = extractOutput(from: payload)
            pendingTools.removeValue(forKey: id)

        default:
            break
        }
    }

    private static func recordUserPrompt(text rawText: String,
                                         timestamp: String,
                                         timestampDate: Date?,
                                         file: URL,
                                         sessionId: String,
                                         cwd: String,
                                         lineIndex: Int,
                                         isSubagent: Bool,
                                         capture: Bool,
                                         includeEvents: Bool,
                                         promptCount: inout Int,
                                         events: inout [SessionEvent],
                                         prompts: inout [PromptRecord],
                                         promptDedupe: inout PromptDedupeState,
                                         eventCounter: inout Int) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !isDuplicateUserPrompt(
            text,
            sessionId: sessionId,
            timestampDate: timestampDate,
            state: &promptDedupe
        ) else {
            return
        }
        guard capture else { return }
        promptCount += 1
        if includeEvents {
            eventCounter += 1
            events.append(SessionEvent(
                id: "codex-user-\(eventCounter)",
                timestamp: timestamp,
                kind: .userMessage,
                summary: short(text, max: 160)
            ))
        }
        guard !isSubagent,
              let timestampDate,
              !CoachingScan.isLikelySystemInjection(text) else {
            return
        }
        prompts.append(PromptRecord(
            id: "codex-\(file.deletingPathExtension().lastPathComponent)-\(lineIndex)",
            timestamp: timestampDate,
            projectSlug: cwd,
            projectDisplay: cwd,
            sessionUuid: sessionId,
            text: text,
            score: PromptScorer.score(text),
            source: .codex
        ))
    }

    private static func usageCheckpoint(payload: [String: Any],
                                        timestamp: Date) -> UsageCheckpoint? {
        guard let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else {
            return nil
        }
        return UsageCheckpoint(
            timestamp: timestamp,
            input: intValue(total["input_tokens"]),
            output: intValue(total["output_tokens"]),
            reasoning: intValue(total["reasoning_output_tokens"]),
            cacheRead: intValue(total["cached_input_tokens"]),
            cacheWrite: intValue(total["cache_write_input_tokens"])
        )
    }

    private static func usage(
        from checkpoints: [UsageCheckpoint],
        range: ClosedRange<Date>?,
        fullFirstTimestamp: Date?
    ) -> (
        input: Int,
        output: Int,
        reasoning: Int,
        cacheRead: Int,
        cacheWrite: Int,
        precision: UsageScopePrecision,
        warning: String?
    ) {
        let ordered = checkpoints.sorted { $0.timestamp < $1.timestamp }
        guard let range else {
            guard let last = ordered.last else {
                return (0, 0, 0, 0, 0, .wholeSession, nil)
            }
            return (
                last.input, last.output, last.reasoning,
                last.cacheRead, last.cacheWrite,
                .wholeSession, nil
            )
        }

        guard let ending = ordered.last(where: { $0.timestamp <= range.upperBound }) else {
            return (
                0, 0, 0, 0, 0, .partialRange,
                "Codex log has no usage checkpoint at or before the selected range end."
            )
        }
        guard ending.timestamp >= range.lowerBound else {
            return (0, 0, 0, 0, 0, .exactRange, nil)
        }

        let baseline = ordered.last(where: { $0.timestamp < range.lowerBound })
        let sessionStartedInsideRange = fullFirstTimestamp.map {
            $0 >= range.lowerBound
        } ?? false

        if let baseline {
            return (
                max(0, ending.input - baseline.input),
                max(0, ending.output - baseline.output),
                max(0, ending.reasoning - baseline.reasoning),
                max(0, ending.cacheRead - baseline.cacheRead),
                max(0, ending.cacheWrite - baseline.cacheWrite),
                .exactRange,
                nil
            )
        }

        if sessionStartedInsideRange {
            return (
                ending.input, ending.output, ending.reasoning,
                ending.cacheRead, ending.cacheWrite,
                .exactRange, nil
            )
        }

        return (
            ending.input, ending.output, ending.reasoning,
            ending.cacheRead, ending.cacheWrite,
            .partialRange,
            "Codex cumulative usage has no checkpoint before the selected range; values may include earlier activity."
        )
    }

    private struct PromptDedupeState {
        var lastTimestampByKey: [String: Date] = [:]
        var timelessKeys: Set<String> = []
    }

    private static func isDuplicateUserPrompt(_ text: String,
                                              sessionId: String,
                                              timestampDate: Date?,
                                              state: inout PromptDedupeState) -> Bool {
        let key = "\(sessionId)|\(normalizedPromptText(text))"
        guard let timestampDate else {
            if state.timelessKeys.contains(key) { return true }
            state.timelessKeys.insert(key)
            return false
        }

        defer { state.lastTimestampByKey[key] = timestampDate }
        guard let previous = state.lastTimestampByKey[key] else { return false }
        return abs(timestampDate.timeIntervalSince(previous)) <= 3
    }

    private static func normalizedPromptText(_ text: String) -> String {
        let compact = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return String(compact.prefix(800))
    }

    private static func promptText(from payload: [String: Any]) -> String {
        var pieces: [String] = []
        if let message = payload["message"] as? String {
            pieces.append(message)
        }
        if let text = payload["text"] as? String {
            pieces.append(text)
        }
        if let content = payload["content"] as? String {
            pieces.append(content)
        }
        if let blocks = payload["content"] as? [[String: Any]] {
            pieces.append(contentsOf: textPieces(from: blocks))
        }
        return pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func responseMessageText(from payload: [String: Any]) -> String {
        if let text = payload["text"] as? String { return text }
        if let content = payload["content"] as? String { return content }
        if let blocks = payload["content"] as? [[String: Any]] {
            return textPieces(from: blocks).joined(separator: "\n")
        }
        return ""
    }

    private static func textPieces(from blocks: [[String: Any]]) -> [String] {
        blocks.flatMap { textPieces(from: $0) }
    }

    private static func textPieces(from block: [String: Any]) -> [String] {
        let type = block["type"] as? String ?? ""
        if type == "input_image" || type == "image_url" { return [] }

        var pieces: [String] = []
        if let text = block["text"] as? String {
            pieces.append(text)
        }
        if let text = block["input_text"] as? String {
            pieces.append(text)
        }
        if let text = block["content"] as? String {
            pieces.append(text)
        }
        if let nested = block["content"] as? [[String: Any]] {
            pieces.append(contentsOf: textPieces(from: nested))
        }
        return pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func thinkingEffort(from payload: [String: Any]) -> String? {
        for key in ["effort", "model_reasoning_effort", "reasoning_effort", "thinkingLevel"] {
            if let value = payload[key] as? String {
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private static func reasoningSummary(from payload: [String: Any]) -> String {
        guard let summary = payload["summary"] as? [[String: Any]] else { return "Reasoning..." }
        let text = summary.compactMap { item -> String? in
            if let text = item["text"] as? String { return text }
            if let text = item["summary_text"] as? String { return text }
            return nil
        }.joined(separator: " ")
        return text.isEmpty ? "Reasoning..." : short(text, max: 160)
    }

    private static func summarizeTool(name: String, payload: [String: Any]) -> String {
        for key in ["input", "arguments", "command", "query", "path", "url", "prompt"] {
            if let text = payload[key] as? String, !text.isEmpty {
                return short(text, max: 400)
            }
            if let dict = payload[key] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return short(text, max: 400)
            }
        }
        return name
    }

    private static func extractOutput(from payload: [String: Any]) -> String? {
        for key in ["output", "content", "stdout", "stderr"] {
            if let text = payload[key] as? String, !text.isEmpty {
                return short(text, max: 600)
            }
        }
        return nil
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
