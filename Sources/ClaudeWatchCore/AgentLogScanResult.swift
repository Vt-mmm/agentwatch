import Foundation

/// One decoded agent log file for a selected reporting range.
///
/// Parsers return the session summary and full user prompts together so callers
/// do not need to stream the same JSONL file once for each projection.
public struct AgentLogScanResult: Sendable, Equatable {
    public let summary: SessionSummary?
    public let prompts: [PromptRecord]

    public init(summary: SessionSummary?, prompts: [PromptRecord]) {
        self.summary = summary
        self.prompts = prompts
    }
}
