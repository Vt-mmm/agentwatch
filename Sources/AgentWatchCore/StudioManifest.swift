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
public struct StudioManifest: Decodable, Sendable {
    public let schemaVersion: Int
    public let revision: String
    public let orgID: UUID
    public let user: StudioUser
    public let keyID: UUID
    public let expiresAt: Date
    public let refreshSeconds: Int
    public let models: [StudioModel]
    public let codexCatalog: StudioJSONValue
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", revision, orgID = "org_id", user, keyID = "key_id", expiresAt = "expires_at", refreshSeconds = "refresh_seconds", models, codexCatalog = "codex_catalog"
    }
    public func validate(profile: StudioProfile? = nil) throws {
        guard schemaVersion == 1, revision.count == 64, revision.allSatisfy({ $0.isHexDigit }),
              user.active, user.teamID != nil, user.version > 0,
              models.count <= 1000, Set(models.map(\.id)).count == models.count,
              models.allSatisfy({ m in
                  !m.id.isEmpty && m.id.count <= 160 && m.contextMode == "provider_default" &&
                  ((m.ownedBy == "claude" && m.nativeProtocol == "messages") || (m.ownedBy == "codex" && m.nativeProtocol == "responses"))
              }) else { throw StudioError.invalidResponse }
        guard expiresAt > Date() else { throw StudioError.invalidKey }
        if let profile, profile.origin.profileID(orgID: orgID, ownerID: user.id) != profile.id { throw StudioError.identityChanged }
    }
}
extension StudioClient {
    public func configuration(origin: StudioOrigin, key: String) async throws -> StudioManifest {
        let manifest: StudioManifest = try await get(origin, "studio/v1/client-config", key: key)
        try manifest.validate()
        return manifest
    }
}
