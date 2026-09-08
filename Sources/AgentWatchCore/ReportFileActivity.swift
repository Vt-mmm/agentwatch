import Foundation

/// Only structured file targets survive into the daily journal. Commands,
/// file contents, model prose and tool responses are deliberately not retained.
public struct ReportFileActivity: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let action: String
    public let path: String
}

public enum ReportFileActivityReader {
    private struct Entry { let stamp: LogFileStamp; let rows: [ReportFileActivity] }
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: Entry] = [:]
    }
    private static let cache = Cache()

    public static func read(session: SessionSummary, period: DailyReportPeriod) -> [ReportFileActivity] {
        guard let url = session.fileURL, let stamp = LogFileStamp.read(url) else { return [] }
        let key = url.path
        cache.lock.lock()
        let cached = cache.entries[key]
        cache.lock.unlock()
        if let cached, cached.stamp == stamp { return cached.rows.filter { period.contains($0.timestamp) } }
        var rows: [ReportFileActivity] = []
        JsonlLineReader.forEachLineData(at: url) { data in
            guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = row["timestamp"] as? String,
                  let date = PiTaskJournal.parseDate(timestamp) else { return }
            if row["type"] as? String == "response_item", let payload = row["payload"] as? [String: Any],
               ["function_call", "custom_tool_call"].contains(payload["type"] as? String ?? "") {
                rows += extract(name: payload["name"] as? String ?? "", input: payload["arguments"] ?? payload["input"], at: date)
            }
            if let message = row["message"] as? [String: Any], (message["role"] as? String == "assistant" || row["type"] as? String == "assistant"),
               let content = message["content"] as? [[String: Any]] {
                for block in content where ["tool_use", "toolCall"].contains(block["type"] as? String ?? "") {
                    rows += extract(name: block["name"] as? String ?? "", input: block["input"] ?? block["arguments"], at: date)
                }
            }
        }
        // Never cache a read that raced a source rewrite or cancellation.
        if !Task.isCancelled, LogFileStamp.read(url) == stamp {
            cache.lock.lock()
            if cache.entries.count >= 128 { cache.entries.removeAll() }
            cache.entries[key] = Entry(stamp: stamp, rows: rows)
            cache.lock.unlock()
        }
        return rows.filter { period.contains($0.timestamp) }
    }

    static func extract(name: String, input: Any?, at date: Date) -> [ReportFileActivity] {
        let tool = name.lowercased().components(separatedBy: ".").last ?? name.lowercased()
        let raw = input as? String
        let arguments = input as? [String: Any] ?? raw.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if tool == "apply_patch", let patch = raw ?? arguments["patch"] as? String ?? arguments["input"] as? String {
            return patch.components(separatedBy: "\n").compactMap { line in
                for (prefix, action) in [("*** Add File: ", "Tạo file"), ("*** Update File: ", "Sửa file"), ("*** Delete File: ", "Xóa file"), ("*** Move to: ", "Chuyển file đến")] {
                    if line.hasPrefix(prefix) { return activity(action, String(line.dropFirst(prefix.count)), date) }
                }
                return nil
            }
        }
        let actions = ["read": "Đọc file", "read_file": "Đọc file", "write": "Ghi file", "write_file": "Ghi file",
                       "edit": "Sửa file", "edit_file": "Sửa file", "multiedit": "Sửa file", "notebookedit": "Sửa file",
                       "view_image": "Xem ảnh"]
        guard let action = actions[tool], let path = arguments["file_path"] as? String ?? arguments["path"] as? String else { return [] }
        return activity(action, path, date).map { [$0] } ?? []
    }

    private static func activity(_ action: String, _ path: String, _ date: Date) -> ReportFileActivity? {
        let path = ReportPromptText.clean(path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\n"), path.count <= 4096 else { return nil }
        return ReportFileActivity(timestamp: date, action: action, path: path)
    }
}
