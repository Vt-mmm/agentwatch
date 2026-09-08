import XCTest
@testable import AgentWatchCore

final class ContextEfficiencyTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!
    private var range: Range<Date> { start..<start.addingTimeInterval(86400) }
    private func fixture(_ rows: [[String: Any]], tail: String = "") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-insights-\(UUID())")
        let file = root.appendingPathComponent(".pi/piagent-state/context-engine/events.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for (index, row) in rows.enumerated() {
            var record: [String: Any] = ["schemaVersion": 1, "source": "piagent", "sessionId": "s1", "taskId": "task1",
                "taskRunId": "r1", "model": "gpt-test", "thinkingLevel": "high", "activityId": "e\(index)",
                "recordedAt": "2026-09-08T10:00:\(String(format: "%02d", index))Z"]
            record.merge(row) { _, new in new }
            data.append(try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)); data.append(10)
        }
        data.append(Data(tail.utf8)); try data.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func read(_ hash: String, run: String = "r1", target: String = "src/a.swift") -> [String: Any] {
        ["event": "tool_call", "toolName": "read", "inputHash": hash, "targetPath": target, "taskRunId": run]
    }
    private func result(_ id: String, error: Bool = true, output: String = "same-error") -> [String: Any] {
        ["event": "tool_result", "toolName": "bash", "toolCallId": id, "inputHash": "same-command",
         "outputHash": output, "outputChars": 100, "isError": error, "repeated": true]
    }
    func testDuplicateReadsPartitionByRunAndInvalidateAfterMutation() throws {
        let project = try fixture([read("a"), read("a"), read("a", run: "r2"),
            ["event": "tool_result", "toolName": "edit", "isError": false, "targetPath": "src/a.swift"], read("a")])
        let analysis = ContextEfficiencyAnalyzer.analyze(PiContextTelemetry.read(project: project), range: range)
        let first = try XCTUnwrap(analysis.groups.first { $0.partition.taskRunID == "r1" })
        XCTAssertEqual(first.duplicateReads.numerator, 1)
        XCTAssertEqual(first.duplicateReads.denominator, 3)
        XCTAssertEqual(analysis.groups.first { $0.partition.taskRunID == "r2" }?.duplicateReads.numerator, 0)
        XCTAssertNil(first.wasteScore)
    }
    func testDistinctReadRangesAndUnrelatedMutationRemainDistinct() throws {
        let project = try fixture([read("range-1"), read("range-2"),
            ["event": "tool_result", "toolName": "edit", "isError": false, "targetPath": "src/b.swift"], read("range-1")])
        let group = try XCTUnwrap(ContextEfficiencyAnalyzer.analyze(PiContextTelemetry.read(project: project), range: range).groups.first)
        XCTAssertEqual(group.duplicateReads.numerator, 1)
    }
    func testFullScoreRequiresAllLanesAndUtilizationNeedsMutation() throws {
        let project = try fixture([
            ["event": "agent_prompt", "activeTools": 12, "systemPromptTokens": 900, "toolSchemaTokens": 100],
            ["event": "context_pack", "confidence": "high"],
            ["event": "context_pack_injected", "selectedPaths": ["src/a.swift", "src/b.swift"]], read("a"),
            ["event": "tool_result", "toolName": "edit", "targetPath": "src/a.swift", "isError": false, "outputChars": 100, "repeated": false]])
        let group = try XCTUnwrap(ContextEfficiencyAnalyzer.analyze(PiContextTelemetry.read(project: project), range: range).groups.first)
        XCTAssertEqual(group.wasteScore, 6)
        XCTAssertEqual(group.utilization.value, 0.5)
    }
    func testTailMalformedAndUnknownSchemaAreNotZeroWaste() throws {
        let project = try fixture([read("a"), ["event": "tool_call", "schemaVersion": 999],
                                   ["event": "tool_call", "recordedAt": "bad"]], tail: "{unfinished")
        let snapshot = PiContextTelemetry.read(project: project)
        XCTAssertEqual(snapshot.coverage, .partial)
        XCTAssertEqual(snapshot.unsupportedRecords, 1)
        XCTAssertEqual(snapshot.malformedRecords, 1)
        XCTAssertTrue(snapshot.incompleteTail)
        let group = try XCTUnwrap(ContextEfficiencyAnalyzer.analyze(snapshot, range: range).groups.first)
        XCTAssertNil(group.wasteScore)
        XCTAssertEqual(group.duplicateReads.coverage, .partial)
    }
    func testEqualTimestampKeepsSourceOrderForReadInvalidation() throws {
        var rows = [read("a"), ["event": "tool_result", "toolName": "edit", "isError": false, "targetPath": "src/a.swift"], read("a")]
        for index in rows.indices { rows[index]["recordedAt"] = "2026-09-08T10:00:00Z" }
        let project = try fixture(rows)
        let result = ContextEfficiencyAnalyzer.analyze(PiContextTelemetry.read(project: project), range: range)
        XCTAssertEqual(result.groups.first?.duplicateReads.numerator, 0)
    }

    func testCorrectedResultRetractsOldLoopAndDoesNotCountTwice() throws {
        let project = try fixture([result("1"), result("2"), result("3"), result("2", error: false, output: "corrected")])
        let analysis = ContextEfficiencyAnalyzer.analyze(PiContextTelemetry.read(project: project), range: range)
        XCTAssertTrue(analysis.loops.isEmpty)
        XCTAssertEqual(analysis.groups.first?.duplicateOutput.observed, 3)
    }
    func testFutureCorrectionDoesNotRewriteEarlierAsOfQuery() throws {
        let project = try fixture([result("1"), result("2"), result("3"), result("2", error: false, output: "later correction")])
        let cutoff = ISO8601DateFormatter().date(from: "2026-09-08T10:00:03Z")!
        let analysis = ContextEfficiencyAnalyzer.analyze(PiContextTelemetry.read(project: project), range: start..<cutoff)
        XCTAssertEqual(analysis.loops.count, 1)
        XCTAssertEqual(analysis.loops.first?.count, 3)
    }

    func testEqualTimeConflictingResultIsNotUsedAsRetryEvidence() throws {
        var corrected = result("2", error: false, output: "corrected")
        corrected["recordedAt"] = "2026-09-08T10:00:01Z"
        let project = try fixture([result("1"), result("2"), result("3"), result("4"), corrected])
        let analysis = ContextEfficiencyAnalyzer.analyze(PiContextTelemetry.read(project: project), range: range)
        XCTAssertTrue(analysis.loops.isEmpty)
        XCTAssertEqual(analysis.coverage, .partial)
        XCTAssertEqual(analysis.groups.first?.duplicateOutput.observed, 3)
    }

    func testLoopsRequireThreeDistinctCallsAndResetOnChangedOutput() throws {
        let project = try fixture([result("1"), result("1"), result("2"), result("3"), result("4", output: "new"), result("5")])
        let analysis = ContextEfficiencyAnalyzer.analyze(PiContextTelemetry.read(project: project), range: range)
        XCTAssertEqual(analysis.loops.count, 1)
        XCTAssertEqual(analysis.loops.first?.count, 3)
        XCTAssertTrue(analysis.loops.first?.failed == true)
        XCTAssertTrue(analysis.loops.first?.evidence.allSatisfy { $0.localRef.contains("#line=") } == true)
    }
    func testUnknownTaskBindingIsNotGuessed() throws {
        let project = try fixture([
            ["event": "tool_call", "toolName": "read", "inputHash": "a", "taskRunId": NSNull(), "turnId": "t1"],
            ["event": "turn_task_bound", "turnId": "t1", "taskRunId": "r1"],
            ["event": "turn_task_bound", "turnId": "t1", "taskRunId": "r2"]])
        let analysis = ContextEfficiencyAnalyzer.analyze(PiContextTelemetry.read(project: project), range: range)
        XCTAssertEqual(analysis.unassignedEvents, 1)
        XCTAssertTrue(analysis.groups.allSatisfy { $0.duplicateReads.value == nil })
    }
    func testRawPayloadExcludedAndBooleanNumbersRejected() throws {
        let project = try fixture([[
            "event": "tool_result", "toolName": "bash", "command": "private-command", "output": "private-output",
            "inputHash": "a", "outputHash": "b", "outputChars": true, "isError": 1, "repeated": false]])
        let snapshot = PiContextTelemetry.read(project: project)
        let event = try XCTUnwrap(snapshot.events.first)
        XCTAssertNil(event.outputChars); XCTAssertNil(event.isError)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-command")); XCTAssertFalse(encoded.contains("private-output"))
    }
    func testSymlinkTelemetryRejectedAndMissingDistinguished() throws {
        let project = try fixture([read("a")])
        let folder = project.appendingPathComponent(".pi/piagent-state/context-engine")
        let file = folder.appendingPathComponent("events.jsonl")
        let moved = project.appendingPathComponent("outside.jsonl")
        try FileManager.default.moveItem(at: file, to: moved)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        let denied = PiContextTelemetry.read(project: project)
        XCTAssertTrue(denied.events.isEmpty); XCTAssertTrue(denied.warnings.contains { $0.contains("symlink") })
        let missing = PiContextTelemetry.read(project: project.appendingPathComponent("missing"))
        XCTAssertEqual(missing.coverage, .unavailable)
    }
}
