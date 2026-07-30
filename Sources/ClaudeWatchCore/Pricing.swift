// USD-per-1M-token lookup. Ported 1:1 from Python claude_watch.pricing.

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
    public static let versionLabel = "official-list-2026-07-30"

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
        guard let raw = modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let model = raw.lowercased()

        if model.contains("gpt-5.3-codex") {
            return PriceQuote(
                price: Price(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0),
                sourceLabel: "OpenAI gpt-5.3-codex standard list"
            )
        }
        if model.contains("gpt-5.6-sol") {
            return PriceQuote(
                price: Price(input: 5, output: 30, cacheRead: 0.50, cacheWrite: 6.25),
                sourceLabel: "OpenAI gpt-5.6-sol standard short-context list"
            )
        }
        if model.contains("gpt-5.6-terra") {
            return PriceQuote(
                price: Price(input: 2.50, output: 15, cacheRead: 0.25, cacheWrite: 3.125),
                sourceLabel: "OpenAI gpt-5.6-terra standard short-context list"
            )
        }
        if model.contains("gpt-5.6-luna") {
            return PriceQuote(
                price: Price(input: 1, output: 6, cacheRead: 0.10, cacheWrite: 1.25),
                sourceLabel: "OpenAI gpt-5.6-luna standard short-context list"
            )
        }
        if model.contains("gpt-5.5-pro") {
            return PriceQuote(
                price: Price(input: 30, output: 180, cacheRead: 0, cacheWrite: 0),
                sourceLabel: "OpenAI gpt-5.5-pro standard short-context list"
            )
        }
        if model.contains("gpt-5.5") {
            return PriceQuote(
                price: Price(input: 5, output: 30, cacheRead: 0.50, cacheWrite: 0),
                sourceLabel: "OpenAI gpt-5.5 standard short-context list"
            )
        }
        if model.contains("gpt-5.4-mini") {
            return PriceQuote(
                price: Price(input: 0.75, output: 4.50, cacheRead: 0.075, cacheWrite: 0),
                sourceLabel: "OpenAI gpt-5.4-mini standard list"
            )
        }
        if model.contains("gpt-5.4-nano") {
            return PriceQuote(
                price: Price(input: 0.20, output: 1.25, cacheRead: 0.02, cacheWrite: 0),
                sourceLabel: "OpenAI gpt-5.4-nano standard list"
            )
        }
        if model.contains("gpt-5.4-pro") {
            return PriceQuote(
                price: Price(input: 30, output: 180, cacheRead: 0, cacheWrite: 0),
                sourceLabel: "OpenAI gpt-5.4-pro standard short-context list"
            )
        }
        if model.contains("gpt-5.4") {
            return PriceQuote(
                price: Price(input: 2.50, output: 15, cacheRead: 0.25, cacheWrite: 0),
                sourceLabel: "OpenAI gpt-5.4 standard short-context list"
            )
        }

        if (model.contains("haiku-3") || model.contains("claude-3-haiku"))
            && !model.contains("haiku-3-5")
            && !model.contains("haiku-3.5") {
            return PriceQuote(
                price: Price(input: 0.25, output: 1.25, cacheRead: 0.03, cacheWrite: 0.30),
                sourceLabel: "Anthropic Claude Haiku 3 list"
            )
        }
        if model.contains("haiku-3-5") || model.contains("haiku-3.5")
            || model.contains("3-5-haiku") || model.contains("haiku") {
            return PriceQuote(
                price: Price(input: 0.80, output: 4, cacheRead: 0.08, cacheWrite: 1),
                sourceLabel: "Anthropic Claude Haiku 3.5 list"
            )
        }
        if model.contains("sonnet") || model.contains("fable") {
            return PriceQuote(
                price: price(for: model.contains("fable") ? .fable : .sonnet),
                sourceLabel: "Anthropic Claude Sonnet family list"
            )
        }
        if model.contains("opus") {
            return PriceQuote(
                price: price(for: .opus),
                sourceLabel: "Anthropic Claude Opus family list"
            )
        }
        return nil
    }

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
