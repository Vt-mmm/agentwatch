import XCTest
@testable import AgentWatchCore

final class TeamReportInboxTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_788_825_600)
    func fixture() throws -> (URL, TeamReportInbox, ReportTeamPolicyStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-inbox-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let policies = ReportTeamPolicyStore(root: root.appendingPathComponent("policy"))
        let policy = ReportTeamPolicy(organizationID: "org", revision: 1, owner: "owner", timeZone: "Asia/Ho_Chi_Minh",
            employees: ["one", "two"].map { ReportEmployeeAccess(employeeID: $0, googleAccountKeys: [String(repeating: "a", count: 64)], recipients: [], driveFolderIDs: []) },
            allowGmail: false, allowDrive: false, allowScheduledDelivery: false, allowNarrativeExport: false, retentionDays: 30,
            effectiveFrom: now.addingTimeInterval(-3600), expiresAt: now.addingTimeInterval(86400))
        try policies.install(ReportEncoding.encode(policy), expectedHash: policy.digest, confirmedBy: "owner")
        return (root, TeamReportInbox(root: root.appendingPathComponent("inbox"), policies: policies), policies)
    }
    func report(_ root: URL, organization: String = "org", employee: String = "one", summary: String = "Reviewed") throws -> ReportSnapshot {
        let draft = DailyReportDraft(employee: EmployeeProfile(organizationID: organization, employeeID: employee, displayName: employee),
            period: try DailyReportPeriod(day: now, timeZone: "Asia/Ho_Chi_Minh", cutoff: now), workItems: [], evidence: [], usage: [], quota: [],
            warnings: [], sourceFiles: [], sourceRoots: [], summary: summary, notes: "", narrativeProvenance: "deterministic-template-v1")
        return try ReportSnapshotStore(root: root).save(draft, reviewedBy: employee, now: now)
    }
    func testOwnerAccessOrganizationIsolationAndMissingMember() throws {
        let (root, inbox, _) = try fixture()
        let bytes = try ReportEncoding.encode(report(root.appendingPathComponent("report")))
        XCTAssertThrowsError(try inbox.importReport(bytes, employeeID: "one", now: now))
        XCTAssertTrue(try inbox.importReport(bytes, employeeID: "owner", now: now))
        XCTAssertThrowsError(try inbox.overview(employeeID: "one", day: now, now: now))
        let overview = try inbox.overview(employeeID: "owner", day: now, now: now)
        XCTAssertNotNil(overview.members[0].snapshot)
        XCTAssertNil(overview.members[1].snapshot)
        XCTAssertTrue(overview.members[0].partialDay)
        let foreign = try ReportEncoding.encode(report(root.appendingPathComponent("foreign"), organization: "foreign"))
        XCTAssertThrowsError(try inbox.importReport(foreign, employeeID: "owner", now: now))
        XCTAssertThrowsError(try inbox.overview(employeeID: "owner", day: now, now: now.addingTimeInterval(86400)))
    }
    func testIdenticalImportAndLatestRevision() throws {
        let (root, inbox, _) = try fixture()
        let directory = root.appendingPathComponent("report")
        let first = try report(directory)
        XCTAssertTrue(try inbox.importReport(ReportEncoding.encode(first), employeeID: "owner", now: now))
        XCTAssertFalse(try inbox.importReport(ReportEncoding.encode(first), employeeID: "owner", now: now))
        let second = try report(directory, summary: "Revision two")
        XCTAssertTrue(try inbox.importReport(ReportEncoding.encode(second), employeeID: "owner", now: now))
        XCTAssertEqual(try inbox.overview(employeeID: "owner", day: now, now: now).members[0].snapshot?.revision, 2)
    }
    func testConflictAndTamperedSealRejected() throws {
        let (root, inbox, _) = try fixture()
        let first = try report(root.appendingPathComponent("first"))
        try inbox.importReport(ReportEncoding.encode(first), employeeID: "owner", now: now)
        let conflict = try report(root.appendingPathComponent("second"), summary: "Different reviewed content")
        XCTAssertThrowsError(try inbox.importReport(ReportEncoding.encode(conflict), employeeID: "owner", now: now))
        var object = try JSONSerialization.jsonObject(with: ReportEncoding.encode(first)) as! [String: Any]
        object["contentHash"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try inbox.importReport(JSONSerialization.data(withJSONObject: object), employeeID: "owner", now: now))
    }
    func testFolderReportsIndividualFailuresAndRejectsSymlink() throws {
        let (root, inbox, _) = try fixture()
        let folder = root.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let valid = try ReportEncoding.encode(report(root.appendingPathComponent("source")))
        try valid.write(to: folder.appendingPathComponent("valid.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("broken.json"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.json"), withDestinationURL: folder.appendingPathComponent("valid.json"))
        let result = try inbox.importFolder(folder, employeeID: "owner", now: now)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.rejected.count, 2)
        let again = try inbox.importFolder(folder, employeeID: "owner", now: now)
        XCTAssertEqual(again.unchanged, 1)
    }
    func testConflictingStoredRevisionIsNotSilentlySelected() throws {
        let (root, inbox, _) = try fixture()
        let first = try report(root.appendingPathComponent("first"))
        try inbox.importReport(ReportEncoding.encode(first), employeeID: "owner", now: now)
        let conflict = try report(root.appendingPathComponent("second"), summary: "Conflicting")
        let partition = ReportEncoding.digest(Data("org".utf8))
        try ReportEncoding.encode(conflict).write(to: root.appendingPathComponent("inbox/" + partition + "/duplicate.json"))
        let overview = try inbox.overview(employeeID: "owner", day: now, now: now)
        XCTAssertNil(overview.members[0].snapshot)
        XCTAssertFalse(overview.warnings.isEmpty)
    }
    func testDeliveryRequiresExactOrganizationRevisionAndContent() throws {
        let (root, _, _) = try fixture()
        let snapshot = try report(root.appendingPathComponent("report"))
        let destination = try ReportMailDestination(accountKey: String(repeating: "a", count: 64), from: "one@example.test", to: ["owner@example.test"], subject: "Report")
        var job = GmailOutboxJob(id: "job", reportID: snapshot.reportID, revision: snapshot.revision, contentHash: snapshot.contentHash,
            employeeID: "one", destination: destination, messageID: "message", payloadHash: "payload", pdfHash: "pdf", previewText: "", createdAt: now,
            state: .failed, attempts: [], reconciliations: [])
        job.organizationID = "org"
        let states = TeamDeliveryObservation.matching(snapshot, gmail: [job], drive: [])
        XCTAssertEqual(states.count, 1)
        XCTAssertTrue(states[0].needsAttention)
        job.organizationID = "foreign"
        XCTAssertTrue(TeamDeliveryObservation.matching(snapshot, gmail: [job], drive: []).isEmpty)
        job.organizationID = "org"
        let next = try report(root.appendingPathComponent("report"), summary: "Revision 2")
        XCTAssertTrue(TeamDeliveryObservation.matching(next, gmail: [job], drive: []).isEmpty)
    }

    func testMissingPolicyFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("missing-policy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamReportInbox(root: root.appendingPathComponent("inbox"), policies: ReportTeamPolicyStore(root: root.appendingPathComponent("policy")))
        XCTAssertThrowsError(try inbox.overview(employeeID: "owner", day: now, now: now))
    }
}
