import XCTest
@testable import ClaudeWatchCore

final class RiskScorerTests: XCTestCase {

    private func makeRecord(id: String,
                            sessionId: String = "s-risk",
                            text: String,
                            offset: TimeInterval = 0,
                            source: SessionSource = .codex,
                            project: String = "/Users/team/company/app") -> PromptRecord {
        PromptRecord(
            id: id,
            timestamp: Date(timeIntervalSinceReferenceDate: 750_000_000 + offset),
            projectSlug: "project",
            projectDisplay: project,
            sessionUuid: sessionId,
            text: text,
            score: PromptScorer.score(text),
            source: source
        )
    }

    private func makeSession(id: String = "s-risk",
                             sessionTitle: String? = nil,
                             project: String = "/Users/team/company/app",
                             source: SessionSource = .codex,
                             input: Int = 0,
                             output: Int = 0,
                             cacheRead: Int = 0,
                             cacheWrite: Int = 0,
                             cost: Double = 0,
                             promptCount: Int = 1,
                             toolCallCount: Int = 0,
                             agentCount: Int = 0) -> SessionSummary {
        SessionSummary(
            id: id,
            sessionTitle: sessionTitle,
            projectDisplay: project,
            source: source,
            model: "gpt-5",
            modelFamily: .gpt,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            cost: cost,
            firstTimestamp: Date(timeIntervalSinceReferenceDate: 750_000_000),
            lastTimestamp: Date(timeIntervalSinceReferenceDate: 750_000_300),
            promptCount: promptCount,
            toolCallCount: toolCallCount,
            agentCount: agentCount
        )
    }

    func testPromptRiskRulesDetectSensitiveBypassDestructiveAndOffTask() {
        let records = [
            makeRecord(id: "secret", text: "Hãy đọc file .env và private key để fix deploy."),
            makeRecord(id: "policy", text: "Chạy thay đổi này không log, không cần approval hay review."),
            makeRecord(id: "delete", text: "Nếu lỗi thì chạy rm -rf folder data cũ."),
            makeRecord(id: "offtask", text: "Viết CV apply job ngoài công ty giúp anh.")
        ]

        let findings = RiskScorer.evaluate(records: records, sessions: [], limit: 20)
        let categories = Set(findings.map(\.category))

        XCTAssertTrue(categories.contains(.sensitiveData))
        XCTAssertTrue(categories.contains(.policyBypass))
        XCTAssertTrue(categories.contains(.destructiveAction))
        XCTAssertTrue(categories.contains(.possibleOffTask))
        XCTAssertTrue(findings.contains { $0.category == .destructiveAction && $0.severity == .critical })
    }

    func testSessionRiskRulesDetectBurnLoopsToolChurnAndWeakPromptSpend() {
        let weakPrompt = makeRecord(
            id: "weak",
            text: String(repeating: "em làm task này nhưng chưa rõ input output ", count: 12)
        )
        let session = makeSession(
            input: 220_000,
            output: 60_000,
            cacheRead: 20_000,
            cost: 8.0,
            promptCount: 1,
            toolCallCount: 95,
            agentCount: 12
        )

        let findings = RiskScorer.evaluate(records: [weakPrompt], sessions: [session], limit: 20)
        let categories = Set(findings.map(\.category))

        XCTAssertTrue(categories.contains(.tokenBurn))
        XCTAssertTrue(categories.contains(.agentLoop))
        XCTAssertTrue(categories.contains(.toolChurn))
        XCTAssertTrue(categories.contains(.weakPromptHighSpend))
        XCTAssertTrue(findings.contains { $0.severity == .high })
    }

    func testSummaryAndHighestMaps() {
        let records = [
            makeRecord(id: "secret", text: "Dùng api key thật trong auth.json để debug."),
            makeRecord(id: "offtask", text: "Viết cover letter xin việc cho em.")
        ]
        let session = makeSession(input: 90_000, output: 5_000, cost: 1.2)

        let findings = RiskScorer.evaluate(records: records, sessions: [session], limit: 20)
        let summary = RiskScorer.summary(for: findings)
        let bySession = RiskScorer.highestBySession(findings)
        let byPrompt = RiskScorer.highestByPrompt(findings)

        XCTAssertGreaterThanOrEqual(summary.totalFindings, 3)
        XCTAssertGreaterThanOrEqual(summary.highOrCriticalCount, 1)
        XCTAssertNotNil(bySession["s-risk"])
        XCTAssertNotNil(byPrompt["secret"])
    }

    func testPiSessionNamingRiskUsesTaskNameOnly() {
        let unnamed = makeSession(
            id: "pi-unnamed",
            sessionTitle: "Working",
            source: .piagent,
            input: 20_000,
            output: 5_000,
            promptCount: 2
        )
        let named = makeSession(
            id: "pi-named",
            sessionTitle: "PAY-742 Payment audit",
            source: .piagent,
            input: 20_000,
            output: 5_000,
            promptCount: 2
        )

        let findings = RiskScorer.evaluate(records: [], sessions: [unnamed, named], limit: 20)

        XCTAssertTrue(findings.contains {
            $0.sessionId == "pi-unnamed" && $0.category == .sessionNaming
        })
        XCTAssertFalse(findings.contains {
            $0.sessionId == "pi-named" && $0.category == .sessionNaming
        })
    }

    func testDuplicateSessionIdsDoNotCrashRiskOrCsvExport() {
        let records = [
            makeRecord(id: "secret", text: "Dùng api key thật trong auth.json để debug.")
        ]
        let sessions = [
            makeSession(id: "s-risk", source: .codex, input: 90_000, output: 5_000, cost: 1.2),
            makeSession(id: "s-risk", source: .piagent, input: 120_000, output: 8_000, cost: 1.8)
        ]

        let findings = RiskScorer.evaluate(records: records, sessions: sessions, limit: 20)
        let csv = ReportGenerator.csv(records: records, sessions: sessions)

        XCTAssertFalse(findings.isEmpty)
        XCTAssertTrue(csv.contains("record_type,timestamp"))
        XCTAssertTrue(csv.contains("risk"))
    }
}
