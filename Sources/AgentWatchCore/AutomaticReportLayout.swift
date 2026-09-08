import Foundation

/// A compact daily journal: employee requests, their location, apps and files.
enum AutomaticReportLayout {
    typealias Block = DailyReportRenderer.Block
    static func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        if value >= 3600 { return "\(value / 3600) giờ \((value % 3600) / 60) phút" }
        return "\(value / 60) phút \(value % 60) giây"
    }
    static func blocks(_ report: DailyReportDraft, revision: Int?) -> [Block] {
        func time(_ date: Date) -> String { DailyReportRenderer.dateLabel(date, zone: report.period.timeZone, format: "HH:mm") }
        let prompts = (report.dailyActivity?.prompts ?? []).filter { ($0.origin ?? .employee) == .employee }
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        let day = DailyReportRenderer.dateLabel(report.period.start, zone: report.period.timeZone)
        let apps = Dictionary(grouping: prompts, by: \.app).keys.sorted()
        let files = Set(prompts.flatMap { prompt in (prompt.fileActivities ?? []).map { $0.path.hasPrefix("/") ? $0.path : prompt.observedProject + "/" + $0.path } })
        var result = [Block(title: "NHẬT KÝ LÀM VIỆC", text: "\(report.employee.displayName) · \(day)\nCập nhật đến \(time(report.period.cutoff)) · \(report.period.timeZone)\n" + (revision.map { "Phiên bản \($0)" } ?? "Báo cáo tự động từ log"), kind: .hero)]
        result.append(Block(title: "01  TRONG NGÀY", text: "\(prompts.count) prompt đã gửi · \(files.count) file có ghi nhận\n" + apps.map { name in "\(name): \(prompts.filter { $0.app == name }.count) prompt" }.joined(separator: " · "), kind: .section))
        result.append(Block(title: "02  ỨNG DỤNG ĐÃ DÙNG", text: "Thời gian app ở phía trước màn hình; không phải giờ công.", kind: .section))
        if let desktop = report.desktopActivity, !desktop.apps.isEmpty {
            for app in desktop.apps.sorted(by: { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }) {
                let active = (desktop.timeline ?? []).filter { $0.name == app.name && $0.interaction == .recentInput }
                    .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
                let interaction = desktop.timeline == nil ? "Chưa có phân loại tương tác." : "Có tương tác gần đây: " + duration(active)
                result.append(Block(title: app.name + " · " + duration(app.seconds), text: interaction, kind: .appUsage,
                                    fraction: desktop.observedSeconds > 0 ? app.seconds / desktop.observedSeconds : 0))
            }
        } else { result.append(Block(title: nil, text: "Chưa có dữ liệu ứng dụng cho ngày này.")) }
        result.append(Block(title: "03  PROMPT & FILE", text: "Theo thời gian gửi. File là thao tác agent được ghi nhận cùng phiên giữa hai prompt; không xác nhận thao tác thành công.", kind: .section))
        var sessions: [String: Int] = [:]
        for prompt in prompts where sessions[prompt.sessionRef] == nil { sessions[prompt.sessionRef] = sessions.count + 1 }
        for (index, prompt) in prompts.enumerated() {
            let location = ReportPromptText.clean(prompt.observedProject)
            let session = prompt.sessionTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Phiên \(sessions[prompt.sessionRef] ?? 0)"
            var lines = ["Ở đâu: \(location) · \(session)", "", ReportPromptText.clean(prompt.content ?? prompt.summary)]
            var seen = Set<String>()
            let actions = (prompt.fileActivities ?? []).filter { seen.insert($0.action + "|" + $0.path).inserted }
            lines += ["", "File: " + (actions.isEmpty ? "Chưa có ghi nhận đường dẫn." : actions.map { "\($0.action): \($0.path)" }.joined(separator: "\n"))]
            result.append(Block(title: String(format: "P%03d", index + 1) + " · \(time(prompt.timestamp)) · \(prompt.app)", text: lines.joined(separator: "\n"), kind: .prompt))
        }
        if prompts.isEmpty { result.append(Block(title: nil, text: "Chưa có prompt người dùng trong nguồn đã đọc.")) }
        var coverage = "App ngoài agent chỉ ghi thời gian dùng và trạng thái tương tác. File dựa trên log thao tác agent; prompt đã lọc ngữ cảnh và che thông tin xác thực phổ biến."
        if report.desktopActivity == nil || report.sourceRoots.contains(where: { !$0.readable }) || report.sourceFiles.contains(where: { !$0.readable || $0.malformedRecordCount > 0 || $0.changedDuringRead }) {
            coverage += " Có nguồn thiếu; chỉ tính phần đã ghi nhận."
        }
        result.append(Block(title: nil, text: coverage))
        return result
    }
}
