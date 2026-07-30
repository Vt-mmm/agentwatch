import Foundation

public enum ReportTime {
    public static let timeZone: TimeZone = TimeZone(secondsFromGMT: 7 * 60 * 60)
        ?? TimeZone(identifier: "Asia/Ho_Chi_Minh")
        ?? .current

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
