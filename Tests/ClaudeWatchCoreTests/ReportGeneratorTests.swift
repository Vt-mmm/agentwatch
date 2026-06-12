import XCTest
@testable import ClaudeWatchCore

final class ReportGeneratorTests: XCTestCase {

    private func makeRecord(text: String, project: String = "ws/api",
                            offsetSeconds: TimeInterval = 0) -> PromptRecord {
        let score = PromptScorer.score(text)
        return PromptRecord(
            id: UUID().uuidString,
            timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000 + offsetSeconds),
            projectSlug: "-Users-tam-Documents-\(project.replacingOccurrences(of: "/", with: "-"))",
            projectDisplay: "/Users/tam/Documents/\(project)",
            sessionUuid: "abc",
            text: text, score: score
        )
    }

    func testStatsAggregateTaskAndFollowUp() {
        let records: [PromptRecord] = [
            makeRecord(text: "test giúp em đi", offsetSeconds: 0),
            makeRecord(text: """
                ## Mục tiêu
                Sửa bug
                ## Role
                Admin
                ## Input
                id
                ## Output
                200/404
                ## Flow
                check
                ## Edge Case
                missing
                ## constrained_by
                schema X
                ## Definition of Done
                pass tests và không phá tính năng cũ. Cần có audit log đầy đủ.
                """, offsetSeconds: 60),
            makeRecord(text: String(repeating: "x", count: 600), offsetSeconds: 120),
        ]
        let s = ReportGenerator.stats(for: records)
        XCTAssertEqual(s.totalPrompts, 3)
        XCTAssertEqual(s.taskPrompts, 2)
        XCTAssertEqual(s.followUpPrompts, 1)
        XCTAssertGreaterThan(s.avgStars, 0)
    }

    func testMarkdownContainsAllSectionsAndPrompts() {
        let records = [makeRecord(text: "## Mục tiêu\nfix bug\n## Role\nadmin")]
        let md = ReportGenerator.markdown(scope: .day(Date()), records: records)
        XCTAssertTrue(md.contains("DAILY/WEEKLY REPORT"))
        XCTAssertTrue(md.contains("Phân bổ chất lượng"))
        XCTAssertTrue(md.contains("Breakdown theo project"))
        XCTAssertTrue(md.contains("Mục tiêu"))    // section name in detail
    }

    func testHTMLIsWellFormedWithSummaryCards() {
        let records = [makeRecord(text: "Hi em")]
        let html = ReportGenerator.html(scope: .day(Date()), records: records)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("Tổng prompts"))
        XCTAssertTrue(html.contains("</html>"))
    }

    func testEmptyRangeProducesValidReportNotCrash() {
        let s = ReportGenerator.stats(for: [])
        XCTAssertEqual(s.totalPrompts, 0)
        XCTAssertEqual(s.avgStars, 0)
        let md = ReportGenerator.markdown(scope: .day(Date()), records: [])
        XCTAssertTrue(md.contains("Không có prompt"))
    }
}
