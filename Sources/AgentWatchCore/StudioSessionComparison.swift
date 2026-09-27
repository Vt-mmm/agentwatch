import Foundation
import CryptoKit

public struct StudioSessionRequest: Decodable, Equatable, Sendable {
    public let usage: StudioUsageRequest
    public let session_digest: String?
    public let session_key_family_id: UUID?
    public let native_models: [String]
    public let finished_at: Date?
    enum CodingKeys: String, CodingKey { case session_digest, session_key_family_id, native_models, finished_at }
    public init(from decoder: any Decoder) throws {
        usage = try StudioUsageRequest(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session_digest = try c.decodeIfPresent(String.self, forKey: .session_digest)
        session_key_family_id = try c.decodeIfPresent(UUID.self, forKey: .session_key_family_id)
        native_models = try c.decode([String].self, forKey: .native_models)
        finished_at = try c.decodeIfPresent(Date.self, forKey: .finished_at)
    }
}
public struct StudioSessionReport: Decodable, Equatable, Sendable {
    public let session_evidence_version: Int
    public let source: String
    public let from, to, observed_at: Date
    public let summary: StudioUsageSummary
    public let requests: [StudioSessionRequest]
    public let limit, offset: Int

    func validate(identity: StudioIdentity, provider: StudioCLIProvider, digest: String, range: Range<Date>) throws {
        guard session_evidence_version == 1, source == "studio_ledger", from < to,
              abs(from.timeIntervalSince(range.lowerBound)) < 0.001, abs(to.timeIntervalSince(range.upperBound)) < 0.001,
              limit == 100, offset == 0, requests.count <= 100,
              Set(requests.map(\.usage.id)).count == requests.count,
              (Int(summary.requests.value) ?? Int.max) >= requests.count,
              requests.allSatisfy({ row in
                  let r = row.usage
                  return r.user_id == identity.user.id && r.provider == provider.rawValue && row.session_digest == digest && row.session_key_family_id != nil &&
                      r.created_at >= from && r.created_at < to && (row.finished_at == nil || row.finished_at! >= r.created_at) &&
                      ["confirmed", "unresolved", "disputed"].contains(r.accounting_status) &&
                      (r.accounting_status == "confirmed" ? r.confirmed.total_tokens == r.charged_tokens : r.confirmed.total_tokens == nil) &&
                      row.native_models.count <= 100 && row.native_models.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 160 })
              }) else { throw StudioError.invalidResponse }
    }
}
public protocol StudioSessionReporting: Sendable {
    func sessionUsage(origin: StudioOrigin, key: String, identity: StudioIdentity, provider: StudioCLIProvider, digest: String, range: Range<Date>) async throws -> StudioSessionReport
}
extension StudioClient: StudioSessionReporting {
    public func sessionUsage(origin: StudioOrigin, key: String, identity: StudioIdentity, provider: StudioCLIProvider, digest: String, range: Range<Date>) async throws -> StudioSessionReport {
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              range.lowerBound < range.upperBound, range.upperBound.timeIntervalSince(range.lowerBound) <= 93 * 86400 else { throw StudioError.invalidResponse }
        let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let query = [URLQueryItem(name: "provider", value: provider.rawValue), URLQueryItem(name: "session_digest", value: digest),
                     URLQueryItem(name: "from", value: date.string(from: range.lowerBound)), URLQueryItem(name: "to", value: date.string(from: range.upperBound)),
                     URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "sort", value: "oldest")]
        let report: StudioSessionReport = try await get(origin, "studio/v1/me/usage", key: key, query: query)
        try report.validate(identity: identity, provider: provider, digest: digest, range: range)
        return report
    }
}

public struct StudioSessionComparison: Equatable, Sendable {
    public enum Status: String, Sendable { case matched, unmatched, partial, unavailable }
    public enum Reason: String, Sendable {
        case matched, noEvidence, differentTokens, localIncomplete, serverIncomplete, ambiguousFamily, modelMismatch, timeMismatch, unsupportedIdentity, unavailable
        public var label: String {
            switch self {
            case .matched: "Khớp phiên và tổng token"
            case .noEvidence: "Chưa có bằng chứng từ Studio trong khoảng đọc"
            case .differentTokens: "Tổng token hai nguồn khác nhau"
            case .localIncomplete: "Log trên máy chưa đầy đủ"
            case .serverIncomplete: "Báo cáo Studio chưa đủ dữ liệu xác nhận"
            case .ambiguousFamily: "Phiên trùng mã dưới nhiều key khác nhau"
            case .modelMismatch: "Chưa khớp được model giữa hai nguồn"
            case .timeMismatch: "Chưa khớp được khoảng thời gian"
            case .unsupportedIdentity: "Chưa hỗ trợ đối soát mã phiên này"
            case .unavailable: "Chưa đọc được báo cáo Studio"
            }
        }
    }
    public let status: Status
    public let reason: Reason
    public let serverTokens: StudioCount?
    public let serverRequests: StudioCount?
    public let observedAt: Date?
    public static func unavailable(_ reason: Reason = .unavailable) -> Self {
        Self(status: .unavailable, reason: reason, serverTokens: nil, serverRequests: nil, observedAt: nil)
    }
    /// Only actual UUID log identities are supported. Arbitrary IDs, hierarchy,
    /// prompt history and normalization remain the connector SDK's responsibility.
    public static func digest(sessionID: String) -> String? {
        guard let uuid = UUID(uuidString: sessionID), uuid.uuidString.lowercased() == sessionID.lowercased(), uuid != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) else { return nil }
        return SHA256.hash(data: Data(("studio-explicit-session-v1\0" + uuid.uuidString.lowercased()).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func compare(local: StudioLocalSession, report: StudioSessionReport, coveragePartial: Bool) -> Self {
        func result(_ status: Status, _ reason: Reason) -> Self {
            Self(status: status, reason: reason, serverTokens: report.summary.confirmed.total_tokens, serverRequests: report.summary.requests, observedAt: report.observed_at)
        }
        guard report.source == "studio_ledger", report.session_evidence_version == 1, let digest = digest(sessionID: local.sessionID),
              report.requests.allSatisfy({ $0.session_digest == digest && $0.usage.provider == local.provider.rawValue && $0.session_key_family_id != nil }) else { return result(.partial, .serverIncomplete) }
        guard !coveragePartial, !local.partial, let localTotal = local.knownTokens else { return result(.partial, .localIncomplete) }
        guard report.summary.requests.value == String(report.requests.count) else { return result(.partial, .serverIncomplete) }
        guard !report.requests.isEmpty else { return result(.unmatched, .noEvidence) }
        guard Set(report.requests.compactMap(\.session_key_family_id)).count == 1 else { return result(.partial, .ambiguousFamily) }
        guard report.summary.unresolved_requests.value == "0", report.summary.disputed_requests.value == "0",
              report.summary.confirmed_requests == report.summary.requests,
              report.requests.allSatisfy({ $0.usage.accounting_status == "confirmed" && $0.finished_at != nil }),
              let serverTotal = report.summary.confirmed.total_tokens else { return result(.partial, .serverIncomplete) }
        let localModels = Set((local.summary.usageEntries ?? []).map(\.modelID))
        // Codex persists the custom provider's canonical Studio ID; Claude
        // persists the native response ID. Each report row proves that mapping.
        let modelEvidence = report.requests.map { Set($0.native_models + [$0.usage.model_id]) }
        let allModels = modelEvidence.reduce(into: Set<String>()) { $0.formUnion($1) }
        guard !localModels.isEmpty, !localModels.contains(""), localModels.isSubset(of: allModels),
              modelEvidence.allSatisfy({ !$0.isDisjoint(with: localModels) }),
              report.requests.allSatisfy({ $0.native_models.count == 1 }) else { return result(.partial, .modelMismatch) }
        guard let first = local.summary.firstTimestamp, let last = local.summary.lastTimestamp,
              first >= report.from, last < report.to,
              let start = report.requests.map(\.usage.created_at).min(), let end = report.requests.compactMap(\.finished_at).max(),
              start <= last, end >= first, end < report.to,
              end <= report.observed_at else { return result(.partial, .timeMismatch) }
        // A complete bounded report must agree with its rows. Overflow remains
        // partial; exact server strings are still displayed, never cast to Double.
        var total = 0
        for row in report.requests {
            guard let value = row.usage.confirmed.total_tokens.flatMap({ Int($0.value) }) else { return result(.partial, .serverIncomplete) }
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return result(.partial, .serverIncomplete) }
            total = sum.partialValue
        }
        guard serverTotal.value == String(total) else { return result(.partial, .serverIncomplete) }
        return result(serverTotal.value == String(localTotal) ? .matched : .unmatched, serverTotal.value == String(localTotal) ? .matched : .differentTokens)
    }
}
