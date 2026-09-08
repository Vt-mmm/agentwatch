import Foundation

public enum TranscriptLoopAnalyzer {
    private struct Key: Equatable { let run: String; let tool: String; let input: String; let output: String; let error: Bool? }
    /// Exact payload equality, distinct IDs and non-overlapping calls. Unknown
    /// error status remains unknown; an identical preview is never sufficient.
    public static func analyze(events: [SessionEvent], eligibleIDs: Set<String>, sessionRef: String,
                               file: URL, range: Range<Date>, runByEventID: [String: String] = [:]) -> [TaskOutcomeEvidence] {
        var chain: [SessionEvent] = [], key: Key?, output: [TaskOutcomeEvidence] = []
        var seen: Set<String> = []
        let counts = Dictionary(events.filter { $0.kind == .toolUse }.compactMap { event in
            event.toolUseId.map { ($0, 1) }
        }, uniquingKeysWith: +)
        let ambiguousIDs = Set(counts.filter { $0.value > 1 }.keys)
        func flush() {
            defer { chain = []; key = nil }
            guard chain.count >= 3, let first = chain.first, let last = chain.last,
                  let started = PiTaskJournal.parseDate(first.timestamp),
                  let finished = PiTaskJournal.parseDate(last.completedAt) else { return }
            let refs = chain.map { file.path + "#event=" + $0.id }
            let status = key?.error.map { $0 ? "nguồn đánh dấu lỗi" : "nguồn không đánh dấu lỗi" } ?? "nguồn chưa có cờ lỗi"
            output.append(TaskOutcomeEvidence(id: ReportEncoding.digest(Data((sessionRef + refs.joined(separator: "|")).utf8)),
                kind: .repeatedToolSequence, timestamp: finished, activityStartedAt: started, sessionRef: sessionRef,
                summary: "\(chain.count) lần gọi \(first.toolName ?? "tool") có cùng input/output đầy đủ; \(status).\n" + refs.joined(separator: "\n"),
                localRef: refs[0], caveat: "Chuỗi cần đối chiếu tiến độ; không tự kết luận thất bại hoặc dừng agent. Hash được tính từ dữ liệu gốc, không từ đoạn xem trước."))
        }
        for event in events {
            if event.kind == .userMessage { flush(); continue }
            guard event.kind == .toolUse else { continue }
            guard eligibleIDs.contains(event.id), let id = event.toolUseId, !id.isEmpty, !ambiguousIDs.contains(id), seen.insert(id).inserted,
                  let tool = event.toolName, !["write", "edit", "apply_patch", "patch", "multiedit"].contains(tool.lowercased()),
                  event.completed, let started = PiTaskJournal.parseDate(event.timestamp),
                  let finished = PiTaskJournal.parseDate(event.completedAt), finished >= started,
                  range.contains(started), range.contains(finished),
                  let input = event.inputDigest, let digest = event.outputDigest else { flush(); continue }
            let candidate = Key(run: runByEventID[event.id] ?? "session", tool: tool, input: input, output: digest, error: event.toolIsError)
            let previousEnd = chain.last.flatMap { PiTaskJournal.parseDate($0.completedAt) }
            if key != candidate || previousEnd.map({ started < $0 || started.timeIntervalSince($0) > 600 }) == true { flush() }
            key = candidate; chain.append(event)
        }
        flush()
        return output
    }
}
