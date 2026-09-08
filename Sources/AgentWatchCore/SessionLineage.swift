import Foundation

public enum SessionRelationKind: String, Codable, Sendable {
    case fork, subagentRequested, resumeRequested
    public var label: String {
        switch self {
        case .fork: "Session được fork"
        case .subagentRequested: "Yêu cầu chạy agent con"
        case .resumeRequested: "Yêu cầu tiếp tục agent"
        }
    }
}

public struct SessionRelation: Codable, Sendable, Identifiable {
    public let id: String
    public let sessionRef: String
    public let kind: SessionRelationKind
    public let timestamp: Date
    /// An identifier or metadata path, never automatically opened or trusted.
    public let relatedRef: String?
    public let localRef: String
    public let explanation: String
}

public struct SessionLineageSnapshot: Sendable {
    public let relations: [SessionRelation]
    public let warnings: [String]
}

public enum SessionLineageReader {
    /// Reads selected session files, not parent paths contained in metadata.
    /// Relations do not inherit task ownership or add parent usage to totals.
    public static func read(sessions: [SessionSummary], before: Date,
                            maxBytesPerFile: Int = 32 * 1024 * 1024) -> SessionLineageSnapshot {
        var relations: [SessionRelation] = [], warnings: [String] = []
        let limit = max(1024, min(maxBytesPerFile, 64 * 1024 * 1024))
        for session in SessionAccounting.canonical(sessions) {
            if Task.isCancelled { warnings.append("Đã dừng đọc quan hệ session."); break }
            guard let file = session.fileURL, let handle = try? FileHandle(forReadingFrom: file) else {
                warnings.append("Không đọc được nguồn của session \(session.id)."); continue
            }
            defer { try? handle.close() }
            do {
                let prior = LogFileStamp.read(file)
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                let truncated = data.count > limit
                let result = extract(data: Data(data.prefix(limit)), sessionRef: session.auditKey,
                    sessionID: session.id, source: session.source, file: file, before: before)
                relations += result.relations; warnings += result.warnings
                if truncated { warnings.append("Session \(session.id): chỉ đọc phần đầu theo giới hạn dung lượng; quan hệ phía sau có thể thiếu.") }
                if prior == nil || prior != LogFileStamp.read(file) { warnings.append("Session \(session.id): nguồn thay đổi trong lúc đọc.") }
            } catch { warnings.append("Không đọc hết nguồn của session \(session.id).") }
        }
        return SessionLineageSnapshot(relations: relations.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp },
                                      warnings: Array(Set(warnings)).sorted())
    }

    public static func extract(data: Data, sessionRef: String, sessionID: String, source: SessionSource,
                               file: URL, before: Date) -> SessionLineageSnapshot {
        var relations: [SessionRelation] = [], warnings: [String] = []
        var malformed = 0, seenHeader = false
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            if Task.isCancelled { warnings.append("Đã dừng phân tích quan hệ session."); break }
            if data.last != 10 && index == lines.count - 1 { warnings.append("Bỏ dòng cuối chưa hoàn chỉnh của \(sessionID)."); break }
            guard line.count <= 1024 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { malformed += 1; continue }
            let payload = object["payload"] as? [String: Any] ?? [:]
            let type = object["type"] as? String ?? ""
            guard let timestamp = PiTaskJournal.parseDate(object["timestamp"] as? String ?? object["_audit_timestamp"] as? String), timestamp < before else { continue }
            func append(_ kind: SessionRelationKind, _ target: String?, _ discriminator: String) {
                let localRef = file.path + "#line=\(index + 1)"
                let id = ReportEncoding.digest(Data("\(sessionRef)|\(kind.rawValue)|\(discriminator)|\(timestamp.timeIntervalSince1970)".utf8))
                relations.append(SessionRelation(id: id, sessionRef: sessionRef, kind: kind, timestamp: timestamp,
                    relatedRef: target, localRef: localRef,
                    explanation: kind == .fork ? "Quan hệ do metadata nguồn khai báo; không tự gộp task hoặc token của phiên cha."
                        : "Log ghi nhận yêu cầu; chưa chứng minh agent con đã chạy hay hoàn thành. Không dùng làm bằng chứng vòng lặp."))
            }
            if source == .codex, type == "session_meta", !seenHeader {
                seenHeader = true
                guard string(payload["id"]) == sessionID else { warnings.append("Metadata session không khớp; bỏ quan hệ fork."); continue }
                if let parent = string(payload["forked_from_id"] ?? payload["forkedFromId"]), parent != sessionID { append(.fork, parent, "header") }
            } else if source == .piagent, type == "session", !seenHeader {
                seenHeader = true
                guard string(object["id"]) == sessionID else { warnings.append("Metadata session không khớp; bỏ quan hệ fork."); continue }
                if let parent = string(object["parentSession"]) { append(.fork, parent, "header") }
            }
            if source == .codex, type == "response_item", payload["type"] as? String == "function_call" {
                let name = payload["name"] as? String ?? ""
                let args = arguments(payload["arguments"])
                let call = string(payload["call_id"]) ?? "line-\(index)"
                if name == "spawn_agent" { append(.subagentRequested, nil, call) }
                if name == "resume_agent", let target = string(args["id"]) { append(.resumeRequested, target, call) }
            }
            if source == .cli || source == .desktop {
                let message = object["message"] as? [String: Any] ?? [:]
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    let name = block["name"] as? String ?? ""
                    guard ["Agent", "Task"].contains(name), let call = string(block["id"]) else { continue }
                    let args = block["input"] as? [String: Any] ?? [:]
                    if let resume = string(args["resume"]) { append(.resumeRequested, resume, call) }
                    else { append(.subagentRequested, nil, call) }
                }
            }
        }
        if malformed > 0 { warnings.append("\(sessionID): \(malformed) dòng lỗi hoặc quá lớn bị bỏ qua.") }
        var seen: Set<String> = []
        return SessionLineageSnapshot(relations: relations.filter { seen.insert($0.id).inserted }, warnings: warnings)
    }
    private static func string(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 4096, !value.contains("\0") else { return nil }
        return value
    }
    private static func arguments(_ raw: Any?) -> [String: Any] {
        if let value = raw as? [String: Any] { return value }
        guard let text = raw as? String, text.utf8.count <= 64 * 1024,
              let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
}
