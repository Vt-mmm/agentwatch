import Foundation
import CryptoKit
import CoreFoundation

/// Source values retain the provider's inclusion semantics. Conversion happens
/// once here, never in a renderer. Sub-buckets are not additive twice.
public struct UsageTokens: Codable, Sendable, Equatable {
    public var input: Int = 0
    public var output: Int = 0
    public var cacheRead: Int = 0
    public var cacheWrite: Int = 0
    public var cacheWrite1h: Int = 0
    public var reasoning: Int = 0
    public var rule: TokenAccountingRule = .additiveCacheBuckets

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                cacheWrite: Int = 0, cacheWrite1h: Int = 0, reasoning: Int = 0,
                rule: TokenAccountingRule = .additiveCacheBuckets) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite; self.cacheWrite1h = cacheWrite1h
        self.reasoning = reasoning; self.rule = rule
    }

    public var isValid: Bool {
        let counts = [input, output, cacheRead, cacheWrite, cacheWrite1h, reasoning]
        guard counts.allSatisfy({ $0 >= 0 }), cacheWrite1h <= cacheWrite,
              reasoning <= output else { return false }
        if rule == .inclusiveBreakdowns && (cacheRead > input || cacheWrite > input - cacheRead) { return false }
        var sum = 0
        for count in counts {
            let next = sum.addingReportingOverflow(count)
            if next.overflow { return false }
            sum = next.partialValue
        }
        return true
    }

    public var uncachedInput: Int { rule == .inclusiveBreakdowns ? input - cacheRead - cacheWrite : input }
    public var total: Int {
        guard isValid else { return 0 }
        return rule == .inclusiveBreakdowns ? input + output : input + output + cacheRead + cacheWrite
    }
    public var normalized: UsageTokens {
        guard isValid else { return UsageTokens() }
        return UsageTokens(input: uncachedInput, output: output, cacheRead: cacheRead,
                           cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1h,
                           reasoning: reasoning)
    }
}

public enum UsageMeasurement: String, Codable, Sendable { case request, counterDelta }

public enum CostCoverage: String, Codable, Sendable { case complete, partial, unavailable }

/// A request or attributable cumulative-counter delta. No credential is stored.
public struct UsageEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sessionID: String
    public var agent: String
    public var provider: String
    public var modelID: String
    public var timestamp: Date
    public var tokens: UsageTokens
    public var serviceTier: String?
    public var measurement: UsageMeasurement
    public var taskID: String?
    public var taskRunID: String?
    public var agentEstimatedUSD: Decimal?
    public var warnings: [String]
    public var pricingVersion: String = Pricing.versionLabel

    public init(id: String, sessionID: String, agent: String, provider: String,
                modelID: String, timestamp: Date, tokens: UsageTokens,
                serviceTier: String? = nil, measurement: UsageMeasurement = .request, taskID: String? = nil, taskRunID: String? = nil,
                agentEstimatedUSD: Decimal? = nil, warnings: [String] = []) {
        self.id = id; self.sessionID = sessionID; self.agent = agent
        self.provider = provider; self.modelID = modelID; self.timestamp = timestamp
        self.tokens = tokens; self.serviceTier = serviceTier; self.measurement = measurement
        self.taskID = taskID; self.taskRunID = taskRunID
        self.agentEstimatedUSD = agentEstimatedUSD; self.warnings = warnings
    }

    public var estimatedUSD: Decimal? {
        guard tokens.isValid else { return nil }
        if let amount = agentEstimatedUSD, !amount.isNaN, amount >= 0 { return amount }
        // Unknown provider routing/tier is never priced as another provider's bill.
        // These are standard list-price equivalents, explicitly labelled as such.
        let t = tokens.normalized
        guard ["anthropic", "openai", "openai-codex"].contains(provider),
              (provider == "anthropic" && modelID.hasPrefix("claude-"))
                || (["openai", "openai-codex"].contains(provider) && modelID.hasPrefix("gpt-")),
              let quote = Pricing.requestQuote(modelID: modelID,
                                                inputContext: t.input + t.cacheRead + t.cacheWrite,
                                                serviceTier: serviceTier, isSingleRequest: measurement == .request) else { return nil }
        let p = quote.price
        // A zero cached/write rate means unsupported in this table, not free.
        guard (t.cacheRead == 0 || p.cacheRead > 0),
              (t.cacheWrite == 0 || p.cacheWrite > 0) else { return nil }
        let amount = Decimal(t.input) * Decimal(p.input)
            + Decimal(t.output) * Decimal(p.output)
            + Decimal(t.cacheRead) * Decimal(p.cacheRead)
            + Decimal(t.cacheWrite - t.cacheWrite1h) * Decimal(p.cacheWrite)
            + Decimal(t.cacheWrite1h) * Decimal(p.input * 2)
        return amount / 1_000_000
    }

    public var costBasis: UsageCostBasis {
        guard estimatedUSD != nil else { return .unavailable }
        return agentEstimatedUSD == nil ? .estimated : .agentEstimated
    }
}

public struct UsageLedger: Sendable, Equatable {
    public private(set) var entries: [UsageEntry] = []
    private var indices: [String: Int] = [:]
    private var sourceWarnings: Set<String> = []
    public mutating func recordWarning(_ message: String) { sourceWarnings.insert(message) }
    public var hasPartialUsage: Bool { !sourceWarnings.isEmpty || entries.contains { !$0.tokens.isValid } || tokenAggregation.overflow }

    public init() {}
    public init(entries: [UsageEntry]) { for entry in entries { upsert(entry) } }

    /// Later source revisions replace earlier ones for the same request; they
    /// are not additional consumption. Cross-session copies share the request ID.
    public mutating func upsert(_ entry: UsageEntry) {
        if let index = indices[entry.id] {
            if entries[index].timestamp <= entry.timestamp { entries[index] = entry }
        } else {
            indices[entry.id] = entries.count
            entries.append(entry)
        }
    }

    private var tokenAggregation: (tokens: UsageTokens, overflow: Bool) {
        var result = UsageTokens()
        var overflow = false
        for entry in entries where entry.tokens.isValid {
            let t = entry.tokens.normalized
            let pairs = [(result.input, t.input), (result.output, t.output),
                         (result.cacheRead, t.cacheRead), (result.cacheWrite, t.cacheWrite),
                         (result.cacheWrite1h, t.cacheWrite1h), (result.reasoning, t.reasoning)]
            let sums = pairs.map { $0.0.addingReportingOverflow($0.1) }
            guard !sums.contains(where: { $0.overflow }) else { overflow = true; continue }
            let candidate = UsageTokens(input: sums[0].partialValue, output: sums[1].partialValue,
                                        cacheRead: sums[2].partialValue, cacheWrite: sums[3].partialValue,
                                        cacheWrite1h: sums[4].partialValue, reasoning: sums[5].partialValue)
            guard candidate.isValid else { overflow = true; continue }
            result = candidate
        }
        return (result, overflow)
    }
    public var normalizedTokens: UsageTokens { tokenAggregation.tokens }
    public var knownCostSubtotal: Decimal { entries.compactMap(\.estimatedUSD).reduce(0, +) }
    public var missingCostCount: Int { entries.filter { $0.estimatedUSD == nil }.count }
    public var costCoverage: CostCoverage {
        if entries.isEmpty || missingCostCount == entries.count { return .unavailable }
        return missingCostCount == 0 ? .complete : .partial
    }
    public var costBasis: UsageCostBasis {
        let known = entries.filter { $0.estimatedUSD != nil }
        guard !known.isEmpty else { return .unavailable }
        return known.allSatisfy { $0.costBasis == .agentEstimated } ? .agentEstimated : .estimated
    }
    public var warnings: [String] {
        var messages = entries.flatMap(\.warnings) + Array(sourceWarnings)
        if tokenAggregation.overflow { messages.append("Token sum overflow; usage is partial.") }
        if entries.contains(where: { !$0.tokens.isValid }) { messages.append("Invalid token breakdown excluded; usage is partial.") }
        if missingCostCount > 0 { messages.append("Cost subtotal only: \(missingCostCount)/\(entries.count) requests have no supported cost estimate.") }
        return Array(Set(messages)).sorted()
    }
}

enum UsageIdentity {
    static func isBoolean(_ raw: Any) -> Bool {
        guard let number = raw as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Missing optional buckets are zero; malformed numbers remain invalid.
    static func count(_ raw: Any?, required: Bool = false) -> Int {
        guard let raw else { return required ? -1 : 0 }
        guard !isBoolean(raw), let decimal = Decimal(string: String(describing: raw), locale: Locale(identifier: "en_US_POSIX")),
              !decimal.isNaN, decimal >= 0, decimal <= Decimal(Int.max) else { return -1 }
        let number = NSDecimalNumber(decimal: decimal)
        let value = number.intValue
        return Decimal(value) == decimal ? value : -1
    }

    static func key(agent: String, provider: String, id: String?, raw: Data, sessionID: String = "unknown") -> String {
        let canonical = (try? JSONSerialization.jsonObject(with: raw)).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? raw
        let suffix = id.flatMap { $0.isEmpty ? nil : $0 }
            ?? "content-" + sessionID + "-" + SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        return "\(agent)|\(provider)|\(suffix)"
    }
    static func decimal(_ raw: Any?) -> Decimal? {
        guard let raw, !isBoolean(raw), let result = Decimal(string: String(describing: raw), locale: Locale(identifier: "en_US_POSIX")),
              !result.isNaN, result >= 0 else { return nil }
        return result
    }
}
