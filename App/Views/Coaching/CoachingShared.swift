// Shared helpers on CoachingReportView: scope/date logic, export actions, pagination reset, misc utils.
// Dependency direction: extension on CoachingReportView ← AppKit (NSSavePanel), ClaudeWatchCore.

import SwiftUI
import AppKit
import ClaudeWatchCore

extension CoachingReportView {

    // MARK: - Scope helpers

    /// Label đầy đủ cho range đang filter — show ở top filterCard.
    /// Day: "Thứ 5, 12/06/2026" — Week: "Tuần 09/06/2026 → 15/06/2026" —
    /// Month: "Tháng 06/2026"
    var scopeRangeLabel: String {
        switch scope {
        case .day:
            let f = DateFormatter()
            f.dateFormat = "EEEE, dd/MM/yyyy"
            f.locale = Locale(identifier: "vi_VN")
            f.timeZone = ReportTime.timeZone
            return f.string(from: anchor).capitalized
        case .week:
            let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"; f.timeZone = ReportTime.timeZone
            let cal = PromptHistory.currentMondayBased
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)
            let start = cal.date(from: comps) ?? anchor
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
            return "Tuần \(f.string(from: start)) → \(f.string(from: end))"
        case .month:
            let f = DateFormatter(); f.dateFormat = "MM/yyyy"; f.timeZone = ReportTime.timeZone
            return "Tháng \(f.string(from: anchor))"
        }
    }

    /// Tooltip text cho nút prev/next theo scope hiện tại.
    func shiftHelp(forward: Bool) -> String {
        let suffix = forward ? "sau" : "trước"
        switch scope {
        case .day:   return "Ngày \(suffix)"
        case .week:  return "Tuần \(suffix)"
        case .month: return "Tháng \(suffix)"
        }
    }

    /// Dịch anchor: ngày → ±1 day, tuần → ±7 day, tháng → ±1 month.
    /// Clamp tối đa = hôm nay (không cho filter ngày tương lai).
    func shiftAnchor(by direction: Int) {
        let cal = ReportTime.calendar
        let next: Date
        switch scope {
        case .day:
            next = cal.date(byAdding: .day, value: direction, to: anchor) ?? anchor
        case .week:
            next = cal.date(byAdding: .day, value: direction * 7, to: anchor) ?? anchor
        case .month:
            next = cal.date(byAdding: .month, value: direction, to: anchor) ?? anchor
        }
        anchor = min(next, Date())
    }

    /// Disable nút → khi range hiện tại đã chạm hôm nay.
    var canShiftForward: Bool {
        let cal = ReportTime.calendar
        switch scope {
        case .day:
            return !cal.isDate(anchor, inSameDayAs: Date()) && anchor < Date()
        case .week:
            let weekCal = PromptHistory.currentMondayBased
            let comps = weekCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)
            let nowComps = weekCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
            return (comps.yearForWeekOfYear ?? 0) < (nowComps.yearForWeekOfYear ?? 0)
                || ((comps.yearForWeekOfYear ?? 0) == (nowComps.yearForWeekOfYear ?? 0)
                    && (comps.weekOfYear ?? 0) < (nowComps.weekOfYear ?? 0))
        case .month:
            let comps = cal.dateComponents([.year, .month], from: anchor)
            let now = cal.dateComponents([.year, .month], from: Date())
            return (comps.year ?? 0) < (now.year ?? 0)
                || ((comps.year ?? 0) == (now.year ?? 0)
                    && (comps.month ?? 0) < (now.month ?? 0))
        }
    }

    var currentScope: ReportScope {
        switch scope {
        case .day:
            return .day(anchor)
        case .week:
            let cal = PromptHistory.currentMondayBased
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)
            let start = cal.date(from: comps) ?? anchor
            return .week(start: start)
        case .month:
            let cal = ReportTime.calendar
            let comps = cal.dateComponents([.year, .month], from: anchor)
            let startDay = cal.date(from: comps) ?? cal.startOfDay(for: anchor)
            let nextMonth = cal.date(byAdding: .month, value: 1, to: startDay) ?? startDay
            let endOfDay = nextMonth
                .addingTimeInterval(-1)
            let f = DateFormatter(); f.dateFormat = "MM/yyyy"; f.timeZone = ReportTime.timeZone
            let label = "Tháng \(f.string(from: startDay))"
            return .custom(start: startDay, end: endOfDay, label: label)
        }
    }

    var canExportCurrentScope: Bool {
        let cal = ReportTime.calendar
        let now = Date()
        switch scope {
        case .day:
            return cal.isDate(anchor, inSameDayAs: now)
        case .week:
            let weekCal = PromptHistory.currentMondayBased
            let anchorComps = weekCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)
            let nowComps = weekCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            return anchorComps.yearForWeekOfYear == nowComps.yearForWeekOfYear
                && anchorComps.weekOfYear == nowComps.weekOfYear
        case .month:
            let anchorComps = cal.dateComponents([.year, .month], from: anchor)
            let nowComps = cal.dateComponents([.year, .month], from: now)
            return anchorComps.year == nowComps.year && anchorComps.month == nowComps.month
        }
    }

    var exportGuardMessage: String {
        switch scope {
        case .day:
            return "Chỉ được export report hôm nay theo giờ GMT+7. Ngày cũ chỉ xem trong app."
        case .week:
            return "Chỉ được export report tuần hiện tại theo giờ GMT+7. Tuần cũ chỉ xem trong app."
        case .month:
            return "Chỉ được export report tháng hiện tại theo giờ GMT+7. Tháng cũ chỉ xem trong app."
        }
    }

    /// Fingerprint scope+anchor để store biết khi nào cần re-fetch.
    var scopeFingerprint: String {
        "\(scope.rawValue)|\(Int(anchor.timeIntervalSinceReferenceDate))"
    }

    var reportRecords: [PromptRecord] {
        dedupedPromptRecords(allRecords)
            .sorted { $0.timestamp > $1.timestamp }
    }

    var reportSessions: [SessionSummary] {
        sortedSessions(allSessions)
    }

    // MARK: - Reload

    func reload() {
        data.reload(scope: currentScope, fingerprint: scopeFingerprint)
    }

    func resetPages() {
        sessionPage = 0
        promptPage = 0
    }

    /// ISO string từ lastRefreshAt — feed vào TokenFormatter.clockTime để ra time string local.
    var isoStringNow: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: lastRefreshAt)
    }

    // MARK: - Export

    func exportMarkdown() {
        guard canExportCurrentScope else {
            NSSound.beep()
            return
        }
        let exportScope = currentScope
        let exportFingerprint = scopeFingerprint
        Task { @MainActor in
            guard await data.reloadForExport(scope: exportScope, fingerprint: exportFingerprint) else {
                NSSound.beep()
                return
            }
            let records = reportRecords
            let sessions = reportSessions
            let base = await Task.detached(priority: .userInitiated) {
                ReportGenerator.markdown(
                    scope: exportScope,
                    records: records,
                    sessions: sessions,
                    includeToolAudit: true
                )
            }.value
            let md = base
                + supervisorLock.markdownSection(scope: exportScope)
                + supervisorLock.complianceMarkdownSection(scope: exportScope, sessions: sessions)
            save(content: md, defaultName: "coaching-\(slugify(exportScope.label)).md",
                 types: ["md", "markdown"], format: "markdown", scope: exportScope)
        }
    }

    func exportHTML() {
        guard canExportCurrentScope else {
            NSSound.beep()
            return
        }
        let exportScope = currentScope
        let exportFingerprint = scopeFingerprint
        Task { @MainActor in
            guard await data.reloadForExport(scope: exportScope, fingerprint: exportFingerprint) else {
                NSSound.beep()
                return
            }
            let records = reportRecords
            let sessions = reportSessions
            let base = await Task.detached(priority: .userInitiated) {
                ReportGenerator.html(
                    scope: exportScope,
                    records: records,
                    sessions: sessions,
                    includeToolAudit: true
                )
            }.value
            let html = base
                .replacingOccurrences(of: "</div></body></html>",
                                      with: supervisorLock.htmlSection(scope: exportScope)
                                          + supervisorLock.complianceHTMLSection(scope: exportScope, sessions: sessions)
                                          + "\n</div></body></html>")
            save(content: html, defaultName: "coaching-\(slugify(exportScope.label)).html",
                 types: ["html", "htm"], format: "html", scope: exportScope)
        }
    }

    func exportCSV() {
        guard canExportCurrentScope else {
            NSSound.beep()
            return
        }
        let exportScope = currentScope
        let exportFingerprint = scopeFingerprint
        Task { @MainActor in
            guard await data.reloadForExport(scope: exportScope, fingerprint: exportFingerprint) else {
                NSSound.beep()
                return
            }
            let records = reportRecords
            let sessions = reportSessions
            var csv = await Task.detached(priority: .userInitiated) {
                ReportGenerator.csv(
                    records: records,
                    sessions: sessions,
                    scope: exportScope,
                    includeToolAudit: true
                )
            }.value
            let lockRows = supervisorLock.csvRows(scope: exportScope)
            if !lockRows.isEmpty {
                csv += lockRows + "\n"
            }
            let complianceRows = supervisorLock.complianceCSVRows(scope: exportScope, sessions: sessions)
            if !complianceRows.isEmpty {
                csv += complianceRows + "\n"
            }
            save(content: csv, defaultName: "coaching-\(slugify(exportScope.label)).csv",
                 types: ["csv"], format: "csv", scope: exportScope)
        }
    }

    private func save(content: String,
                      defaultName: String,
                      types: [String],
                      format: String,
                      scope: ReportScope) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            supervisorLock.recordReportExportCancelled(format: format, scope: scope)
            return
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            supervisorLock.recordReportExport(format: format, scope: scope, url: url)
        } catch {
            supervisorLock.recordReportExportFailure(format: format, scope: scope, error: error)
            NSSound.beep()
        }
    }

    /// Truncate string in the middle — used by project/model picker labels.
    func truncateMid(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let half = (max - 1) / 2
        let prefix = s.prefix(half)
        let suffix = s.suffix(half)
        return "\(prefix)…\(suffix)"
    }

    func slugify(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }
}
