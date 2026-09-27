import AppKit
@testable import AgentWatchCore

// Explicit, opt-in Launch Services smoke. Opens one real Terminal window with
// an inert fixture executable, no Keychain access or provider/network requests.
@main struct StudioTerminalProbe {
    @MainActor static func main() async {
        do { try await verify() }
        catch { FileHandle.standardError.write(Data("FAIL Terminal fixture handoff\n".utf8)); exit(1) }
    }
    @MainActor private static func verify() async throws {
        guard CommandLine.arguments.contains("--open-terminal") else { throw StudioCLIError.invalidArguments }
        let base = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(base) }
        let root = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("studio-terminal-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("fixture-helper"), receipt = root.appendingPathComponent("receipt")
        let script = "#!/bin/sh\n/usr/bin/printf '%s\\0' \"$@\" > \(StudioTerminalCommand.quote(receipt.path))\n"
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let connection = try StudioProfile(origin: StudioOrigin("https://studio.example"), id: String(repeating: "a", count: 64))
        let profile = try StudioCLIProfiles.prepare(connection: connection, provider: .claude, directory: root.appendingPathComponent("profiles"))
        let plan = try StudioCLILaunchPlan(executable: StudioCLIExecutable.resolve(.claude, explicit: helper), profile: profile, project: root,
                                          model: StudioModel(id: "fixture-model", displayName: "Fixture", ownedBy: "claude", nativeProtocol: "messages"))
        let command = try StudioTerminalCommand.create(plan: plan, helper: helper, directory: root.appendingPathComponent("launches"))
        try await StudioTerminalOpener.open(command, activate: false)
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: receipt), !data.isEmpty {
                let args = String(decoding: data, as: UTF8.self).split(separator: "\u{0}").map(String.init)
                guard args == ["run", "claude", "--profile", connection.id, "--model", "fixture-model", "--project", plan.project.path, "--binary", plan.executable.url.path],
                      !FileManager.default.fileExists(atPath: command.url.path) else { throw StudioCLIError.processFailed }
                print("PASS real Terminal/Launch Services: pinned literal arguments and self-deleting command; no credentials or inference")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw StudioCLIError.terminalFailed
    }
}
