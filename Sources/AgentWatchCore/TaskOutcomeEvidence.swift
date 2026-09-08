import Foundation

public enum OutcomeEvidenceKind: String, Codable, Sendable {
    case artifactVerified, commitVerified, repeatedToolSequence, testReportObserved
    case agentStatement, testInvocation, testOutput, artifactOperation, commitOutput, toolResponse, humanAcceptance
    public var label: String {
        switch self {
        case .repeatedToolSequence: "Chuỗi tool lặp cần kiểm tra"
        case .testReportObserved: "Kết quả trong báo cáo test"
        case .artifactVerified: "File đã kiểm tra nội dung"
        case .commitVerified: "Commit đã kiểm tra cục bộ"
        case .agentStatement: "Lời agent"
        case .testInvocation: "Lệnh kiểm thử quan sát được"
        case .testOutput: "Phản hồi lệnh kiểm thử"
        case .artifactOperation: "Thao tác file"
        case .commitOutput: "Phản hồi lệnh commit"
        case .toolResponse: "Phản hồi công cụ"
        case .humanAcceptance: "Người dùng xác nhận nghiệm thu"
        }
    }
}

public struct TaskOutcomeEvidence: Codable, Sendable, Identifiable {
    public let id: String
    public let kind: OutcomeEvidenceKind
    public let timestamp: Date
    public let activityStartedAt: Date
    public let sessionRef: String
    public let summary: String
    public let localRef: String
    public let caveat: String
}

public enum TaskOutcomeReader {
    /// Only sessions already associated with the displayed task are read. This
    /// runs on demand, separately from the fast snapshot/history query path.
    public static func read(sessions: [SessionSummary], range: Range<Date>, item: TaskLifecycleItem,
                            bindings: [TaskSessionBinding], links: [JournalTaskLink]) -> [TaskOutcomeEvidence] {
        var result: [TaskOutcomeEvidence] = []
        for session in SessionAccounting.canonical(sessions) {
            if Task.isCancelled { break }
            guard let file = session.fileURL else { continue }
            let stats: SessionStats
            switch session.source {
            case .cli, .desktop: stats = JsonlParser.parseSession(at: file, range: range, eventLimit: nil)
            case .codex: stats = CodexJsonlParser.parseSession(at: file, range: range, eventLimit: nil)
            case .piagent: stats = PiAgentJsonlParser.parseSession(at: file, range: range, eventLimit: nil)
            }
            result += extract(events: stats.events, sessionRef: session.auditKey, file: file, range: range).filter {
                belongs($0, source: session.source, sessionID: session.id, item: item, bindings: bindings, links: links)
            }
            let assignments = Dictionary(stats.events.compactMap { event -> (String, String)? in
                guard let time = PiTaskJournal.parseDate(event.timestamp) else { return nil }
                let marker = TaskOutcomeEvidence(id: event.id, kind: .toolResponse, timestamp: time, activityStartedAt: time,
                    sessionRef: session.auditKey, summary: "", localRef: "", caveat: "")
                guard let run = resolvedRun(marker, source: session.source, sessionID: session.id, item: item, bindings: bindings, links: links) else { return nil }
                return (event.id, run)
            }, uniquingKeysWith: { a, b in a == b ? a : "" })
            result += TranscriptLoopAnalyzer.analyze(events: stats.events, eligibleIDs: Set(assignments.filter { !$0.value.isEmpty }.keys),
                sessionRef: session.auditKey, file: file, range: range, runByEventID: assignments)
        }
        return result.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }

    /// A preview is source evidence, never a verdict. Tool completion may also
    /// represent a failure, timeout or a background process that is still running.
    public static func extract(events: [SessionEvent], sessionRef: String, file: URL,
                               range: Range<Date>) -> [TaskOutcomeEvidence] {
        var rows: [TaskOutcomeEvidence] = []
        for event in events {
            guard let started = PiTaskJournal.parseDate(event.timestamp) else { continue }
            let ref = file.path + "#event=" + event.id
            func add(_ kind: OutcomeEvidenceKind, _ time: Date, _ text: String, _ caveat: String) {
                guard range.contains(time) else { return }
                let id = ReportEncoding.digest(Data("\(sessionRef)|\(event.id)|\(kind.rawValue)|\(time.timeIntervalSince1970)".utf8))
                rows.append(TaskOutcomeEvidence(id: id, kind: kind, timestamp: time, activityStartedAt: started, sessionRef: sessionRef,
                    summary: String(text.prefix(2000)), localRef: ref, caveat: caveat))
            }
            if event.kind == .assistantText {
                add(.agentStatement, started, event.summary, "Trích lời agent; không chứng minh test đã chạy hoặc task đã hoàn thành.")
                continue
            }
            guard event.kind == .toolUse else { continue }
            let name = (event.toolName ?? "").lowercased()
            let command = event.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let shell = ["bash", "exec_command", "shell_command", "shell"].contains(name)
            // Deliberately excludes shell composition and echoed statements.
            // Unsupported wrappers remain ordinary tool responses.
            let simple = !command.contains(where: { ";|&\n`$".contains($0) })
            let test = shell && simple && matches(command, pattern: "^(swift test|pytest|python(?:3)? -m pytest|cargo test|go test|npm test|npm run test|pnpm test|yarn test|bun test|npx (?:vitest|jest|playwright test))(?: |$)")
            let commit = shell && simple && matches(command, pattern: "^git commit(?: |$)")
            if test { add(.testInvocation, started, command, "Nhận diện từ phần lệnh được log lưu; chưa kết luận đã chạy xong hay pass.") }
            if ["write", "edit", "apply_patch", "patch", "multiedit"].contains(name) {
                add(.artifactOperation, started, event.summary, "Thao tác được yêu cầu; cần đối chiếu file/diff thực tế để xác nhận thay đổi.")
            }
            guard event.completed else { continue }
            guard let finished = PiTaskJournal.parseDate(event.completedAt) else { continue }
            let kind: OutcomeEvidenceKind = test ? .testOutput : (commit ? .commitOutput : .toolResponse)
            add(kind, finished, event.resultPreview ?? "Log ghi nhận phản hồi nhưng không có nội dung xem trước.",
                "Phản hồi có thể bị cắt ngắn; không tự suy ra pass, commit đã tồn tại hoặc đã nghiệm thu. Mở nguồn để đối chiếu.")
        }
        var seen: Set<String> = []
        return rows.filter { seen.insert($0.id).inserted }
    }
    public static func belongs(_ row: TaskOutcomeEvidence, source: SessionSource, sessionID: String,
                               item: TaskLifecycleItem, bindings: [TaskSessionBinding], links: [JournalTaskLink]) -> Bool {
        resolvedRun(row, source: source, sessionID: sessionID, item: item, bindings: bindings, links: links) != nil
    }
    private static func resolvedRun(_ row: TaskOutcomeEvidence, source: SessionSource, sessionID: String,
                                   item: TaskLifecycleItem, bindings: [TaskSessionBinding], links: [JournalTaskLink]) -> String? {
        let time = row.activityStartedAt
        var candidates = bindings.filter { $0.source == source && $0.sessionID == sessionID && $0.contains(time) }
            .map { [$0.projectPath, $0.taskID, $0.taskRunID] }
        if source == .piagent {
            let eligible = links.filter { $0.sessionID == sessionID && $0.recordedAt <= time }
            if let latest = eligible.map(\.recordedAt).max() {
                candidates += eligible.filter { $0.recordedAt == latest }.map { [$0.projectPath, $0.taskID, $0.taskRunID] }
            }
        }
        let unique = Set(candidates)
        guard unique.count == 1, let match = unique.first, match[0] == item.projectPath, match[1] == item.taskID, item.runIDs.contains(match[2]) else { return nil }
        return match[2]
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Immutable local attestations, scoped to the exact task runs and evidence IDs.
/// The operator name is self-declared; this is not authenticated team approval.
public struct TaskAcceptance: Codable, Sendable, Identifiable {
    public let id: String
    public let projectPath: String
    public let taskID: String
    public let runIDs: [String]
    public let evidence: [TaskOutcomeEvidence]
    public var evidenceIDs: [String] { evidence.map(\.id) }
    public let reviewer: String
    public let note: String
    public let recordedAt: Date
    public init(projectPath: String, taskID: String, runIDs: [String], evidence: [TaskOutcomeEvidence],
                reviewer: String, note: String, recordedAt: Date = Date()) {
        id = UUID().uuidString; self.projectPath = projectPath; self.taskID = taskID
        self.runIDs = runIDs; self.evidence = evidence; self.reviewer = reviewer
        self.note = note; self.recordedAt = recordedAt
    }
}

public struct TaskAcceptanceStore: Sendable {
    private let files: ReportFileStore
    public init(root: URL) { files = ReportFileStore(root: root) }
    public static var local: Self { Self(root: URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/AgentWatch/task-acceptance")) }
    public func load(projectPath: String, taskID: String) throws -> [TaskAcceptance] {
        try files.transaction { try read().filter { $0.projectPath == projectPath && $0.taskID == taskID }.sorted { $0.recordedAt < $1.recordedAt } }
    }
    public func append(_ value: TaskAcceptance) throws {
        guard value.projectPath.hasPrefix("/"), !value.runIDs.isEmpty, !value.evidenceIDs.isEmpty,
              ([value.taskID, value.reviewer, value.note] + value.runIDs + value.evidenceIDs).allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains("\0") && $0.utf8.count <= 4096
              }), value.recordedAt.timeIntervalSince1970.isFinite else {
            throw ReportValidationError.invalid("Nghiệm thu cần task/run, bằng chứng đã chọn, tên người xác nhận và ghi chú.")
        }
        try files.transaction {
            var existing = try read()
            guard !existing.contains(where: { $0.id == value.id }) else { throw ReportValidationError.invalid("Xác nhận đã được lưu.") }
            existing.append(value)
            try files.write(ReportEncoding.encode(existing), to: files.root.appendingPathComponent("acceptance.json"))
        }
    }
    private func read() throws -> [TaskAcceptance] {
        let path = files.root.appendingPathComponent("acceptance.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try ReportEncoding.decode([TaskAcceptance].self, from: Data(contentsOf: path))
    }
}
