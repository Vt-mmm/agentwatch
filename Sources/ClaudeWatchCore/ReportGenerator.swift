// Render daily/weekly report cho list PromptRecord. Theo template mục 12 của
// tài liệu coaching, có aggregate stats + breakdown theo project + top gaps.

import Foundation

public enum ReportScope: Sendable, Equatable {
    case day(Date)
    case week(start: Date)            // tuần Thứ Hai → Chủ Nhật
    case custom(start: Date, end: Date, label: String)

    public var label: String {
        switch self {
        case .day(let d):
            return ReportGenerator.dayLabel.string(from: d)
        case .week(let start):
            let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
            return "Tuần \(ReportGenerator.dayLabel.string(from: start)) → \(ReportGenerator.dayLabel.string(from: end))"
        case .custom(_, _, let label):
            return label
        }
    }
}

/// Số liệu tổng hợp.
public struct ReportStats: Sendable, Equatable {
    public let totalPrompts: Int
    public let taskPrompts: Int
    public let followUpPrompts: Int
    public let avgStars: Double
    public let starCounts: [Int: Int]          // 0★→count, … 5★→count
    public let topMissingSections: [(SpecSection, Int)]
    public let projectBreakdown: [(project: String, count: Int, avgStars: Double)]
    public let sourceBreakdown: [SessionSource: Int]   // cli/desktop count

    public init(totalPrompts: Int, taskPrompts: Int, followUpPrompts: Int,
                avgStars: Double, starCounts: [Int: Int],
                topMissingSections: [(SpecSection, Int)],
                projectBreakdown: [(project: String, count: Int, avgStars: Double)],
                sourceBreakdown: [SessionSource: Int] = [:]) {
        self.totalPrompts = totalPrompts
        self.taskPrompts = taskPrompts
        self.followUpPrompts = followUpPrompts
        self.avgStars = avgStars
        self.starCounts = starCounts
        self.topMissingSections = topMissingSections
        self.projectBreakdown = projectBreakdown
        self.sourceBreakdown = sourceBreakdown
    }

    public static func == (lhs: ReportStats, rhs: ReportStats) -> Bool {
        lhs.totalPrompts == rhs.totalPrompts
            && lhs.taskPrompts == rhs.taskPrompts
            && lhs.avgStars == rhs.avgStars
            && lhs.starCounts == rhs.starCounts
            && lhs.sourceBreakdown == rhs.sourceBreakdown
    }
}

public enum ReportGenerator {

    /// Tính stats từ list prompts.
    public static func stats(for records: [PromptRecord]) -> ReportStats {
        let task = records.filter { $0.score.isTaskPrompt }
        let follow = records.count - task.count

        let avg: Double = task.isEmpty ? 0
            : Double(task.reduce(0) { $0 + $1.score.stars }) / Double(task.count)

        var stars: [Int: Int] = [:]
        for r in task { stars[r.score.stars, default: 0] += 1 }

        var missingCount: [SpecSection: Int] = [:]
        for r in task {
            for s in r.score.sectionsMissing { missingCount[s, default: 0] += 1 }
        }
        let topMissing = missingCount.sorted { $0.value > $1.value }
            .prefix(3).map { ($0.key, $0.value) }

        var byProj: [String: (count: Int, total: Int)] = [:]
        for r in task {
            byProj[r.projectDisplay, default: (0, 0)].count += 1
            byProj[r.projectDisplay, default: (0, 0)].total += r.score.stars
        }
        let proj = byProj
            .map { (project: $0.key, count: $0.value.count,
                    avgStars: Double($0.value.total) / Double(max($0.value.count, 1))) }
            .sorted { $0.count > $1.count }

        var srcCount: [SessionSource: Int] = [:]
        for r in records { srcCount[r.source, default: 0] += 1 }

        return ReportStats(
            totalPrompts: records.count,
            taskPrompts: task.count,
            followUpPrompts: follow,
            avgStars: avg,
            starCounts: stars,
            topMissingSections: Array(topMissing),
            projectBreakdown: proj,
            sourceBreakdown: srcCount
        )
    }

    /// Render daily/weekly report ra Markdown theo template mục 12.
    public static func markdown(scope: ReportScope, records: [PromptRecord]) -> String {
        let s = stats(for: records)
        var md = "# DAILY/WEEKLY REPORT — AI Coding theo SDD/VSDD\n\n"
        md += "**Phạm vi:** \(scope.label)\n"
        md += "**Tổng prompts:** \(s.totalPrompts) (task: \(s.taskPrompts), follow-up: \(s.followUpPrompts))\n"
        md += "**Avg score (task prompts):** \(starString(s.avgStars))\n"
        let cli = s.sourceBreakdown[.cli] ?? 0
        let desk = s.sourceBreakdown[.desktop] ?? 0
        md += "**Nguồn:** CLI \(cli) · Desktop \(desk)\n\n"

        md += "## 1. Phân bổ chất lượng prompt\n"
        for star in (0...5).reversed() {
            let c = s.starCounts[star] ?? 0
            md += "- \(starGlyph(star)) (\(star)★): \(c)\n"
        }
        md += "\n"

        md += "## 2. Section hay thiếu nhất\n"
        if s.topMissingSections.isEmpty {
            md += "_Không có data task prompt trong khoảng này._\n\n"
        } else {
            for (sec, n) in s.topMissingSections {
                md += "- **\(sec.label)** — thiếu trong \(n) prompt\n"
            }
            md += "\n"
        }

        md += "## 3. Breakdown theo project\n"
        if s.projectBreakdown.isEmpty {
            md += "_Không có project nào._\n\n"
        } else {
            md += "| Project | Task prompts | Avg score |\n|---|---:|---:|\n"
            for p in s.projectBreakdown.prefix(10) {
                md += "| \(p.project) | \(p.count) | \(String(format: "%.1f", p.avgStars))★ |\n"
            }
            md += "\n"
        }

        md += "## 4. Prompts chi tiết\n"
        if records.isEmpty {
            md += "_Không có prompt nào._\n"
            return md
        }
        for r in records.prefix(50) {
            let tag = r.score.isTaskPrompt ? "\(r.score.stars)★" : "follow-up"
            md += "\n### \(timeLabel.string(from: r.timestamp)) · \(tag) · \(r.source.label)\n"
            md += "_\(r.projectDisplay)_\n\n"
            if r.score.isTaskPrompt && !r.score.sectionsMissing.isEmpty {
                md += "Thiếu: " + r.score.sectionsMissing.map(\.label).joined(separator: ", ") + "\n\n"
            }
            md += "```\n\(r.text.prefix(800))\(r.text.count > 800 ? "\n…[truncated]" : "")\n```\n"
        }
        if records.count > 50 {
            md += "\n_Còn \(records.count - 50) prompt nữa không hiển thị._\n"
        }
        return md
    }

    /// Render thành HTML self-contained, in được PDF.
    public static func html(scope: ReportScope, records: [PromptRecord]) -> String {
        let s = stats(for: records)
        var rows = ""
        for star in (0...5).reversed() {
            let c = s.starCounts[star] ?? 0
            rows += "<tr><td>\(starGlyph(star)) (\(star)★)</td><td>\(c)</td></tr>"
        }
        var missing = ""
        for (sec, n) in s.topMissingSections {
            missing += "<li><b>\(sec.label)</b> — thiếu trong \(n) prompt</li>"
        }
        var projects = ""
        for p in s.projectBreakdown.prefix(10) {
            projects += "<tr><td>\(htmlEscape(p.project))</td>"
                + "<td>\(p.count)</td>"
                + "<td>\(String(format: "%.1f", p.avgStars))★</td></tr>"
        }
        var details = ""
        for r in records.prefix(50) {
            let tag = r.score.isTaskPrompt ? "\(r.score.stars)★" : "follow-up"
            let miss = r.score.isTaskPrompt && !r.score.sectionsMissing.isEmpty
                ? "<p class=missing>Thiếu: " + r.score.sectionsMissing.map(\.label).joined(separator: ", ") + "</p>"
                : ""
            details += """
            <div class="prompt">
              <div class="ptime">\(timeLabel.string(from: r.timestamp)) · <span class="tag">\(tag)</span></div>
              <div class="proj">\(htmlEscape(r.projectDisplay))</div>
              \(miss)
              <pre>\(htmlEscape(String(r.text.prefix(800))))\(r.text.count > 800 ? "\n…[truncated]" : "")</pre>
            </div>
            """
        }
        return """
        <!DOCTYPE html><html lang="vi"><head><meta charset="UTF-8">
        <title>Coaching Report — \(htmlEscape(scope.label))</title>
        <style>
          body{font-family:-apple-system,BlinkMacSystemFont,system-ui;color:#172033;background:#faf7f2;margin:0;padding:32px}
          .wrap{max-width:960px;margin:0 auto;background:#fff;border-radius:18px;padding:32px;box-shadow:0 6px 24px rgba(0,0,0,.06)}
          h1{margin:0 0 6px;font-size:28px;letter-spacing:-.02em}
          .muted{color:#666}
          h2{margin-top:28px;font-size:20px}
          table{width:100%;border-collapse:collapse;margin:8px 0}
          th,td{padding:8px 10px;border-bottom:1px solid #eee;text-align:left}
          th{font-weight:600;background:#fafafa}
          .stat{display:inline-block;padding:10px 16px;margin:4px 8px 4px 0;background:#fff4e8;border-radius:12px;border:1px solid #f0c7a0}
          .stat b{display:block;font-size:22px;color:#cc785c}
          .prompt{margin:14px 0;padding:12px;border:1px solid #eee;border-radius:10px;background:#fcfbf9}
          .ptime{font-weight:600}
          .tag{background:#cc785c;color:#fff;padding:2px 8px;border-radius:999px;font-size:12px}
          .proj{color:#888;font-size:13px;margin:2px 0 8px}
          .missing{color:#b14a1a;font-size:13px;margin:6px 0}
          pre{background:#1a1a1a;color:#e8e2d5;padding:12px;border-radius:8px;overflow-x:auto;white-space:pre-wrap;font-size:12px;line-height:1.5}
          @media print{body{background:#fff;padding:0}.wrap{box-shadow:none}}
        </style></head><body><div class="wrap">
        <h1>Coaching Report</h1>
        <div class="muted">\(htmlEscape(scope.label)) · SDD/VSDD/CoDD rubric</div>
        <div style="margin-top:20px">
          <span class="stat"><b>\(s.totalPrompts)</b>Tổng prompts</span>
          <span class="stat"><b>\(s.taskPrompts)</b>Task prompts</span>
          <span class="stat"><b>\(String(format: "%.1f", s.avgStars))★</b>Avg score</span>
        </div>
        <h2>Phân bổ chất lượng</h2>
        <table><thead><tr><th>Mức</th><th>Số prompt</th></tr></thead><tbody>\(rows)</tbody></table>
        <h2>Section hay thiếu</h2>
        <ul>\(missing.isEmpty ? "<li class=muted>Không có data.</li>" : missing)</ul>
        <h2>Breakdown theo project</h2>
        <table><thead><tr><th>Project</th><th>Task prompts</th><th>Avg score</th></tr></thead><tbody>\(projects)</tbody></table>
        <h2>Prompts chi tiết</h2>
        \(details.isEmpty ? "<p class=muted>Không có prompt nào.</p>" : details)
        </div></body></html>
        """
    }

    /// Render CSV: 1 hàng / prompt. Columns: timestamp, source, project,
    /// session_uuid, is_task, stars, char_count, sections_present, sections_missing,
    /// text (escaped). Dùng cho phân tích trong Sheet/Excel.
    public static func csv(records: [PromptRecord]) -> String {
        let header = "timestamp,source,project,session_uuid,is_task,stars,char_count,sections_present,sections_missing,text"
        var out = header + "\n"
        for r in records {
            let cols: [String] = [
                isoLabel.string(from: r.timestamp),
                r.source.rawValue,
                csvEscape(r.projectDisplay),
                r.sessionUuid,
                r.score.isTaskPrompt ? "1" : "0",
                "\(r.score.stars)",
                "\(r.score.charCount)",
                csvEscape(r.score.sectionsPresent.map(\.rawValue).sorted().joined(separator: "|")),
                csvEscape(r.score.sectionsMissing.map(\.rawValue).joined(separator: "|")),
                csvEscape(r.text)
            ]
            out += cols.joined(separator: ",") + "\n"
        }
        return out
    }

    private static func csvEscape(_ s: String) -> String {
        let needs = s.contains(",") || s.contains("\"") || s.contains("\n")
        if !needs { return s }
        let q = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(q)\""
    }

    nonisolated(unsafe) private static let isoLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    // MARK: - Helpers

    private static func starGlyph(_ stars: Int) -> String {
        let filled = String(repeating: "★", count: stars)
        let empty = String(repeating: "☆", count: 5 - stars)
        return filled + empty
    }

    private static func starString(_ avg: Double) -> String {
        String(format: "%.1f★", avg)
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    nonisolated(unsafe) static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd (EEE)"
        f.locale = Locale(identifier: "vi_VN")
        f.timeZone = .current
        return f
    }()

    nonisolated(unsafe) static let timeLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.timeZone = .current
        return f
    }()
}
