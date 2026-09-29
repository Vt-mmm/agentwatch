#if DEBUG
import Foundation
import AgentWatchCore

// Explicit local acceptance entry point, never part of distributed products.
// Raw key arrives only on stdin. Config files contain a helper reference only.
enum StudioLocalAcceptance {
    @MainActor static func run(arguments: [String]) async {
        do {
            let args = arguments
            guard args.count == 2 else { throw StudioConfigurationError.invalid }
            let stateFile = URL(fileURLWithPath: args[1])
            let settings = StudioPreferences(defaults: StudioPreferences.applicationDefaults)
            let keys = StudioKeychainStorage()
            if args[0] == "cleanup" {
                let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
                try keys.delete(profileID: state.current.id)
                if try settings.load()?.id == state.current.id { settings.save(state.previous) }
                try FileManager.default.removeItem(at: stateFile); print("cleanup_ok"); return
            }
            guard args[0] == "prepare" else { throw StudioConfigurationError.invalid }
            let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
            guard input.origin == "http://127.0.0.1:17922", let tool = StudioConfiguredTool(rawValue: input.tool) else { throw StudioConfigurationError.invalid }
            let origin = try StudioOrigin(input.origin)
            let result = try await StudioClient().connect(origin: origin, key: input.key)
            guard case .available(let models) = result.models, let model = models.first(where: {$0.id == input.model}) else { throw StudioConfigurationError.invalid }
            let profile = try StudioProfile(origin: origin, id: origin.profileID(orgID: result.identity.orgID, ownerID: result.identity.user.id))
            let state = State(previous: try settings.load(), current: profile)
            guard !FileManager.default.fileExists(atPath: stateFile.path) else { throw StudioConfigurationError.changed }
            let stateData = try JSONEncoder().encode(state)
            guard FileManager.default.createFile(atPath: stateFile.path, contents: stateData, attributes: [.posixPermissions: 0o600]) else { throw StudioConfigurationError.unsafe }
            try keys.save(input.key, profileID: profile.id); settings.save(profile)
            let catalog = tool == .pi ? try StudioClientConfiguration.catalogModel(for: model, piExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/pi")) : nil
            let plan = try StudioClientConfiguration.prepare(tool: tool, directory: URL(fileURLWithPath: input.directory), connection: profile, model: model, helper: URL(fileURLWithPath: CommandLine.arguments[0]), piCatalogModel: catalog)
            try StudioClientConfiguration.apply(plan)
            print("prepared_\(input.tool)_\(model.ownedBy)_context_provider_default")
        } catch { FileHandle.standardError.write(Data("Configuration acceptance failed: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    struct Input: Decodable { let origin, key, tool, model, directory: String }
    struct State: Codable { let previous: StudioProfile?; let current: StudioProfile }
}

#endif
