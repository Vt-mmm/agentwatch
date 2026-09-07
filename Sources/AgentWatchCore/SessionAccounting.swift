import Foundation

public extension SessionSummary {
    /// Preserve the richer display record, but combine request evidence instead
    /// of summing archived/live copies of the same session.
    func withAccounting(entries: [UsageEntry], warnings: [String]? = nil) -> SessionSummary {
        let ledger = UsageLedger(entries: entries)
        let t = ledger.normalizedTokens
        let input = tokenAccountingRule == .inclusiveBreakdowns ? t.input + t.cacheRead + t.cacheWrite : t.input
        return SessionSummary(id: id, sessionTitle: sessionTitle, titleHistory: titleHistory,
                              projectDisplay: projectDisplay, source: source, model: model, modelFamily: modelFamily,
                              inputTokens: input, outputTokens: t.output, reasoningTokens: t.reasoning,
                              cacheReadTokens: t.cacheRead, cacheWriteTokens: t.cacheWrite,
                              cost: NSDecimalNumber(decimal: ledger.knownCostSubtotal).doubleValue,
                              firstTimestamp: firstTimestamp, lastTimestamp: lastTimestamp,
                              promptCount: promptCount, toolCallCount: toolCallCount, fileURL: fileURL,
                              agentCount: agentCount, thinkingLevel: thinkingLevel,
                              tokenAccountingRule: tokenAccountingRule, costBasis: ledger.costBasis,
                              usageScope: usageScope, dataWarnings: Array(Set((warnings ?? dataWarnings) + ledger.warnings)).sorted(),
                              usageEntries: ledger.entries)
    }
}

public enum SessionAccounting {
    public static func canonical(_ sessions: [SessionSummary]) -> [SessionSummary] {
        let grouped = Dictionary(grouping: sessions, by: \.auditKey)
        return grouped.keys.sorted().compactMap { key in
            guard let copies = grouped[key], let primary = copies.sorted(by: preferred).first else { return nil }
            guard copies.count > 1, copies.contains(where: { $0.usageEntries != nil }) else { return primary }
            // Stable input order resolves equal-time conflicting revisions.
            let entries = copies.sorted(by: { ($0.fileURL?.path ?? "") < ($1.fileURL?.path ?? "") }).flatMap { $0.usageEntries ?? [] }
            let warnings = copies.flatMap(\.dataWarnings) + ["Duplicate session sources merged by request identity."]
            return primary.withAccounting(entries: entries, warnings: warnings)
        }
    }
    private static func preferred(_ a: SessionSummary, _ b: SessionSummary) -> Bool {
        if a.lastTimestamp != b.lastTimestamp { return (a.lastTimestamp ?? .distantPast) > (b.lastTimestamp ?? .distantPast) }
        if a.totalTokens != b.totalTokens { return a.totalTokens > b.totalTokens }
        return (a.fileURL?.path ?? "") < (b.fileURL?.path ?? "")
    }
}
