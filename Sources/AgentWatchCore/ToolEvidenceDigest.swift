import Foundation

/// Hash full structured source data, not display previews. No raw payload is
/// retained. Missing values stay unknown instead of becoming comparable empties.
enum ToolEvidenceDigest {
    static func hash(_ raw: Any?) -> String? {
        guard let raw, !(raw is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
        return ReportEncoding.digest(data)
    }
    static func arguments(_ raw: Any?) -> String? {
        if let string = raw as? String, let data = string.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return hash(value) }
        return hash(raw)
    }
    static func update(_ event: inout SessionEvent, output: Any?, error: Any?, timestamp: String) -> Bool {
        guard let incoming = PiTaskJournal.parseDate(timestamp) else { event.outputDigest = nil; event.toolIsError = nil; return false }
        let previous = PiTaskJournal.parseDate(event.completedAt)
        if let previous, incoming < previous { return false }
        var digest = hash(output), failed = boolean(error)
        if previous == incoming && event.completed && (event.outputDigest != digest || event.toolIsError != failed) {
            digest = nil; failed = nil
        }
        event.completed = true; event.completedAt = timestamp
        event.outputDigest = digest; event.toolIsError = failed
        return true
    }
    static func boolean(_ raw: Any?) -> Bool? {
        guard let raw, UsageIdentity.isBoolean(raw) else { return nil }
        return raw as? Bool
    }
}
