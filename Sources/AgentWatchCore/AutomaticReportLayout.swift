import Foundation

/// Management overview first, complete sanitized prompt journal in the appendix.
/// All metrics describe observations; no automatic performance/completion score.
enum AutomaticReportLayout {
    typealias Block = DailyReportRenderer.Block

    static func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        if value >= 3600 { return "\(value / 3600) giờ \((value % 3600) / 60) phút" }
        return "\(value / 60) phút \(value % 60) giây"
    }

    static func blocks(_ report: DailyReportDraft, revision: Int?) -> [Block] {
        func time(_ date: Date) -> String { DailyReportRenderer.dateLabel(date, zone: report.period.timeZone, format: "HH:mm:ss") }
        let prompts = (report.dailyActivity?.prompts ?? []).sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        let employeePrompts = prompts.filter { ($0.origin ?? .employee) == .employee }
        let automated = prompts.filter { ($0.origin ?? .employee) != .employee }
        var sessions: [String: Int] = [:]
        for prompt in prompts where sessions[prompt.sessionRef] == nil { sessions[prompt.sessionRef] = sessions.count + 1 }
        let day = DailyReportRenderer.dateLabel(report.period.start, zone: report.period.timeZone)
        var result = [Block(title: "BÁO CÁO HOẠT ĐỘNG NGÀY", text: "\(report.employee.displayName) · \(day)\nChốt dữ liệu lúc \(time(report.period.cutoff)) · \(report.period.timeZone)\n" + (revision.map { "Phiên bản \($0)" } ?? "Báo cáo tự động từ log"), kind: .hero)]
        result.append(Block(title: "01  TỔNG QUAN CÔNG VIỆC", text: "\(employeePrompts.count) prompt nhân viên; \(automated.count) lượt tự động/ngữ cảnh; \(sessions.count) phiên có ghi nhận; \(report.workItems.count) nhóm công việc được đối chiếu theo phiên hoặc nhật ký task. Nội dung yêu cầu nằm ở phần 05. Trạng thái hoàn thành chỉ được ghi khi có căn cứ xác nhận.", kind: .section))
        if report.workItems.isEmpty { result.append(Block(title: "Chưa có công việc từ nguồn đã đọc", text: "Kiểm tra ngày đã chọn và nguồn log được cấu hình trên máy.")) }
        for (index, item) in report.workItems.enumerated() {
            let rows = employeePrompts.filter { $0.workItemID == item.id }
            let refs = Set(rows.compactMap { sessions[$0.sessionRef] }).sorted().map { "Phiên \($0)" }.joined(separator: ", ")
            var lines = ["Dự án từ log: \(item.project) · \(rows.count) prompt · \(refs)"]
            lines += item.activities
            lines.append("Kết quả: " + (item.claims.isEmpty ? "Chưa có xác nhận kết quả từ nguồn đã thu." : item.claims.map(\.text).joined(separator: "; ")))
            lines.append("Vướng mắc: " + (item.blockers.isEmpty ? "Chưa được xác nhận trong dữ liệu." : item.blockers))
            lines.append("Tiếp theo: " + (item.nextActions.isEmpty ? "Chưa được xác nhận trong dữ liệu." : item.nextActions))
            result.append(Block(title: "\(index + 1). \(item.title)", text: lines.joined(separator: "\n")))
        }

        result.append(Block(title: "02  ỨNG DỤNG & THỜI GIAN GHI NHẬN", text: "Ứng dụng ở phía trước màn hình; thời lượng không đồng nghĩa giờ công. “Có tương tác gần đây” nghĩa là máy có sự kiện nhập liệu trong 60 giây gần nhất, không lưu phím gõ hay nội dung cửa sổ.", kind: .section))
        if let desktop = report.desktopActivity {
            for app in desktop.apps.sorted(by: { $0.seconds > $1.seconds }) {
                let spans = (desktop.timeline ?? []).filter { $0.name == app.name }
                let active = spans.filter { $0.interaction == .recentInput }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
                let idle = spans.filter { $0.interaction == .idle }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
                result.append(Block(title: app.name + " · " + duration(app.seconds), text: "Có tương tác gần đây: \(duration(active)) · Không thao tác: \(duration(idle)) · Chưa phân loại: \(duration(max(0, app.seconds - active - idle)))", kind: .appUsage, fraction: desktop.observedSeconds > 0 ? app.seconds / desktop.observedSeconds : 0))
            }
            if desktop.apps.isEmpty { result.append(Block(title: nil, text: "Chưa có lịch sử ứng dụng cho ngày này.")) }
            let coverage = desktop.timeline ?? []
            var lines = ["Tổng thời gian quan sát được: " + duration(desktop.observedSeconds)]
            if let first = coverage.first, let last = coverage.last {
                lines.append("Trong ngày: \(time(first.start)) - \(time(last.end)). Các khoảng không có mẫu không được tính là không thao tác.")
                var cursor = first.start
                for span in coverage {
                    if span.start.timeIntervalSince(cursor) >= 60 { lines.append("Thiếu dữ liệu: \(time(cursor)) - \(time(span.start))") }
                    cursor = span.end
                }
                if report.period.cutoff.timeIntervalSince(last.end) >= 60 { lines.append("Thiếu dữ liệu đến lúc chốt: \(time(last.end)) - \(time(report.period.cutoff))") }
                lines.append("Trước \(time(first.start)): không có mẫu trong ngày; không suy ra máy đã bật hoặc nhân viên nghỉ.")
            }
            lines.append("Chỉ ghi khi AgentWatch chạy trên máy đã gắn key. Máy ngủ, phiên không hoạt động hoặc app bị dừng có thể tạo khoảng trống. Không có lịch sử trước khi bật thu thập.")
            result.append(Block(title: "Độ phủ dữ liệu", text: lines.joined(separator: "\n")))
            if !coverage.isEmpty {
                // Group short sampling spans into hour/app/state rows without
                // merging gaps into fabricated continuous work sessions.
                var bins: [String: (Date, String, DesktopInteractionState, Double)] = [:]
                for span in coverage {
                    var start = span.start
                    while start < span.end {
                        let hour = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / 3600) * 3600)
                        let end = min(span.end, hour.addingTimeInterval(3600))
                        let key = "\(hour.timeIntervalSince1970)|\(span.name)|\(span.interaction.rawValue)"
                        let prior = bins[key]?.3 ?? 0
                        bins[key] = (hour, span.name, span.interaction, prior + end.timeIntervalSince(start)); start = end
                    }
                }
                let rows = bins.keys.sorted().map { key -> String in
                    let row = bins[key]!
                    return "\(time(row.0).prefix(5)) - \(time(row.0.addingTimeInterval(3600)).prefix(5))  |  \(row.1)  |  \(duration(row.3))  |  \(row.2.label)"
                }
                result.append(Block(title: "Diễn biến ứng dụng theo giờ", text: rows.joined(separator: "\n")))
            }
        } else { result.append(Block(title: nil, text: "Không đọc được lịch sử ứng dụng; xem phần chất lượng dữ liệu.")) }

        result.append(Block(title: "03  TƯƠNG TÁC VỚI CODING AGENT", text: "Số liệu theo app/agent từ log trong ngày. Mốc đầu và cuối là sự kiện quan sát được, không phải một ca làm việc liên tục.", kind: .section))
        for app in report.dailyActivity?.apps ?? [] {
            let humanCount = employeePrompts.filter { $0.app == app.name }.count
            let autoCount = automated.filter { $0.app == app.name }.count
            result.append(Block(title: app.name, text: "\(humanCount) prompt nhân viên · \(autoCount) lượt tự động/ngữ cảnh · \(app.sessionCount) phiên · \(app.usageRecordCount) đoạn usage\nMốc ghi nhận: \(time(app.firstObservedAt)) - \(time(app.lastObservedAt))\n\(app.tokens.formatted()) token (bao gồm token cache nếu nguồn có)."))
        }
        let cost = report.costCoverage == .unavailable ? "Chưa có giá" : String(format: "$%.4f", NSDecimalNumber(decimal: report.knownCostSubtotal).doubleValue)
        result.append(Block(title: "Usage & quota", text: "\(report.totalTokens.formatted()) token được ghi nhận · Chi phí token tương đương: \(cost)\n\(report.missingCostCount) dòng chưa có giá. Đây là ước tính, không phải hóa đơn hoặc chi phí thuê bao. Token không đo năng suất.\n" + ReportQuotaGrouping.latest(report.quota, organizationID: report.employee.organizationID, mappings: []).flatMap { snapshot in snapshot.windows.map { window in "\(snapshot.provider) / \(window.id): " + (window.usedPercent.map { String(format: "đã dùng %.1f%%", $0) } ?? "chưa rõ") + (snapshot.isStale(at: report.period.cutoff) ? " · snapshot đã cũ" : " · snapshot trong ngày") } }.joined(separator: "\n")))
        let unknown = employeePrompts.filter { $0.scope == .unknown }.count
        result.append(Block(title: "04  CHẤT LƯỢNG & PHẠM VI DỮ LIỆU", text: "\(unknown)/\(employeePrompts.count) prompt nhân viên chưa xác định phạm vi nghiệp vụ. Tên thư mục/phiên là thông tin đối chiếu, không tự chứng minh yêu cầu đúng dự án.\nPrompt đã che mẫu thông tin xác thực phổ biến và lược ngữ cảnh hệ thống nhận diện được; không bảo đảm nhận diện mọi bí mật trong văn bản tự do.\n" + report.warnings.map { warning in
            warning.contains("Codex counter reset") ? "Codex có khoảng bộ đếm bị đặt lại/điều chỉnh; usage không chắc chắn đã được loại, tổng chỉ phản ánh phần xác định được." : warning
        }.joined(separator: "\n"), kind: .section))

        result.append(Block(title: "05  NHẬT KÝ PROMPT CHI TIẾT", text: "Theo thứ tự thời gian. Nội dung yêu cầu được giữ sau bước lọc; không cắt ngắn trong phụ lục. Công cụ liệt kê là tối đa 3 ghi nhận trong cùng phiên, từ prompt này đến prompt tiếp theo; không xác nhận công cụ thuộc duy nhất prompt hoặc chứng minh công việc hoàn thành.", kind: .section))
        for (index, prompt) in employeePrompts.enumerated() {
            let tools = prompt.toolObservations ?? []
            var lines = ["Dự án từ log: \(prompt.observedProject) · Phiên \(sessions[prompt.sessionRef] ?? 0)",
                         "Task: \(DailyReportRenderer.promptTaskLabel(prompt, report: report))",
                         "Phạm vi: \(prompt.scope.label) · \(prompt.taskBasis == .taskJournal ? "Có nhật ký gắn task" : "Đối chiếu theo phiên; chưa xác nhận task nghiệp vụ")",
                         "", "YÊU CẦU CỦA NHÂN VIÊN", prompt.content ?? prompt.summary, "",
                         "GHI NHẬN CÔNG CỤ: \(prompt.toolObservationCount ?? 0)"]
            if tools.isEmpty { lines.append("Chưa có ghi nhận công cụ trong khoảng đối chiếu; không suy ra agent không xử lý.") }
            else { lines += tools.map { "- " + ReportPromptText.clean($0) } }
            if (prompt.toolObservationCount ?? 0) > tools.count { lines.append("Hiển thị \(tools.count)/\(prompt.toolObservationCount ?? 0) ghi nhận; đối chiếu thêm trong log cục bộ.") }
            result.append(Block(title: String(format: "P%03d", index + 1) + "  ·  \(time(prompt.timestamp))  ·  \(prompt.app)", text: lines.joined(separator: "\n"), kind: .prompt))
        }
        if !automated.isEmpty {
            result.append(Block(title: "06  AGENT TỰ CHẠY & NGỮ CẢNH", text: "\(automated.count) lượt do hệ thống/agent điều phối; không tính vào prompt nhân viên hoặc thời gian tương tác trên máy. Các hướng dẫn hệ thống lặp lại được lược, giữ thời điểm và mục tiêu để đối chiếu.", kind: .section))
            let lines = automated.map { row in
                "\(time(row.timestamp))  |  \(row.app) · Phiên \(sessions[row.sessionRef] ?? 0)  |  " + (row.origin == .context ? "Ngữ cảnh tự động" : ReportPromptText.excerpt(row.content ?? "Agent tự tiếp tục", limit: 320))
            }
            result.append(Block(title: nil, text: lines.joined(separator: "\n")))
        }
        return result
    }
}
