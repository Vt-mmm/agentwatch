import XCTest
@testable import AgentWatchCore

final class JUnitEvidenceTests: XCTestCase {
    func parse(_ text: String) throws -> JUnitSummary { try JUnitEvidence.parse(Data(text.utf8)) }
    func testNestedSuitesDoNotDoubleCountAndOutcomesStaySeparate() throws {
        let xml = """
        <testsuites tests="4" failures="1" errors="1" skipped="1"><testsuite tests="4" failures="1" errors="1" skipped="1">
        <testcase name="pass"/><testcase name="fail"><failure>failed</failure><failure>second assertion</failure></testcase>
        <testcase name="error"><error>crash</error></testcase><testcase name="skip"><skipped/></testcase>
        </testsuite></testsuites>
        """
        XCTAssertEqual(try parse(xml), JUnitSummary(tests: 4, failures: 1, errors: 1, skipped: 1))
    }
    func testMalformedMismatchedSummaryEmptyAndContradictoryOutcomeRejected() {
        for xml in ["<testsuite>", "<testsuite tests=\"2\"><testcase/></testsuite>", "<testsuite tests=\"0\"/>",
                    "<testsuite><testcase><failure/><skipped/></testcase></testsuite>", "<other><testcase/></other>",
                    "<testsuite><failure/></testsuite>", "<testsuite tests=\"-1\"><testcase/></testsuite>"] {
            XCTAssertThrowsError(try parse(xml), xml)
        }
    }
    func testExternalEntitiesAndExcessiveDepthRejected() {
        let xml = "<!DOCTYPE testsuite [<!ENTITY secret SYSTEM 'file:///must-not-read'>]><testsuite><testcase>&secret;</testcase></testsuite>"
        XCTAssertThrowsError(try parse(xml))
        XCTAssertThrowsError(try parse("<testsuite>" + String(repeating: "<nested>", count: 65) + "<testcase/>" + String(repeating: "</nested>", count: 65) + "</testsuite>"))
    }
    func testReportVerificationPreservesDigestAndDoesNotAcceptTask() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("junit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<testsuite tests=\"1\"><testcase/></testsuite>".utf8).write(to: root.appendingPathComponent("tests.xml"))
        let evidence = try LocalArtifactVerifier.testReport(project: root, relativePath: "tests.xml")
        XCTAssertEqual(evidence.kind, .testReportObserved)
        XCTAssertTrue(evidence.summary.contains("1 testcase"))
        XCTAssertTrue(evidence.summary.contains("SHA-256"))
        XCTAssertNotEqual(evidence.kind, .humanAcceptance)
        XCTAssertThrowsError(try LocalArtifactVerifier.testReport(project: root, relativePath: "../tests.xml"))
    }
}
