import XCTest
@testable import AgentWatchCore

@MainActor private final class CommandStorage: StudioSettingsStorage, StudioKeyStorage {
    var profile: StudioProfile?
    var key: String? = "as_live_synthetic_fixture"
    var keyReads = 0
    func load() throws -> StudioProfile? { profile }
    func save(_ profile: StudioProfile?) { self.profile = profile }
    func load(profileID: String) throws -> String? { keyReads += 1; return key }
    func save(_ key: String, profileID: String) throws { self.key = key }
    func delete(profileID: String) throws { key = nil }
}
private actor CommandClient: StudioConnecting {
    let snapshot: StudioConnectionSnapshot
    init(_ snapshot: StudioConnectionSnapshot) { self.snapshot = snapshot }
    func connect(origin: StudioOrigin, key: String) async throws -> StudioConnectionSnapshot { snapshot }
}

@MainActor final class StudioRunCommandTests: XCTestCase {
    private func setup() throws -> (URL, CommandStorage, CommandClient, [String]) {
        let base = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(base) }
        let root = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("studio-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let origin = try StudioOrigin("https://studio.example"), org = UUID(), owner = UUID()
        let store = CommandStorage()
        store.profile = try StudioProfile(origin: origin, id: origin.profileID(orgID: org, ownerID: owner))
        let identity = StudioIdentity(user: StudioUser(id: owner, displayName: "Fixture", role: "member", active: true, version: 1), orgID: org, apiVersion: "studio/v1")
        let snapshot = StudioConnectionSnapshot(identity: identity, capabilities: StudioCapabilities(apiVersion: "studio/v1", protocols: ["messages"], auth: ["bearer"]), models: .available([StudioModel(id: "studio-model", displayName: "Fixture", ownedBy: "claude", nativeProtocol: "messages")]))
        let args = ["claude", "--model", "studio-model", "--binary", "/usr/bin/true", "--project", root.path, "--profile", store.profile!.id]
        return (root, store, CommandClient(snapshot), args)
    }
    func testCheckAndExecutionReadCurrentCredentialWithoutPuttingItInArguments() async throws {
        for check in [true, false] {
            let (root, store, client, args) = try setup()
            var prepared = false, executed = false
            let command = StudioRunCommand(arguments: args + (check ? ["--check"] : []), settings: store, keys: store, client: client, directory: root.appendingPathComponent("profiles"), preflight: { plan in
                prepared = true
                XCTAssertNil(plan.environment["ANTHROPIC_API_KEY"])
            }, execute: { plan, key in
                executed = true
                XCTAssertEqual(key, store.key)
                XCTAssertFalse(plan.arguments.contains(key))
            })
            let status = await command.run()
            XCTAssertEqual(status, 0); XCTAssertTrue(prepared); XCTAssertEqual(executed, !check); XCTAssertEqual(store.keyReads, 2)
        }
    }
    func testDisconnectRotationAndProfileSwitchDuringPreflightPreventExecution() async throws {
        for change in ["disconnect", "rotation", "profile"] {
            let (root, store, client, args) = try setup()
            var executed = false
            let command = StudioRunCommand(arguments: args, settings: store, keys: store, client: client, directory: root.appendingPathComponent("profiles"), preflight: { _ in
                switch change {
                case "disconnect": store.profile = nil; store.key = nil
                case "rotation": store.key = "as_live_other_fixture"
                default: store.profile = try StudioProfile(origin: StudioOrigin("https://other.example"), id: String(repeating: "b", count: 64))
                }
            }, execute: { _, _ in executed = true })
            let status = await command.run()
            XCTAssertEqual(status, 1); XCTAssertFalse(executed)
        }
    }
    func testStaleTerminalIdentityAndMalformedFlagsStopBeforeKeychainRead() async throws {
        let invalid: [[String]] = [["--profile", "wrong"], ["--resume", "not-a-uuid"], ["--dangerously-skip-permissions"], ["--key", "not-accepted"]]
        for suffix in invalid {
            let (root, store, client, args) = try setup()
            var prepared = false, executed = false
            let command = StudioRunCommand(arguments: Array(args.dropLast(2)) + suffix, settings: store, keys: store, client: client, directory: root.appendingPathComponent("profiles"), preflight: { _ in prepared = true }, execute: { _, _ in executed = true })
            let status = await command.run()
            XCTAssertEqual(status, 1); XCTAssertEqual(store.keyReads, 0); XCTAssertFalse(prepared); XCTAssertFalse(executed)
        }
    }
    func testUnavailableModelAndFailedPreflightNeverExecute() async throws {
        for modelDenied in [true, false] {
            let (root, store, client, original) = try setup()
            var args = original, executed = false, prepared = false
            if modelDenied { args[2] = "unavailable" }
            let command = StudioRunCommand(arguments: args, settings: store, keys: store, client: client, directory: root.appendingPathComponent("profiles"), preflight: { _ in prepared = true; throw StudioCLIError.unsupportedVersion }, execute: { _, _ in executed = true })
            let status = await command.run()
            XCTAssertEqual(status, 1); XCTAssertEqual(prepared, !modelDenied); XCTAssertFalse(executed)
        }
    }
    func testHelpTextUsedAsPromptRemainsALiteralArgument() async throws {
        let (root, store, client, args) = try setup()
        var executed = false
        let command = StudioRunCommand(arguments: args + ["--print", "--help"], settings: store, keys: store, client: client, directory: root.appendingPathComponent("profiles"), preflight: { _ in }, execute: { plan, _ in
            executed = true
            XCTAssertEqual(plan.prompt, "--help")
            XCTAssertEqual(plan.arguments.suffix(2), ["--", "--help"])
        })
        let status = await command.run()
        XCTAssertEqual(status, 0); XCTAssertTrue(executed)
    }
}
