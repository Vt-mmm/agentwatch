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
        var report = DailyReportBuilder.build(employee: employee, period: period, scan: scan, journals: journals, quota: quota)
        let prompts = scan.prompts.filter { period.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        let labels: [SessionIntent: String] = [.bugFix: "Yêu cầu sửa lỗi", .refactor: "Yêu cầu chỉnh sửa/tổ chức mã nguồn",
            .newFeature: "Yêu cầu phát triển tính năng", .docs: "Yêu cầu tài liệu/hướng dẫn", .exploration: "Yêu cầu tìm hiểu/đối chiếu", .general: "Trao đổi trong phiên làm việc"]
        for index in report.workItems.indices {
            let item = report.workItems[index]
            let related = prompts.filter { item.sessionRefs.contains($0.sessionAuditKey) }
            let topics = Set(related.map { labels[SessionIntentClassifier.classify(prompts: [$0.text])] ?? "Trao đổi" }).sorted()
            let employeePrompts = related.filter { ReportPromptText.origin($0.text) == .employee }
            let excerpts = employeePrompts.map { ReportPromptText.excerpt($0.text) }.filter { !$0.isEmpty }
            report.workItems[index].activities = ["Ghi nhận \(Set(employeePrompts.map(\.auditKey)).count) prompt nhân viên; \(related.count - employeePrompts.count) lượt tự động/ngữ cảnh trong các phiên liên quan."]
                + Array(excerpts.prefix(3)).map { "Yêu cầu: " + $0 }
                + ["Nhóm yêu cầu gợi ý: " + topics.joined(separator: ", ") + "."]
            if item.title.hasPrefix("Công việc tại "), let first = excerpts.first {
                report.workItems[index].title = ReportPromptText.excerpt(first, limit: 90)
            }
            report.workItems[index].nextActions = ""
        }
        if let count = report.dailyActivity?.prompts.count {
            let byID = Dictionary(prompts.map { (ReportDailyActivity.promptID($0), $0) }, uniquingKeysWith: { first, _ in first })
            for index in 0..<count {
                guard let row = report.dailyActivity?.prompts[index] else { continue }
                if let prompt = byID[row.id] {
                    report.dailyActivity?.prompts[index].content = ReportPromptText.clean(prompt.text)
                    report.dailyActivity?.prompts[index].origin = ReportPromptText.origin(prompt.text)
                    let next = prompts.first { $0.sessionAuditKey == prompt.sessionAuditKey && $0.timestamp > prompt.timestamp }?.timestamp ?? period.end
                    let tools = report.evidence.filter { $0.kind == .toolResult && $0.sessionRef == prompt.sessionAuditKey && $0.observedAt >= prompt.timestamp && $0.observedAt < next }.sorted { $0.observedAt < $1.observedAt }
                    report.dailyActivity?.prompts[index].toolObservationCount = tools.count
                    report.dailyActivity?.prompts[index].toolObservations = tools.prefix(3).map { ReportPromptText.toolObservation($0, zone: period.timeZone) }
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
        report.desktopActivity = desktop
        report.summary = "Tự động tổng hợp \(report.dailyActivity?.prompts.count ?? 0) prompt, \(scan.sessions.count) phiên coding agent và \(desktop?.apps.count ?? 0) ứng dụng có ghi nhận foreground trong ngày. Các công việc được nhóm theo phiên/dự án; không xác nhận hoàn thành từ lời agent."
        report.notes = "Báo cáo tự động từ các nguồn đọc được trên máy đến thời điểm chốt. Phạm vi nghiệp vụ chưa có căn cứ được giữ Chưa xác định. Phân loại yêu cầu bằng quy tắc chỉ là gợi ý; Có nội dung prompt đã lọc ngữ cảnh hệ thống và che mẫu thông tin nhạy cảm phổ biến. Công cụ được đối chiếu theo khoảng thời gian trong cùng phiên, không chứng minh quan hệ nhân quả hoặc kết quả hoàn thành. Không đọc nội dung cửa sổ hay lịch sử duyệt web."
        report.narrativeProvenance = "automatic-local-v1"
        return report
    }
}
