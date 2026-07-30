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
            let end = ReportTime.mondayBasedCalendar.date(byAdding: .day, value: 6, to: start) ?? start
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
    public let sourceBreakdown: [SessionSource: Int]

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
        // Stable sort: primary theo count desc, tie-break theo rawValue asc.
        // Dict iteration không deterministic → nếu chỉ sort count, ties đổi thứ
        // tự mỗi render → UI smart-tip flicker.
        let topMissing = missingCount
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key.rawValue < $1.key.rawValue
            }
            .prefix(3).map { ($0.key, $0.value) }

        var byProj: [String: (count: Int, total: Int)] = [:]
        for r in task {
            byProj[r.projectDisplay, default: (0, 0)].count += 1
            byProj[r.projectDisplay, default: (0, 0)].total += r.score.stars
        }
        let proj = byProj
            .map { (project: $0.key, count: $0.value.count,
                    avgStars: Double($0.value.total) / Double(max($0.value.count, 1))) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.project < $1.project  // tie-break stable
            }

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
    public static func markdown(scope: ReportScope,
                                records: [PromptRecord],
                                sessions: [SessionSummary] = [],
                                includeToolAudit: Bool = false) -> String {
        let s = stats(for: records)
        let usage = SessionInventory.aggregate(sessions)
        let risks = RiskScorer.evaluate(records: records, sessions: sessions, limit: 500)
        let riskSummary = RiskScorer.summary(for: risks)
        let thinking = thinkingBreakdownLine(sessions)
        var md = "# AGENT WATCH REPORT — AI Coding theo SDD/VSDD\n\n"
        md += "**Phạm vi:** \(scope.label)\n"
        md += "**Múi giờ:** GMT+7\n"
        md += "**Tổng prompts:** \(s.totalPrompts) (task: \(s.taskPrompts), follow-up: \(s.followUpPrompts))\n"
        md += "**Sessions:** \(usage.sessionCount) · tokens \(usage.totalTokens)\n"
        md += "**Cost:** reported \(String(format: "$%.4f", usage.reportedCost)) · estimated \(String(format: "$%.4f", usage.estimatedCost))"
        if usage.unavailableCostSessionCount > 0 {
            md += " · unavailable \(usage.unavailableCostSessionCount) session"
        }
        md += "\n"
        if usage.reasoningTokens > 0 {
            md += "**Reasoning tokens:** \(usage.reasoningTokens)\n"
        }
        if !thinking.isEmpty {
            md += "**Thinking modes:** \(thinking)\n"
        }
        md += "**Risk findings:** \(riskSummary.totalFindings) · high/critical \(riskSummary.highOrCriticalCount) · affected sessions \(riskSummary.affectedSessions)\n"
        md += "**Avg score (task prompts):** \(starString(s.avgStars))\n"
        md += "**Nguồn prompt:** \(sourceBreakdownLine(s.sourceBreakdown))\n\n"

        md += "## 0. Nguồn và công thức\n"
        md += "- Accounting schema: `usage-v2`; price table `\(Pricing.versionLabel)`; mọi số liệu phía dưới đều ghi source, cost basis và range precision.\n"
        md += "- Claude: total = input + output + cache read + cache write; cost ước tính từ bảng giá Agent Watch.\n"
        md += "- Codex: total = input + output; cached input nằm trong input và reasoning nằm trong output; cost chỉ là API-equivalent estimate, không phải hóa đơn subscription.\n"
        md += "- PiAgent: total = input + output + cache read + cache write; reasoning nằm trong output; ưu tiên cost do Pi ghi trực tiếp trong log.\n"
        md += "- Estimated cost dùng standard public API list price; không đại diện subscription, enterprise/custom tier, long-context surcharge hay provider tool fee.\n"
        md += "- Cache hit: Claude/Pi = cache read / (input + cache read); Codex = cached input / input.\n"
        md += "- Mỗi session row chỉ tính event nằm trong đúng kỳ report. Row `partial selected range` có cảnh báo vì log cumulative thiếu baseline đầu kỳ.\n\n"

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

        md += "## 4. Risk audit\n"
        if risks.isEmpty {
            md += "_Không có risk finding nào trong khoảng này._\n\n"
        } else {
            md += "| Severity | Score | Category | Source | Project | Session | Reason |\n"
            md += "|---|---:|---|---|---|---|---|\n"
            for risk in risks {
                md += "| \(risk.severity.label) | \(risk.score) | \(risk.category.label) | \(risk.source.label) | \(risk.projectDisplay) | \(risk.sessionId) | \(risk.reason) |\n"
            }
            md += "\n"
        }

        md += "## 5. Top usage sessions theo task/session\n"
        if sessions.isEmpty {
            md += "_Không có session nào._\n\n"
        } else {
            md += "| Source | Task/session | Project | Model | Thinking | Prompts | Tools | Tokens | Reasoning | Cost | Basis | Range |\n"
            md += "|---|---|---|---|---|---:|---:|---:|---:|---:|---|---|\n"
            for session in sessions {
                md += "| \(session.source.label) | \(markdownTableEscape(session.displayTitle)) | \(markdownTableEscape(session.projectDisplay)) | \(markdownTableEscape(session.model)) | \(markdownTableEscape(session.thinkingLevel ?? "")) | \(session.promptCount) | \(session.toolCallCount) | \(session.totalTokens) | \(session.reasoningTokens) | \(String(format: "$%.4f", session.cost)) | \(session.costBasis.label) | \(session.usageScope.label) |\n"
            }
            md += "\n"
        }

        md += "## 6. Công việc theo từng session\n"
        if sessions.isEmpty && records.isEmpty {
            md += "_Không có prompt hoặc session nào trong kỳ._\n"
            return md
        }
        var emittedPromptIds: Set<String> = []
        for session in sessions.sorted(by: sessionReportSort) {
            let sessionRecords = records
                .filter {
                    $0.source == session.source
                        && $0.sessionUuid == session.id
                }
                .sorted { $0.timestamp < $1.timestamp }
            emittedPromptIds.formUnion(sessionRecords.map(\.auditKey))
            md += "\n### \(session.source.label) · \(session.displayTitle)\n"
            md += "- Session: `\(session.id)`\n"
            md += "- Project: `\(session.projectDisplay)`\n"
            md += "- Model/thinking: \(session.model)\(session.thinkingLevel.map { " / \($0)" } ?? "")\n"
            md += "- Period activity: \(sessionRange(session))\n"
            if !session.titleHistory.isEmpty {
                md += "- Name history (full session metadata): \(sessionTitleTimeline(session))\n"
            }
            md += "- Usage: \(session.totalTokens) total · input \(session.inputTokens) · output \(session.outputTokens) · reasoning \(session.reasoningTokens) · cache R/W \(session.cacheReadTokens)/\(session.cacheWriteTokens)\n"
            md += "- Formula: \(session.tokenAccountingRule.label); cost \(String(format: "$%.4f", session.cost)) (\(session.costBasis.label)); scope \(session.usageScope.label)\n"
            md += "- Cost provenance: \(costProvenance(session))\n"
            md += "- Cache hit: \(String(format: "%.1f", session.cacheHitRate * 100))% (\(session.cacheHitRateFormula))\n"
            if let fileURL = session.fileURL {
                md += "- Source log: `\(fileURL.path)`\n"
            }
            for warning in session.dataWarnings {
                md += "- Data warning: \(warning)\n"
            }
            if includeToolAudit {
                md += toolAuditMarkdown(for: session, scope: scope)
            }
            if sessionRecords.isEmpty {
                md += "\n_Không có human prompt trong kỳ; session có thể chỉ chứa tool/assistant activity._\n"
                continue
            }
            for record in sessionRecords {
                md += promptMarkdown(record)
            }
        }

        let orphanRecords = records
            .filter { !emittedPromptIds.contains($0.auditKey) }
            .sorted { $0.timestamp < $1.timestamp }
        if !orphanRecords.isEmpty {
            md += "\n### Prompts chưa map được session summary\n"
            for record in orphanRecords {
                md += promptMarkdown(record)
            }
        }
        return md
    }

    /// Render thành HTML self-contained, in được PDF.
    public static func html(scope: ReportScope,
                            records: [PromptRecord],
                            sessions: [SessionSummary] = [],
                            includeToolAudit: Bool = false) -> String {
        let s = stats(for: records)
        let usage = SessionInventory.aggregate(sessions)
        let risks = RiskScorer.evaluate(records: records, sessions: sessions, limit: 500)
        let riskSummary = RiskScorer.summary(for: risks)
        let thinking = thinkingBreakdownLine(sessions)
        let reasoningStat = usage.reasoningTokens > 0
            ? "<span class=\"stat\"><b>\(usage.reasoningTokens)</b>Reasoning</span>"
            : ""
        let thinkingStat = thinking.isEmpty
            ? ""
            : "<span class=\"stat\"><b>\(htmlEscape(thinking))</b>Thinking</span>"
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
        var sessionRows = ""
        for session in sessions {
            sessionRows += "<tr><td>\(htmlEscape(session.source.label))</td>"
                + "<td>\(htmlEscape(session.displayTitle))</td>"
                + "<td>\(htmlEscape(session.projectDisplay))</td>"
                + "<td>\(htmlEscape(session.model))</td>"
                + "<td>\(htmlEscape(session.thinkingLevel ?? ""))</td>"
                + "<td>\(session.promptCount)</td>"
                + "<td>\(session.toolCallCount)</td>"
                + "<td>\(session.totalTokens)</td>"
                + "<td>\(session.reasoningTokens)</td>"
                + "<td>\(String(format: "$%.4f", session.cost))</td>"
                + "<td>\(htmlEscape(session.costBasis.label))</td>"
                + "<td>\(htmlEscape(session.usageScope.label))</td></tr>"
        }
        var riskRows = ""
        for risk in risks {
            riskRows += "<tr><td>\(htmlEscape(risk.severity.label))</td>"
                + "<td>\(risk.score)</td>"
                + "<td>\(htmlEscape(risk.category.label))</td>"
                + "<td>\(htmlEscape(risk.source.label))</td>"
                + "<td>\(htmlEscape(risk.projectDisplay))</td>"
                + "<td>\(htmlEscape(risk.sessionId))</td>"
                + "<td>\(htmlEscape(risk.reason))</td></tr>"
        }
        var details = ""
        var emittedPromptIds: Set<String> = []
        for session in sessions.sorted(by: sessionReportSort) {
            let sessionRecords = records
                .filter { $0.source == session.source && $0.sessionUuid == session.id }
                .sorted { $0.timestamp < $1.timestamp }
            emittedPromptIds.formUnion(sessionRecords.map(\.auditKey))
            let warnings = session.dataWarnings
                .map { "<li class=missing>\(htmlEscape($0))</li>" }
                .joined()
            let sourceLog = session.fileURL.map {
                "<div class=\"proj\">Source log: \(htmlEscape($0.path))</div>"
            } ?? ""
            let toolAudit = includeToolAudit
                ? toolAuditHTML(for: session, scope: scope)
                : ""
            let titleHistory = session.titleHistory.isEmpty
                ? ""
                : "<div class=\"proj\">Name history (full session metadata): \(htmlEscape(sessionTitleTimeline(session)))</div>"
            details += """
            <section class="session">
              <h3>\(htmlEscape(session.source.label)) · \(htmlEscape(session.displayTitle))</h3>
              <div class="proj">Session \(htmlEscape(session.id)) · \(htmlEscape(session.projectDisplay)) · \(htmlEscape(sessionRange(session)))</div>
              \(titleHistory)
              \(sourceLog)
              <p class="formula">\(htmlEscape(session.tokenAccountingRule.label)) · cache \(String(format: "%.1f", session.cacheHitRate * 100))% (\(htmlEscape(session.cacheHitRateFormula))) · cost \(String(format: "$%.4f", session.cost)) (\(htmlEscape(costProvenance(session)))) · \(htmlEscape(session.usageScope.label))</p>
              \(warnings.isEmpty ? "" : "<ul>\(warnings)</ul>")
              \(toolAudit)
              \(sessionRecords.isEmpty ? "<p class=muted>Không có human prompt trong kỳ; session có thể chỉ chứa tool/assistant activity.</p>" : sessionRecords.map(promptHTML).joined())
            </section>
            """
        }
        let orphanRecords = records
            .filter { !emittedPromptIds.contains($0.auditKey) }
            .sorted { $0.timestamp < $1.timestamp }
        if !orphanRecords.isEmpty {
            details += "<section class=session><h3>Prompts chưa map được session summary</h3>"
                + orphanRecords.map(promptHTML).joined()
                + "</section>"
        }
        return """
        <!DOCTYPE html><html lang="vi"><head><meta charset="UTF-8">
        <title>Agent Watch Report — \(htmlEscape(scope.label))</title>
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
          .session{margin:18px 0;padding:14px;border:1px solid #ddd;border-radius:10px}
          .session h3{margin:0 0 4px}
          .formula{font-family:ui-monospace,SFMono-Regular,monospace;color:#555;font-size:12px}
          .ptime{font-weight:600}
          .tag{background:#cc785c;color:#fff;padding:2px 8px;border-radius:999px;font-size:12px}
          .proj{color:#888;font-size:13px;margin:2px 0 8px}
          .missing{color:#b14a1a;font-size:13px;margin:6px 0}
          pre{background:#1a1a1a;color:#e8e2d5;padding:12px;border-radius:8px;overflow-x:auto;white-space:pre-wrap;font-size:12px;line-height:1.5}
          @media print{body{background:#fff;padding:0}.wrap{box-shadow:none}}
        </style></head><body><div class="wrap">
        <h1>Agent Watch Report</h1>
        <div class="muted">\(htmlEscape(scope.label)) · GMT+7 · accounting usage-v2 · prices \(Pricing.versionLabel)</div>
        <div style="margin-top:20px">
          <span class="stat"><b>\(s.totalPrompts)</b>Tổng prompts</span>
          <span class="stat"><b>\(usage.sessionCount)</b>Sessions</span>
          <span class="stat"><b>\(usage.totalTokens)</b>Tokens</span>
          <span class="stat"><b>\(String(format: "$%.4f", usage.reportedCost))</b>Reported cost</span>
          <span class="stat"><b>\(String(format: "$%.4f", usage.estimatedCost))</b>Estimated cost</span>
          \(reasoningStat)
          \(thinkingStat)
          <span class="stat"><b>\(riskSummary.highOrCriticalCount)</b>High risks</span>
          <span class="stat"><b>\(s.taskPrompts)</b>Task prompts</span>
          <span class="stat"><b>\(String(format: "%.1f", s.avgStars))★</b>Avg score</span>
        </div>
        <h2>Nguồn và công thức</h2>
        <ul>
          <li>Every session includes source log, cost basis and range precision.</li>
          <li>Claude: input + output + cache read + cache write; cost estimated.</li>
          <li>Codex: input + output; cache is inside input and reasoning is inside output; cost is an API-equivalent estimate.</li>
          <li>PiAgent: input + output + cache read + cache write; reasoning is inside output; source-reported cost is preferred.</li>
          <li>Estimated cost uses standard public API list price; it excludes subscription, enterprise/custom tiers, long-context surcharges and provider tool fees.</li>
          <li>Cache hit: Claude/Pi = cache read / (input + cache read); Codex = cached input / input.</li>
          <li>Session rows are scoped to the selected GMT+7 report period. Partial rows carry an explicit warning.</li>
        </ul>
        <h2>Phân bổ chất lượng</h2>
        <table><thead><tr><th>Mức</th><th>Số prompt</th></tr></thead><tbody>\(rows)</tbody></table>
        <h2>Section hay thiếu</h2>
        <ul>\(missing.isEmpty ? "<li class=muted>Không có data.</li>" : missing)</ul>
        <h2>Breakdown theo project</h2>
        <table><thead><tr><th>Project</th><th>Task prompts</th><th>Avg score</th></tr></thead><tbody>\(projects)</tbody></table>
        <h2>Risk audit</h2>
        <table><thead><tr><th>Severity</th><th>Score</th><th>Category</th><th>Source</th><th>Project</th><th>Session</th><th>Reason</th></tr></thead><tbody>\(riskRows.isEmpty ? "<tr><td colspan=7 class=muted>Không có risk finding nào.</td></tr>" : riskRows)</tbody></table>
        <h2>Top usage sessions theo task/session</h2>
        <table><thead><tr><th>Source</th><th>Task/session</th><th>Project</th><th>Model</th><th>Thinking</th><th>Prompts</th><th>Tools</th><th>Tokens</th><th>Reasoning</th><th>Cost</th><th>Basis</th><th>Range</th></tr></thead><tbody>\(sessionRows.isEmpty ? "<tr><td colspan=12 class=muted>Không có session nào.</td></tr>" : sessionRows)</tbody></table>
        <h2>Công việc theo từng session</h2>
        \(details.isEmpty ? "<p class=muted>Không có prompt nào.</p>" : details)
        </div></body></html>
        """
    }

    /// Render CSV: session rows first, prompt rows after. Dung cho Sheet/Excel.
    public static func csv(records: [PromptRecord],
                           sessions: [SessionSummary] = [],
                           scope: ReportScope? = nil,
                           includeToolAudit: Bool = false) -> String {
        let risks = RiskScorer.evaluate(records: records, sessions: sessions, limit: 500)
        let riskByPrompt = RiskScorer.highestByPrompt(risks)
        let sessionsById = bestSessionsById(sessions)
        let header = "record_type,timestamp,source,project,session_uuid,session_title,model,thinking_level,cost_usd,total_tokens,input_tokens,output_tokens,reasoning_tokens,cache_read_tokens,cache_write_tokens,prompt_count,tool_count,agent_count,risk_score,risk_severity,risk_category,risk_title,risk_reason,risk_recommendation,is_task,stars,char_count,sections_present,sections_missing,text,cost_basis,token_formula,usage_scope,source_file,data_warnings"
        var out = header + "\n"
        for risk in risks {
            let session = sessionsById[sessionKey(source: risk.source, id: risk.sessionId)]
            let cols: [String] = [
                "risk",
                isoLabel.string(from: risk.timestamp ?? session?.lastTimestamp ?? session?.firstTimestamp ?? Date.distantPast),
                risk.source.rawValue,
                csvEscape(risk.projectDisplay),
                risk.sessionId,
                csvEscape(session?.sessionTitle ?? ""),
                csvEscape(session?.model ?? ""),
                csvEscape(session?.thinkingLevel ?? ""),
                session.map { String(format: "%.6f", $0.cost) } ?? "",
                session.map { "\($0.totalTokens)" } ?? "",
                session.map { "\($0.inputTokens)" } ?? "",
                session.map { "\($0.outputTokens)" } ?? "",
                session.map { "\($0.reasoningTokens)" } ?? "",
                session.map { "\($0.cacheReadTokens)" } ?? "",
                session.map { "\($0.cacheWriteTokens)" } ?? "",
                session.map { "\($0.promptCount)" } ?? "",
                session.map { "\($0.toolCallCount)" } ?? "",
                session.map { "\($0.agentCount)" } ?? "",
                "\(risk.score)",
                risk.severity.label,
                risk.category.rawValue,
                csvEscape(risk.title),
                csvEscape(risk.reason),
                csvEscape(risk.recommendation),
                "",
                "",
                "",
                "",
                "",
                csvEscape(risk.evidence),
                csvEscape(session?.costBasis.label ?? ""),
                csvEscape(session?.tokenAccountingRule.label ?? ""),
                csvEscape(session?.usageScope.label ?? ""),
                csvEscape(session?.fileURL?.path ?? ""),
                csvEscape(session?.dataWarnings.joined(separator: " | ") ?? "")
            ]
            out += cols.joined(separator: ",") + "\n"
        }
        for s in sessions {
            let risk = highestRisk(for: s, risks: risks)
            let cols: [String] = [
                "session",
                isoLabel.string(from: s.lastTimestamp ?? s.firstTimestamp ?? Date.distantPast),
                s.source.rawValue,
                csvEscape(s.projectDisplay),
                s.id,
                csvEscape(s.sessionTitle ?? ""),
                csvEscape(s.model),
                csvEscape(s.thinkingLevel ?? ""),
                String(format: "%.6f", s.cost),
                "\(s.totalTokens)",
                "\(s.inputTokens)",
                "\(s.outputTokens)",
                "\(s.reasoningTokens)",
                "\(s.cacheReadTokens)",
                "\(s.cacheWriteTokens)",
                "\(s.promptCount)",
                "\(s.toolCallCount)",
                "\(s.agentCount)",
                risk.map { "\($0.score)" } ?? "",
                risk?.severity.label ?? "",
                risk?.category.rawValue ?? "",
                csvEscape(risk?.title ?? ""),
                csvEscape(risk?.reason ?? ""),
                csvEscape(risk?.recommendation ?? ""),
                "",
                "",
                "",
                "",
                "",
                "",
                csvEscape(s.costBasis.label),
                csvEscape(s.tokenAccountingRule.label),
                csvEscape(s.usageScope.label),
                csvEscape(s.fileURL?.path ?? ""),
                csvEscape(s.dataWarnings.joined(separator: " | "))
            ]
            out += cols.joined(separator: ",") + "\n"
        }
        for r in records {
            let risk = riskByPrompt[RiskScorer.promptKey(source: r.source, id: r.id)]
            let session = sessionsById[sessionKey(source: r.source, id: r.sessionUuid)]
            let cols: [String] = [
                "prompt",
                isoLabel.string(from: r.timestamp),
                r.source.rawValue,
                csvEscape(r.projectDisplay),
                r.sessionUuid,
                csvEscape(r.sessionTitle ?? ""),
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                risk.map { "\($0.score)" } ?? "",
                risk?.severity.label ?? "",
                risk?.category.rawValue ?? "",
                csvEscape(risk?.title ?? ""),
                csvEscape(risk?.reason ?? ""),
                csvEscape(risk?.recommendation ?? ""),
                r.score.isTaskPrompt ? "1" : "0",
                "\(r.score.stars)",
                "\(r.score.charCount)",
                csvEscape(r.score.sectionsPresent.map(\.rawValue).sorted().joined(separator: "|")),
                csvEscape(r.score.sectionsMissing.map(\.rawValue).joined(separator: "|")),
                csvEscape(r.text),
                csvEscape(session?.costBasis.label ?? ""),
                csvEscape(session?.tokenAccountingRule.label ?? ""),
                csvEscape(session?.usageScope.label ?? ""),
                csvEscape(session?.fileURL?.path ?? ""),
                csvEscape(session?.dataWarnings.joined(separator: " | ") ?? "")
            ]
            out += cols.joined(separator: ",") + "\n"
        }
        if includeToolAudit, let scope {
            for session in sessions.sorted(by: sessionReportSort) {
                for event in toolAuditEvents(for: session, scope: scope) {
                    let text = [
                        event.toolName ?? "Tool",
                        event.summary,
                        event.resultPreview.map { "result: \($0)" }
                    ]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                    let cols: [String] = [
                        "tool_action",
                        event.timestamp,
                        session.source.rawValue,
                        csvEscape(session.projectDisplay),
                        session.id,
                        csvEscape(session.sessionTitle ?? ""),
                        csvEscape(session.model),
                        csvEscape(session.thinkingLevel ?? ""),
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        csvEscape(event.toolName ?? "Tool"),
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        csvEscape(text),
                        csvEscape(session.costBasis.label),
                        csvEscape(session.tokenAccountingRule.label),
                        csvEscape(session.usageScope.label),
                        csvEscape(session.fileURL?.path ?? ""),
                        event.completed ? "completed" : "no result in selected range"
                    ]
                    out += cols.joined(separator: ",") + "\n"
                }
            }
        }
        return out
    }

    private static func sourceBreakdownLine(_ breakdown: [SessionSource: Int]) -> String {
        SessionSource.allCases
            .map { "\($0.shortLabel) \(breakdown[$0] ?? 0)" }
            .joined(separator: " · ")
    }

    private static func thinkingBreakdownLine(_ sessions: [SessionSummary]) -> String {
        var counts: [String: Int] = [:]
        for session in sessions {
            guard let raw = session.thinkingLevel else { continue }
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            counts[cleaned, default: 0] += 1
        }
        return counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        .map { $0.value > 1 ? "\($0.key) x\($0.value)" : $0.key }
        .joined(separator: " · ")
    }

    private static func promptMarkdown(_ record: PromptRecord) -> String {
        let tag = record.score.isTaskPrompt ? "\(record.score.stars)★" : "follow-up"
        var output = "\n#### \(timeLabel.string(from: record.timestamp)) · \(tag)\n"
        if record.score.isTaskPrompt && !record.score.sectionsMissing.isEmpty {
            output += "Thiếu: "
                + record.score.sectionsMissing.map(\.label).joined(separator: ", ")
                + "\n\n"
        }
        let fence = markdownFence(for: record.text)
        output += "\(fence)\n\(record.text)\n\(fence)\n"
        return output
    }

    private static func promptHTML(_ record: PromptRecord) -> String {
        let tag = record.score.isTaskPrompt ? "\(record.score.stars)★" : "follow-up"
        let missing = record.score.isTaskPrompt && !record.score.sectionsMissing.isEmpty
            ? "<p class=missing>Thiếu: "
                + record.score.sectionsMissing.map(\.label).joined(separator: ", ")
                + "</p>"
            : ""
        return """
        <div class="prompt">
          <div class="ptime">\(timeLabel.string(from: record.timestamp)) · <span class="tag">\(tag)</span></div>
          \(missing)
          <pre>\(htmlEscape(record.text))</pre>
        </div>
        """
    }

    private static func sessionRange(_ session: SessionSummary) -> String {
        let start = session.firstTimestamp.map(isoLabel.string) ?? "unknown"
        let end = session.lastTimestamp.map(isoLabel.string) ?? start
        return "\(start) → \(end)"
    }

    private static func sessionTitleTimeline(_ session: SessionSummary) -> String {
        session.titleHistory.map { change in
            let timestamp = change.timestamp.map(isoLabel.string(from:))
                ?? (change.timestampString.isEmpty ? "unknown time" : change.timestampString)
            return "\(timestamp) → \(change.title)"
        }.joined(separator: " | ")
    }

    private static func costProvenance(_ session: SessionSummary) -> String {
        switch session.costBasis {
        case .reported:
            return "reported by source log"
        case .estimated:
            let source = Pricing.quote(forModelId: session.model)?.sourceLabel
                ?? "unknown price quote"
            return "estimated from \(source) @ \(Pricing.versionLabel)"
        case .unavailable:
            return "unavailable; no source-reported cost or recognised price quote"
        }
    }

    private static func toolAuditEvents(for session: SessionSummary,
                                        scope: ReportScope) -> [SessionEvent] {
        guard session.toolCallCount > 0, let file = session.fileURL else { return [] }
        let range = reportRange(for: scope)
        let stats: SessionStats
        switch session.source {
        case .cli, .desktop:
            stats = JsonlParser.parseSession(at: file, range: range, eventLimit: nil)
        case .codex:
            stats = CodexJsonlParser.parseSession(at: file, range: range, eventLimit: nil)
        case .piagent:
            stats = PiAgentJsonlParser.parseSession(at: file, range: range, eventLimit: nil)
        }
        return stats.events
            .filter { $0.kind == .toolUse }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func toolAuditMarkdown(for session: SessionSummary,
                                          scope: ReportScope) -> String {
        let events = toolAuditEvents(for: session, scope: scope)
        if events.isEmpty {
            return session.toolCallCount > 0
                ? "\n#### Tool activity audit\n_Data warning: source reported \(session.toolCallCount) tool calls but no tool events could be decoded._\n"
                : ""
        }
        var output = "\n#### Tool activity audit (\(events.count))\n"
        output += "| Time | Tool | Action | Status | Result |\n"
        output += "|---|---|---|---|---|\n"
        for event in events {
            output += "| \(markdownTableEscape(event.timestamp))"
                + " | \(markdownTableEscape(event.toolName ?? "Tool"))"
                + " | \(markdownTableEscape(event.summary))"
                + " | \(event.completed ? "completed" : "no result in range")"
                + " | \(markdownTableEscape(event.resultPreview ?? "")) |\n"
        }
        return output
    }

    private static func toolAuditHTML(for session: SessionSummary,
                                      scope: ReportScope) -> String {
        let events = toolAuditEvents(for: session, scope: scope)
        if events.isEmpty {
            return session.toolCallCount > 0
                ? "<h4>Tool activity audit</h4><p class=missing>Source reported \(session.toolCallCount) tool calls but no tool events could be decoded.</p>"
                : ""
        }
        let rows = events.map { event in
            "<tr><td>\(htmlEscape(event.timestamp))</td>"
                + "<td>\(htmlEscape(event.toolName ?? "Tool"))</td>"
                + "<td>\(htmlEscape(event.summary))</td>"
                + "<td>\(event.completed ? "completed" : "no result in range")</td>"
                + "<td>\(htmlEscape(event.resultPreview ?? ""))</td></tr>"
        }
        .joined()
        return """
        <h4>Tool activity audit (\(events.count))</h4>
        <table><thead><tr><th>Time</th><th>Tool</th><th>Action</th><th>Status</th><th>Result</th></tr></thead><tbody>\(rows)</tbody></table>
        """
    }

    private static func reportRange(for scope: ReportScope) -> ClosedRange<Date> {
        let calendar = ReportTime.calendar
        switch scope {
        case .day(let day):
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return start...end.addingTimeInterval(-1)
        case .week(let start):
            let end = ReportTime.mondayBasedCalendar
                .date(byAdding: .day, value: 7, to: start) ?? start
            return start...end.addingTimeInterval(-1)
        case .custom(let start, let end, _):
            return start...end
        }
    }

    private static func markdownFence(for text: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in text {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: max(3, longestRun + 1))
    }

    private static func sessionReportSort(_ lhs: SessionSummary,
                                          _ rhs: SessionSummary) -> Bool {
        let left = lhs.firstTimestamp ?? lhs.lastTimestamp ?? .distantPast
        let right = rhs.firstTimestamp ?? rhs.lastTimestamp ?? .distantPast
        if left != right { return left < right }
        if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
        return lhs.id < rhs.id
    }

    private static func highestRisk(for session: SessionSummary,
                                    risks: [RiskFinding]) -> RiskFinding? {
        risks
            .filter { $0.source == session.source && $0.sessionId == session.id }
            .max {
                if $0.severity.rawValue != $1.severity.rawValue {
                    return $0.severity.rawValue < $1.severity.rawValue
                }
                return $0.score < $1.score
            }
    }

    private static func sessionKey(source: SessionSource, id: String) -> String {
        "\(source.rawValue)|\(id)"
    }

    private static func bestSessionsById(_ sessions: [SessionSummary]) -> [String: SessionSummary] {
        var out: [String: SessionSummary] = [:]
        for session in sessions {
            let key = sessionKey(source: session.source, id: session.id)
            guard let current = out[key] else {
                out[key] = session
                continue
            }
            if session.cost > current.cost
                || (session.cost == current.cost && session.totalTokens > current.totalTokens) {
                out[key] = session
            }
        }
        return out
    }

    private static func markdownTableEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
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
        f.timeZone = ReportTime.timeZone
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
        f.timeZone = ReportTime.timeZone
        return f
    }()

    nonisolated(unsafe) static let timeLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.timeZone = ReportTime.timeZone
        return f
    }()
}
