import Foundation

public enum ReportTime {
    public static let timeZone: TimeZone = AgentWatchLocale.timeZone
    public static let timeZoneLabel: String = AgentWatchLocale.timeZoneLabel

    /// All report readers use [start, end). Never subtract a second: JSONL
    /// timestamps can include fractions of a second right before midnight.
    public static func range(for scope: ReportScope) -> Range<Date> {
        switch scope {
        case .day(let date):
            let start = calendar.startOfDay(for: date)
            return start..<(calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        case .week(let date):
            let start = mondayBasedCalendar.startOfDay(for: date)
            return start..<(mondayBasedCalendar.date(byAdding: .day, value: 7, to: start) ?? start)
        case .custom(let start, let end, _):
            return start..<max(start, end)
        }
    }

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    public static var mondayBasedCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }
}
