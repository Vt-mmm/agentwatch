import SwiftUI
import Darwin
@testable import AgentWatchCore

/// Standalone harness: actual product views, synthetic roots, no app schedulers.
@main struct InsightsQA: App {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentwatch-insights-review-v1")
    private let failure: String?
    @AppStorage("dailyReport.employeeID") private var identity = "qa-owner"
    init() {
        do {
            try Self.seed(root)
            if CommandLine.arguments.contains("--validate-fixture") { print("UI_FIXTURE_OK " + root.path); exit(0) }
            UserDefaults.standard.set(root.path, forKey: "insights.selectedProject")
            UserDefaults.standard.set("qa-owner", forKey: "dailyReport.employeeID")
            failure = nil
        } catch {
            if CommandLine.arguments.contains("--validate-fixture") { print("UI_FIXTURE_FAILED " + error.localizedDescription); exit(1) }
            failure = error.localizedDescription
        }
    }
    var body: some Scene {
        WindowGroup("AgentWatch — dữ liệu kiểm thử giả lập") {
            if let failure { Text(failure).padding() }
            else {
                VStack {
                    Picker("Hồ sơ giả lập để kiểm tra quyền", selection: $identity) {
                        Text("Chủ chính sách QA").tag("qa-owner")
                        Text("Thành viên QA (bị từ chối xem nhóm)").tag("qa-member")
                    }.padding()
                TaskInsightsView(roots: AgentLogRoots(home: root.path, environment: [:]),
                    queryStore: CoachingQueryStore(url: root.appendingPathComponent("query.sqlite")),
                    bindingStore: TaskBindingStore(root: root.appendingPathComponent("bindings")),
                    historyStore: InsightHistoryStore(url: root.appendingPathComponent("history.sqlite")),
                    acceptanceStore: TaskAcceptanceStore(root: root.appendingPathComponent("acceptance")),
                    teamInbox: TeamReportInbox(root: root.appendingPathComponent("inbox"),
                        policies: ReportTeamPolicyStore(root: root.appendingPathComponent("policy"))))
                    .frame(minWidth: 1050, minHeight: 780)
                }
            }
        }
    }
    private static func seed(_ root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let start = Calendar.current.startOfDay(for: Date()), end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let formatter = ISO8601DateFormatter()
        func timestamp(_ seconds: Double) -> String { formatter.string(from: start.addingTimeInterval(seconds)) }
        func write(_ relative: String, rows: [[String: Any]]) throws {
            let file = root.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for row in rows { data.append(try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)); data.append(10) }
            try data.write(to: file)
        }
        var rows: [[String: Any]] = [
            ["type": "user", "timestamp": timestamp(10), "message": ["content": "Tối ưu truy vấn giả lập"]]
        ]
        for index in 0..<3 {
            rows += [
                ["type": "assistant", "timestamp": timestamp(Double(20 + index * 4)), "message": ["id": "request-\(index)", "model": "claude-sonnet-4-6", "usage": ["input_tokens": 100, "output_tokens": 20], "content": [["type": "tool_use", "id": "call-\(index)", "name": "Bash", "input": ["command": "swift test"]]]]],
                ["type": "user", "timestamp": timestamp(Double(22 + index * 4)), "message": ["content": [["type": "tool_result", "tool_use_id": "call-\(index)", "content": "Synthetic test failure", "is_error": true]]]]
            ]
        }
        for index in 0..<120 {
            rows.append(["type": "user", "timestamp": timestamp(Double(100 + index)), "message": ["content": "Paging fixture \(index)"]])
        }
        try write(".claude/projects/synthetic/qa-session.jsonl", rows: rows)
        let store = TaskBindingStore(root: root.appendingPathComponent("bindings"))
        if !(try store.load()).contains(where: { $0.sessionID == "qa-session" && $0.contains(start) }) {
            try store.save(TaskSessionBinding(projectPath: root.path, taskID: "QA query", taskRunID: "qa-run", source: .cli,
                sessionID: "qa-session", start: start, end: end))
        }
        try Data("<testsuite tests=\"2\" failures=\"1\"><testcase name=\"pass\"/><testcase name=\"fail\"><failure/></testcase></testsuite>".utf8)
            .write(to: root.appendingPathComponent("synthetic-tests.xml"))
        try Data("Synthetic artifact\n".utf8).write(to: root.appendingPathComponent("artifact.txt"))
        var telemetry: [[String: Any]] = []
        for index in 0..<3 {
            telemetry.append(["schemaVersion": 1, "telemetrySource": "piagent", "recordedAt": timestamp(Double(20 + index * 4)),
                "sessionId": "pi-qa", "taskId": "QA context", "taskRunId": "qa-context-run", "model": "synthetic", "thinkingLevel": "high",
                "event": "tool_result", "toolName": "bash", "toolCallId": "pi-call-\(index)", "inputHash": "same", "outputHash": "same",
                "outputChars": 100, "repeated": true, "isError": true])
        }
        try write(".pi/piagent-state/context-engine/events.jsonl", rows: telemetry)
        let policies = ReportTeamPolicyStore(root: root.appendingPathComponent("policy"))
        if try policies.load() == nil {
            let policy = ReportTeamPolicy(organizationID: "qa-org", revision: 1, owner: "qa-owner", timeZone: "Asia/Ho_Chi_Minh",
                employees: ["qa-member", "qa-missing"].map { ReportEmployeeAccess(employeeID: $0, googleAccountKeys: [String(repeating: "a", count: 64)], recipients: [], driveFolderIDs: []) },
                allowGmail: false, allowDrive: false, allowScheduledDelivery: false, allowNarrativeExport: false, retentionDays: 30,
                effectiveFrom: start.addingTimeInterval(-86400), expiresAt: end.addingTimeInterval(30 * 86400))
            try policies.install(ReportEncoding.encode(policy), expectedHash: policy.digest, confirmedBy: "qa-owner")
        }
        let incoming = root.appendingPathComponent("incoming")
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        let period = try DailyReportPeriod(day: Date(), timeZone: "Asia/Ho_Chi_Minh", cutoff: Date())
        let draft = DailyReportDraft(employee: EmployeeProfile(organizationID: "qa-org", employeeID: "qa-member", displayName: "Synthetic member"),
            period: period, workItems: [ReportWorkItem(id: "qa-work", project: "Synthetic", title: "Kiểm tra công việc đang vướng", status: .blocked,
                blockers: "Dữ liệu giả lập cần xác nhận", nextActions: "Đối chiếu báo cáo")], evidence: [], usage: [], quota: [], warnings: [], sourceFiles: [], sourceRoots: [],
            summary: "Báo cáo kiểm thử, không phải dữ liệu nhân sự", notes: "", narrativeProvenance: "deterministic-template-v1")
        let snapshot = try ReportSnapshotStore(root: root.appendingPathComponent("snapshots")).save(draft, reviewedBy: "qa-member")
        try ReportEncoding.encode(snapshot).write(to: incoming.appendingPathComponent(snapshot.id + ".json"))
        try Data("{}".utf8).write(to: incoming.appendingPathComponent("invalid-report.json"))
    }
}
