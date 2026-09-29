#if DEBUG
import Foundation
import AppKit
import Carbon
import ServiceManagement
import AgentWatchCore

// Explicit local acceptance entry point, never part of distributed products.
// Raw key arrives only on stdin. Config files contain a helper reference only.
enum StudioLocalAcceptance {
    @MainActor static func run(arguments: [String]) async {
        do {
            let args = arguments
            if args == ["lifecycle"] {
                let suite = "watch-lifecycle-qa-" + UUID().uuidString
                let isolated = UserDefaults(suiteName: suite)!
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
                defer { isolated.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
                isolated.set(true, forKey: "supervisor.lock.enabled")
                isolated.set("retired-enrollment", forKey: "supervisor.lock.byLabel")
                let lifecycle = SupervisorLockStore(defaults: isolated, directory: directory)
                guard !lifecycle.isLocked, lifecycle.reportIdentity != nil,
                      isolated.object(forKey: "supervisor.lock.enabled") == nil,
                      isolated.object(forKey: "supervisor.lock.byLabel") == nil,
                      lifecycle.shouldTerminate(source: "isolated QA") == .terminateNow else { throw StudioConfigurationError.invalid }
                let delegate = AgentWatchAppDelegate()
                guard !delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
                      !AgentWatchAppDelegate.isLoginLaunch(nil) else { throw StudioConfigurationError.invalid }
                let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
                    targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                guard !AgentWatchAppDelegate.isLoginLaunch(event) else { throw StudioConfigurationError.invalid }
                event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
                guard AgentWatchAppDelegate.isLoginLaunch(event) else { throw StudioConfigurationError.invalid }
                print("lifecycle_verified_no_enrollment_unrestricted_quit_background_close_login_detection")
                return
            }
            if args == ["background-status"] {
                switch SMAppService.mainApp.status {
                case .enabled: print("login_item_enabled")
                case .requiresApproval: print("login_item_requires_approval")
                case .notRegistered: print("login_item_not_registered")
                default: print("login_item_unavailable")
                }
                return
            }
            guard args.count == 2 else { throw StudioConfigurationError.invalid }
            let stateFile = URL(fileURLWithPath: args[1])
            let settings = StudioPreferences(defaults: StudioPreferences.applicationDefaults)
            let keys = StudioKeychainStorage()
            if args[0] == "verify-sync" {
                let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
                let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
                guard let target = StudioSyncTarget(rawValue: input.tool), input.origin == "http://127.0.0.1:17922" else { throw StudioConfigurationError.invalid }
                let suite = "com.vtamm.agentwatch.studio.qa." + state.current.id
                guard let isolated = UserDefaults(suiteName: suite) else { throw StudioConfigurationError.invalid }
                defer { isolated.removePersistentDomain(forName: suite) }
                StudioPreferences(defaults: isolated).save(state.current)
                let sync = StudioSyncStore(defaults: isolated)
                sync.selected = [target]; sync.directories = [target.rawValue: input.directory]; sync.enabled = true
                await sync.synchronize(helper: URL(fileURLWithPath: CommandLine.arguments[0]))
                guard sync.results.count == 1, sync.results.allSatisfy(\.success) else { throw StudioConfigurationError.invalid }
                let receipt = StudioClientConfiguration.receiptURL(tool: target.tool, directory: URL(fileURLWithPath: input.directory))
                defer { try? FileManager.default.removeItem(at: receipt) }
                let first = try Data(contentsOf: receipt)
                let at = try receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                await sync.synchronize(helper: URL(fileURLWithPath: CommandLine.arguments[0]))
                guard sync.results.allSatisfy(\.success), try Data(contentsOf: receipt) == first,
                      try receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == at else { throw StudioConfigurationError.changed }
                print("sync_verified_unchanged_files"); return
            }
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
            let plan: StudioConfigurationPlan
            if input.all == true {
                let manifest = try await StudioClient().configuration(origin: origin, key: input.key)
                try manifest.validate(profile: profile)
                var native: [String: Data] = [:]
                if tool == .pi { for item in manifest.models { native[item.id] = try StudioClientConfiguration.catalogModel(for: item, piExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/pi")) } }
                plan = try StudioClientConfiguration.prepareAll(tool: tool, directory: URL(fileURLWithPath: input.directory), connection: profile, models: manifest.models, helper: URL(fileURLWithPath: CommandLine.arguments[0]), codexCatalog: JSONEncoder().encode(manifest.codexCatalog), piCatalogModels: native)
            } else {
                plan = try StudioClientConfiguration.prepare(tool: tool, directory: URL(fileURLWithPath: input.directory), connection: profile, model: model, helper: URL(fileURLWithPath: CommandLine.arguments[0]), piCatalogModel: catalog)
            }
            try StudioClientConfiguration.apply(plan)
            print("prepared_\(input.tool)_\(model.ownedBy)_context_provider_default")
        } catch { FileHandle.standardError.write(Data("Configuration acceptance failed: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    struct Input: Decodable { let origin, key, tool, model, directory: String; let all: Bool? }
    struct State: Codable { let previous: StudioProfile?; let current: StudioProfile }
}

#endif
