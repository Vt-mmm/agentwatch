import Foundation
import CryptoKit

public struct EmployeeProfile: Codable, Sendable, Equatable {
    public var organizationID: String
    public var employeeID: String
    public var displayName: String
    public var timeZone: String
    public var workEmail: String?
    public init(organizationID: String, employeeID: String, displayName: String,
                timeZone: String = "Asia/Ho_Chi_Minh", workEmail: String? = nil) {
        self.organizationID = organizationID; self.employeeID = employeeID
        self.displayName = displayName; self.timeZone = timeZone; self.workEmail = workEmail
    }
}

public struct DailyReportPeriod: Codable, Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let cutoff: Date
    public let timeZone: String
    public var range: Range<Date> { start..<end }
    public var scanRange: Range<Date> {
        let inclusiveCutoff = Date(timeIntervalSinceReferenceDate: cutoff.timeIntervalSinceReferenceDate.nextUp)
        return start..<min(end, inclusiveCutoff)
    }
    public init(day: Date, timeZone: String, cutoff: Date) throws {
        guard let zone = TimeZone(identifier: timeZone) else { throw ReportValidationError.invalid("Múi giờ không hợp lệ.") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        start = calendar.startOfDay(for: day)
        end = calendar.date(byAdding: .day, value: 1, to: start)!
        self.cutoff = min(cutoff, end); self.timeZone = timeZone
        guard cutoff >= start else { throw ReportValidationError.invalid("Không thể chốt báo cáo trước ngày được chọn.") }
    }
    public func contains(_ date: Date) -> Bool { range.contains(date) && date <= cutoff }
}

public enum WorkStatus: String, Codable, CaseIterable, Sendable {
    case completed, readyForReview, inProgress, blocked, cancelled, unknown
    public var label: String {
        switch self {
        case .completed: "Hoàn thành"
        case .readyForReview: "Chờ review"
        case .inProgress: "Đang làm"
        case .blocked: "Đang vướng"
        case .cancelled: "Đã dừng"
        case .unknown: "Cần xác nhận"
        }
    }
}
public enum ClaimBasis: String, Codable, Sendable { case toolVerified, humanConfirmed, agentReported, inferred }
public enum ReportEvidenceKind: String, Codable, Sendable { case sessionActivity, toolResult, artifact, taskJournal, humanConfirmation }

public struct ReportEvidence: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionRef: String?
    public let kind: ReportEvidenceKind
    public let observedAt: Date
    public let summary: String
    public let localRef: String?
    public let digest: String
    public var shareableURL: String?
    /// Backfilled employee notes keep their actual entry time and explicit report day.
    public let appliesToDay: Date?
    public init(id: String, sessionRef: String?, kind: ReportEvidenceKind, observedAt: Date,
                summary: String, localRef: String? = nil, digest: String, shareableURL: String? = nil, appliesToDay: Date? = nil) {
        self.id = id; self.sessionRef = sessionRef; self.kind = kind; self.observedAt = observedAt
        self.summary = summary; self.localRef = localRef; self.digest = digest; self.shareableURL = shareableURL; self.appliesToDay = appliesToDay
    }
}

public struct WorkClaim: Codable, Sendable, Equatable {
    public var text: String
    public var basis: ClaimBasis
    public var evidenceIDs: [String]
    public init(text: String, basis: ClaimBasis, evidenceIDs: [String]) {
        self.text = text; self.basis = basis; self.evidenceIDs = evidenceIDs
    }
}

public struct ReportWorkItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var project: String
    public var title: String
    public var taskRefs: [String]
    public var taskRunIDs: [String]
    public var sessionRefs: [String]
    public var status: WorkStatus
    public var activities: [String]
    public var claims: [WorkClaim]
    public var evidenceIDs: [String]
    public var blockers: String
    public var nextActions: String
    public var humanConfirmed: Bool
    public var manualMinutes: Int?
    public init(id: String, project: String, title: String, taskRefs: [String] = [], taskRunIDs: [String] = [],
                sessionRefs: [String] = [], status: WorkStatus = .unknown, activities: [String] = [], claims: [WorkClaim] = [],
                evidenceIDs: [String] = [], blockers: String = "", nextActions: String = "", humanConfirmed: Bool = false,
                manualMinutes: Int? = nil) {
        self.id = id; self.project = project; self.title = title; self.taskRefs = taskRefs
        self.taskRunIDs = taskRunIDs; self.sessionRefs = sessionRefs; self.status = status
        self.activities = activities; self.claims = claims; self.evidenceIDs = evidenceIDs
        self.blockers = blockers; self.nextActions = nextActions; self.humanConfirmed = humanConfirmed
        self.manualMinutes = manualMinutes
    }
}

/// Freeze numeric values when the report is built: future price catalog changes
/// must not silently recalculate an already reviewed report.
public struct ReportUsageRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let agent: String
    public let provider: String
    public let modelID: String
    public let timestamp: Date
    public let tokens: UsageTokens
    public let knownUSD: Decimal?
    public let costBasis: UsageCostBasis
    public let pricingVersion: String
    public var workItemID: String?
    public init(entry: UsageEntry, workItemID: String? = nil) {
        id = entry.id; agent = entry.agent; provider = entry.provider; modelID = entry.modelID
        timestamp = entry.timestamp; tokens = entry.tokens; knownUSD = entry.estimatedUSD
        costBasis = entry.costBasis; pricingVersion = entry.pricingVersion; self.workItemID = workItemID
    }
    enum CodingKeys: String, CodingKey { case id, agent, provider, modelID, timestamp, tokens, knownUSD, costBasis, pricingVersion, workItemID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); agent = try c.decode(String.self, forKey: .agent)
        provider = try c.decode(String.self, forKey: .provider); modelID = try c.decode(String.self, forKey: .modelID)
        timestamp = try c.decode(Date.self, forKey: .timestamp); tokens = try c.decode(UsageTokens.self, forKey: .tokens)
        if let amount = try c.decodeIfPresent(String.self, forKey: .knownUSD) {
            guard let decimal = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN, decimal >= 0 else {
                throw ReportValidationError.invalid("Chi phí snapshot không phải decimal hợp lệ.")
            }
            knownUSD = decimal
        } else { knownUSD = nil }
        costBasis = try c.decode(UsageCostBasis.self, forKey: .costBasis)
        pricingVersion = try c.decode(String.self, forKey: .pricingVersion)
        workItemID = try c.decodeIfPresent(String.self, forKey: .workItemID)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(agent, forKey: .agent); try c.encode(provider, forKey: .provider)
        try c.encode(modelID, forKey: .modelID); try c.encode(timestamp, forKey: .timestamp); try c.encode(tokens, forKey: .tokens)
        try c.encodeIfPresent(knownUSD.map { NSDecimalNumber(decimal: $0).stringValue }, forKey: .knownUSD)
        try c.encode(costBasis, forKey: .costBasis); try c.encode(pricingVersion, forKey: .pricingVersion)
        try c.encodeIfPresent(workItemID, forKey: .workItemID)
    }

}

public struct DailyReportDraft: Codable, Sendable, Equatable {
    public var employee: EmployeeProfile
    public let period: DailyReportPeriod
    public var workItems: [ReportWorkItem]
    public var evidence: [ReportEvidence]
    public var usage: [ReportUsageRecord]
    public var quota: [QuotaSnapshot]
    public var warnings: [String]
    public var sourceFiles: [SourceFileManifest]
    public var sourceRoots: [SourceRootManifest]
    public var summary: String
    public var notes: String
    public var narrativeProvenance: String
    // Optional so legacy snapshots re-encode without changing their content seal.
    public var dailyActivity: ReportDailyActivity? = nil
    public var desktopActivity: DesktopActivityReport? = nil
    public var reportID: String {
        ReportEncoding.digest(Data("\(employee.organizationID)|\(employee.employeeID)|\(period.start.timeIntervalSince1970)|\(period.timeZone)".utf8))
    }
    public var knownCostSubtotal: Decimal { usage.compactMap(\.knownUSD).reduce(0, +) }
    public var missingCostCount: Int { usage.filter { $0.knownUSD == nil }.count }
    public var totalTokens: Int { usage.reduce(0) { $0 + $1.tokens.total } }
    public var unallocatedTokens: Int { usage.filter { $0.workItemID == nil }.reduce(0) { $0 + $1.tokens.total } }
    public var costCoverage: CostCoverage {
        if usage.isEmpty || missingCostCount == usage.count { return .unavailable }
        return missingCostCount == 0 ? .complete : .partial
    }
}

public struct ReportSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let rendererVersion: String
    public let reportID: String
    public let revision: Int
    public let generatedAt: Date
    public let reviewedBy: String
    public let report: DailyReportDraft
    public let contentHash: String
    public var id: String { "\(reportID)-r\(revision)" }
}

public enum ReportValidationError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

public enum ReportEncoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = PiTaskJournal.parseDate(raw) else { throw ReportValidationError.invalid("Timestamp không đúng ISO 8601.") }
            return date
        }
        return try decoder.decode(type, from: data)
    }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
