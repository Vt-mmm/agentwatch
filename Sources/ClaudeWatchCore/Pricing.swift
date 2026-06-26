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
    /// Anthropic public list prices per 1M tokens (Jan 2026 snapshot).
    public static let defaultPrices: [ModelFamily: Price] = [
        .opus:   Price(input: 15, output: 75, cacheRead: 1.50, cacheWrite: 18.75),
        .sonnet: Price(input: 3,  output: 15, cacheRead: 0.30, cacheWrite: 3.75),
        .haiku:  Price(input: 1,  output: 5,  cacheRead: 0.10, cacheWrite: 1.25),
        .fable:  Price(input: 3,  output: 15, cacheRead: 0.30, cacheWrite: 3.75),
    ]

    public static func price(for family: ModelFamily) -> Price {
        defaultPrices[family] ?? Price(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
    }

    /// Cost in USD for the given token counts under the model's pricing.
    public static func cost(
        family: ModelFamily,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) -> Double {
        let p = price(for: family)
        return (
            Double(inputTokens)      * p.input      +
            Double(outputTokens)     * p.output     +
            Double(cacheReadTokens)  * p.cacheRead  +
            Double(cacheWriteTokens) * p.cacheWrite
        ) / 1_000_000.0
    }
}
