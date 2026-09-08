import Foundation

public enum AutomaticDailyReport {
    public static func savePDF(_ report: DailyReportDraft, directory: URL) throws -> URL {
        try ReportValidator.validate(report)
        let files = ReportFileStore(root: directory)
        let bytes = try DailyReportRenderer.pdf(report)
        return try files.transaction {
            let day = DailyReportRenderer.dateLabel(report.period.start, zone: report.period.timeZone, format: "yyyy-MM-dd")
            let url = directory.appendingPathComponent("Report-\(day)-\(UUID().uuidString).pdf")
            guard !FileManager.default.fileExists(atPath: url.path) else { throw ReportValidationError.invalid("Tên report bị trùng; thử xuất lại.") }
            try files.write(bytes, to: url)
            return url
        }
    }

    public static func build(employee: EmployeeProfile, period: DailyReportPeriod, scan: CoachingScanResult,
                             journals: [PiTaskJournalResult] = [], quota: [QuotaSnapshot] = [],
                             desktop: DesktopActivityReport? = nil) -> DailyReportDraft {
        var report = DailyReportBuilder.build(employee: employee, period: period, scan: scan, journals: journals, quota: quota, includeToolEvidence: false)
        let prompts = scan.prompts.filter { period.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        let groupedPrompts = Dictionary(grouping: prompts, by: \.sessionAuditKey)
        let origins = Dictionary(prompts.map { ($0.auditKey, ReportPromptText.origin($0.text)) }, uniquingKeysWith: { first, _ in first })
        let labels: [SessionIntent: String] = [.bugFix: "Yêu cầu sửa lỗi", .refactor: "Yêu cầu chỉnh sửa/tổ chức mã nguồn",
            .newFeature: "Yêu cầu phát triển tính năng", .docs: "Yêu cầu tài liệu/hướng dẫn", .exploration: "Yêu cầu tìm hiểu/đối chiếu", .general: "Trao đổi trong phiên làm việc"]
        for index in report.workItems.indices {
            let item = report.workItems[index]
            let related = item.sessionRefs.flatMap { groupedPrompts[$0] ?? [] }.sorted { $0.timestamp < $1.timestamp }
            let topics = Set(related.map { labels[SessionIntentClassifier.classify(prompts: [$0.text])] ?? "Trao đổi" }).sorted()
            let employeePrompts = related.filter { origins[$0.auditKey] == .employee }
            let excerpts = employeePrompts.map { ReportPromptText.excerpt($0.text) }.filter { !$0.isEmpty }
            report.workItems[index].activities = ["Ghi nhận \(Set(employeePrompts.map(\.auditKey)).count) prompt nhân viên; \(related.count - employeePrompts.count) lượt tự động/ngữ cảnh trong các phiên liên quan."]
                + Array(excerpts.prefix(3)).map { "Yêu cầu: " + $0 }
                + ["Nhóm yêu cầu gợi ý: " + topics.joined(separator: ", ") + "."]
            if item.title.hasPrefix("Công việc tại "), let first = excerpts.first {
                report.workItems[index].title = ReportPromptText.excerpt(first, limit: 90)
            }
            report.workItems[index].nextActions = ""
        }
        var filesByPrompt: [String: [ReportFileActivity]] = [:]
        for session in SessionAccounting.canonical(scan.sessions) {
            let human = (groupedPrompts[session.auditKey] ?? []).filter { origins[$0.auditKey] == .employee }
            let byTime = Dictionary(grouping: human, by: \.timestamp)
            let times = byTime.keys.sorted()
            guard let first = times.first else { continue }
            var position = 0
            for file in ReportFileActivityReader.read(session: session, period: period).sorted(by: { $0.timestamp < $1.timestamp }) {
                guard file.timestamp >= first else { continue }
                while position + 1 < times.count && times[position + 1] <= file.timestamp { position += 1 }
                // Equal-time requests are ambiguous, not two owners of one action.
                if let candidates = byTime[times[position]], candidates.count == 1 {
                    filesByPrompt[candidates[0].auditKey, default: []].append(file)
                }
            }
        }
        if let count = report.dailyActivity?.prompts.count {
            let byID = Dictionary(prompts.map { (ReportDailyActivity.promptID($0), $0) }, uniquingKeysWith: { first, _ in first })
            for index in 0..<count {
                guard let row = report.dailyActivity?.prompts[index] else { continue }
                if let prompt = byID[row.id] {
                    report.dailyActivity?.prompts[index].content = ReportPromptText.clean(prompt.text)
                    report.dailyActivity?.prompts[index].origin = origins[prompt.auditKey]
                    report.dailyActivity?.prompts[index].observedProject = ReportPromptText.clean(prompt.projectDisplay)
                    report.dailyActivity?.prompts[index].sessionTitle = prompt.sessionTitle.map(ReportPromptText.clean)
                    report.dailyActivity?.prompts[index].fileActivities = filesByPrompt[prompt.auditKey] ?? []
                    report.dailyActivity?.prompts[index].summary = (labels[SessionIntentClassifier.classify(prompts: [prompt.text])] ?? "Trao đổi") + " (phân loại tự động)."
                }
                if row.workItemID == nil {
                    let matches = report.workItems.filter { $0.sessionRefs.contains(row.sessionRef) }
                    if matches.count == 1 {
                        report.dailyActivity?.prompts[index].workItemID = matches[0].id
                        report.dailyActivity?.prompts[index].taskBasis = .sessionContext
                    }
                }
            }
        }
        let humanCount = report.dailyActivity?.prompts.filter { ($0.origin ?? .employee) == .employee }.count ?? 0
        report.desktopActivity = desktop
        report.summary = "Tự động tổng hợp \(humanCount) prompt người dùng, \(scan.sessions.count) phiên coding agent và \(desktop?.apps.count ?? 0) ứng dụng có ghi nhận foreground trong ngày. Các công việc được nhóm theo phiên/dự án; không xác nhận hoàn thành từ lời agent."
        report.notes = "Báo cáo tự động từ các nguồn đọc được trên máy đến thời điểm chốt. Phạm vi nghiệp vụ chưa có căn cứ được giữ Chưa xác định. Phân loại yêu cầu bằng quy tắc chỉ là gợi ý; Có nội dung prompt đã lọc ngữ cảnh hệ thống và che mẫu thông tin nhạy cảm phổ biến. Công cụ được đối chiếu theo khoảng thời gian trong cùng phiên, không chứng minh quan hệ nhân quả hoặc kết quả hoàn thành. Không đọc nội dung cửa sổ hay lịch sử duyệt web."
        report.narrativeProvenance = "automatic-local-v1"
        return report
    }
}
