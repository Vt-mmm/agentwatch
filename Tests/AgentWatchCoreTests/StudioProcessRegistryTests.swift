import XCTest
import Darwin
@testable import AgentWatchCore

final class StudioProcessRegistryTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (StudioProcessRegistry, StudioCLILaunchPlan) {
        let base = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(base) }
        let root = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("studio-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let origin = try StudioOrigin("https://studio.example")
        let connection = try StudioProfile(origin: origin, id: origin.profileID(orgID: UUID(), ownerID: UUID()))
        let registry = StudioProcessRegistry(directory: root.appendingPathComponent("profiles"))
        let profile = try StudioCLIProfiles.prepare(connection: connection, provider: .claude, directory: registry.directory)
        let plan = try StudioCLILaunchPlan(executable: StudioCLIExecutable(url: URL(fileURLWithPath: "/bin/sleep"), provider: .claude), profile: profile,
                                         project: root, model: StudioModel(id: "fixture", displayName: "Fixture", ownedBy: "claude", nativeProtocol: "messages"))
        return (registry, plan)
    }
    private func child(_ executable: String = "/bin/sleep", arguments: [String] = ["30"], input: Pipe? = nil) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        child.standardInput = input ?? Pipe(); child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        addTeardownBlock { () async throws -> Void in
            // Only fixture children retained by Process; never a discovered PID.
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            for _ in 0..<100 {
                if !child.isRunning { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Fixture child termination was not observed")
        }
        return child
    }
    private func registered(_ registry: StudioProcessRegistry, _ plan: StudioCLILaunchPlan, _ child: Process) throws -> StudioManagedProcess {
        try registry.withLaunchLock(connection: plan.profile.connection) { try registry.register(plan: plan, pid: child.processIdentifier) }
    }
    private func file(_ registry: StudioProcessRegistry, _ record: StudioManagedProcess) -> URL {
        registry.directory.appendingPathComponent(record.connection.id).appendingPathComponent("runs").appendingPathComponent(record.id.uuidString.lowercased() + ".json")
    }
    func testPreExecRegistrationSurvivesExecAndStopsOnlyRegisteredChild() async throws {
        let (registry, plan) = try fixture(), pipe = Pipe()
        let managed = try child("/bin/sh", arguments: ["-c", "read gate; exec /bin/sleep 30"], input: pipe)
        let peer = try child(), record = try registered(registry, plan, managed)
        XCTAssertEqual(StudioProcessControl.state(record), .unverified)
        pipe.fileHandleForWriting.write(Data("go\n".utf8))
        for _ in 0..<100 where StudioProcessControl.state(record) != .running { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(StudioProcessControl.state(record), .running)
        XCTAssertFalse(registry.snapshot(connection: record.connection).incomplete)
        var stale = try StudioProcessControl.token(record)
        stale.val.7 &+= 1
        XCTAssertEqual(StudioProcessControl.signal(&stale, SIGTERM), ESRCH)
        XCTAssertTrue(managed.isRunning)
        let stopped = try await registry.stop(record)
        XCTAssertEqual(stopped, .finished); XCTAssertTrue(peer.isRunning)
        let metadata = try String(contentsOf: file(registry, record), encoding: .utf8)
        XCTAssertFalse(metadata.contains("as_live_")); XCTAssertFalse(metadata.contains("arguments")); XCTAssertFalse(metadata.contains("prompt"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file(registry, record).path)[.posixPermissions] as? Int, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.profile.configFile.path))
    }
    func testMismatchedBirthOrExecutableNeverSignalsAnotherProcess() async throws {
        let (registry, plan) = try fixture(), managed = try child()
        let record = try registered(registry, plan, managed), path = file(registry, record)
        for field in ["startSeconds", "executable"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            json[field] = field == "startSeconds" ? record.startSeconds + 1 : "/bin/other"
            try JSONSerialization.data(withJSONObject: json).write(to: path)
            let altered = try JSONDecoder().decode(StudioManagedProcess.self, from: Data(contentsOf: path))
            XCTAssertEqual(StudioProcessControl.state(altered), field == "startSeconds" ? .finished : .unverified)
            if field == "startSeconds" { let result = try await registry.stop(altered); XCTAssertEqual(result, .finished) }
            else {
                do { _ = try await registry.stop(altered); XCTFail("Unverified executable must not be signalled") }
                catch { XCTAssertEqual(error as? StudioProcessError, .changedProcess) }
            }
            XCTAssertTrue(managed.isRunning)
        }
    }
    func testChangedMetadataAndUnsafeFilesFailClosed() async throws {
        let (registry, plan) = try fixture(), managed = try child()
        let record = try registered(registry, plan, managed), path = file(registry, record)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        XCTAssertTrue(registry.snapshot(connection: record.connection).incomplete)
        do { _ = try await registry.stop(record); XCTFail("Unsafe registry must refuse stop") } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let original = path.deletingLastPathComponent().appendingPathComponent("saved")
        try FileManager.default.moveItem(at: path, to: original)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: original)
        XCTAssertTrue(registry.snapshot(connection: record.connection).incomplete)
        do { _ = try await registry.stop(record); XCTFail("Symlink must refuse stop") } catch {}
        XCTAssertTrue(managed.isRunning)
    }
    func testLaunchLockRejectsConcurrentOperationAndReleasesAfterError() throws {
        let (registry, plan) = try fixture()
        XCTAssertThrowsError(try registry.withLaunchLock(connection: plan.profile.connection) {
            XCTAssertThrowsError(try registry.withLaunchLock(connection: plan.profile.connection) {}) { XCTAssertEqual($0 as? StudioProcessError, .busy) }
            throw StudioProcessError.unavailable
        })
        try registry.withLaunchLock(connection: plan.profile.connection) {}
    }
    func testIgnoredTerminationRemainsRunning() async throws {
        let (registry, plan) = try fixture(), pipe = Pipe()
        let managed = try child("/bin/sh", arguments: ["-c", "trap '' TERM; read gate; exec /bin/sleep 30"], input: pipe)
        let record = try registered(registry, plan, managed)
        pipe.fileHandleForWriting.write(Data("go\n".utf8))
        for _ in 0..<100 where StudioProcessControl.state(record) != .running { try await Task.sleep(for: .milliseconds(20)) }
        let result = try await registry.stop(record)
        XCTAssertEqual(result, .running); XCTAssertTrue(managed.isRunning)
    }
    @MainActor func testDisconnectChoicesRemoveOnlySavedKeyAndPreserveLogs() async throws {
        for choice in [StudioDisconnectChoice.keepCLI, .closeCLI] {
            let (registry, plan) = try fixture(), managed = try child(), peer = try child()
            _ = try registered(registry, plan, managed)
            let storage = DisconnectStorage(profile: plan.profile.connection)
            let store = StudioConnectionStore(keys: storage, settings: storage, cache: DisconnectCache())
            let log = plan.profile.root.appendingPathComponent("preserved-log.jsonl")
            try Data("fixture log".utf8).write(to: log)
            let result = try await StudioDisconnect.perform(store: store, expected: plan.profile.connection, choice: choice, registry: registry)
            XCTAssertNil(store.profile); XCTAssertNil(storage.key); XCTAssertEqual(store.state, .disconnected)
            XCTAssertTrue(peer.isRunning); XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "fixture log")
            XCTAssertEqual(result.unverified, 0); XCTAssertFalse(result.incomplete)
            if choice == .keepCLI { XCTAssertTrue(managed.isRunning); XCTAssertEqual(result.remaining, 1) }
            else { XCTAssertEqual(result.closed, 1); XCTAssertEqual(result.remaining, 0) }
        }
    }
    @MainActor func testDisconnectStorageFailureOrStaleIdentityNeverSignals() async throws {
        let (registry, plan) = try fixture(), managed = try child()
        _ = try registered(registry, plan, managed)
        let storage = DisconnectStorage(profile: plan.profile.connection)
        let store = StudioConnectionStore(keys: storage, settings: storage, cache: DisconnectCache())
        let foreign = try StudioProfile(origin: plan.profile.connection.origin, id: String(repeating: "b", count: 64))
        do { _ = try await StudioDisconnect.perform(store: store, expected: foreign, choice: .closeCLI, registry: registry); XCTFail("Stale confirmation") }
        catch { XCTAssertEqual(error as? StudioError, .identityChanged) }
        XCTAssertNotNil(storage.key); XCTAssertEqual(store.profile, plan.profile.connection)
        storage.failDelete = true
        do { _ = try await StudioDisconnect.perform(store: store, expected: plan.profile.connection, choice: .closeCLI, registry: registry); XCTFail("Failed deletion") }
        catch { XCTAssertEqual(error as? StudioError, .storage) }
        XCTAssertTrue(managed.isRunning); XCTAssertNotNil(storage.key); XCTAssertEqual(store.state, .failed)
    }
    @MainActor func testDisconnectWithIncompleteRegistryReportsUnknownAndDoesNotGuess() async throws {
        let (registry, plan) = try fixture(), managed = try child()
        let record = try registered(registry, plan, managed)
        try Data("invalid".utf8).write(to: file(registry, record))
        let storage = DisconnectStorage(profile: plan.profile.connection)
        let store = StudioConnectionStore(keys: storage, settings: storage, cache: DisconnectCache())
        let result = try await StudioDisconnect.perform(store: store, expected: plan.profile.connection, choice: .closeCLI, registry: registry)
        XCTAssertTrue(result.incomplete); XCTAssertEqual(result.closed, 0); XCTAssertTrue(managed.isRunning)
        XCTAssertNil(storage.key); XCTAssertNil(store.profile)
    }
}

@MainActor private final class DisconnectStorage: StudioSettingsStorage, StudioKeyStorage {
    var profile: StudioProfile?
    var key: String? = "as_live_synthetic_fixture"
    var failDelete = false
    init(profile: StudioProfile) { self.profile = profile }
    func load() throws -> StudioProfile? { profile }
    func save(_ profile: StudioProfile?) { self.profile = profile }
    func load(profileID: String) throws -> String? { key }
    func save(_ key: String, profileID: String) throws { self.key = key }
    func delete(profileID: String) throws { if failDelete { throw StudioError.storage }; key = nil }
}
@MainActor private final class DisconnectCache: StudioDashboardCaching {
    func load(profile: StudioProfile) throws -> StudioDashboardSnapshot? { nil }
    func save(_ snapshot: StudioDashboardSnapshot, profile: StudioProfile) throws {}
    func delete(profile: StudioProfile) throws {}
}
