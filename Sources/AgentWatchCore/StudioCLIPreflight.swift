import Foundation
import Darwin

public enum StudioCLIPreflight {
    /// Bulk configuration must not install a catalog schema into an unqualified CLI.
    /// The version probe receives no employee key and does not send inference.
    public static func verifyVersion(_ executable: StudioCLIExecutable) async throws {
        guard try await installedVersion(executable) == executable.provider.qualifiedVersion else { throw StudioCLIError.unsupportedVersion }
    }
    /// Raw `--version` output, trimmed; one short process, no network.
    public static func installedVersion(_ executable: StudioCLIExecutable) async throws -> String {
        let version = try await Task.detached {
            let process = Process(), output = Pipe()
            let invocation = try executable.invocation()
            process.executableURL = invocation.executable; process.arguments = invocation.prefixArguments + ["--version"]
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "LANG": "en_US.UTF-8",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1"]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            return try readBounded(process, output: output, input: nil)
        }.value
        guard let text = String(data: version, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { throw StudioCLIError.unsupportedVersion }
        return text
    }

    /// Every probe uses the managed profile and receives no employee credential.
    public static func verify(_ plan: StudioCLILaunchPlan) async throws {
        let version = try await capture(plan, arguments: ["--version"])
        guard String(data: version, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == plan.profile.provider.qualifiedVersion else {
            throw StudioCLIError.unsupportedVersion
        }
        if plan.profile.provider == .claude {
            // Do not bypass administrative settings. Qualify those layers before
            // allowing this adapter to supply an employee credential on managed Macs.
            let home = FileManager.default.homeDirectoryForCurrentUser
            let paths = ["/Library/Application Support/ClaudeCode/managed-settings.json", "/Library/Application Support/ClaudeCode/managed-settings.d", "/Library/Application Support/ClaudeCode/managed-mcp.json", "/Library/Managed Preferences/com.anthropic.claudecode.plist", "/Library/Managed Preferences/\(NSUserName())/com.anthropic.claudecode.plist", home.appendingPathComponent("Library/Managed Preferences/com.anthropic.claudecode.plist").path]
            guard !paths.contains(where: FileManager.default.fileExists(atPath:)) else { throw StudioCLIError.managedSettings }
            let help = String(decoding: try await capture(plan, arguments: ["--help"]), as: UTF8.self)
            guard ["--bare", "--setting-sources", "--strict-mcp-config", "--permission-mode"].allSatisfy(help.contains) else { throw StudioCLIError.unsupportedVersion }
        } else {
            let raw = try await codexConfiguration(plan)
            try validateCodexConfiguration(raw, plan: plan)
        }
    }

    static func validateCodexConfiguration(_ data: Data, plan: StudioCLILaunchPlan) throws {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = response["result"] as? [String: Any], let config = result["config"] as? [String: Any],
              config["model"] as? String == plan.model.cliModelID, config["model_provider"] as? String == "agent_studio",
              config["sandbox_mode"] as? String == "workspace-write", config["approval_policy"] as? String == "on-request",
              config["allow_login_shell"] as? Bool == false, config["web_search"] as? String == "disabled",
              let sandbox = config["sandbox_workspace_write"] as? [String: Any], sandbox["network_access"] as? Bool == false,
              let providers = config["model_providers"] as? [String: Any], let selected = providers["agent_studio"] as? [String: Any],
              selected["base_url"] as? String == plan.profile.connection.origin.value + "/v1",
              selected["env_key"] as? String == "AGENTWATCH_STUDIO_KEY", selected["requires_openai_auth"] as? Bool == false,
              selected["wire_api"] as? String == "responses", selected["request_max_retries"] as? Int == 0,
              selected["stream_max_retries"] as? Int == 0 else { throw StudioCLIError.incompatibleConfiguration }
        guard selected["supports_websockets"] as? Bool == false,
              selected["supports_standalone_web_search"] as? Bool == false else { throw StudioCLIError.incompatibleConfiguration }
        let expectedProvider: Set<String> = ["name", "base_url", "env_key", "requires_openai_auth", "wire_api", "request_max_retries", "stream_max_retries", "supports_websockets", "supports_standalone_web_search"]
        guard Set(selected.keys).subtracting(expectedProvider).allSatisfy({ selected[$0] is NSNull }) else { throw StudioCLIError.incompatibleConfiguration }
        // Project/system additions that run commands or change execution/auth need
        // explicit qualification, not a recursive TOML merge guessed by this app.
        for key in ["mcp_servers", "hooks", "plugins", "notify", "permissions", "default_permissions", "forced_login_method", "forced_chatgpt_workspace_id", "profile"] {
            guard empty(config[key]) else { throw StudioCLIError.incompatibleConfiguration }
        }
        guard let features = config["features"] as? [String: Any],
              ["shell_snapshot", "multi_agent", "apps", "remote_plugin", "hooks", "enable_request_compression"].allSatisfy({ features[$0] as? Bool == false }),
              let shell = config["shell_environment_policy"] as? [String: Any], shell["inherit"] as? String == "core",
              shell["ignore_default_excludes"] as? Bool == false, shell["experimental_use_profile"] as? Bool == false,
              empty(shell["set"]), empty(shell["filters"]),
              Set(shell["exclude"] as? [String] ?? []) == ["*KEY*", "*TOKEN*", "*SECRET*"] else { throw StudioCLIError.incompatibleConfiguration }
    }
    private static func empty(_ value: Any?) -> Bool {
        value == nil || value is NSNull || (value as? [String: Any])?.isEmpty == true || (value as? [Any])?.isEmpty == true
    }
    private static func capture(_ plan: StudioCLILaunchPlan, arguments: [String]) async throws -> Data {
        try await Task.detached {
            let process = Process(), output = Pipe()
            let invocation = try plan.executable.invocation()
            process.executableURL = invocation.executable; process.arguments = invocation.prefixArguments + arguments
            process.environment = plan.environment; process.currentDirectoryURL = plan.project
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            return try readBounded(process, output: output, input: nil)
        }.value
    }
    private static func codexConfiguration(_ plan: StudioCLILaunchPlan) async throws -> Data {
        try await Task.detached {
            let process = Process(), input = Pipe(), output = Pipe()
            let invocation = try plan.executable.invocation()
            process.executableURL = invocation.executable; process.arguments = invocation.prefixArguments + plan.codexOverrides + ["app-server", "--stdio"]
            process.environment = plan.environment; process.currentDirectoryURL = plan.project
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let request: [String: Any] = ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "agentwatch-studio", "version": "1.0.0"], "capabilities": ["experimentalApi": true]]]
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
            return try readBounded(process, output: output, input: input, project: plan.project.path)
        }.value
    }
    private static func readBounded(_ process: Process, output: Pipe, input: Pipe?, project: String = "") throws -> Data {
        defer {
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? input?.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
        let deadline = Date().addingTimeInterval(10)
        var buffer = Data(), total = 0, initialized = false
        let fd = output.fileHandleForReading.fileDescriptor
        while Date() < deadline {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw StudioCLIError.processFailed }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; throw StudioCLIError.processFailed }
            if count == 0 {
                guard input == nil, !buffer.isEmpty else { throw StudioCLIError.processFailed }
                while process.isRunning && Date() < deadline { usleep(10_000) }
                guard !process.isRunning else { throw StudioCLIError.processFailed }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw StudioCLIError.processFailed }
                return buffer
            }
            let data = Data(bytes.prefix(count))
            total += data.count; guard total <= 1_048_576 else { throw StudioCLIError.processFailed }
            buffer.append(data)
            if let input {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw StudioCLIError.processFailed }
                    if row["id"] as? Int == 1 && !initialized {
                        guard row["result"] != nil else { throw StudioCLIError.processFailed }
                        initialized = true
                        let messages: [[String: Any]] = [["method": "initialized", "params": [:]], ["id": 2, "method": "config/read", "params": ["includeLayers": true, "cwd": project]]]
                        for message in messages { try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([10])) }
                    } else if row["id"] as? Int == 2 { return line }
                }
            }
        }
        throw StudioCLIError.processFailed
    }
}
