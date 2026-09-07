import Foundation
import CoreGraphics
import CoreText

public enum DailyReportRenderer {
    public enum BlockKind: Sendable { case body, hero, section, prompt, appUsage }
    public struct Block: Sendable {
        let title: String?
        let text: String
        var kind: BlockKind = .body
        var fraction: Double = 0
    }
    public static func dateLabel(_ date: Date, zone: String, format: String = "dd/MM/yyyy") -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: zone)
        formatter.locale = Locale(identifier: "vi_VN"); formatter.dateFormat = format
        return formatter.string(from: date)
    }
    public static func blocks(_ report: DailyReportDraft, revision: Int? = nil) -> [Block] {
        if report.narrativeProvenance == "automatic-local-v1" { return AutomaticReportLayout.blocks(report, revision: revision) }
        let date = dateLabel(report.period.start, zone: report.period.timeZone)
        let versionLabel = revision.map { "Phiên bản \($0)" } ?? (report.narrativeProvenance == "automatic-local-v1" ? "Báo cáo tự động từ log" : "Bản nháp cần rà soát")
        var result = [Block(title: "BÁO CÁO CÔNG VIỆC NGÀY \(date)",
                            text: "\(report.employee.displayName) · \(report.employee.employeeID) · \(report.employee.organizationID)\nDữ liệu đến \(dateLabel(report.period.cutoff, zone: report.period.timeZone, format: "HH:mm dd/MM/yyyy")) (\(report.period.timeZone))\n\(versionLabel)")]
        if !report.summary.isEmpty { result.append(Block(title: "Tổng quan", text: report.summary)) }
        if report.workItems.isEmpty { result.append(Block(title: "Công việc trong ngày", text: "Chưa có đầu việc trong các nguồn đã thu. Nhân viên có thể bổ sung công việc thủ công.")) }
        for (index, item) in report.workItems.enumerated() {
            var lines = ["\(item.project) · \(item.status.label)\(item.humanConfirmed ? " · Nhân viên đã xác nhận" : " · Cần rà soát")"]
            if report.narrativeProvenance == "automatic-local-v1" { lines = [item.project + " · Hoạt động ghi nhận từ log"] }
            if !item.activities.isEmpty { lines += item.activities.map { "- " + $0 } }
            if item.claims.isEmpty { lines.append("Kết quả: chưa được bổ sung/xác nhận.") }
            for claim in item.claims {
                let basis = claim.basis == .humanConfirmed ? "Nhân viên xác nhận" : "Agent đề xuất, cần kiểm chứng"
                lines.append("Kết quả: \(claim.text) [\(basis)]")
            }
            if !item.blockers.isEmpty { lines.append("Vướng mắc: \(item.blockers)") }
            if !item.nextActions.isEmpty { lines.append("Tiếp theo: \(item.nextActions)") }
            if let minutes = item.manualMinutes { lines.append("Thời gian nhân viên tự nhập: \(minutes) phút (không suy từ log agent).") }
            let links = report.evidence.filter { item.evidenceIDs.contains($0.id) }.compactMap(\.shareableURL)
            if !links.isEmpty { lines.append("Bằng chứng chia sẻ: " + links.joined(separator: "\n")) }
            else { lines.append("Bằng chứng: \(item.evidenceIDs.count) ghi nhận cục bộ; có thể đối chiếu trong AgentWatch.") }
            result.append(Block(title: "\(index + 1). \(item.title)", text: lines.joined(separator: "\n")))
        }
        if let desktop = report.desktopActivity {
            let lines = desktop.apps.map { "\($0.name): \(Int($0.seconds / 60)) phút \(Int($0.seconds) % 60) giây ở phía trước màn hình." }
            let start = desktop.collectionStartedAt.map { dateLabel($0, zone: report.period.timeZone, format: "HH:mm dd/MM/yyyy") } ?? "chưa có ghi nhận"
            result.append(Block(title: "Ứng dụng trên máy", text: (lines.isEmpty ? "Chưa có lịch sử ứng dụng cho ngày này." : lines.joined(separator: "\n")) + "\nBắt đầu có dữ liệu: \(start). Chỉ gồm khoảng AgentWatch chạy và đã nhập key; có thể gồm thời gian để ứng dụng mở nhưng không thao tác. Không phải giờ công; không khôi phục lịch sử trước khi bật thu thập."))
        }
        result += activityBlocks(report)
        let cost = report.costCoverage == .unavailable ? "Chưa có dữ liệu chi phí" : String(format: "$%.4f", NSDecimalNumber(decimal: report.knownCostSubtotal).doubleValue)
        let costLabel = report.costCoverage == .partial ? "Tạm tính phần có giá" : "Chi phí token tương đương"
        result.append(Block(title: "Số liệu sử dụng coding agent", text: "\(report.totalTokens) token được ghi nhận · \(report.usage.count) request/đoạn usage\n\(costLabel): \(cost). \(report.missingCostCount) dòng chưa có giá.\n\(report.unallocatedTokens) token chưa phân bổ vào task xác định.\nUsage thuộc ngày có sự kiện ghi nhận kết quả request. Chi phí là ước tính theo giá đã lưu, không phải hóa đơn hoặc chi phí thuê bao. Token và thời gian có log không đo năng suất hay giờ công."))
        let groups = Dictionary(grouping: report.usage, by: { "\($0.agent) · \($0.provider) · \($0.modelID)" })
        if !groups.isEmpty {
            let lines = groups.keys.sorted().map { key in
                let rows = groups[key]!, tokens = rows.reduce(0) { $0 + $1.tokens.total }
                let known = rows.compactMap(\.knownUSD), subtotal = known.reduce(0, +)
                let amount = known.isEmpty ? "chưa có giá" : String(format: "$%.4f", NSDecimalNumber(decimal: subtotal).doubleValue) + " ước tính"
                let coverage = known.count < rows.count ? " · có giá \(known.count)/\(rows.count) dòng" : ""
                return "\(key): \(tokens) token · \(amount)\(coverage)"
            }
            result.append(Block(title: "Chi tiết theo agent / provider / model", text: lines.joined(separator: "\n")))
        }
        let quota = ReportQuotaGrouping.latest(report.quota, organizationID: report.employee.organizationID, mappings: [])
        if !quota.isEmpty {
            let lines = quota.flatMap { snapshot -> [String] in
                let freshness = snapshot.isStale(at: report.period.cutoff) ? "đã cũ lúc chốt" : "snapshot trong ngày"
                return snapshot.windows.map { window in
                    "\(snapshot.provider) \(window.id): \(window.usedPercent.map { String(format: "đã dùng %.1f%%", $0) } ?? "chưa rõ") · \(freshness)"
                }
            }
            result.append(Block(title: "Quota tài khoản dùng chung", text: lines.isEmpty ? "Chưa có quota khả dụng." : lines.joined(separator: "\n")))
        }
        if !report.notes.isEmpty { result.append(Block(title: report.narrativeProvenance == "automatic-local-v1" ? "Ghi chú hệ thống" : "Ghi chú nhân viên", text: report.notes)) }
        if !report.warnings.isEmpty { result.append(Block(title: "Phạm vi và dữ liệu cần đối chiếu", text: report.warnings.map { "- " + $0 }.joined(separator: "\n"))) }
        return result
    }

    public static func promptTaskLabel(_ prompt: ReportPromptActivity, report: DailyReportDraft) -> String {
        guard let item = report.workItems.first(where: { $0.id == prompt.workItemID }) else { return "Chưa gắn task" }
        let reference = item.taskRefs.isEmpty ? "" : " [" + item.taskRefs.joined(separator: ", ") + "]"
        return item.project + " / " + item.title + reference
    }
    public static func activityBlocks(_ report: DailyReportDraft) -> [Block] {
        guard let activity = report.dailyActivity else {
            return [Block(title: "Prompt và app trong ngày", text: "Bản cũ chưa thu bảng prompt/task và app theo ngày. Tạo lại bản nháp để bổ sung.")]
        }
        var result: [Block] = []
        let appLines = activity.apps.map { app in
            let first = dateLabel(app.firstObservedAt, zone: report.period.timeZone, format: "HH:mm:ss")
            let last = dateLabel(app.lastObservedAt, zone: report.period.timeZone, format: "HH:mm:ss")
            let usage = app.usageRecordCount == 0 ? "chưa ghi nhận usage" : "\(app.usageRecordCount) dòng usage · \(app.tokens) token"
            return "\(app.name): \(app.promptCount) prompt · \(app.sessionCount) session · \(usage). Ghi nhận đầu/cuối: \(first)–\(last)."
        }
        result.append(Block(title: "App/agent sử dụng trong ngày", text: (appLines.isEmpty ? "Chưa có hoạt động trong nguồn đã đọc." : appLines.joined(separator: "\n")) + "\nChỉ gồm coding app/agent có log đã thu; Codex chưa tách CLI/Desktop. Mốc đầu/cuối không phải thời gian sử dụng liên tục hoặc giờ công."))
        let unknown = activity.prompts.filter { $0.scope == .unknown }.count
        let outside = activity.prompts.filter { $0.scope == .outOfScope }.count
        let unassigned = activity.prompts.filter { $0.workItemID == nil }.count
        result.append(Block(title: "Prompt dùng cho task và phạm vi dự án", text: "\(activity.prompts.count) prompt · \(unassigned) chưa gắn task · \(unknown) chưa xác định phạm vi · \(outside) ngoài phạm vi theo người rà soát.\nLiên kết task từ nhật ký không tự chứng minh prompt đúng phạm vi. Nội dung prompt gốc không nằm trong bản gửi quản lý."))
        if report.narrativeProvenance == "automatic-local-v1" {
            let groups = Dictionary(grouping: activity.prompts, by: { $0.workItemID ?? "unassigned" })
            for key in groups.keys.sorted() {
                let rows = groups[key]!, first = rows[0]
                let topics = Dictionary(grouping: rows, by: \.summary).map { "\($0.key) · \($0.value.count) prompt" }.sorted()
                let apps = Set(rows.map(\.app)).sorted().joined(separator: ", ")
                result.append(Block(title: promptTaskLabel(first, report: report), text:
                    "\(rows.count) prompt · \(apps)\n" + topics.joined(separator: "\n") + "\nPhạm vi nghiệp vụ: chưa xác định. Nhóm theo phiên hoặc nhật ký task; không xác nhận hoàn thành."))
            }
            return result
        }
        for (index, prompt) in activity.prompts.enumerated() {
            let basis: String = switch prompt.taskBasis {
            case .unassigned: "Chưa xác định"
            case .taskJournal: "Nhật ký task tại thời điểm prompt"
            case .humanConfirmed: "Người rà soát gắn task"
            case .sessionContext: "Nhóm theo phiên; chưa xác định task nghiệp vụ"
            }
            let time = dateLabel(prompt.timestamp, zone: report.period.timeZone, format: "HH:mm:ss")
            result.append(Block(title: "Prompt \(index + 1) · \(time) · \(prompt.app)", text:
                "Mục đích: \(prompt.summary.isEmpty ? "Chưa bổ sung" : prompt.summary)\nTask: \(promptTaskLabel(prompt, report: report))\nNguồn liên kết: \(basis)\nDự án từ log: \(prompt.observedProject)\nPhạm vi: \(prompt.scope.label)\nLý do / yêu cầu đối chiếu: \(prompt.scopeReason.isEmpty ? "Chưa bổ sung" : prompt.scopeReason)"))
        }
        return result
    }

    public static func plainText(_ report: DailyReportDraft, revision: Int? = nil) -> String {
        blocks(report, revision: revision).map { block in
            [block.title, block.text].compactMap { $0 }.map(ShareText.clean).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
    public static func markdown(_ report: DailyReportDraft, revision: Int? = nil) -> String {
        blocks(report, revision: revision).enumerated().map { index, block in
            let title = block.title.map { (index == 0 ? "# " : "## ") + markdownEscape($0) + "\n\n" } ?? ""
            return title + markdownEscape(block.text)
        }.joined(separator: "\n\n")
    }
    private static func markdownEscape(_ text: String) -> String {
        ShareText.clean(text).replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
    public static func html(_ report: DailyReportDraft, revision: Int? = nil) -> String {
        let content = blocks(report, revision: revision).enumerated().map { index, block in
            "<section class=\"\(index == 0 ? "hero" : "section")\"><\(index == 0 ? "h1" : "h2")>\(ShareText.html(block.title ?? ""))</\(index == 0 ? "h1" : "h2")><p>\(ShareText.html(block.text).replacingOccurrences(of: "\n", with: "<br>"))</p></section>"
        }.joined()
        return """
        <!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>Báo cáo công việc ngày</title><style>
        *{box-sizing:border-box}body{margin:0;background:#f4f5f7;color:#223047;font:15px/1.65 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
        main{max-width:900px;margin:36px auto;background:#fff;border:1px solid #dfe4eb;border-radius:12px;overflow:hidden}
        .hero{background:#17283e;color:#fff;padding:32px 40px;border-top:6px solid #d9ad60}.hero p{color:#d9e2ef;margin-bottom:0}
        h1{font-size:25px;line-height:1.35;letter-spacing:.01em;margin:0 0 14px}h2{font-size:18px;line-height:1.4;margin:0 0 12px;color:#193952}
        .section{padding:24px 40px;border-bottom:1px solid #e7ebf0;break-inside:avoid}p{white-space:normal;overflow-wrap:anywhere;margin:0}
        footer{padding:18px 40px;color:#68768b;font-size:12px}@media print{body{background:#fff}main{margin:0;border:0;border-radius:0}.hero{-webkit-print-color-adjust:exact}footer{padding-top:12px}}
        </style></head><body><main>\(content)<footer>AgentWatch · Báo cáo nội bộ · Nội dung được tổng hợp từ nguồn cục bộ</footer></main></body></html>
        """
    }
    public static func csv(_ report: DailyReportDraft) -> String {
        func cell(_ text: String) -> String {
            var value = ShareText.clean(text)
            if let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let header = ["Ngày", "Nhân viên", "Dự án", "Công việc", "Trạng thái", "Kết quả", "Vướng mắc", "Tiếp theo",
                      "Loại dòng", "App", "Số prompt", "Số session", "Dòng usage", "Token ghi nhận", "Mốc đầu", "Mốc cuối",
                      "Phạm vi", "Lý do", "Nguồn gắn task", "Nội dung / mục đích prompt"]
        let day = dateLabel(report.period.start, zone: report.period.timeZone)
        var rows = report.workItems.map { item in
            [day, report.employee.displayName, item.project, item.title,
             item.status.label, item.claims.map(\.text).joined(separator: " | "), item.blockers, item.nextActions,
             "Công việc"] + Array(repeating: "", count: 11)
        }
        if let activity = report.dailyActivity {
            for app in activity.apps {
                rows.append([day, report.employee.displayName, "", "", "", "", "", "", "App", app.name,
                    String(app.promptCount), String(app.sessionCount), String(app.usageRecordCount), String(app.tokens),
                    dateLabel(app.firstObservedAt, zone: report.period.timeZone, format: "HH:mm:ss"),
                    dateLabel(app.lastObservedAt, zone: report.period.timeZone, format: "HH:mm:ss"), "", "", "", ""])
            }
            for prompt in activity.prompts {
                rows.append([day, report.employee.displayName, prompt.observedProject, promptTaskLabel(prompt, report: report),
                    "", "", "", "", (prompt.origin == .agentContinuation ? "Agent tự chạy" : prompt.origin == .context ? "Ngữ cảnh tự động" : "Prompt"), prompt.app, "1", "", "", "",
                    dateLabel(prompt.timestamp, zone: report.period.timeZone, format: "HH:mm:ss"), "",
                    prompt.scope.label, prompt.scopeReason, prompt.taskBasis.rawValue, prompt.content.map(ReportPromptText.clean) ?? prompt.summary])
            }
        }
        if let desktop = report.desktopActivity {
            for app in desktop.apps {
                rows.append([day, report.employee.displayName, "", "", "", "\(Int(app.seconds)) giây foreground", "", "", "Ứng dụng trên máy", app.name] + Array(repeating: "", count: 10))
            }
        }
        return ([header] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    public static func json(_ report: DailyReportDraft, revision: Int? = nil) throws -> Data {
        // Deliberate share projection: never encode the local draft/snapshot,
        // which contains source paths, audit joins and local evidence references.
        let rows: [[String: Any]] = report.workItems.map { item in
            ["project": ShareText.clean(item.project), "title": ShareText.clean(item.title), "status": item.status.rawValue,
             "confirmedByEmployee": item.humanConfirmed, "activities": item.activities.map(ShareText.clean),
             "results": item.claims.map { ["text": ShareText.clean($0.text), "basis": $0.basis.rawValue] },
             "blockers": ShareText.clean(item.blockers), "nextActions": ShareText.clean(item.nextActions)]
        }
        var value: [String: Any] = ["schemaVersion": 1, "rendererVersion": "daily-v1", "revision": revision as Any? ?? NSNull(),
            "employee": ["organization": ShareText.clean(report.employee.organizationID), "id": ShareText.clean(report.employee.employeeID), "name": ShareText.clean(report.employee.displayName)],
            "day": dateLabel(report.period.start, zone: report.period.timeZone, format: "yyyy-MM-dd"), "timeZone": report.period.timeZone,
            "cutoff": dateLabel(report.period.cutoff, zone: report.period.timeZone, format: "yyyy-MM-dd'T'HH:mm:ssZZZZZ"),
            "summary": ShareText.clean(report.summary), "workItems": rows, "notes": ShareText.clean(report.notes),
            "tokens": report.totalTokens, "unallocatedTokens": report.unallocatedTokens,
            "knownCostSubtotalUSD": NSDecimalNumber(decimal: report.knownCostSubtotal).stringValue,
            "costCoverage": report.costCoverage.rawValue, "requestsMissingCost": report.missingCostCount,
            "warnings": report.warnings.map(ShareText.clean)]
        if let activity = report.dailyActivity {
            value["dailyApps"] = activity.apps.map { app -> [String: Any] in
                ["app": app.name, "prompts": app.promptCount, "sessions": app.sessionCount, "usageRecords": app.usageRecordCount,
                 "tokens": app.tokens, "usageCoverage": app.usageRecordCount == 0 ? "unavailable" : "observedOnly", "firstObserved": dateLabel(app.firstObservedAt, zone: report.period.timeZone, format: "HH:mm:ss"),
                 "lastObserved": dateLabel(app.lastObservedAt, zone: report.period.timeZone, format: "HH:mm:ss")]
            }
            value["promptTasks"] = activity.prompts.enumerated().map { index, prompt -> [String: Any] in
                ["number": index + 1, "time": dateLabel(prompt.timestamp, zone: report.period.timeZone, format: "HH:mm:ss"),
                 "app": ShareText.clean(prompt.app), "summary": ShareText.clean(prompt.summary),
                 "content": prompt.content.map(ReportPromptText.clean) ?? "", "toolObservations": (prompt.toolObservations ?? []).map(ReportPromptText.clean),
                 "toolObservationCount": prompt.toolObservationCount ?? 0, "origin": (prompt.origin ?? .employee).rawValue,
                 "task": ShareText.clean(promptTaskLabel(prompt, report: report)), "taskBasis": prompt.taskBasis.rawValue,
                 "observedProject": ShareText.clean(prompt.observedProject), "scope": prompt.scope.rawValue,
                 "scopeReason": ShareText.clean(prompt.scopeReason)]
            }
        }
        if let desktop = report.desktopActivity {
            value["desktopApps"] = desktop.apps.map { ["name": ShareText.clean($0.name), "foregroundSeconds": $0.seconds] as [String: Any] }
            value["desktopCoverage"] = "Only while AgentWatch is running and enrolled; no retrospective app history; foreground time is not work time."
            value["desktopTimeline"] = (desktop.timeline ?? []).map { span -> [String: Any] in
                ["app": ShareText.clean(span.name), "start": dateLabel(span.start, zone: report.period.timeZone, format: "HH:mm:ss"),
                 "end": dateLabel(span.end, zone: report.period.timeZone, format: "HH:mm:ss"), "interaction": span.interaction.rawValue]
            }
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    }

    /// Native paginated A4 PDF; text remains selectable, and long sections flow
    /// across pages without scaling to unreadable font sizes.
    public static func pdf(_ report: DailyReportDraft, revision: Int? = nil) throws -> Data {
        try ReportPDFDocument.render(report, revision: revision)
    }
}
