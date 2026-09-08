import XCTest
@testable import AgentWatchCore

final class InsightDataHealthTests: XCTestCase {
    func testExistingLogsWithoutParsedActivityRemainUncertain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-uncertain-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scan = CoachingScanResult(prompts: [], sessions: [], candidateFileCount: 2, sourceFiles: [], sourceRoots: [SourceRootManifest(path: root.path)])
        let telemetry = PiContextTelemetry.read(project: root)
        let lifecycle = TaskLifecycleBuilder.build(scan: scan, journals: [], bindings: [], range: Date.distantPast..<Date.distantFuture)
        let health = InsightDataHealth.build(scan: scan, telemetry: telemetry, lifecycle: lifecycle)
        XCTAssertTrue(health.warnings.contains { $0.contains("2 file log") })
        XCTAssertTrue(health.warnings.contains { $0.contains("chưa kiểm kê") })
    }

    func testThoroughManifestMakesCorruptAndChangingFilesVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-manifest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = SourceFileManifest(path: root.appendingPathComponent("session.jsonl").path, byteCount: 10, sha256: nil,
            modifiedAt: nil, malformedRecordCount: 2, readable: false, changedDuringRead: true)
        let scan = CoachingScanResult(prompts: [], sessions: [], candidateFileCount: 1, sourceFiles: [manifest], sourceRoots: [SourceRootManifest(path: root.path)])
        let lifecycle = TaskLifecycleBuilder.build(scan: scan, journals: [], bindings: [], range: Date.distantPast..<Date.distantFuture)
        let health = InsightDataHealth.build(scan: scan, telemetry: PiContextTelemetry.read(project: root), lifecycle: lifecycle)
        XCTAssertEqual(health.sources.first?.state, .partial)
        XCTAssertTrue(health.sources.first?.warnings.contains { $0.contains("2 dòng JSON") } == true)
        XCTAssertTrue(health.sources.first?.warnings.contains { $0.contains("không đọc") } == true)
        XCTAssertTrue(health.sources.first?.warnings.contains { $0.contains("thay đổi") } == true)
    }

    func testMissingSourceIsDifferentFromReadableEmptySource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scan = CoachingScanResult(prompts: [], sessions: [], candidateFileCount: 0, sourceFiles: [],
            sourceRoots: [SourceRootManifest(path: root.path), SourceRootManifest(path: root.appendingPathComponent("missing").path)])
        let telemetry = PiContextTelemetry.read(project: root)
        let lifecycle = TaskLifecycleBuilder.build(scan: scan, journals: [], bindings: [], range: Date.distantPast..<Date.distantFuture)
        let now = Date()
        let health = InsightDataHealth.build(scan: scan, telemetry: telemetry, lifecycle: lifecycle, checkedAt: now)
        XCTAssertEqual(health.sources.map(\.state), [.empty, .missing])
        XCTAssertEqual(health.checkedAt, now)
        XCTAssertEqual(health.telemetryCoverage, .unavailable)
        XCTAssertNil(health.sources.first?.lastObservedEvent)
    }
}
