import Foundation

public enum StudioJSONValue: Codable, Sendable {
    case object([String: StudioJSONValue]), array([StudioJSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: StudioJSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([StudioJSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
public struct StudioManifest: Codable, Sendable {
    public var authority: StudioAuthority? = nil
    public var harness: StudioHarness? = nil
    public var thinkingLevels: [String]? = nil
    /// Process report versions Studio takes when a run closes.
    public var processVersions: [Int]? = nil
    public let schemaVersion: Int
    public let revision: String
    public let orgID: UUID
    public let user: StudioUser
    public let keyID: UUID
    public var keyLabel: String? = nil
    public var keyPrefix: String? = nil
    public var credentialMode: StudioCredentialMode? = nil
    public let expiresAt: Date
    public let refreshSeconds: Int
    public let models: [StudioModel]
    public let codexCatalog: StudioJSONValue
    enum CodingKeys: String, CodingKey {
        case thinkingLevels = "thinking_levels", processVersions = "process_versions", authority, harness, schemaVersion = "schema_version", revision, orgID = "org_id", user, keyID = "key_id", keyLabel = "key_label", keyPrefix = "key_prefix", credentialMode = "credential_mode", expiresAt = "expires_at", refreshSeconds = "refresh_seconds", models, codexCatalog = "codex_catalog"
    }
    public func validate(profile: StudioProfile? = nil) throws {
        guard ((schemaVersion == 1 && (credentialMode ?? .direct) == .direct && authority == nil && harness == nil) || (schemaVersion == 2 && credentialMode == .managed && authority?.generation ?? 0 > 0 && (harness?.valid ?? true))), revision.count == 64, revision.allSatisfy({ $0.isHexDigit }),
              user.active, user.teamID != nil, user.version > 0,
              models.count <= 1000, Set(models.map(\.id)).count == models.count,
              models.allSatisfy({ m in
                  !m.id.isEmpty && m.id.count <= 160 && m.contextMode == "provider_default" &&
                  StudioVendor.validModel(ownedBy: m.ownedBy, nativeProtocol: m.nativeProtocol)
              }) else { throw StudioError.invalidResponse }
        if let harness, harness.teamID != user.teamID { throw StudioError.invalidResponse }
        guard expiresAt > Date() else { throw StudioError.invalidKey }
        if let profile, !profile.belongsTo(orgID: orgID, ownerID: user.id) || (profile.keyID != nil && profile.keyID != keyID) || profile.credentialMode != (credentialMode ?? .direct) { throw StudioError.identityChanged }
    }
}
extension StudioClient {
    public func configuration(origin: StudioOrigin, key: String) async throws -> StudioManifest {
        let manifest: StudioManifest = try await get(origin, "studio/v1/client-config", key: key)
        try manifest.validate()
        return manifest
    }
}
