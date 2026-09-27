import Foundation
import Darwin

public enum StudioCLIError: String, Error, LocalizedError, Sendable {
    case binaryMissing, desktopBinary, unsupportedVersion, unsafePath, changedProfile, managedSettings, incompatibleConfiguration, processFailed, invalidArguments
    public var errorDescription: String? {
        switch self {
        case .binaryMissing: "Không tìm thấy CLI độc lập. Chọn đường dẫn Claude Code hoặc Codex CLI đã cài."
        case .desktopBinary: "Không dùng binary bên trong ứng dụng desktop cho profile công ty."
        case .unsupportedVersion: "Phiên bản CLI chưa được kiểm chứng với Studio. Cần kiểm tra tương thích trước khi chạy."
        case .unsafePath: "Đường dẫn project/profile không an toàn hoặc không truy cập được."
        case .changedProfile: "Cấu hình profile công ty đã thay đổi ngoài Agent Watch. Kiểm tra lại trước khi chạy; file hiện có được giữ nguyên."
        case .managedSettings: "Máy có cấu hình Claude do tổ chức quản lý chưa được kiểm chứng với launcher. Cần đối chiếu cấu hình đó; launcher không sửa hay bỏ qua policy quản lý."
        case .incompatibleConfiguration: "Cấu hình CLI thực tế không khớp endpoint, model hoặc quyền chạy của profile Studio. Chưa gửi key cho CLI."
        case .processFailed: "Không khởi chạy hoặc xác minh được CLI."
        case .invalidArguments: "Tham số launcher không hợp lệ. Dùng agentwatch run --help để xem cách dùng."
        }
    }
}
public enum StudioCLIProvider: String, Codable, Sendable, CaseIterable {
    case claude, codex
    public var qualifiedVersion: String { self == .claude ? "2.1.181 (Claude Code)" : "codex-cli 0.155.1" }
    public var nativeProtocol: String { self == .claude ? "messages" : "responses" }
}

public struct StudioCLIExecutable: Sendable {
    public let url: URL
    public let provider: StudioCLIProvider
    public static func resolve(_ provider: StudioCLIProvider, explicit: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> StudioCLIExecutable {
        var candidates: [URL] = []
        if let explicit { candidates = [explicit] }
        else {
            candidates = [home.appendingPathComponent(".local/bin/\(provider.rawValue)"), URL(fileURLWithPath: "/opt/homebrew/bin/\(provider.rawValue)"), URL(fileURLWithPath: "/usr/local/bin/\(provider.rawValue)")]
        }
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard candidate.isFileURL else { throw StudioCLIError.unsafePath }
            if (candidate.pathComponents + resolved.pathComponents).contains(where: { $0.lowercased().hasSuffix(".app") }) {
                if explicit != nil { throw StudioCLIError.desktopBinary }; continue
            }
            var executable = resolved
            // The npm JS entrypoint delegates to this packaged native CLI. Avoid
            // requiring a global Node runtime and never search inside desktop apps.
            if provider == .codex && resolved.lastPathComponent == "codex.js" {
                #if arch(arm64)
                let package = "codex-darwin-arm64", triple = "aarch64-apple-darwin"
                #else
                let package = "codex-darwin-x64", triple = "x86_64-apple-darwin"
                #endif
                executable = resolved.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("node_modules/@openai/\(package)/vendor/\(triple)/bin/codex").resolvingSymlinksInPath()
            }
            guard !executable.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else { throw StudioCLIError.desktopBinary }
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            return StudioCLIExecutable(url: executable, provider: provider)
        }
        throw StudioCLIError.binaryMissing
    }
}

public struct StudioCLIProfile: Codable, Equatable, Sendable {
    public let version: Int
    public let connection: StudioProfile
    public let provider: StudioCLIProvider
    public let root: URL
    public var home: URL { root.appendingPathComponent("home") }
    public var config: URL { root.appendingPathComponent("config") }
    public var temporary: URL { root.appendingPathComponent("tmp") }
    public var logRoot: URL { config.appendingPathComponent(provider == .claude ? "projects" : "sessions") }
    public var configFile: URL { config.appendingPathComponent(provider == .claude ? "settings.json" : "config.toml") }
}

public enum StudioCLIProfiles {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentWatch/StudioProfiles")
    }
    public static func prepare(connection: StudioProfile, provider: StudioCLIProvider, directory: URL = directory) throws -> StudioCLIProfile {
        guard directory.isFileURL else { throw StudioCLIError.unsafePath }
        let root = directory.appendingPathComponent(connection.id, isDirectory: true).appendingPathComponent(provider.rawValue, isDirectory: true)
        let profile = StudioCLIProfile(version: 1, connection: connection, provider: provider, root: root)
        for path in [directory, root.deletingLastPathComponent(), root, profile.home, profile.config, profile.temporary] { try privateDirectory(path) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let manifest = try encoder.encode(profile)
        let config = Data(configuration(profile).utf8)
        try managedFile(root.appendingPathComponent("profile.json"), expected: manifest)
        // Codex records workspace trust/preferences in its own config. Preserve
        // those writes and validate the merged native configuration before launch.
        try managedFile(profile.configFile, expected: config, exact: provider == .claude)
        return profile
    }
    public static func configuration(_ profile: StudioCLIProfile) -> String {
        if profile.provider == .claude { return "{}\n" }
        return """
        model_provider = "agent_studio"
        check_for_update_on_startup = false
        cli_auth_credentials_store = "file"
        allow_login_shell = false
        web_search = "disabled"
        [analytics]
        enabled = false
        [feedback]
        enabled = false
        [features]
        shell_snapshot = false
        multi_agent = false
        apps = false
        remote_plugin = false
        hooks = false
        enable_request_compression = false
        [model_providers.agent_studio]
        name = "Agent Studio"
        base_url = \(quoted(profile.connection.origin.value + "/v1"))
        env_key = "AGENTWATCH_STUDIO_KEY"
        requires_openai_auth = false
        wire_api = "responses"
        request_max_retries = 0
        stream_max_retries = 0

        """
    }
    static func quoted(_ string: String) -> String {
        let encoder = JSONEncoder()
        // TOML basic strings accept JSON escapes except the optional slash escape.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: try! encoder.encode(string), encoding: .utf8)!
    }
    static func privateDirectory(_ url: URL) throws {
        // Refuse redirected components before creating anything under the managed root.
        guard !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw StudioCLIError.unsafePath }
        // Foundation's standardizedFileURL rewrites /private/var to /var on
        // macOS, reintroducing a symlink even after realpath canonicalization.
        var component = url
        while component.path != "/" {
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw StudioCLIError.unsafePath }
            component.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static func managedFile(_ url: URL, expected: Data, exact: Bool = true) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw StudioCLIError.unsafePath }
        if FileManager.default.fileExists(atPath: url.path) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576 else { throw StudioCLIError.changedProfile }
            if exact {
                guard size == expected.count else { throw StudioCLIError.changedProfile }
                guard try Data(contentsOf: url) == expected else { throw StudioCLIError.changedProfile }
            }
        } else { try expected.write(to: url, options: [.withoutOverwriting]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct StudioCLILaunchPlan: Sendable, CustomStringConvertible {
    public let executable: StudioCLIExecutable
    public let profile: StudioCLIProfile
    public let project: URL
    public let model: StudioModel
    public let resumeID: UUID?
    public let prompt: String?
    public var description: String { "StudioCLILaunchPlan(provider: \(executable.provider.rawValue), credentials: omitted)" }
    public init(executable: StudioCLIExecutable, profile: StudioCLIProfile, project: URL, model: StudioModel, resumeID: UUID? = nil, prompt: String? = nil) throws {
        guard executable.provider == profile.provider, model.ownedBy == profile.provider.rawValue, model.nativeProtocol == profile.provider.nativeProtocol,
              !model.id.isEmpty, model.id.utf8.count <= 160, !model.id.contains(where: { $0.isNewline || $0.asciiValue == 0 }),
              project.isFileURL, (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              !project.path.contains("\u{0}"), prompt?.contains("\u{0}") != true else { throw StudioCLIError.invalidArguments }
        self.executable = executable; self.profile = profile; self.project = project.resolvingSymlinksInPath()
        self.model = model; self.resumeID = resumeID; self.prompt = prompt
    }
    public var environment: [String: String] {
        ["HOME": profile.home.path, "TMPDIR": profile.temporary.path, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color", "SHELL": "/bin/zsh",
         "CODEX_HOME": profile.config.path, "CLAUDE_CONFIG_DIR": profile.config.path,
         "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
         "ANTHROPIC_BASE_URL": profile.connection.origin.value, "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "32000"]
    }
    public var codexOverrides: [String] {
        let pairs = ["model=" + StudioCLIProfiles.quoted(model.id), "model_provider=\"agent_studio\"", "sandbox_mode=\"workspace-write\"", "approval_policy=\"on-request\"", "sandbox_workspace_write.network_access=false", "allow_login_shell=false", "web_search=\"disabled\"", "check_for_update_on_startup=false", "analytics.enabled=false", "feedback.enabled=false", "features.shell_snapshot=false", "features.multi_agent=false", "features.apps=false", "features.remote_plugin=false", "features.hooks=false", "features.enable_request_compression=false", "model_providers.agent_studio={name=\"Agent Studio\",base_url=\(StudioCLIProfiles.quoted(profile.connection.origin.value + "/v1")),env_key=\"AGENTWATCH_STUDIO_KEY\",requires_openai_auth=false,wire_api=\"responses\",request_max_retries=0,stream_max_retries=0}", "shell_environment_policy={inherit=\"core\",ignore_default_excludes=false,experimental_use_profile=false,exclude=[\"*KEY*\",\"*TOKEN*\",\"*SECRET*\"]}"]
        return pairs.flatMap { ["-c", $0] }
    }
    public var arguments: [String] {
        if profile.provider == .claude {
            var args = ["--bare", "--setting-sources", "", "--settings", profile.configFile.path, "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--disable-slash-commands", "--no-chrome", "--permission-mode", "default", "--model", model.id]
            if let resumeID { args += ["--resume", resumeID.uuidString.lowercased()] }
            if let prompt { args += ["--print", "--output-format", "json", "--", prompt] }
            return args
        }
        var args = codexOverrides
        if let prompt {
            args += ["exec", "--skip-git-repo-check", "--json"]
            if let resumeID { args += ["resume", resumeID.uuidString.lowercased()] }
            args += ["--", prompt]
        } else if let resumeID { args += ["resume", resumeID.uuidString.lowercased()] }
        return args
    }
    public func credentialEnvironment(_ key: String) throws -> [String: String] {
        guard StudioClient.validKey(key) else { throw StudioError.invalidKey }
        var result = environment
        result[profile.provider == .claude ? "ANTHROPIC_API_KEY" : "AGENTWATCH_STUDIO_KEY"] = key
        return result
    }
    /// Replaces the launcher process so stdin, terminal and signals remain native.
    /// The key is never part of argv or a shell command; the child environment is
    /// still readable by the same macOS user and is not a hostile-code sandbox.
    public func execute(key: String) throws -> Never {
        let env = try credentialEnvironment(key)
        guard chdir(project.path) == 0 else { throw StudioCLIError.unsafePath }
        umask(0o077)
        let argv = ([executable.url.path] + arguments).map { strdup($0) } + [nil]
        let envp = env.keys.sorted().map { strdup($0 + "=" + env[$0]!) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        execve(executable.url.path, argv, envp)
        throw StudioCLIError.processFailed
    }
}
