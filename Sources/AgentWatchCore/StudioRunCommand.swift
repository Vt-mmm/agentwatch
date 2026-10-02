import Foundation

@MainActor public struct StudioRunCommand {
    private let arguments: [String]
    private let settings: any StudioSettingsStorage
    private let keys: any StudioKeyStorage
    private let client: any StudioConnecting
    private let directory: URL
    private let preflight: (StudioCLILaunchPlan) async throws -> Void
    private let execute: (StudioCLILaunchPlan, String) throws -> Void

    public init(arguments: [String]) {
        self.init(arguments: arguments,
                  settings: StudioPreferences(defaults: UserDefaults(suiteName: "com.vtamm.claudewatch.ClaudeWatchMac")!),
                  keys: StudioKeychainStorage(), client: StudioClient(), directory: StudioCLIProfiles.directory)
    }
    // Dependency injection is internal for isolated tests, never a CLI flag or
    // environment override that can redirect the production Keychain namespace.
    init(arguments: [String], settings: any StudioSettingsStorage, keys: any StudioKeyStorage,
         client: any StudioConnecting, directory: URL,
         preflight: @escaping (StudioCLILaunchPlan) async throws -> Void = { try await StudioCLIPreflight.verify($0) },
         execute: @escaping (StudioCLILaunchPlan, String) throws -> Void = { try $0.execute(key: $1) }) {
        self.arguments = arguments; self.settings = settings; self.keys = keys; self.client = client
        self.directory = directory; self.preflight = preflight; self.execute = execute
    }
    public func run() async -> Int32 {
        if arguments.isEmpty || arguments == ["--help"] || (arguments.count == 2 && StudioCLIProvider(rawValue: arguments[0]) != nil && arguments[1] == "--help") {
            print("""
            agentwatch run claude|codex --model ID [--project PATH] [--binary PATH]
                                       [--runtime-node PATH] [--resume UUID] [--print TEXT] [--check] [--profile ID]

            Kết nối Studio bằng key nhân viên trong app Mac trước khi chạy.
            --check chỉ kiểm tra kết nối/CLI/profile; không gửi inference.
            Không nhận key hoặc tham số cấu hình CLI tùy ý trên dòng lệnh.
            Profile công ty giữ HOME/config riêng; dùng đúng phiên bản CLI đã kiểm chứng.
            """)
            return 0
        }
        do {
            guard let provider = StudioCLIProvider(rawValue: arguments[0]) else { throw StudioCLIError.invalidArguments }
            var values: [String: String] = [:], check = false, index = 1
            while index < arguments.count {
                let option = arguments[index]
                if option == "--check" { guard !check else { throw StudioCLIError.invalidArguments }; check = true; index += 1; continue }
                guard ["--model", "--project", "--binary", "--runtime-node", "--resume", "--print", "--profile"].contains(option), values[option] == nil, index + 1 < arguments.count else { throw StudioCLIError.invalidArguments }
                values[option] = arguments[index + 1]; index += 2
            }
            let resume = values["--resume"].flatMap(UUID.init(uuidString:))
            if values["--resume"] != nil && resume == nil { throw StudioCLIError.invalidArguments }
            guard let modelID = values["--model"], let connection = try settings.load() else { throw StudioError.invalidKey }
            guard connection.credentialMode == .direct else { throw StudioError.permissionDenied }
            try StudioTerminalCommand.validateProfile(connection, expectedID: values["--profile"])
            guard let key = try keys.load(profileID: connection.id) else { throw StudioError.invalidKey }
            let identity = try await client.connect(origin: connection.origin, key: key)
            guard connection.matches(identity.identity) else { throw StudioError.identityChanged }
            guard case .available(let models) = identity.models, let model = models.first(where: { $0.id == modelID && $0.ownedBy == provider.rawValue }) else { throw StudioError.permissionDenied }
            let executable = try StudioCLIExecutable.resolve(provider, explicit: values["--binary"].map { URL(fileURLWithPath: $0) }, node: values["--runtime-node"].map { URL(fileURLWithPath: $0) })
            let profile = try StudioCLIProfiles.prepare(connection: connection, provider: provider, directory: directory)
            let plan = try StudioCLILaunchPlan(executable: executable, profile: profile, project: URL(fileURLWithPath: values["--project"] ?? FileManager.default.currentDirectoryPath), model: model, resumeID: resume, prompt: values["--print"])
            try await preflight(plan)
            // A Terminal handoff/preflight can outlive an app disconnect or key
            // rotation. Do not launch from the stale credential read above.
            if check {
                guard try settings.load() == connection,
                      try keys.load(profileID: connection.id) == key else { throw StudioError.identityChanged }
                print("Đã kiểm tra \(provider.rawValue) · \(provider.qualifiedVersion) · model \(model.id) · chưa gửi inference.")
                return 0
            }
            let registry = StudioProcessRegistry(directory: directory)
            return try registry.withLaunchLock(connection: connection) {
                // Disconnect uses this same short lock around its key/profile
                // removal. A successful exec closes it before native CLI work.
                guard try settings.load() == connection, try keys.load(profileID: connection.id) == key else { throw StudioError.identityChanged }
                let process = try registry.register(plan: plan)
                defer { try? registry.remove(process) } // exec success never returns.
                try execute(plan, key)
                return 0
            }
        } catch {
            let message = (error as? StudioError)?.localizedDescription ?? (error as? StudioCLIError)?.localizedDescription ?? "Không chuẩn bị được profile CLI Studio."
            FileHandle.standardError.write(Data((message + "\n").utf8)); return 1
        }
    }
}
