import Foundation

/// Decimal strings remain exact above Int64 and JavaScript's safe integer range.
public struct StudioCount: Codable, Equatable, Sendable {
    public let value: String
    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 80, value.utf8.allSatisfy({ (48...57).contains($0) }) else { throw StudioError.invalidResponse }
        self.value = String(value.drop(while: { $0 == "0" })).isEmpty ? "0" : String(value.drop(while: { $0 == "0" }))
    }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value) }
    public var formatted: String {
        String(value.reversed().enumerated().flatMap { index, c in index > 0 && index % 3 == 0 ? [Character("."), c] : [c] }.reversed())
    }
}
public struct StudioTokenTotals: Codable, Equatable, Sendable {
    public let total_tokens, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens: StudioCount?
}
// Wire field names are retained deliberately so this projection can be audited
// against the authoritative Go reporting contract without a second accounting model.
public struct StudioUsageSummary: Codable, Equatable, Sendable {
    public let requests, confirmed_requests, unresolved_requests, disputed_requests, charged_tokens: StudioCount
    public let confirmed: StudioTokenTotals
}
public struct StudioUsageGroup: Codable, Equatable, Sendable {
    public let id: String?
    public let label: String
    public let requests, unresolved_requests, charged_tokens: StudioCount
    public let confirmed: StudioTokenTotals
}
public struct StudioOverview: Codable, Equatable, Sendable {
    public let source, timezone: String
    public let observed_at, from, to: Date
    public let summary: StudioUsageSummary
    public let models: [StudioUsageGroup]
}
public struct StudioUsageRequest: Codable, Equatable, Sendable, Identifiable {
    public let id, user_id, key_id: UUID
    public let model_id, provider, accounting_status: String
    public let created_at: Date
    public let charged_tokens: StudioCount
    public let confirmed: StudioTokenTotals
}
public struct StudioUsageReport: Codable, Equatable, Sendable {
    public let source, timezone: String
    public let observed_at, from, to: Date
    public let requests: [StudioUsageRequest]
    public let limit, offset: Int
}
public struct StudioQuotaWindow: Codable, Equatable, Sendable, Identifiable {
    public let id, policy_id: UUID
    public let model_id: String?
    public let period, timezone: String
    public let tokens: Int64
    public let starts_at, ends_at: Date
    public let confirmed_tokens, reserved_tokens, remaining_tokens: StudioCount
}
public struct StudioQuotaPolicy: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let scope: String
}
public struct StudioQuota: Codable, Equatable, Sendable {
    public let policy_allowed, admission_required: Bool
    public let user_id, key_id: UUID
    public let model_id, reason: String?
    public let observed_at: Date
    public let windows: [StudioQuotaWindow]
    public let policies: [StudioQuotaPolicy]
}
public struct StudioDashboardSnapshot: Codable, Equatable, Sendable {
    public let identity: StudioIdentity
    public let today, month: StudioOverview
    public let recent: StudioUsageReport
    public let quotaModel: StudioModel?
    public let quota: StudioQuota?
    public let quotaError: StudioError?
    public let fetchedAt: Date
}

public struct StudioReportingRange: Sendable {
    public let today, month, until: Date
    public let timezone: String
    public init(now: Date, timezone: TimeZone) throws {
        // IANA IDs match PostgreSQL's timezone catalogue; a custom fixed zone is
        // presented explicitly as UTC, never silently used for local boundaries.
        let zone = TimeZone.knownTimeZoneIdentifiers.contains(timezone.identifier) ? timezone : TimeZone(secondsFromGMT: 0)!
        self.timezone = zone.secondsFromGMT() == 0 && zone.identifier == "GMT" ? "UTC" : zone.identifier
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        today = calendar.startOfDay(for: now)
        guard let month = calendar.dateInterval(of: .month, for: now)?.start else { throw StudioError.invalidResponse }
        self.month = month
        until = max(Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 * 1000) / 1000), today.addingTimeInterval(0.001))
    }
    func query(from: Date, includeTimezone: Bool) -> [URLQueryItem] {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var items = [URLQueryItem(name: "from", value: formatter.string(from: from)), URLQueryItem(name: "to", value: formatter.string(from: until))]
        if includeTimezone { items.append(URLQueryItem(name: "timezone", value: timezone)) }
        return items
    }
}
public protocol StudioReporting: Sendable {
    func dashboard(origin: StudioOrigin, key: String, identity: StudioIdentity, model: StudioModel?, now: Date, timezone: TimeZone) async throws -> StudioDashboardSnapshot
}
extension StudioClient: StudioReporting {
    public func dashboard(origin: StudioOrigin, key: String, identity: StudioIdentity, model: StudioModel?, now: Date = Date(), timezone: TimeZone = .current) async throws -> StudioDashboardSnapshot {
        let range = try StudioReportingRange(now: now, timezone: timezone)
        let today: StudioOverview = try await get(origin, "studio/v1/me/overview", key: key, query: range.query(from: range.today, includeTimezone: true))
        let month: StudioOverview = try await get(origin, "studio/v1/me/overview", key: key, query: range.query(from: range.month, includeTimezone: true))
        let recent: StudioUsageReport = try await get(origin, "studio/v1/me/usage", key: key, query: range.query(from: range.month, includeTimezone: false) + [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "sort", value: "newest")])
        var quota: StudioQuota?, quotaError: StudioError?
        if let model {
            do {
                quota = try await get(origin, "studio/v1/me/policy", key: key, query: [URLQueryItem(name: "model", value: model.id), URLQueryItem(name: "protocol", value: model.nativeProtocol)])
            } catch let error as StudioError {
                guard [.serverUnavailable, .offline, .rateLimited, .quotaExceeded, .upstreamUnavailable, .permissionDenied].contains(error) else { throw error }
                quotaError = error
            }
        }
        let result = StudioDashboardSnapshot(identity: identity, today: today, month: month, recent: recent, quotaModel: model, quota: quota, quotaError: quotaError, fetchedAt: Date())
        try result.validate()
        guard abs(today.from.timeIntervalSince(range.today)) < 0.001, abs(month.from.timeIntervalSince(range.month)) < 0.001,
              abs(month.to.timeIntervalSince(range.until)) < 0.001, today.timezone == range.timezone else { throw StudioError.invalidResponse }
        return result
    }
}
extension StudioDashboardSnapshot {
    func validate() throws {
        guard today.source == "studio_ledger", month.source == "studio_ledger", recent.source == "studio_ledger",
              today.from < today.to, month.from < month.to, today.from >= month.from,
              today.to == month.to, recent.from == month.from, recent.to == month.to,
              today.timezone == month.timezone, TimeZone(identifier: today.timezone) != nil,
              month.to.timeIntervalSince(month.from) <= 32 * 86400,
              today.models.count <= 10, month.models.count <= 10,
              recent.requests.count <= 20, recent.limit == 20, recent.offset == 0,
              Set(recent.requests.map(\.id)).count == recent.requests.count,
              recent.requests.allSatisfy({ $0.user_id == identity.user.id && ["confirmed", "unresolved", "disputed"].contains($0.accounting_status) && (["claude", "codex"].contains($0.provider) || StudioVendor.valid($0.provider)) && $0.created_at >= recent.from && $0.created_at < recent.to && ($0.accounting_status == "confirmed" || $0.confirmed.total_tokens == nil) })
        else { throw StudioError.invalidResponse }
        if let quota {
            guard quota.admission_required, quota.user_id == identity.user.id, quota.windows.count <= 1000,
                  Set(quota.windows.map(\.id)).count == quota.windows.count,
                  quotaModel != nil, quota.policy_allowed ? quota.model_id == quotaModel?.id : quota.windows.isEmpty,
                  quota.windows.allSatisfy({ $0.tokens >= 0 && $0.starts_at < $0.ends_at && ["day", "month"].contains($0.period) && TimeZone(identifier: $0.timezone) != nil }) else { throw StudioError.invalidResponse }
        }
    }
}
