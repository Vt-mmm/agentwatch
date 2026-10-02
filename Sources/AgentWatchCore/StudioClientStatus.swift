import Foundation

/// Bounded configuration status Agent Watch shares with Studio after a sync.
/// Codes and versions only: never prompts, paths, hostnames, error text or
/// local usage. The same value is shown to the employee in the app.
public struct StudioClientStatusReport: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable { public let version: String; public let build: String? }
    public struct OS: Codable, Equatable, Sendable { public let platform: String; public let version: String? }
    public struct Background: Codable, Equatable, Sendable {
        public let auto_sync: Bool
        public let launch_at_login: String
    }
    public struct Tool: Codable, Equatable, Sendable {
        public let target: String
        public let status: String
        public var models: Int? = nil
        public var cli_version: String? = nil
        public var cli_supported: Bool? = nil
        public var error_code: String? = nil
        public var synced_at: Date? = nil
    }
    public var schema = 1
    public let installation_id: String
    public let app: App
    public let os: OS
    public let config_revision: String?
    public let background: Background
    public let tools: [Tool]

    public static let launchModes: Set<String> = ["enabled", "requires_approval", "unavailable"]

    public static func make(installationID: UUID, appVersion: String, appBuild: String?, osVersion: String?, revision: String?,
                            autoSync: Bool, launchAtLogin: String, selected: Set<StudioSyncTarget>, results: [StudioSyncResult],
                            cliVersions: [String: String], syncedAt: Date?) -> StudioClientStatusReport {
        let tools = StudioSyncTarget.allCases.map { target -> Tool in
            guard selected.contains(target) else { return Tool(target: target.rawValue, status: "not_selected") }
            let cli = [.claude, .codex].contains(target) ? cliVersions[target.rawValue] : nil
            let supported = cli.map { version in
                StudioCLIProvider(rawValue: target.rawValue).map { StudioClientStatusReport.number(in: $0.qualifiedVersion) == version } ?? true
            }
            guard let result = results.first(where: { $0.target == target }) else {
                return Tool(target: target.rawValue, status: "pending", cli_version: cli, cli_supported: supported)
            }
            return Tool(target: target.rawValue, status: result.success ? "synced" : "failed", models: max(0, min(result.count, 1000)),
                        cli_version: cli, cli_supported: supported, error_code: result.success ? nil : (result.code ?? "unknown"), synced_at: syncedAt)
        }
        let app = number(in: appVersion) ?? "0"
        let build = appBuild.flatMap { $0.range(of: #"^[0-9A-Za-z.]{1,32}$"#, options: .regularExpression) != nil ? $0 : nil }
        return StudioClientStatusReport(installation_id: installationID.uuidString.lowercased(), app: App(version: app, build: build),
                                        os: OS(platform: "macos", version: osVersion.flatMap { number(in: $0) }),
                                        config_revision: revision?.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil ? revision : nil,
                                        background: Background(auto_sync: autoSync, launch_at_login: launchModes.contains(launchAtLogin) ? launchAtLogin : "unavailable"),
                                        tools: tools)
    }

    /// First dotted version number in free text ("codex-cli 0.155.1" → "0.155.1").
    public static func number(in text: String) -> String? {
        guard let range = text.range(of: #"[0-9]{1,4}(\.[0-9]{1,5}){1,3}"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Maps local sync failures onto the stable codes Studio accepts.
public enum StudioSyncErrorCode {
    public static func code(for error: Error, target: StudioSyncTarget) -> String {
        if let error = error as? StudioCLIError {
            switch error {
            case .binaryMissing: return "cli_missing"
            case .desktopBinary: return "cli_desktop_binary"
            case .unsupportedVersion: return "cli_unsupported_version"
            case .managedSettings: return "managed_settings"
            case .changedProfile: return "config_changed_externally"
            case .unsafePath: return "config_unwritable"
            case .incompatibleConfiguration: return "config_unsupported"
            default: return "unknown"
            }
        }
        if let error = error as? StudioConfigurationError {
            switch error {
            case .unsafe: return "config_unwritable"
            case .changed: return "config_changed_externally"
            case .unsupported: return "config_unsupported"
            case .missingCatalog: return target.tool == .pi && (try? StudioClientConfiguration.piExecutable()) == nil ? "pi_missing" : "missing_catalog"
            case .nativeModelUnavailable: return "native_model_unavailable"
            case .destinationInUse: return "config_changed_externally"
            case .invalid: return "unknown"
            }
        }
        if let error = error as? StudioError {
            switch error {
            case .invalidKey, .permissionDenied: return "key_invalid"
            case .offline, .serverUnavailable: return "offline"
            default: return "unknown"
            }
        }
        return "unknown"
    }
}

/// Non-secret facts about the key in use, taken from the signed-in manifest.
public struct StudioKeyInfo: Codable, Equatable, Sendable {
    public let keyID: UUID
    public let label: String?
    public let prefix: String
    public let expiresAt: Date
    public init(keyID: UUID, label: String?, prefix: String?, expiresAt: Date) {
        self.keyID = keyID; self.label = label?.isEmpty == false ? label : nil
        self.prefix = prefix ?? "as_live_" + keyID.uuidString.lowercased().prefix(8)
        self.expiresAt = expiresAt
    }
    public func daysLeft(now: Date = Date()) -> Int { Int((expiresAt.timeIntervalSince(now) / 86_400).rounded(.up)) }
}

extension StudioClient {
    /// Posts a status report. Older servers without the endpoint answer 404;
    /// the caller then stops reporting for the session instead of retrying.
    public func postClientStatus(origin: StudioOrigin, key: String, report: StudioClientStatusReport) async throws {
        guard Self.validKey(key) else { throw StudioError.invalidKey }
        var request = URLRequest(url: origin.url(path: "studio/v1/me/client-status"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try report.encoded()
        let response: StudioHTTPResponse
        do { response = try await transport.send(request, origin: origin) }
        catch let error as StudioError { throw error }
        catch { throw StudioError.offline }
        switch response.status {
        case 200, 202, 204: return
        case 401: throw StudioError.invalidKey
        case 404: throw StudioError.incompatibleVersion
        case 429: throw StudioError.rateLimited
        default: throw StudioError.serverUnavailable
        }
    }
}
