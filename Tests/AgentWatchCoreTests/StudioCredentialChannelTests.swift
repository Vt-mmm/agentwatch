import XCTest
@testable import AgentWatchCore

final class StudioCredentialChannelTests: XCTestCase {
    private var directories: [URL] = []
    private func socketPath() -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("awc-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directories.append(directory)
        return directory.appendingPathComponent("s").path
    }

    override func tearDownWithError() throws { for directory in directories { try? FileManager.default.removeItem(at: directory) } }

    func testRunningAppHandsTheSavedKeyOnlyForItsProfile() throws {
        let path = socketPath()
        let server = StudioCredentialServer(path: path) { $0 == "profile-a" ? "as_live_synthetic_fixture" : nil }
        XCTAssertTrue(server.start())
        defer { server.stop() }
        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "socket must be private to the user")
        XCTAssertEqual(StudioCredentialChannel.request(profileID: "profile-a", path: path), "as_live_synthetic_fixture")
        XCTAssertNil(StudioCredentialChannel.request(profileID: "profile-b", path: path))
        XCTAssertNil(StudioCredentialChannel.request(profileID: "bad id\nx", path: path), "request line cannot be injected")
    }

    func testMissingAppFailsFastSoTheHelperCanFallBack() {
        let started = Date()
        XCTAssertNil(StudioCredentialChannel.request(profileID: "profile-a", path: socketPath(), timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testInvalidKeyFromProviderIsNeverServed() {
        let path = socketPath()
        let server = StudioCredentialServer(path: path) { _ in "not a key\nok as_live_x" }
        XCTAssertTrue(server.start())
        defer { server.stop() }
        XCTAssertNil(StudioCredentialChannel.request(profileID: "profile-a", path: path))
    }

    func testStopRemovesTheSocket() {
        let path = socketPath()
        let server = StudioCredentialServer(path: path) { _ in nil }
        XCTAssertTrue(server.start())
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testContenderCannotTakeOverOrRemoveOwnerForEitherStopOrder() {
        for contenderFirst in [true, false] {
            let path = socketPath()
            let owner = StudioCredentialServer(path: path) { _ in "as_live_owner_fixture" }
            let contender = StudioCredentialServer(path: path) { _ in "as_live_contender_fixture" }
            XCTAssertTrue(owner.start()); XCTAssertFalse(contender.start())
            if contenderFirst { contender.stop() }
            XCTAssertEqual(StudioCredentialChannel.request(profileID: "a", path: path), "as_live_owner_fixture")
            owner.stop(); contender.stop()
            XCTAssertTrue(contender.start())
            XCTAssertEqual(StudioCredentialChannel.request(profileID: "a", path: path), "as_live_contender_fixture")
            contender.stop()
        }
    }

    func testStopDoesNotRemoveReplacementPathAndLockInodePersists() throws {
        let path = socketPath()
        let owner = StudioCredentialServer(path: path) { _ in nil }
        XCTAssertTrue(owner.start())
        var before = stat(); XCTAssertEqual(lstat(path + ".lock", &before), 0)
        XCTAssertEqual(unlink(path), 0)
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: path))
        owner.stop()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "replacement")
        var after = stat(); XCTAssertEqual(lstat(path + ".lock", &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertFalse(owner.start(), "a non-socket must not be deleted")
    }

    func testSymlinkLockIsRejectedWithoutTouchingTarget() throws {
        let path = socketPath(), target = path + ".target"
        try Data("sentinel".utf8).write(to: URL(fileURLWithPath: target))
        XCTAssertEqual(symlink(target, path + ".lock"), 0)
        let server = StudioCredentialServer(path: path) { _ in nil }
        XCTAssertFalse(server.start())
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "sentinel")
    }

    /// Executed only by our child xctest process; no real app or key is used.
    func testChildFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["AW_CHANNEL_FIXTURE"] else { return }
        let server = StudioCredentialServer(path: path) { _ in "as_live_child_fixture" }
        let ready = server.start()
        try Data((ready ? "owner" : "contender").utf8).write(to: URL(fileURLWithPath: path + ".ready"))
        _ = FileHandle.standardInput.readDataToEndOfFile()
        server.stop()
    }

    private func child(_ path: String) throws -> (Process, Pipe) {
        try? FileManager.default.removeItem(atPath: path + ".ready")
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "AgentWatchCoreTests.StudioCredentialChannelTests/testChildFixture", Bundle(for: Self.self).bundlePath]
        process.environment = ["PATH": "/usr/bin:/bin", "AW_CHANNEL_FIXTURE": path]
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: path + ".ready"), process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard FileManager.default.fileExists(atPath: path + ".ready") else {
            if process.isRunning { process.terminate() }; process.waitUntilExit()
            throw NSError(domain: "child fixture did not start", code: Int(process.terminationStatus))
        }
        return (process, input)
    }

    func testSeparateProcessesRespectLeaseAndRecoverAfterCrash() throws {
        let path = socketPath()
        let (owner, ownerInput) = try child(path)
        defer { if owner.isRunning { kill(owner.processIdentifier, SIGKILL); owner.waitUntilExit() }; try? ownerInput.fileHandleForWriting.close() }
        XCTAssertEqual(try String(contentsOfFile: path + ".ready", encoding: .utf8), "owner")
        let (contender, contenderInput) = try child(path)
        defer { if contender.isRunning { kill(contender.processIdentifier, SIGKILL); contender.waitUntilExit() } }
        XCTAssertEqual(try String(contentsOfFile: path + ".ready", encoding: .utf8), "contender")
        try contenderInput.fileHandleForWriting.close(); contender.waitUntilExit()
        XCTAssertEqual(StudioCredentialChannel.request(profileID: "a", path: path), "as_live_child_fixture")
        kill(owner.processIdentifier, SIGKILL); owner.waitUntilExit()
        let replacement = StudioCredentialServer(path: path) { _ in "as_live_recovered_fixture" }
        XCTAssertTrue(replacement.start())
        defer { replacement.stop() }
        XCTAssertEqual(StudioCredentialChannel.request(profileID: "a", path: path), "as_live_recovered_fixture")
    }
}
