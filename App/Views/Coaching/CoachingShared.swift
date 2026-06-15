// Shared helpers on CoachingReportView: scope/date logic, export actions, pagination reset, misc utils.
// Dependency direction: extension on CoachingReportView ← AppKit (NSSavePanel), ClaudeWatchCore.

import SwiftUI
import AppKit
import ClaudeWatchCore

extension CoachingReportView {

    // MARK: - Scope helpers

    /// Label đầy đủ cho range đang filter — show ở top filterCard.
    /// Day: "Thứ 5, 12/06/2026" — Week: "Tuần 09/06/2026 → 15/06/2026" —
    /// Month: "30 ngày 14/05/2026 → 12/06/2026"
    var scopeRangeLabel: String {
        switch scope {
        case .day:
            let f = DateFormatter()
            f.dateFormat = "EEEE, dd/MM/yyyy"
            f.locale = Locale(identifier: "vi_VN")
            return f.string(from: anchor).capitalized
        case .week:
            let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"
            let cal = PromptHistory.currentMondayBased
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)
            let start = cal.date(from: comps) ?? anchor
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
            return "Tuần \(f.string(from: start)) → \(f.string(from: end))"
        case .month:
            let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"
            let cal = Calendar.current
            let start = cal.date(byAdding: .day, value: -29, to: anchor) ?? anchor
            return "30 ngày \(f.string(from: start)) → \(f.string(from: anchor))"
        }
    }

    /// Tooltip text cho nút prev/next theo scope hiện tại.
    func shiftHelp(forward: Bool) -> String {
        let suffix = forward ? "sau" : "trước"
        switch scope {
        case .day:   return "Ngày \(suffix)"
        case .week:  return "Tuần \(suffix)"
        case .month: return "30 ngày \(suffix)"
        }
    }

    /// Dịch anchor: ngày → ±1 day, tuần → ±7 day, tháng → ±30 day.
    /// Clamp tối đa = hôm nay (không cho filter ngày tương lai).
    func shiftAnchor(by direction: Int) {
        let cal = Calendar.current
        let step: Int
        switch scope {
        case .day:   step = direction
        case .week:  step = direction * 7
        case .month: step = direction * 30
        }
        let next = cal.date(byAdding: .day, value: step, to: anchor) ?? anchor
        anchor = min(next, Date())
    }

    /// Disable nút → khi range hiện tại đã chạm hôm nay.
    var canShiftForward: Bool {
        let cal = Calendar.current
        switch scope {
        case .day:
            return !cal.isDate(anchor, inSameDayAs: Date()) && anchor < Date()
        case .week:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)
            let nowComps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
            return (comps.yearForWeekOfYear ?? 0) < (nowComps.yearForWeekOfYear ?? 0)
                || ((comps.yearForWeekOfYear ?? 0) == (nowComps.yearForWeekOfYear ?? 0)
                    && (comps.weekOfYear ?? 0) < (nowComps.weekOfYear ?? 0))
        case .month:
            return !cal.isDate(anchor, inSameDayAs: Date()) && anchor < Date()
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
            let cal = Calendar.current
            let startDay = cal.startOfDay(for: cal.date(byAdding: .day, value: -29, to: anchor) ?? anchor)
            let endOfDay = (cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: anchor)) ?? anchor)
                .addingTimeInterval(-1)
            let f = DateFormatter(); f.dateFormat = "dd/MM"
            let label = "30 ngày \(f.string(from: startDay))→\(f.string(from: endOfDay))"
            return .custom(start: startDay, end: endOfDay, label: label)
        }
    }

    /// Fingerprint scope+anchor để store biết khi nào cần re-fetch.
    var scopeFingerprint: String {
        "\(scope.rawValue)|\(Int(anchor.timeIntervalSinceReferenceDate))"
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
        let md = ReportGenerator.markdown(scope: currentScope, records: records)
        save(content: md, defaultName: "coaching-\(slugify(currentScope.label)).md",
             types: ["md", "markdown"])
    }

    func exportHTML() {
        let html = ReportGenerator.html(scope: currentScope, records: records)
        save(content: html, defaultName: "coaching-\(slugify(currentScope.label)).html",
             types: ["html", "htm"])
    }

    func exportCSV() {
        let csv = ReportGenerator.csv(records: records)
        save(content: csv, defaultName: "coaching-\(slugify(currentScope.label)).csv",
             types: ["csv"])
    }

    private func save(content: String, defaultName: String, types: [String]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) }
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
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
