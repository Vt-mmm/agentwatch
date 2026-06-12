// Shared formatters for the UI — keeps view code free of inline String(format:) noise.

import Foundation

enum TokenFormatter {
    /// 1_234 → "1.2k", 1_234_567 → "1.23M".
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    static func usd(_ value: Double) -> String {
        String(format: "$%.3f", value)
    }

    /// "2026-06-12T05:00:10.000Z" → "12:00:10" (converted to the user's local
    /// timezone). Falls back to raw substring slicing if parsing fails.
    static func clockTime(from iso: String) -> String {
        guard !iso.isEmpty else { return iso }
        if let date = parseISO(iso) {
            return localClockFormatter.string(from: date)
        }
        guard let tIndex = iso.firstIndex(of: "T") else { return iso }
        let after = iso.index(after: tIndex)
        return String(iso[after...].prefix(8))
    }

    private static func parseISO(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let localClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
