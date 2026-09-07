import Foundation
import CryptoKit

public enum QuotaAvailability: String, Codable, Sendable {
    case available, unavailable, unsupported, unauthenticated, failed
}

public struct QuotaWindow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let usedPercent: Double?
    public let durationMinutes: Int?
    public let resetsAt: Date?
    /// Clamp display only: preserve provider values such as 105% for audit.
    public var remainingPercent: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
}

/// Account/provider capacity, never employee usage, token cost or context fill.
public struct QuotaSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let provider: String
    public let source: String
    public let sourceVersion: String?
    public let accountKey: String?
    public let captureKey: String
    public let capturedAt: Date
    public let availability: QuotaAvailability
    public let windows: [QuotaWindow]
    public let warnings: [String]
    public var id: String { "\(provider)|\(accountKey ?? "unassigned")|\(captureKey)" }

    public func isStale(at now: Date, maxAge: TimeInterval = 900) -> Bool {
        now < capturedAt || now.timeIntervalSince(capturedAt) > maxAge
            || windows.contains { $0.resetsAt.map { now >= $0 } ?? false }
    }

    public static func unavailable(provider: String, source: String, at date: Date = Date(),
                                   reason: String, state: QuotaAvailability = .unavailable) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, source: source, sourceVersion: nil, accountKey: nil,
                      captureKey: source, capturedAt: date, availability: state, windows: [], warnings: [reason])
    }
}

public enum QuotaParser {
    public static func claudeStatusLine(_ info: [String: Any], at now: Date = Date()) -> QuotaSnapshot {
        let limits = info["rate_limits"] as? [String: Any] ?? [:]
        let windows = [("five_hour", 300), ("seven_day", 10_080)].compactMap { name, minutes -> QuotaWindow? in
            guard let raw = limits[name] as? [String: Any] else { return nil }
            return QuotaWindow(id: name, usedPercent: percent(raw["used_percentage"]),
                               durationMinutes: minutes, resetsAt: date(raw["resets_at"]))
        }
        // Statusline has no authenticated account identity. Keep captures separate
        // until the operator maps a session to a provider account.
        let session = info["session_id"] as? String ?? "unknown-session"
        return QuotaSnapshot(provider: "anthropic", source: "claude-statusline",
                             sourceVersion: info["version"] as? String, accountKey: nil,
                             captureKey: digest(session), capturedAt: now,
                             availability: windows.contains { $0.usedPercent != nil } ? .available : .unavailable,
                             windows: windows, warnings: windows.isEmpty
                                ? ["No rate_limits capability in this payload; subscription quota is unknown."]
                                : ["Account identity is not exposed by statusline; mapping requires operator review."])
    }

    /// Supply result from account/rateLimits/read or the notification params.
    /// A populated bucket map is authoritative; do not add the legacy mirror.
    public static func codex(_ payload: [String: Any], sourceVersion: String? = nil,
                             at now: Date = Date()) -> QuotaSnapshot {
        var buckets = payload["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        if buckets.isEmpty, let legacy = payload["rateLimits"] as? [String: Any] {
            buckets[legacy["limitId"] as? String ?? "codex"] = legacy
        }
        let windows = buckets.keys.sorted().flatMap { key -> [QuotaWindow] in
            ["primary", "secondary"].compactMap { name in
                guard let raw = buckets[key]?[name] as? [String: Any] else { return nil }
                let minutes = UsageIdentity.count(raw["windowDurationMins"], required: true)
                return QuotaWindow(id: "\(key)/\(name)", usedPercent: percent(raw["usedPercent"]),
                                   durationMinutes: minutes > 0 ? minutes : nil, resetsAt: date(raw["resetsAt"]))
            }
        }
        let account = (payload["accountId"] as? String).flatMap { $0.isEmpty ? nil : digest($0) }
        return QuotaSnapshot(provider: "openai", source: "codex-app-server", sourceVersion: sourceVersion,
                             accountKey: account, captureKey: "account-read", capturedAt: now,
                             availability: windows.contains { $0.usedPercent != nil } ? .available : .unavailable,
                             windows: windows, warnings: account == nil ? ["Account identity unavailable; do not join to employee totals."] : [])
    }

    public static func pi(at now: Date = Date()) -> QuotaSnapshot {
        .unavailable(provider: "pi", source: "pi-runtime", at: now,
                     reason: "Pi has no universal subscription quota. Select the underlying provider/account adapter.", state: .unsupported)
    }

    private static func percent(_ raw: Any?) -> Double? {
        guard let raw, !UsageIdentity.isBoolean(raw), let value = Double(String(describing: raw)),
              value.isFinite, value >= 0 else { return nil }
        return value
    }
    private static func date(_ raw: Any?) -> Date? {
        guard let seconds = percent(raw), seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Only normalized quota data is persisted; stdin, OAuth tokens and CLI auth
/// files are never copied. Atomic per-capture files avoid cross-process rewrites.
public struct QuotaSnapshotStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static var local: Self {
        Self(root: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/AgentWatch/quota", isDirectory: true))
    }
    public func save(_ snapshot: QuotaSnapshot) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Keep one normalized sample per source/account/minute for historical reports.
        let historyKey = snapshot.id + "|" + String(Int(snapshot.capturedAt.timeIntervalSince1970 / 60))
        let name = SHA256.hash(data: Data(historyKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = root.appendingPathComponent(name + ".json")
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load() throws -> [QuotaSnapshot] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(QuotaSnapshot.self, from: Data(contentsOf: $0)) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }
}
