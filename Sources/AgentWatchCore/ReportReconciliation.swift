import Foundation

public struct ReconciliationObservation: Codable, Sendable, Equatable {
    public let provider: String
    public let accountKey: String
    public let periodStart: Date
    public let periodEnd: Date
    public let timeZone: String
    public let metric: String
    public let unit: String
    public let basis: String
    public let scope: String
    public let value: String
    public let complete: Bool
    public let source: String
    public let observedAt: Date
    public var decimal: Decimal? { Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) }
    public func validate() throws {
        guard !provider.isEmpty, !accountKey.isEmpty, periodStart < periodEnd, TimeZone(identifier: timeZone) != nil,
              ["tokens", "cost"].contains(metric), ["token", "USD"].contains(unit),
              ["normalized-request-usage", "provider-analytics", "list-price-estimate", "invoice"].contains(basis),
              !scope.isEmpty, !source.isEmpty, let decimal, !decimal.isNaN, decimal >= 0,
              value.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              (metric == "tokens" && unit == "token") || (metric == "cost" && unit == "USD") else { throw GoogleServiceError.invalidConfiguration }
    }
}
public struct ReportReconciliation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let organizationID: String
    public let owner: String
    public let recordedAt: Date
    public let left: ReconciliationObservation
    public let right: ReconciliationObservation
    public let note: String
    public var comparability: String {
        if !left.complete || !right.complete { return "Dữ liệu chưa đầy đủ; không tính chênh lệch tổng." }
        if left.provider != right.provider || left.accountKey != right.accountKey || left.scope != right.scope { return "Khác provider/tài khoản/phạm vi; giữ hai số riêng." }
        if left.periodStart != right.periodStart || left.periodEnd != right.periodEnd { return "Khác kỳ thu thập; không chia tỷ lệ bucket UTC sang ngày địa phương." }
        if left.metric != right.metric || left.unit != right.unit || left.basis != right.basis { return "Khác đơn vị hoặc cơ sở tính; estimate không phải hóa đơn." }
        return "Cùng phạm vi, kỳ, đơn vị và cơ sở tính; có thể đối chiếu."
    }
    public var difference: Decimal? {
        guard left.complete, right.complete, left.provider == right.provider, left.accountKey == right.accountKey,
              left.scope == right.scope, left.periodStart == right.periodStart, left.periodEnd == right.periodEnd,
              left.metric == right.metric, left.unit == right.unit, left.basis == right.basis,
              let a = left.decimal, let b = right.decimal else { return nil }
        return b - a
    }
    public func validate() throws {
        guard UUID(uuidString: id) != nil, !organizationID.isEmpty, !owner.isEmpty, !note.isEmpty else { throw GoogleServiceError.invalidConfiguration }
        try left.validate(); try right.validate()
    }
}
public struct ReportReconciliationStore: Sendable {
    public let files: ReportFileStore
    public init(root: URL) { files = ReportFileStore(root: root) }
    public static var local: Self { Self(root: ReportSnapshotStore.local.files.root.appendingPathComponent("reconciliations")) }
    public func save(_ record: ReportReconciliation) throws {
        try record.validate()
        try files.transaction {
            let url = files.root.appendingPathComponent(record.id + ".json")
            guard !FileManager.default.fileExists(atPath: url.path) else { throw GoogleServiceError.conflict }
            try files.write(ReportEncoding.encode(record), to: url)
        }
    }
    public func all() throws -> [ReportReconciliation] {
        try files.transaction {
            try FileManager.default.contentsOfDirectory(at: files.root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map {
                let record = try ReportEncoding.decode(ReportReconciliation.self, from: Data(contentsOf: $0)); try record.validate(); return record
            }.sorted { $0.recordedAt > $1.recordedAt }
        }
    }
}
