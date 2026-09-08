import Foundation
import CryptoKit

public enum InsightCoverage: String, Codable, Sendable {
    case complete, partial, unavailable
    public var label: String {
        switch self {
        case .complete: "Đủ trong mẫu đã đọc"
        case .partial: "Dữ liệu một phần"
        case .unavailable: "Chưa có dữ liệu"
        }
    }
}

/// Allowlisted metadata only. Commands, raw output, prompts and images are not retained.
public struct ContextObservation: Codable, Sendable, Identifiable {
    public let id: String
    public let projectPath: String
    public let recordedAt: Date
    public let event: String
    public let sessionID: String
    public let taskID: String?
    public let taskRunID: String?
    public let turnID: String?
    public let model: String?
    public let thinkingLevel: String?
    public let toolCallID: String?
    public let toolName: String?
    public let inputHash: String?
    public let outputHash: String?
    public let targetPath: String?
    public let changedPaths: [String]
    public let selectedPaths: [String]
    public let outputChars: Int?
    public let repeated: Bool?
    public let isError: Bool?
    public let reasonCode: String?
    public let activeTools: Int?
    public let systemPromptTokens: Int?
    public let toolSchemaTokens: Int?
    public let confidence: String?
    public let localRef: String
}

public struct ContextTelemetrySnapshot: Codable, Sendable {
    public let projectPath: String
    public let capturedAt: Date
    public let events: [ContextObservation]
    public let coverage: InsightCoverage
    public let warnings: [String]
    public let malformedRecords: Int
    public let unsupportedRecords: Int
    public let incompleteTail: Bool
    public let sampledBytes: Int
}

public enum PiContextTelemetry {
    /// Reads only the selected project's fixed telemetry paths; never follows
    /// a path contained in a log. Rotation and bounded tails are explicit gaps.
    public static func read(project: URL, before cutoff: Date = .distantFuture,
                            maxBytes: Int = 32 * 1024 * 1024,
                            maxRecords: Int = 50_000) -> ContextTelemetrySnapshot {
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        var events: [ContextObservation] = []
        var warnings: [String] = []
        var malformed = 0, unsupported = 0, sampledBytes = 0
        var partial = false, incompleteTail = false, found = false
        let byteLimit = max(1024, min(maxBytes, 64 * 1024 * 1024))
        let recordLimit = max(1, min(maxRecords, 100_000))
        for name in ["events.jsonl.1", "events.jsonl"] {
            let file = root.appendingPathComponent(".pi/piagent-state/context-engine/" + name)
            guard safe(file, inside: root) else {
                warnings.append("Từ chối telemetry đi qua symlink hoặc ra ngoài dự án.")
                partial = true; continue
            }
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            found = true
            if name.hasSuffix(".1") { partial = true; warnings.append("Telemetry đã rotate; lịch sử trước mẫu có thể không còn.") }
            guard let stamp = LogFileStamp.read(file), let handle = try? FileHandle(forReadingFrom: file) else {
                warnings.append("Không đọc được \(name).")
                partial = true; continue
            }
            defer { try? handle.close() }
            do {
                let start = stamp.size > UInt64(byteLimit) ? stamp.size - UInt64(byteLimit) : 0
                try handle.seek(toOffset: start)
                var data = try handle.read(upToCount: byteLimit) ?? Data()
                sampledBytes += data.count
                var lineNumber = 0
                if start > 0 {
                    partial = true
                    warnings.append("Chỉ đọc phần đuôi telemetry theo giới hạn dung lượng.")
                    if let newline = data.firstIndex(of: 10) { data = Data(data[data.index(after: newline)...]) }
                    else { data = Data() }
                }
                let terminated = data.last == 10
                let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                for (index, bytes) in lines.enumerated() {
                    if Task.isCancelled { partial = true; warnings.append("Đã dừng đọc telemetry."); break }
                    lineNumber += 1
                    guard !bytes.isEmpty else { continue }
                    // Do not use an in-flight final record as stable evidence.
                    if !terminated && index == lines.count - 1 { incompleteTail = true; partial = true; continue }
                    guard bytes.count <= 1024 * 1024,
                          let object = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any] else {
                        malformed += 1; continue
                    }
                    guard integer(object["schemaVersion"]) == 1,
                          (object["telemetrySource"] as? String ?? object["source"] as? String) == "piagent" else {
                        unsupported += 1; continue
                    }
                    if object["truncated"] as? Bool == true { partial = true; continue }
                    guard let timestamp = PiTaskJournal.parseDate(object["recordedAt"] as? String),
                          let event = string(object["event"]), let session = string(object["sessionId"]) else {
                        malformed += 1; continue
                    }
                    guard timestamp < cutoff else { continue }
                    let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
                    events.append(ContextObservation(
                        id: digest, projectPath: root.path, recordedAt: timestamp, event: event, sessionID: session,
                        taskID: string(object["taskId"]), taskRunID: string(object["taskRunId"]), turnID: string(object["turnId"]),
                        model: string(object["model"]), thinkingLevel: string(object["thinkingLevel"]),
                        toolCallID: string(object["toolCallId"]), toolName: string(object["toolName"]),
                        inputHash: string(object["inputHash"]), outputHash: string(object["outputHash"]),
                        targetPath: relativePath(object["targetPath"]),
                        changedPaths: ((object["changedPaths"] ?? object["mutationPaths"] ?? object["targetPaths"]) as? [String] ?? []).compactMap(relativePath),
                        selectedPaths: Array(Set(((object["selectedPaths"] as? [String] ?? [])
                            + ((object["selectedItems"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })).compactMap(relativePath))).sorted(),
                        outputChars: integer(object["outputChars"]), repeated: boolean(object["repeated"]), isError: boolean(object["isError"]),
                        reasonCode: string(object["reasonCode"]), activeTools: integer(object["activeTools"]),
                        systemPromptTokens: integer(object["systemPromptTokens"]), toolSchemaTokens: integer(object["toolSchemaTokens"]),
                        confidence: string(object["confidence"]),
                        localRef: file.path + (start == 0 ? "#line=\(lineNumber)" : "#sha256=\(digest)")))
                    // Bound retained metadata even if files contain many tiny records.
                    if events.count > recordLimit * 2 { events.removeFirst(events.count - recordLimit); partial = true }
                }
                if LogFileStamp.read(file) != stamp { partial = true; warnings.append("Telemetry thay đổi trong lúc đọc.") }
            } catch { partial = true; warnings.append("Đọc telemetry thất bại: \(name).") }
        }
        var seen: Set<String> = []
        events = events.filter { seen.insert($0.id).inserted }
        if events.count > recordLimit { events = Array(events.suffix(recordLimit)); partial = true }
        if malformed > 0 { warnings.append("\(malformed) dòng thiếu trường bắt buộc hoặc JSON lỗi.") }
        if unsupported > 0 { warnings.append("\(unsupported) dòng có schema/nguồn chưa hỗ trợ.") }
        if incompleteTail { warnings.append("Bỏ qua dòng cuối đang ghi dở.") }
        if !found { warnings.append("Dự án chưa có context telemetry.") }
        return ContextTelemetrySnapshot(projectPath: root.path, capturedAt: Date(), events: events,
            coverage: !found || events.isEmpty ? .unavailable : partial || malformed > 0 || unsupported > 0 ? .partial : .complete,
            warnings: Array(Set(warnings)).sorted(), malformedRecords: malformed, unsupportedRecords: unsupported,
            incompleteTail: incompleteTail, sampledBytes: sampledBytes)
    }

    private static func safe(_ file: URL, inside root: URL) -> Bool {
        var cursor = file
        while cursor.path != root.path {
            guard cursor.path.hasPrefix(root.path + "/") else { return false }
            if let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { return false }
            cursor.deleteLastPathComponent()
        }
        return true
    }
    private static func string(_ raw: Any?) -> String? {
        guard let text = raw as? String, !text.isEmpty, text.utf8.count <= 4096 else { return nil }
        return text
    }
    private static func relativePath(_ raw: Any?) -> String? {
        guard let path = string(raw), !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        return path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }
    private static func integer(_ raw: Any?) -> Int? {
        guard let raw, !UsageIdentity.isBoolean(raw), let number = raw as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 1_000_000_000_000, value.rounded() == value else { return nil }
        return Int(value)
    }
    private static func boolean(_ raw: Any?) -> Bool? {
        guard let raw, UsageIdentity.isBoolean(raw) else { return nil }
        return raw as? Bool
    }
}
