import Foundation

public struct JournalTaskLink: Sendable, Equatable {
    public let projectPath: String
    public let taskID: String
    public let taskRunID: String
    public let sessionID: String
    public let sessionName: String?
    public let recordedAt: Date
    public let evidenceID: String
}

public struct JournalTaskEvent: Codable, Sendable, Identifiable {
    public let id: String
    public let projectPath: String
    public let taskID: String
    public let taskRunID: String
    public let sessionID: String
    public let recordedAt: Date
    public let eventType: String
    public let checkpointID: String?
    public let phase: String?
    public let status: String?
    public let attempt: Int?
    public let localRef: String
}

public struct PiTaskJournalResult: Sendable {
    public let links: [JournalTaskLink]
    public let evidence: [ReportEvidence]
    public let warnings: [String]
    public let manifest: SourceFileManifest
    public var events: [JournalTaskEvent] = []
}

public enum PiTaskJournal {
    /// Read only operator-selected project journals. Their local hash chain
    /// proves file continuity, not that task claims are objectively true.
    public static func read(project: URL, period: DailyReportPeriod) -> PiTaskJournalResult {
        read(project: project, range: period.scanRange)
    }

    public static func read(project: URL, range selectedRange: Range<Date>) -> PiTaskJournalResult {
        let url = project.appendingPathComponent(".pi/piagent-state/task-journal/events.jsonl")
        let manifest = SourceFileManifest.inspect(url)
        var links: [JournalTaskLink] = [], evidence: [ReportEvidence] = [], warnings: [String] = []
        var events: [JournalTaskEvent] = []
        var previousHash: String?
        var sequence = 0
        var chainValid = true
        JsonlLineReader.forEachLineData(at: url) { raw in
            guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  object["schemaVersion"] as? Int == 1,
                  let seq = object["sequence"] as? Int, seq == sequence + 1,
                  let hash = object["hash"] as? String,
                  let text = String(data: raw, encoding: .utf8),
                  let range = text.range(of: ",\"hash\":\"" + hash + "\"}", options: .backwards),
                  range.upperBound == text.endIndex,
                  ReportEncoding.digest(Data((String(text[..<range.lowerBound]) + "}").utf8)) == hash,
                  object["previousHash"] as? String == previousHash else {
                chainValid = false; return
            }
            sequence = seq; previousHash = hash
            guard chainValid, let timestamp = parseDate(object["recordedAt"] as? String), timestamp < selectedRange.upperBound,
                  let sessionID = object["sessionId"] as? String, !sessionID.isEmpty,
                  let taskID = object["taskId"] as? String, !taskID.isEmpty,
                  let runID = object["taskRunId"] as? String, !runID.isEmpty else { return }
            let id = "journal-" + hash
            links.append(JournalTaskLink(projectPath: project.standardizedFileURL.path,
                                         taskID: taskID, taskRunID: runID, sessionID: sessionID,
                                         sessionName: object["sessionName"] as? String,
                                         recordedAt: timestamp, evidenceID: id))
            let data = object["data"] as? [String: Any] ?? [:]
            events.append(JournalTaskEvent(id: id, projectPath: project.standardizedFileURL.path,
                taskID: taskID, taskRunID: runID, sessionID: sessionID, recordedAt: timestamp,
                eventType: object["eventType"] as? String ?? "event", checkpointID: object["checkpointId"] as? String,
                phase: data["phase"] as? String, status: data["status"] as? String,
                attempt: data["attempt"] as? Int, localRef: url.path + "#sequence=\(seq)"))
            if selectedRange.contains(timestamp) {
                evidence.append(ReportEvidence(id: id, sessionRef: "piagent|" + sessionID,
                                               kind: .taskJournal, observedAt: timestamp,
                                               summary: "Nhật ký task \(taskID): \(object["eventType"] as? String ?? "event")",
                                               localRef: url.path + "#sequence=\(seq)", digest: hash))
            }
        }
        if !chainValid { warnings.append("Pi task journal has an invalid or unsupported hash chain; task linking is disabled for this journal."); links = []; evidence = []; events = [] }
        if !manifest.readable { warnings.append("Selected Pi task journal is unavailable.") }
        return PiTaskJournalResult(links: links, evidence: evidence, warnings: warnings, manifest: manifest, events: events)
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
