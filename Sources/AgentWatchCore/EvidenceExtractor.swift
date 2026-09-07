import Foundation

public enum EvidenceExtractor {
    /// Extract metadata and short, redacted tool observations. Thinking blocks,
    /// images, raw tool output and user prompts never enter this evidence list.
    public static func extract(session: SessionSummary, period: DailyReportPeriod) -> [ReportEvidence] {
        guard let url = session.fileURL else { return [] }
        let stats: SessionStats
        let range = period.scanRange
        switch session.source {
        case .cli, .desktop: stats = JsonlParser.parseSession(at: url, range: range, eventLimit: nil)
        case .codex: stats = CodexJsonlParser.parseSession(at: url, range: range, eventLimit: nil)
        case .piagent: stats = PiAgentJsonlParser.parseSession(at: url, range: range, eventLimit: nil)
        }
        return stats.events.compactMap { event in
            guard event.kind == .toolUse,
                  let observedAt = PiTaskJournal.parseDate(event.completedAt ?? event.timestamp), period.contains(observedAt) else { return nil }
            let key = "\(session.auditKey)|\(event.id)|\(observedAt.timeIntervalSince1970)"
            let summary = "\(event.toolName ?? "Tool"): \(ShareText.clean(String(event.summary.prefix(240)))). "
                + (event.completed ? "Đã có phản hồi công cụ; chưa xác nhận chất lượng/kết quả." : "Chưa thu được phản hồi công cụ.")
            let digest = ReportEncoding.digest(Data("\(key)|\(event.summary)|\(event.resultPreview ?? "")".utf8))
            return ReportEvidence(id: "tool-" + ReportEncoding.digest(Data(key.utf8)), sessionRef: session.auditKey,
                                  kind: .toolResult, observedAt: observedAt, summary: summary,
                                  localRef: url.path + "#event=" + event.id, digest: digest)
        }
    }
}
