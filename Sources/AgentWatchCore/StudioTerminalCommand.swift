import Foundation

/// A one-use Terminal file. Contains only public launch arguments, never a key
/// or prompt. The bundled helper reads the pinned active profile at execution.
public struct StudioTerminalCommand: Sendable {
    public let url: URL
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentWatch/StudioLaunches", isDirectory: true)
    }
    public static func validateProfile(_ connection: StudioProfile, expectedID: String?) throws {
        if let expectedID, connection.id != expectedID { throw StudioError.identityChanged }
    }
    public static func create(plan: StudioCLILaunchPlan, helper: URL, directory: URL = directory) throws -> StudioTerminalCommand {
        guard helper.isFileURL, FileManager.default.isExecutableFile(atPath: helper.path),
              (try? helper.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              !helper.path.contains("\u{0}"), plan.prompt == nil else { throw StudioCLIError.helperMissing }
        let root = directory.appendingPathComponent(plan.profile.connection.id, isDirectory: true)
        try StudioCLIProfiles.privateDirectory(directory); try StudioCLIProfiles.privateDirectory(root)
        let file = root.appendingPathComponent(UUID().uuidString.lowercased() + ".command")
        var args = [helper.path, "run", plan.profile.provider.rawValue, "--profile", plan.profile.connection.id,
                    "--model", plan.model.id, "--project", plan.project.path, "--binary", plan.executable.url.path]
        if let resume = plan.resumeID { args += ["--resume", resume.uuidString.lowercased()] }
        let script = "#!/bin/sh\n# Agent Watch Studio: no credentials in this file.\numask 077\n/bin/rm -f -- \(quote(file.path))\nexec \(args.map(quote).joined(separator: " "))\n"
        try Data(script.utf8).write(to: file, options: [.withoutOverwriting])
        do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        return StudioTerminalCommand(url: file)
    }
    /// Used only if Launch Services failed to hand the file to Terminal.
    public func discard() { try? FileManager.default.removeItem(at: url) }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}
