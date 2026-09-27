import XCTest
@testable import AgentWatchCore

final class StudioCLITests: XCTestCase, @unchecked Sendable {
    private func temporary() throws -> URL {
        let base = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(base) }
        let url = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("studio-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func connection(_ origin: String = "https://studio.example", owner: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!) throws -> StudioProfile {
        let url = try StudioOrigin(origin)
        return try StudioProfile(origin: url, id: url.profileID(orgID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, ownerID: owner))
    }
    private func plan(_ provider: StudioCLIProvider, root: URL, binary: URL? = nil, prompt: String? = nil) throws -> StudioCLILaunchPlan {
        let model = StudioModel(id: "studio-model", displayName: "Fixture", ownedBy: provider.rawValue, nativeProtocol: provider.nativeProtocol)
        let executable = try binary.map { try StudioCLIExecutable.resolve(provider, explicit: $0) } ?? StudioCLIExecutable.resolve(provider)
        return try StudioCLILaunchPlan(executable: executable, profile: StudioCLIProfiles.prepare(connection: connection(), provider: provider, directory: root.appendingPathComponent("profiles")), project: root, model: model, prompt: prompt)
    }
    private func fake(_ root: URL, text: String = "#!/bin/sh\nprintf 'unqualified-version\\n'\n") throws -> URL {
        let file = root.appendingPathComponent("fixture-cli")
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    func testProfileIdentityProviderIsolationPermissionsAndNoCredentials() throws {
        let root = try temporary(), identity = try connection()
        let first = try StudioCLIProfiles.prepare(connection: identity, provider: .claude, directory: root)
        let second = try StudioCLIProfiles.prepare(connection: identity, provider: .codex, directory: root)
        let foreign = try StudioCLIProfiles.prepare(connection: connection("https://other.example"), provider: .claude, directory: root)
        let otherOwner = try StudioCLIProfiles.prepare(connection: connection(owner: UUID()), provider: .claude, directory: root)
        XCTAssertNotEqual(first.root, second.root); XCTAssertNotEqual(first.root, foreign.root)
        XCTAssertNotEqual(first.root, otherOwner.root)
        XCTAssertEqual(try StudioCLIProfiles.prepare(connection: identity, provider: .claude, directory: root), first)
        for profile in [first, second, foreign] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: profile.root.path)[.posixPermissions] as? Int, 0o700)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: profile.configFile.path)[.posixPermissions] as? Int, 0o600)
            XCTAssertFalse(try String(contentsOf: profile.configFile, encoding: .utf8).contains("as_live_"))
        }
        XCTAssertEqual(first.logRoot.lastPathComponent, "projects")
        XCTAssertEqual(second.logRoot.lastPathComponent, "sessions")
    }
    func testDesktopBinaryAndSymlinkToDesktopAreRejected() throws {
        let root = try temporary(), desktop = root.appendingPathComponent("Codex.app")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let binary = try fake(desktop), link = root.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        for path in [binary, link] {
            XCTAssertThrowsError(try StudioCLIExecutable.resolve(.codex, explicit: path)) { XCTAssertEqual($0 as? StudioCLIError, .desktopBinary) }
        }
    }
    func testProfileTamperingDoesNotOverwriteExistingData() throws {
        let root = try temporary(), identity = try connection()
        let profile = try StudioCLIProfiles.prepare(connection: identity, provider: .claude, directory: root)
        try Data("changed".utf8).write(to: profile.configFile)
        XCTAssertThrowsError(try StudioCLIProfiles.prepare(connection: identity, provider: .claude, directory: root))
        XCTAssertEqual(try String(contentsOf: profile.configFile, encoding: .utf8), "changed")
        let other = try StudioCLIProfiles.prepare(connection: identity, provider: .codex, directory: root)
        let manifest = other.root.appendingPathComponent("profile.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: profile.configFile)
        XCTAssertThrowsError(try StudioCLIProfiles.prepare(connection: identity, provider: .codex, directory: root))
        XCTAssertEqual(try String(contentsOf: profile.configFile, encoding: .utf8), "changed")
    }
    func testPlansKeepKeyOutOfArgumentsConfigAndDiagnostics() throws {
        let root = try temporary(), binary = try fake(root)
        for provider in StudioCLIProvider.allCases {
            let value = try plan(provider, root: root, binary: binary, prompt: "$(not-a-shell) `literal` ; sample")
            XCTAssertEqual(value.arguments.last, "$(not-a-shell) `literal` ; sample")
            XCTAssertEqual(value.environment["HOME"], value.profile.home.path)
            XCTAssertEqual(value.environment["CODEX_HOME"], value.profile.config.path)
            XCTAssertNil(value.environment["OPENAI_API_KEY"]); XCTAssertNil(value.environment["AGENTWATCH_STUDIO_KEY"])
            let key = "as_live_synthetic_fixture"
            let env = try value.credentialEnvironment(key)
            XCTAssertEqual(env[provider == .claude ? "ANTHROPIC_API_KEY" : "AGENTWATCH_STUDIO_KEY"], key)
            XCTAssertFalse(value.arguments.joined().contains(key)); XCTAssertFalse(String(describing: value).contains(key))
            XCTAssertFalse(value.arguments.contains("--dangerously-skip-permissions"))
            XCTAssertFalse(value.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
            XCTAssertThrowsError(try value.credentialEnvironment("bad\nkey"))
        }
    }
    func testUnknownVersionFailsBeforeAnyCredentialIsPassed() async throws {
        let root = try temporary(), binary = try fake(root, text: "#!/bin/sh\nif [ -n \"$ANTHROPIC_API_KEY$AGENTWATCH_STUDIO_KEY$OPENAI_API_KEY\" ]; then exit 9; fi\nprintf 'unqualified-version\\n'\n")
        let value = try plan(.claude, root: root, binary: binary)
        do { try await StudioCLIPreflight.verify(value); XCTFail() } catch { XCTAssertEqual(error as? StudioCLIError, .unsupportedVersion) }
    }
    func testActualNativeCLIConfigurationPreflight() async throws {
        guard ProcessInfo.processInfo.environment["STUDIO_TEST_NATIVE_CLI"] == "1" else { throw XCTSkip("opt in to installed standalone CLI checks") }
        for provider in StudioCLIProvider.allCases {
            let root = try temporary(), value = try plan(provider, root: root, binary: URL(fileURLWithPath: "/opt/homebrew/bin/\(provider.rawValue)"))
            do { try await StudioCLIPreflight.verify(value) }
            catch { XCTFail("\(provider.rawValue) preflight: \(error)"); continue }
            if provider == .codex {
                // Native CLI is allowed to persist trust/preferences. The launcher
                // keeps them and verifies the actual merged configuration instead.
                var config = try String(contentsOf: value.profile.configFile, encoding: .utf8)
                config += "\n[projects.\(StudioCLIProfiles.quoted(root.path))]\ntrust_level = \"trusted\"\n"
                try Data(config.utf8).write(to: value.profile.configFile)
                _ = try StudioCLIProfiles.prepare(connection: connection(), provider: provider, directory: root.appendingPathComponent("profiles"))
                let projectConfig = root.appendingPathComponent(".codex")
                try FileManager.default.createDirectory(at: projectConfig, withIntermediateDirectories: true)
                try Data("""
                model = "wrong-model"
                model_provider = "wrong-provider"
                [model_providers.agent_studio]
                name = "Wrong provider"
                base_url = "https://wrong.invalid/v1"
                env_key = "WRONG_KEY"
                requires_openai_auth = true
                wire_api = "responses"

                """.utf8).write(to: projectConfig.appendingPathComponent("config.toml"))
                try await StudioCLIPreflight.verify(value)
                config = "notify = [\"/usr/bin/false\"]\n" + config
                try Data(config.utf8).write(to: value.profile.configFile)
                do { try await StudioCLIPreflight.verify(value); XCTFail("Unexpected notify accepted") }
                catch { XCTAssertEqual(error as? StudioCLIError, .incompatibleConfiguration) }
            }
        }
    }
}
