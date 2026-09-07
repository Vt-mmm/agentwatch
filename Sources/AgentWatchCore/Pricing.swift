// USD-per-1M-token lookup. Ported 1:1 from the legacy Python price table.

import Foundation

public struct Price: Sendable, Equatable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public struct PriceQuote: Sendable, Equatable {
    public let price: Price
    public let sourceLabel: String

    public init(price: Price, sourceLabel: String) {
        self.price = price
        self.sourceLabel = sourceLabel
    }
}

public enum ModelFamily: String, Sendable, CaseIterable {
    case opus, sonnet, haiku, fable
    /// v0.7.0: GPT family (Codex agent uses gpt-5/gpt-4o/etc.). Pricing = 0 vì
    /// Codex là subscription, không bill per-token; UI vẫn show token count.
    case gpt
    case unknown

    public static func from(modelId: String?) -> ModelFamily {
        guard let m = modelId?.lowercased() else { return .unknown }
        for family in ModelFamily.allCases where family != .unknown {
            if m.contains(family.rawValue) { return family }
        }
        return .unknown
    }
}

public enum Pricing {
    /// Version is carried into exports/audit logs so old reports remain
    /// explainable after providers change their public prices.
    public static let versionLabel = "official-list-2026-09-06"

    /// Family fallbacks are retained for backwards-compatible tests and older
    /// Claude aliases. Production cost calculation uses `quote(forModelId:)`
    /// and returns unavailable for unrecognised GPT/Codex models.
    public static let defaultPrices: [ModelFamily: Price] = [
        .opus:   Price(input: 15, output: 75, cacheRead: 1.50, cacheWrite: 18.75),
        .sonnet: Price(input: 3,  output: 15, cacheRead: 0.30, cacheWrite: 3.75),
        .haiku:  Price(input: 0.80, output: 4, cacheRead: 0.08, cacheWrite: 1),
        .fable:  Price(input: 3,  output: 15, cacheRead: 0.30, cacheWrite: 3.75),
        .gpt:    Price(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
    ]

    public static func price(for family: ModelFamily) -> Price {
        defaultPrices[family] ?? Price(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
    }

    /// Public list-price quote for a recognised model. A nil quote is
    /// intentionally different from a zero-dollar subscription session.
    public static func quote(forModelId modelId: String?) -> PriceQuote? {
        guard let model = modelId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let price = exactPrices[model] else { return nil }
        return PriceQuote(price: price, sourceLabel: "\(model) standard list-price equivalent")
    }

    /// Verified per-request tiers. A cumulative delta cannot establish whether
    /// one request crossed a threshold, so callers can decline long-context pricing.
    public static func requestQuote(modelID: String, inputContext: Int, serviceTier: String?,
                                    isSingleRequest: Bool) -> PriceQuote? {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let base = quote(forModelId: model) else { return nil }
        let modernOpenAI: Set<String> = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        let flatLongClaude: Set<String> = ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5",
                                          "claude-sonnet-4-6", "claude-sonnet-5", "claude-fable-5", "claude-fable-5-1"]
        var inputMultiplier = 1.0, outputMultiplier = 1.0, tierMultiplier = 1.0
        if modernOpenAI.contains(model) {
            if inputContext > 272_000 {
                guard isSingleRequest else { return nil }
                inputMultiplier = 2; outputMultiplier = 1.5
            }
            switch serviceTier ?? "standard" {
            case "default", "standard", "auto": break
            case "fast": tierMultiplier = 2
            case "batch", "flex": tierMultiplier = 0.5
            default: return nil
            }
        } else {
            guard serviceTier == nil || ["default", "standard", "auto"].contains(serviceTier!) else { return nil }
            if inputContext > 200_000 && !flatLongClaude.contains(model) { return nil }
        }
        let p = base.price
        return PriceQuote(price: Price(input: p.input * inputMultiplier * tierMultiplier,
                                       output: p.output * outputMultiplier * tierMultiplier,
                                       cacheRead: p.cacheRead * inputMultiplier * tierMultiplier,
                                       cacheWrite: p.cacheWrite * inputMultiplier * tierMultiplier),
                          sourceLabel: base.sourceLabel + "; tier " + (serviceTier ?? "standard equivalent"))
    }

    /// Explicit IDs only. Unknown versions and subscription-only variants must
    /// never inherit a price just because their names contain a familiar family.
    /// Snapshot, not historical billing: https://developers.openai.com/api/docs/pricing
    /// and https://platform.claude.com/docs/en/about-claude/pricing (2026-09-06).
    private static let exactPrices: [String: Price] = [
        "gpt-6-astra": Price(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        "gpt-5.6-sol": Price(input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5),
        "gpt-5.6-terra": Price(input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2.5),
        "gpt-5.6-luna": Price(input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25),
        "gpt-5.5": Price(input: 5, output: 30, cacheRead: 0.5, cacheWrite: 0),
        "gpt-5.5-pro": Price(input: 30, output: 180, cacheRead: 0, cacheWrite: 0),
        "gpt-5.4": Price(input: 2.5, output: 15, cacheRead: 0.25, cacheWrite: 0),
        "gpt-5.4-pro": Price(input: 30, output: 180, cacheRead: 0, cacheWrite: 0),
        "gpt-5.4-mini": Price(input: 0.75, output: 4.5, cacheRead: 0.075, cacheWrite: 0),
        "gpt-5.4-nano": Price(input: 0.2, output: 1.25, cacheRead: 0.02, cacheWrite: 0),
        "gpt-5.3-codex": Price(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0),
        "claude-opus-5": Price(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-8": Price(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-7": Price(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-6": Price(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-5": Price(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-5-20251101": Price(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-1": Price(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        "claude-opus-4-1-20250805": Price(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        "claude-opus-4-20250514": Price(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        "claude-sonnet-5": Price(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        "claude-sonnet-4-6": Price(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-sonnet-4-5": Price(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-sonnet-4-5-20250929": Price(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-sonnet-4-20250514": Price(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-haiku-4-5": Price(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        "claude-haiku-4-5-20251001": Price(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        "claude-3-5-haiku-20241022": Price(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1),
        "claude-3-haiku-20240307": Price(input: 0.25, output: 1.25, cacheRead: 0.03, cacheWrite: 0.3),
        "claude-fable-5": Price(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        "claude-fable-5-1": Price(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)
    ]

    public static func cost(
        quote: PriceQuote,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) -> Double {
        cost(
            price: quote.price,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens
        )
    }

    /// Cost in USD for the given token counts under the model's pricing.
    public static func cost(
        family: ModelFamily,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) -> Double {
        cost(
            price: price(for: family),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens
        )
    }

    private static func cost(
        price p: Price,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) -> Double {
        return (
            Double(inputTokens)      * p.input      +
            Double(outputTokens)     * p.output     +
            Double(cacheReadTokens)  * p.cacheRead  +
            Double(cacheWriteTokens) * p.cacheWrite
        ) / 1_000_000.0
    }
}
