import XCTest
@testable import AgentWatchCore

final class ReportTeamTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private var credential: GoogleCredential {
        GoogleCredential(clientID: "fake.apps.googleusercontent.com", subject: "test", email: "employee@example.test", accessToken: "fake",
                         refreshToken: nil, expiresAt: Date().addingTimeInterval(3600), scopes: [GoogleScopes.gmailSend])
    }
    private func policy(now: Date = Date()) -> ReportTeamPolicy {
        ReportTeamPolicy(organizationID: "org", revision: 1, owner: "admin", timeZone: "Asia/Ho_Chi_Minh",
            employees: [ReportEmployeeAccess(employeeID: "employee", googleAccountKeys: [credential.accountKey], recipients: ["boss@example.test"], driveFolderIDs: ["folder-1"])],
            allowGmail: true, allowDrive: true, allowScheduledDelivery: true, allowNarrativeExport: false, retentionDays: 30,
            effectiveFrom: now.addingTimeInterval(-3600), expiresAt: now.addingTimeInterval(30 * 86_400))
    }
    private func install(_ policy: ReportTeamPolicy, in store: ReportTeamPolicyStore) throws {
        try store.install(ReportEncoding.encode(policy), expectedHash: policy.digest, confirmedBy: "admin")
    }
    private func snapshot(root: URL, now: Date = Date()) throws -> ReportSnapshot {
        let draft = DailyReportDraft(employee: EmployeeProfile(organizationID: "org", employeeID: "employee", displayName: "Synthetic"),
            period: try DailyReportPeriod(day: now, timeZone: "Asia/Ho_Chi_Minh", cutoff: now), workItems: [], evidence: [], usage: [], quota: [],
            warnings: [], sourceFiles: [], sourceRoots: [], summary: "Synthetic report", notes: "", narrativeProvenance: "deterministic-template-v1")
        return try ReportSnapshotStore(root: root).save(draft, reviewedBy: "employee", now: now)
    }
    private func gmail(root: URL, report: ReportSnapshot, recipient: String = "boss@example.test", now: Date = Date()) throws -> GmailOutboxJob {
        let store = GmailOutboxStore(root: root.appendingPathComponent("gmail-outbox"))
        let dest = try ReportMailDestination(accountKey: credential.accountKey, from: credential.email, to: [recipient], subject: "Report")
        let job = try store.prepare(snapshot: report, destination: dest, now: now)
        return try store.approve(job.id, employeeID: "employee", expectedPayloadHash: job.payloadHash, now: now)
    }
    func testPolicyIsClosedAndRequiresReviewedOwnerAndIncreasingRevision() throws {
        let store = ReportTeamPolicyStore(root: try root()), p = policy(), bytes = try ReportEncoding.encode(p)
        XCTAssertThrowsError(try store.install(bytes, expectedHash: p.digest, confirmedBy: "employee"))
        XCTAssertThrowsError(try store.install(bytes, expectedHash: "wrong", confirmedBy: "admin"))
        var object = try GoogleWire.json(bytes); object["silentlySendEverything"] = true
        XCTAssertThrowsError(try store.decode(JSONSerialization.data(withJSONObject: object)))
        try install(p, in: store)
        XCTAssertThrowsError(try install(p, in: store))
        var newer = p; newer.revision = 2; newer.allowGmail = false
        try install(newer, in: store); XCTAssertEqual(try store.load()?.revision, 2)
    }
    func testBrokenManagedPolicyNeverFallsBackToLocalAndCannotBeOverwritten() throws {
        let dir = try root(), managed = dir.appendingPathComponent("managed.json")
        let store = ReportTeamPolicyStore(root: dir.appendingPathComponent("local"), managedURL: managed)
        try install(policy(), in: store)
        try Data("{}".utf8).write(to: managed)
        XCTAssertThrowsError(try store.load())
        var newer = policy(); newer.revision = 2
        XCTAssertThrowsError(try install(newer, in: store))
    }
    func testPolicyBlocksBccWrongAccountOrganizationAndExpiredPolicy() throws {
        let store = ReportTeamPolicyStore(root: try root()), p = policy(); try install(p, in: store)
        let dest = try ReportMailDestination(accountKey: credential.accountKey, from: credential.email, to: ["boss@example.test"], bcc: ["outside@example.test"], subject: "Report")
        XCTAssertThrowsError(try store.checkGmail(organizationID: "org", employeeID: "employee", destination: dest))
        XCTAssertThrowsError(try p.access(organizationID: "other", employeeID: "employee", accountKey: credential.accountKey))
        XCTAssertThrowsError(try p.access(organizationID: "org", employeeID: "employee", accountKey: "other"))
        XCTAssertThrowsError(try p.access(organizationID: "org", employeeID: "employee", accountKey: credential.accountKey, now: p.expiresAt))
    }
    func testChangedPolicyBlocksApprovedGmailBeforeAnyNetworkRequest() async throws {
        let dir = try root(), store = GmailOutboxStore(root: dir.appendingPathComponent("gmail-outbox")), policies = ReportTeamPolicyStore(root: dir.appendingPathComponent("team"))
        let job = try gmail(root: dir, report: snapshot(root: dir))
        var p = policy(); p.allowGmail = false; try install(p, in: policies)
        let transport = ScriptedGoogleTransport([])
        do { _ = try await GmailDeliveryService(api: GmailAPI(transport: transport), store: store, policyStore: policies).deliver(jobID: job.id, credential: credential); XCTFail() } catch { }
        let requests = await transport.requests(); XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(try store.read(job.id)?.state, .prepared)
    }
    func testScheduleRequiresPolicyAndExactReviewedEmployeeAndJob() throws {
        let dir = try root(), schedules = ReportDeliveryScheduleStore(root: dir.appendingPathComponent("schedules")), policies = ReportTeamPolicyStore(root: dir.appendingPathComponent("team"))
        let job = try gmail(root: dir, report: snapshot(root: dir)), at = Date().addingTimeInterval(300)
        XCTAssertThrowsError(try schedules.scheduleGmail(job, at: at, expiresAt: at.addingTimeInterval(3600), timeZone: "Asia/Ho_Chi_Minh", approvedBy: "employee", policy: policies))
        try install(policy(), in: policies)
        XCTAssertThrowsError(try schedules.scheduleGmail(job, at: at, expiresAt: at.addingTimeInterval(3600), timeZone: "Asia/Ho_Chi_Minh", approvedBy: "other", policy: policies))
        let saved = try schedules.scheduleGmail(job, at: at, expiresAt: at.addingTimeInterval(3600), timeZone: "Asia/Ho_Chi_Minh", approvedBy: "employee", policy: policies)
        XCTAssertEqual(saved.payloadHash, job.payloadHash); XCTAssertEqual(saved.policyHash, try policies.load()?.digest)
        XCTAssertThrowsError(try schedules.scheduleGmail(job, at: at, expiresAt: at.addingTimeInterval(3600), timeZone: "Asia/Ho_Chi_Minh", approvedBy: "employee", policy: policies))
    }
    func testScheduleHasOneWorkerAndAbandonedRunNeverRetries() throws {
        let dir = try root(), schedules = ReportDeliveryScheduleStore(root: dir.appendingPathComponent("schedules")), policies = ReportTeamPolicyStore(root: dir.appendingPathComponent("team"))
        try install(policy(), in: policies)
        let now = Date(), at = now.addingTimeInterval(300), job = try gmail(root: dir, report: snapshot(root: dir))
        let saved = try schedules.scheduleGmail(job, at: at, expiresAt: at.addingTimeInterval(3600), timeZone: "Asia/Ho_Chi_Minh", approvedBy: "employee", policy: policies)
        XCTAssertNil(try schedules.claimNext(now: now))
        XCTAssertEqual(try schedules.claimNext(now: at)?.id, saved.id)
        XCTAssertNil(try schedules.claimNext(now: at))
        XCTAssertNil(try schedules.claimNext(now: at.addingTimeInterval(181)))
        XCTAssertEqual(try schedules.all().first?.state, .needsReview)
    }
    func testOfflinePastDeadlineIsMissedInsteadOfCatchUpSend() throws {
        let dir = try root(), schedules = ReportDeliveryScheduleStore(root: dir.appendingPathComponent("schedules")), policies = ReportTeamPolicyStore(root: dir.appendingPathComponent("team"))
        try install(policy(), in: policies)
        let at = Date().addingTimeInterval(300), expiry = at.addingTimeInterval(3600), job = try gmail(root: dir, report: snapshot(root: dir))
        _ = try schedules.scheduleGmail(job, at: at, expiresAt: expiry, timeZone: "Asia/Ho_Chi_Minh", approvedBy: "employee", policy: policies)
        XCTAssertNil(try schedules.claimNext(now: expiry))
        XCTAssertEqual(try schedules.all().first?.state, .missed)
    }
    func testMappingRequiresExplicitSourceAndTimeAndNeverAddsQuotaPercentages() throws {
        let now = Date(), store = ReportAccountMappingStore(root: try root())
        let one = QuotaSnapshot(provider: "openai", source: "codex", sourceVersion: "test", accountKey: nil, captureKey: "session-one", capturedAt: now,
            availability: .available, windows: [QuotaWindow(id: "shared/primary", usedPercent: 30, durationMinutes: 300, resetsAt: nil)], warnings: [])
        let two = QuotaSnapshot(provider: "openai", source: "pi-provider-adapter", sourceVersion: "test", accountKey: nil, captureKey: "session-two", capturedAt: now.addingTimeInterval(1),
            availability: .available, windows: [QuotaWindow(id: "shared/primary", usedPercent: 40, durationMinutes: 300, resetsAt: nil)], warnings: [])
        XCTAssertEqual(ReportQuotaGrouping.latest([one, two], organizationID: "org", mappings: []).count, 2)
        for s in [one, two] {
            let mapping = try ReportAccountMapping(organizationID: "org", provider: s.provider, source: s.source, sourceAccountKey: nil, captureKey: s.captureKey,
                accountLabel: "shared-subscription", confirmedBy: "employee", validFrom: now.addingTimeInterval(-1), validUntil: now.addingTimeInterval(10))
            try store.save(mapping); XCTAssertThrowsError(try store.save(mapping))
        }
        let grouped = ReportQuotaGrouping.latest([one, two], organizationID: "org", mappings: try store.all())
        XCTAssertEqual(grouped.count, 1); XCTAssertEqual(grouped[0].windows[0].usedPercent, 40)
        XCTAssertEqual(ReportQuotaGrouping.latest([one, two], organizationID: "other-org", mappings: try store.all()).count, 2)
    }
    private func observation(start: Date, end: Date, basis: String = "normalized-request-usage", complete: Bool = true, value: String = "100") -> ReconciliationObservation {
        ReconciliationObservation(provider: "openai", accountKey: "test", periodStart: start, periodEnd: end, timeZone: "Etc/UTC", metric: "tokens", unit: "token",
                                  basis: basis, scope: "same-requests", value: value, complete: complete, source: "synthetic", observedAt: end)
    }
    func testReconciliationNeverProratesUTCOrComparesDifferentCostBasisOrPartialCoverage() throws {
        let now = Date(), left = observation(start: now, end: now.addingTimeInterval(86_400))
        let rights = [observation(start: now.addingTimeInterval(7 * 3600), end: now.addingTimeInterval(31 * 3600)),
                      observation(start: left.periodStart, end: left.periodEnd, basis: "provider-analytics"),
                      observation(start: left.periodStart, end: left.periodEnd, complete: false)]
        for right in rights {
            let record = ReportReconciliation(id: UUID().uuidString, organizationID: "org", owner: "employee", recordedAt: Date(), left: left, right: right, note: "Review")
            try record.validate(); XCTAssertNil(record.difference)
        }
        let right = observation(start: left.periodStart, end: left.periodEnd, value: "125")
        let exact = ReportReconciliation(id: UUID().uuidString, organizationID: "org", owner: "employee", recordedAt: Date(), left: left, right: right, note: "Same basis")
        XCTAssertEqual(exact.difference, 25)
    }
    func testRetentionProtectsUncertainWorkAndKeepsReceiptsWhilePurgingExpiredPayloads() throws {
        let dir = try root(), old = Date().addingTimeInterval(-60 * 86_400), report = try snapshot(root: dir, now: old)
        let gmailStore = GmailOutboxStore(root: dir.appendingPathComponent("gmail-outbox")), job = try gmail(root: dir, report: report, now: old)
        let service = ReportRetentionService(root: dir)
        _ = try gmailStore.claim(job.id, owner: "attempt", now: old)
        _ = try gmailStore.finish(job.id, owner: "attempt", state: .uncertain, now: old)
        XCTAssertTrue(try service.preview(retentionDays: 30).candidates.isEmpty)
        _ = try gmailStore.reconcile(job.id, employeeID: "employee", observedInSent: true, acceptsDuplicateRisk: false, note: "Verified Sent")
        let plan = try service.preview(retentionDays: 30)
        XCTAssertEqual(plan.candidates.count, 4)
        XCTAssertThrowsError(try service.execute(plan, expectedDigest: "wrong"))
        XCTAssertEqual(try service.execute(plan, expectedDigest: plan.digest), 4)
        XCTAssertEqual(try gmailStore.read(job.id)?.state, .manuallyConfirmed)
        XCTAssertEqual(try gmailStore.read(job.id)?.reconciliations.count, 1)
        XCTAssertFalse(try XCTUnwrap(gmailStore.read(job.id)).previewText.contains("Synthetic report"))
        XCTAssertThrowsError(try gmailStore.payload(for: job))
    }
    func testRetentionRejectsChangedFileOrExpiredReview() throws {
        let dir = try root(), report = try snapshot(root: dir, now: Date().addingTimeInterval(-60 * 86_400)), service = ReportRetentionService(root: dir)
        let plan = try service.preview(retentionDays: 30)
        XCTAssertThrowsError(try service.execute(plan, expectedDigest: plan.digest, now: plan.createdAt.addingTimeInterval(301)))
        try Data("tampered".utf8).write(to: dir.appendingPathComponent(report.id + ".json"))
        XCTAssertThrowsError(try service.execute(plan, expectedDigest: plan.digest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(report.id + ".json").path))
    }
}
