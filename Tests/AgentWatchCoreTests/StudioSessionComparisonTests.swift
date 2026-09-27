import XCTest
@testable import AgentWatchCore

private let sessionID = "00000000-0000-4000-8000-000000000003"
private let sessionOwner = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
private let sessionOrg = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
private let sessionIdentity = StudioIdentity(user: StudioUser(id: sessionOwner, displayName: "Fixture", role: "member", active: true, version: 1), orgID: sessionOrg, apiVersion: "studio/v1")
private let sessionOrigin = try! StudioOrigin("https://studio.example")
private let sessionProfile = try! StudioProfile(origin: sessionOrigin, id: sessionOrigin.profileID(orgID: sessionOrg, ownerID: sessionOwner))
private let sessionRange = Date(timeIntervalSince1970: 1790553600)..<Date(timeIntervalSince1970: 1790553660)
private func sessionBody(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    let tokens: [String: Any] = ["total_tokens":"15", "input_tokens":"10", "output_tokens":"5", "cache_read_tokens":"0", "cache_write_tokens":"0", "reasoning_tokens":"0"]
    let row: [String: Any] = ["id":sessionOrg.uuidString,"user_id":sessionOwner.uuidString,"key_id":sessionOrg.uuidString,"model_id":"friendly-studio","provider":"claude","accounting_status":"confirmed","created_at":"2026-09-28T00:00:09Z","finished_at":"2026-09-28T00:00:21Z","charged_tokens":"15","confirmed":tokens,"session_digest":StudioSessionComparison.digest(sessionID: sessionID)!,"session_key_family_id":sessionOrg.uuidString,"native_models":["claude-native"]]
    var body: [String: Any] = ["session_evidence_version":1,"source":"studio_ledger","from":"2026-09-28T00:00:00Z","to":"2026-09-28T00:01:00Z","observed_at":"2026-09-28T00:01:00Z","limit":100,"offset":0,"requests":[row],"summary":["requests":"1","confirmed_requests":"1","unresolved_requests":"0","disputed_requests":"0","charged_tokens":"15","confirmed":tokens]]
    change(&body)
    return try JSONSerialization.data(withJSONObject: body)
}
private func rowChange(_ body: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
    var rows = body["requests"] as! [[String: Any]]; edit(&rows[0]); body["requests"] = rows
}
private func summaryChange(_ body: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
    var summary = body["summary"] as! [String: Any]; edit(&summary); body["summary"] = summary
}
private func localSession(_ partial: Bool = false, id: String = sessionID, model: String = "claude-native") -> StudioLocalSession {
    let entry = UsageEntry(id: "fixture", sessionID: id, agent: "claude", provider: "anthropic", modelID: model, timestamp: sessionRange.lowerBound.addingTimeInterval(20), tokens: UsageTokens(input: 10, output: 5))
    return StudioLocalSession(profileID: sessionProfile.id, provider: .claude, summary: SessionSummary(id: id, projectDisplay: "/fixture", source: .cli, model: model, modelFamily: .haiku, inputTokens: 10, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0, firstTimestamp: sessionRange.lowerBound.addingTimeInterval(10), lastTimestamp: entry.timestamp, promptCount: 1, toolCallCount: 0, usageScope: .exactRange, usageEntries: [entry]), sourcePartial: partial)
}
private actor SessionTransport: StudioHTTPTransport {
    let body: Data
    var request: URLRequest?
    init(_ body: Data) { self.body = body }
    func send(_ request: URLRequest, origin: StudioOrigin) async throws -> StudioHTTPResponse { self.request = request; return StudioHTTPResponse(status: 200, body: body) }
}
private func fetchSession(_ data: Data) async throws -> StudioSessionReport {
    try await StudioClient(transport: SessionTransport(data)).sessionUsage(origin: sessionOrigin, key: "fixture_key", identity: sessionIdentity, provider: .claude, digest: StudioSessionComparison.digest(sessionID: sessionID)!, range: sessionRange)
}
final class StudioSessionComparisonTests: XCTestCase, @unchecked Sendable {
    func testReadOnlyOwnRouteAndNativeModelEvidence() async throws {
        let transport = SessionTransport(try sessionBody())
        let report = try await StudioClient(transport: transport).sessionUsage(origin: sessionOrigin, key: "fixture_key", identity: sessionIdentity, provider: .claude, digest: StudioSessionComparison.digest(sessionID: sessionID)!, range: sessionRange)
        let request = await transport.request!
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.url!.path, "/studio/v1/me/usage")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(Set(query.map(\.name)).isDisjoint(with: ["user_id","account_id","key_id"]))
        let result = StudioSessionComparison.compare(local: localSession(), report: report, coveragePartial: false)
        XCTAssertEqual(result.status, .matched); XCTAssertEqual(result.serverTokens?.value, "15")
        XCTAssertEqual(StudioSessionComparison.compare(local: localSession(model: "friendly-studio"), report: report, coveragePartial: false).status, .matched)
        XCTAssertEqual(report.requests[0].usage.model_id, "friendly-studio") // Native model is intentionally different.
    }
    func testIdentityOnlyAcceptsCanonicalUUIDsAndIsCaseInsensitive() {
        XCTAssertEqual(StudioSessionComparison.digest(sessionID: sessionID), StudioSessionComparison.digest(sessionID: sessionID.uppercased()))
        for id in ["agent-123", "derived:"+sessionID, " "+sessionID, "00000000-0000-0000-0000-000000000000", sessionID.replacingOccurrences(of: "-", with: "")] { XCTAssertNil(StudioSessionComparison.digest(sessionID: id)) }
    }
    func testForeignOwnerProviderDigestRangeAndMissingVersionFailClosed() async throws {
        let changes: [(inout [String: Any]) -> Void] = [
            { rowChange(&$0) { $0["user_id"] = UUID().uuidString } },
            { rowChange(&$0) { $0["provider"] = "codex" } },
            { rowChange(&$0) { $0["session_digest"] = String(repeating: "a", count: 64) } },
            { rowChange(&$0) { $0["session_key_family_id"] = NSNull() } },
            { rowChange(&$0) { $0["created_at"] = "2026-09-27T00:00:00Z" } },
            { $0["source"] = "local" }, { $0["to"] = "2026-09-28T00:02:00Z" },
            { $0.removeValue(forKey: "session_evidence_version") }, { $0["offset"] = 1 },
            { $0["requests"] = ($0["requests"] as! [[String: Any]]) + ($0["requests"] as! [[String: Any]]) }
        ]
        for change in changes {
            do { _ = try await fetchSession(sessionBody(change)); XCTFail("accepted invalid correlation") }
            catch { XCTAssertEqual(error as? StudioError, .invalidResponse) }
        }
    }
    func testPartialScopeCoverageModelAndClockNeverMatch() async throws {
        let full = try await fetchSession(sessionBody())
        XCTAssertEqual(StudioSessionComparison.compare(local: localSession(true), report: full, coveragePartial: false).reason, .localIncomplete)
        XCTAssertEqual(StudioSessionComparison.compare(local: localSession(), report: full, coveragePartial: true).reason, .localIncomplete)
        let cases: [(StudioSessionComparison.Reason, (inout [String: Any]) -> Void)] = [
            (.serverIncomplete, { summaryChange(&$0) { $0["requests"] = "101" } }),
            (.serverIncomplete, { summaryChange(&$0) { $0["unresolved_requests"] = "1" } }),
            (.modelMismatch, { rowChange(&$0) { $0["native_models"] = ["different"] } }),
            (.modelMismatch, { rowChange(&$0) { $0["native_models"] = ["claude-native", "second-native"] } }),
            (.timeMismatch, { rowChange(&$0) { $0["finished_at"] = "2026-09-28T00:00:09Z" } }),
            (.ambiguousFamily, { body in
                var rows = body["requests"] as! [[String: Any]], second = rows[0]
                second["id"] = UUID().uuidString; second["session_key_family_id"] = UUID().uuidString; rows.append(second); body["requests"] = rows
                summaryChange(&body) { $0["requests"] = "2" }
            })
        ]
        for (reason, edit) in cases {
            let report = try await fetchSession(sessionBody(edit))
            let result = StudioSessionComparison.compare(local: localSession(), report: report, coveragePartial: false)
            XCTAssertEqual(result.status, .partial); XCTAssertEqual(result.reason, reason)
        }
    }
    func testNoEvidenceAndDifferentConfirmedTotalsAreUnmatchedNotZero() async throws {
        let empty = try await fetchSession(sessionBody { body in
            body["requests"] = []
            summaryChange(&body) { $0["requests"] = "0"; $0["confirmed_requests"] = "0"; $0["confirmed"] = ["total_tokens": NSNull()] }
        })
        let result = StudioSessionComparison.compare(local: localSession(), report: empty, coveragePartial: false)
        XCTAssertEqual(result.status, .unmatched); XCTAssertEqual(result.reason, .noEvidence); XCTAssertNil(result.serverTokens)
        let different = try await fetchSession(sessionBody { body in
            rowChange(&body) { $0["charged_tokens"] = "16"; $0["confirmed"] = ["total_tokens":"16"] }
            summaryChange(&body) { $0["confirmed"] = ["total_tokens":"16"] }
        })
        XCTAssertEqual(StudioSessionComparison.compare(local: localSession(), report: different, coveragePartial: false).reason, .differentTokens)
        let huge = try await fetchSession(sessionBody { body in
            rowChange(&body) { $0["charged_tokens"] = "922337203685477580812345"; $0["confirmed"] = ["total_tokens":"922337203685477580812345"] }
            summaryChange(&body) { $0["confirmed"] = ["total_tokens":"922337203685477580812345"] }
        })
        let partial = StudioSessionComparison.compare(local: localSession(), report: huge, coveragePartial: false)
        XCTAssertEqual(partial.status, .partial); XCTAssertEqual(partial.serverTokens?.value, "922337203685477580812345")
    }
}

private actor DelayedSessionClient: StudioConnecting, StudioSessionReporting {
    var waiter: CheckedContinuation<StudioSessionReport, any Error>?
    var failure: StudioError?
    var immediate = false, firstOnly = false, calls = 0
    func completeImmediately() { immediate = true }
    func completeFirstOnly() { firstOnly = true }
    func connect(origin: StudioOrigin, key: String) async throws -> StudioConnectionSnapshot {
        StudioConnectionSnapshot(identity: sessionIdentity, capabilities: StudioCapabilities(apiVersion: "studio/v1", protocols: [], auth: ["bearer"]), models: .available([]))
    }
    func sessionUsage(origin: StudioOrigin, key: String, identity: StudioIdentity, provider: StudioCLIProvider, digest: String, range: Range<Date>) async throws -> StudioSessionReport {
        calls += 1
        if let failure { throw failure }
        if immediate || firstOnly && calls == 1 { return try StudioClient.apiDecoder().decode(StudioSessionReport.self, from: sessionBody { rowChange(&$0) { $0["session_digest"] = digest } }) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func waiting() -> Bool { waiter != nil }
    func finish(_ result: StudioSessionReport) { waiter?.resume(returning: result); waiter = nil }
    func fail(_ error: StudioError) { failure = error }
}
@MainActor private final class SessionKeys: StudioKeyStorage {
    var key: String? = "fixture_key"
    func load(profileID: String) throws -> String? { key }
    func save(_ key: String, profileID: String) throws { self.key = key }
    func delete(profileID: String) throws { key = nil }
}
@MainActor private final class SessionSettings: StudioSettingsStorage {
    var profile: StudioProfile?
    func load() throws -> StudioProfile? { profile }
    func save(_ profile: StudioProfile?) { self.profile = profile }
}
@MainActor private final class SessionCache: StudioDashboardCaching {
    func load(profile: StudioProfile) throws -> StudioDashboardSnapshot? { nil }
    func save(_ snapshot: StudioDashboardSnapshot, profile: StudioProfile) throws {}
    func delete(profile: StudioProfile) throws {}
}
@MainActor final class StudioSessionStoreTests: XCTestCase {
    func testDisconnectRefreshAndKeyChangesRejectLateReports() async throws {
        for action in ["disconnect", "refresh", "key"] {
            let client = DelayedSessionClient(), keys = SessionKeys()
            let store = StudioConnectionStore(client: client, keys: keys, settings: SessionSettings(), cache: SessionCache())
            await store.connect(origin: sessionOrigin.value, key: "fixture_key")
            let task = Task { try await store.compareSession(localSession(), range: sessionRange, coveragePartial: false) }
            for _ in 0..<100 { if await client.waiting() { break }; try await Task.sleep(for: .milliseconds(5)) }
            if action == "disconnect" { store.disconnect() }
            else if action == "refresh" { await store.refresh() }
            else { keys.key = "rotated_fixture_key" }
            await client.finish(try await fetchSession(sessionBody()))
            do { _ = try await task.value; XCTFail("stale comparison returned") } catch { XCTAssertTrue(error is CancellationError) }
        }
    }
    func testRevokedKeyInvalidatesConnectionAndPriorEvidence() async throws {
        let client = DelayedSessionClient()
        let current = StudioConnectionStore(client: client, keys: SessionKeys(), settings: SessionSettings(), cache: SessionCache())
        await current.connect(origin: sessionOrigin.value, key: "fixture_key")
        let before = current.sessionReportsRevision
        await client.fail(.invalidKey)
        do { _ = try await current.compareSession(localSession(), range: sessionRange, coveragePartial: false); XCTFail() } catch { XCTAssertEqual(error as? StudioError, .invalidKey) }
        XCTAssertEqual(current.state, .failed); XCTAssertNil(current.snapshot); XCTAssertNil(current.dashboard)
        XCTAssertGreaterThan(current.sessionReportsRevision, before)
    }
}

private struct FixedSessionLogs: StudioLocalLogReading {
    let sessions: [StudioLocalSession]
    func read(connection: StudioProfile, range: Range<Date>) async -> StudioLocalLogSnapshot {
        StudioLocalLogSnapshot(connection: connection, from: range.lowerBound, to: range.upperBound, observedAt: range.upperBound, registrations: [], sessions: sessions, filesRead: sessions.count, issues: [])
    }
}
@MainActor final class StudioLocalComparisonStoreTests: XCTestCase {
    func testBoundsServerReadsToDisplayedSessions() async throws {
        let client = DelayedSessionClient()
        await client.completeImmediately()
        let studio = StudioConnectionStore(client: client, keys: SessionKeys(), settings: SessionSettings(), cache: SessionCache())
        await studio.connect(origin: sessionOrigin.value, key: "fixture_key")
        let sessions = (1...25).map { localSession(id: String(format: "00000000-0000-4000-8000-%012d", $0)) }
        let logs = StudioLocalLogStore(reader: FixedSessionLogs(sessions: sessions))
        await logs.refresh(connection: sessionProfile, range: sessionRange)
        await logs.compare(using: studio)
        let calls = await client.calls
        XCTAssertEqual(calls, 20); XCTAssertEqual(logs.comparisons.count, 20)
        XCTAssertTrue(logs.comparisons.values.allSatisfy { $0.status == .matched })
        XCTAssertFalse(logs.comparing)
    }
    func testCancellationDiscardsEarlierRowsInBatch() async throws {
        let client = DelayedSessionClient()
        await client.completeFirstOnly()
        let studio = StudioConnectionStore(client: client, keys: SessionKeys(), settings: SessionSettings(), cache: SessionCache())
        await studio.connect(origin: sessionOrigin.value, key: "fixture_key")
        let logs = StudioLocalLogStore(reader: FixedSessionLogs(sessions: [localSession(), localSession(id: "00000000-0000-4000-8000-000000000004")]))
        await logs.refresh(connection: sessionProfile, range: sessionRange)
        let task = Task { await logs.compare(using: studio) }
        for _ in 0..<100 { if await client.waiting() { break }; try await Task.sleep(for: .milliseconds(5)) }
        let calls = await client.calls
        XCTAssertEqual(calls, 2)
        task.cancel()
        await client.finish(try await fetchSession(sessionBody()))
        await task.value
        XCTAssertTrue(logs.comparisons.isEmpty); XCTAssertFalse(logs.comparing)
    }
    func testClearedLocalSnapshotRejectsPendingComparison() async throws {
        let client = DelayedSessionClient()
        let studio = StudioConnectionStore(client: client, keys: SessionKeys(), settings: SessionSettings(), cache: SessionCache())
        await studio.connect(origin: sessionOrigin.value, key: "fixture_key")
        let logs = StudioLocalLogStore(reader: FixedSessionLogs(sessions: [localSession()]))
        await logs.refresh(connection: sessionProfile, range: sessionRange)
        let task = Task { await logs.compare(using: studio) }
        for _ in 0..<100 { if await client.waiting() { break }; try await Task.sleep(for: .milliseconds(5)) }
        logs.clear()
        await client.finish(try await fetchSession(sessionBody()))
        await task.value
        XCTAssertTrue(logs.comparisons.isEmpty); XCTAssertNil(logs.snapshot); XCTAssertFalse(logs.comparing)
    }
}
