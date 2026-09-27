import Foundation
import AgentWatchCore

// Test-only entry point: no production environment-key fallback. The Go fixture
// supplies a temporary database key and confines this process to its gateway.
@main struct StudioCLIProbe {
    static func main() async {
        do {
            let env = ProcessInfo.processInfo.environment
            guard let raw = env["STUDIO_FIXTURE_ORIGIN"], raw.hasPrefix("http://127.0.0.1:"),
                  let key = env["STUDIO_FIXTURE_KEY"], let directory = env["STUDIO_FIXTURE_DIRECTORY"],
                  let provider = env["STUDIO_FIXTURE_PROVIDER"].flatMap(StudioCLIProvider.init(rawValue:)),
                  let binary = env["STUDIO_FIXTURE_BINARY"] else { throw StudioCLIError.invalidArguments }
            let origin = try StudioOrigin(raw), result = try await StudioClient().connect(origin: origin, key: key)
            guard case .available(let models) = result.models, let model = models.first(where: { $0.id == "studio-model" }) else { throw StudioError.invalidResponse }
            let identity = try StudioProfile(origin: origin, id: origin.profileID(orgID: result.identity.orgID, ownerID: result.identity.user.id))
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            let profile = try StudioCLIProfiles.prepare(connection: identity, provider: provider, directory: root.appendingPathComponent("profiles", isDirectory: true))
            let executable = try StudioCLIExecutable.resolve(provider, explicit: URL(fileURLWithPath: binary))
            let resume = env["STUDIO_FIXTURE_RESUME"].flatMap(UUID.init(uuidString:))
            let plan = try StudioCLILaunchPlan(executable: executable, profile: profile, project: root.appendingPathComponent("project"), model: model, resumeID: resume, prompt: resume == nil ? "Return STUDIO_FIXTURE_OK." : "Continue with STUDIO_RESUME_QUESTION.")
            try await StudioCLIPreflight.verify(plan)
            if CommandLine.arguments.contains("--check") { print("PASS keyless native configuration preflight; no inference"); return }
            try plan.execute(key: key)
        } catch {
            // Never dump native output, config, request data or keys.
            let message = (error as? StudioCLIError)?.rawValue ?? (error as? StudioError)?.rawValue ?? "fixtureFailed"
            FileHandle.standardError.write(Data(("launcher fixture: " + message + "\n").utf8))
            exit(1)
        }
    }
}
