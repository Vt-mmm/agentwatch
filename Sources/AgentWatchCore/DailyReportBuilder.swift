import Foundation

public enum DailyReportBuilder {
    public static func build(employee: EmployeeProfile, period: DailyReportPeriod,
                             scan: CoachingScanResult, journals: [PiTaskJournalResult] = [],
                             quota: [QuotaSnapshot] = [], includeToolEvidence: Bool = true) -> DailyReportDraft {
        let sessions = SessionAccounting.canonical(scan.sessions)
        let links = journals.flatMap(\.links).sorted { $0.recordedAt < $1.recordedAt }
        var evidence = journals.flatMap(\.evidence)
        var items: [String: ReportWorkItem] = [:]
        var ledger = UsageLedger()
        var usage: [ReportUsageRecord] = []
        var warnings = sessions.flatMap(\.dataWarnings) + journals.flatMap(\.warnings)

        for session in sessions {
            let projectPath = session.projectDisplay
            let projectLabel = ShareText.clean(URL(fileURLWithPath: projectPath).lastPathComponent)
            let allSessionLinks = links.filter { $0.sessionID == session.id && $0.projectPath == projectPath && session.source == .piagent }
            let baselineLink = allSessionLinks.last { $0.recordedAt < period.start }
            let sessionLinks = (baselineLink.map { [$0] } ?? []) + allSessionLinks.filter { $0.recordedAt >= period.start }
            let itemKey = "session-" + ReportEncoding.digest(Data(session.auditKey.utf8))
            let evidenceID = "activity-" + ReportEncoding.digest(Data(session.auditKey.utf8))
            if let date = session.lastTimestamp, period.contains(date) {
                evidence.append(ReportEvidence(id: evidenceID, sessionRef: session.auditKey, kind: .sessionActivity,
                                               observedAt: date, summary: "Có sự kiện hoạt động từ \(session.source.label) trong ngày.",
                                               localRef: session.fileURL?.path,
                                               digest: ReportEncoding.digest(Data("\(session.auditKey)|\(date.timeIntervalSince1970)|\(session.totalTokens)".utf8))))
            }
            if includeToolEvidence { evidence.append(contentsOf: EvidenceExtractor.extract(session: session, period: period)) }
            let sessionEvidence = evidence.filter { $0.sessionRef == session.auditKey }.map(\.id)
            items[itemKey] = ReportWorkItem(id: itemKey, project: projectLabel,
                                           title: ShareText.clean(session.sessionTitle ?? "Công việc tại \(projectLabel)"),
                                           sessionRefs: [session.auditKey],
                                           activities: ["Có hoạt động với \(session.source.label); nhân viên cần bổ sung kết quả công việc."],
                                           evidenceIDs: sessionEvidence)
            for link in sessionLinks {
                let taskKey = "task-" + ReportEncoding.digest(Data("\(projectPath)|\(link.taskID)".utf8))
                var item = items[taskKey] ?? ReportWorkItem(id: taskKey, project: projectLabel,
                                                          title: ShareText.clean(link.sessionName ?? link.taskID), taskRefs: [link.taskID])
                item.taskRunIDs = Array(Set(item.taskRunIDs + [link.taskRunID])).sorted()
                item.sessionRefs = Array(Set(item.sessionRefs + [session.auditKey])).sorted()
                item.evidenceIDs = Array(Set(item.evidenceIDs + sessionEvidence)).sorted()
                items[taskKey] = item
            }
            for entry in session.usageEntries ?? [] where period.contains(entry.timestamp) { ledger.upsert(entry) }
            if session.usageEntries == nil { warnings.append("Session without request ledger excluded from daily usage; accounting is partial.") }
        }
        var exportedTokenSum = 0
        for entry in ledger.entries.sorted(by: { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }) {
            let next = exportedTokenSum.addingReportingOverflow(entry.tokens.total)
            guard entry.tokens.isValid, !next.overflow else {
                warnings.append("Loại usage không hợp lệ hoặc vượt giới hạn khỏi tổng: \(entry.id). Báo cáo chỉ gồm phần dữ liệu hợp lệ.")
                continue
            }
            exportedTokenSum = next.partialValue
            var key: String?
            // Explicit request task references are preferred. Journal binding is
            // valid from that event until a later binding changes the same session.
            if entry.agent == "pi", let session = sessions.first(where: { $0.source == .piagent && $0.id == entry.sessionID }) {
                let matching = links.filter { $0.sessionID == entry.sessionID && $0.projectPath == session.projectDisplay && $0.recordedAt <= entry.timestamp }
                if let link = matching.last {
                    key = "task-" + ReportEncoding.digest(Data("\(link.projectPath)|\(link.taskID)".utf8))
                }
            }
            usage.append(ReportUsageRecord(entry: entry, workItemID: key))
        }
        // Session-title suggestions never allocate tokens by guesswork. Once an
        // explicitly linked task covers a session, its extra suggestion is redundant.
        let linkedSessions = Set(items.values.filter { !$0.taskRefs.isEmpty }.flatMap(\.sessionRefs))
        items = items.filter { _, item in !item.taskRefs.isEmpty || !item.sessionRefs.allSatisfy { linkedSessions.contains($0) } }
        let files = (scan.sourceFiles + journals.map(\.manifest)).map { prior in
            let after = SourceFileManifest.inspect(URL(fileURLWithPath: prior.path))
            return SourceFileManifest(path: prior.path, byteCount: prior.byteCount, sha256: prior.sha256,
                                      modifiedAt: prior.modifiedAt, malformedRecordCount: prior.malformedRecordCount,
                                      readable: prior.readable,
                                      changedDuringRead: prior.changedDuringRead || after.sha256 != prior.sha256)
        }
        if files.contains(where: { !$0.readable || $0.malformedRecordCount > 0 || $0.changedDuringRead }) {
            warnings.append("Một số nguồn không đọc đủ hoặc thay đổi trong lúc quét; số liệu chỉ phản ánh phần đã thu.")
        }
        if scan.sourceRoots.contains(where: { !$0.readable }) { warnings.append("Có nguồn agent chưa có hoặc chưa đọc được trên máy này.") }
        let currentQuota = quota.filter { period.contains($0.capturedAt) }
        if currentQuota.isEmpty { warnings.append("Không có snapshot quota được thu trong ngày này; không dùng quota hiện tại để điền ngày cũ.") }
        warnings += ledger.warnings
        return DailyReportDraft(employee: employee, period: period,
                                workItems: items.values.sorted { $0.project == $1.project ? $0.id < $1.id : $0.project < $1.project },
                                evidence: evidence.sorted { $0.id < $1.id }, usage: usage, quota: currentQuota,
                                warnings: Array(Set(warnings)).sorted(), sourceFiles: files, sourceRoots: scan.sourceRoots,
                                summary: "", notes: "", narrativeProvenance: "deterministic-template-v1",
                                dailyActivity: ReportDailyActivity.build(scan: scan, period: period, links: links, items: Array(items.values), usage: usage))
    }
}

public enum ShareText {
    /// Defense in depth for titles/notes. The share renderer still uses an
    /// allowlist and escapes markup; redaction is not a substitute for review.
    public static func clean(_ text: String) -> String {
        var result = text
        for pattern in [#"(?i)(?:GOCSPX-|sk-|ghp_|github_pat_|ya29\.)[A-Za-z0-9_.-]{12,}"#,
                        #"(?i)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|authorization)\s*[:=]\s*\S+"#,
                        #"(?:/Users/|/home/|/private/|/tmp/)[^\s<>\"']+"#] {
            result = result.replacingOccurrences(of: pattern, with: "[đã ẩn]", options: .regularExpression)
        }
        return result.replacingOccurrences(of: "\u{0000}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func html(_ text: String) -> String {
        clean(text).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}
