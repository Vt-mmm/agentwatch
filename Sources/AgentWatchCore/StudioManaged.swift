import Foundation

public struct StudioAuthority: Codable, Equatable, Sendable {
    public let instanceID: UUID
    public let epoch: UUID
    public let generation: Int64
    enum CodingKeys: String, CodingKey { case instanceID = "studio_instance_id", epoch = "dataset_epoch", generation = "auth_generation" }
}
public struct StudioHarnessRole: Codable, Sendable {
    public let mode: String
    public let modelIDs: [String]
    /// A level the Harness fixes for this role; nil follows the member.
    public var effort: String? = nil
    enum CodingKeys: String, CodingKey { case mode, modelIDs = "model_ids", effort }
    var valid: Bool { ["fixed", "auto"].contains(mode) && (1...20).contains(modelIDs.count) && Set(modelIDs).count == modelIDs.count && (mode != "fixed" || modelIDs.count == 1) && modelIDs.allSatisfy { !$0.isEmpty && $0.count <= 160 }
        && (effort.map { ["off", "minimal", "low", "medium", "high", "xhigh", "max"].contains($0) } ?? true) }
}
/// The process a code-changing turn follows (plan, checks, review), which the
/// managed runtime enforces. Watch only carries it to the runtime.
public struct StudioWorkflow: Codable, Sendable, Equatable {
    public let plan: String
    public let verify: String
    public let review: String
    public let maxFixLoops: Int
    enum CodingKeys: String, CodingKey { case plan, verify, review, maxFixLoops = "max_fix_loops" }
    var valid: Bool { [plan, verify, review].allSatisfy { ["off", "suggest", "require"].contains($0) } && (0...3).contains(maxFixLoops) }
}
public struct StudioHarness: Codable, Sendable {
    public struct Configuration: Codable, Sendable {
        public let main: StudioHarnessRole
        public let research: StudioHarnessRole?
        public let review: StudioHarnessRole?
        public var workflow: StudioWorkflow? = nil
        /// Scout reads the codebase; verify reproduces a result with evidence.
        /// A Studio without them sends neither, and the runtime offers neither.
        public var scout: StudioHarnessRole? = nil
        public var verify: StudioHarnessRole? = nil
    }
    /// The roles the main agent may delegate to.
    public static let helperRoles: Set<String> = ["scout", "research", "verify", "review"]
    public let id: UUID
    public let teamID: UUID
    public let revision: Int64
    public let configuration: Configuration
    enum CodingKeys: String, CodingKey { case id, teamID = "team_id", revision, configuration }
    var valid: Bool { revision > 0 && configuration.main.valid && [configuration.scout, configuration.research, configuration.verify, configuration.review].allSatisfy { $0?.valid ?? true } && (configuration.workflow?.valid ?? true) }
}
public struct StudioManagedDevice: Decodable, Sendable {
    public let deviceID: UUID
    public let token: String
    public let expiresAt: Date
    public let instanceID: UUID
    public let epoch: UUID
    public let generation: Int64
    enum CodingKeys: String, CodingKey { case deviceID = "device_id", token, expiresAt = "expires_at", instanceID = "studio_instance_id", epoch = "dataset_epoch", generation = "auth_generation" }
    var authority: StudioAuthority { StudioAuthority(instanceID: instanceID, epoch: epoch, generation: generation) }
}
public struct StudioRunGrant: Codable, Sendable {
    public let runID: UUID
    public let roleID: UUID
    public let role: String
    public let modelID: String
    public let provider: String
    public let providerModelID: String
    public let effort: String
    public let fence: Int64
    public let token: String
    public let expiresAt: Date
    public let profileID: UUID
    public let instanceID: UUID
    public let epoch: UUID
    public let generation: Int64
    enum CodingKeys: String, CodingKey {
        case runID = "run_id", roleID = "role_id", role, modelID = "model_id", provider, providerModelID = "provider_model_id", effort, fence, token, expiresAt = "expires_at", profileID = "profile_id", instanceID = "studio_instance_id", epoch = "dataset_epoch", generation = "auth_generation"
    }
    var authority: StudioAuthority { StudioAuthority(instanceID: instanceID, epoch: epoch, generation: generation) }
    func validate(authority: StudioAuthority) throws {
        guard self.authority == authority, role == "main" || StudioHarness.helperRoles.contains(role), ["claude", "codex"].contains(provider) || StudioVendor.valid(provider), fence > 0,
              !modelID.isEmpty, modelID.count <= 160, !providerModelID.isEmpty, providerModelID.count <= 160,
              StudioManagedClient.validToken(token, kind: "run", id: roleID) else { throw StudioError.invalidResponse }
        // Lease validity is enforced using server time. Do not trust the laptop clock.
    }
}
public struct StudioManagedClient: Sendable {
    let transport: any StudioHTTPTransport
    public init(transport: any StudioHTTPTransport = StudioURLSessionTransport()) { self.transport = transport }
    static func validToken(_ value: String, kind: String, id: UUID? = nil) -> Bool {
        let prefix = "as_" + kind + "_"
        guard value.hasPrefix(prefix) else { return false }
        let tail = String(value.dropFirst(prefix.count))
        guard tail.utf8.count == 80 else { return false }
        let rawID = String(tail.prefix(36)), suffix = String(tail.suffix(43))
        guard let parsed = UUID(uuidString: rawID), tail.dropFirst(36).first == "_", id == nil || id == parsed else { return false }
        return suffix.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    func post<T: Decodable>(_ origin: StudioOrigin, _ path: String, credential: String, body: [String: StudioJSONValue]) async throws -> T {
        let data = try await request(origin, path, credential: credential, body: body)
        do { return try StudioClient.apiDecoder().decode(T.self, from: data) } catch { throw StudioError.invalidResponse }
    }
    func request(_ origin: StudioOrigin, _ path: String, credential: String, body: [String: StudioJSONValue]) async throws -> Data {
        guard StudioClient.validKey(credential) else { throw StudioError.invalidKey }
        var request = URLRequest(url: origin.url(path: "studio/v1/managed/" + path))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(StudioClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)
        let response: StudioHTTPResponse
        do { response = try await transport.send(request, origin: origin) }
        catch is CancellationError { throw CancellationError() }
        catch let error as StudioError { throw error }
        catch { throw StudioError.offline }
        if (300..<400).contains(response.status) { throw StudioError.redirectDenied }
        guard response.body.count <= StudioClient.maxResponseBytes else { throw StudioError.invalidResponse }
        switch response.status {
        case 200, 201: guard response.contentType.split(separator: ";").first?.lowercased() == "application/json" else { throw StudioError.invalidResponse }
        case 204: return Data()
        case 401: throw StudioError.invalidKey
        case 403: throw StudioError.permissionDenied
        case 409: throw StudioError.identityChanged
        case 429: throw StudioError.rateLimited
        case 400: throw StudioError.invalidResponse
        default: throw StudioError.serverUnavailable
        }
        return response.body
    }
}

/// One broker belongs to one isolated Pi process. No public socket and no
/// operation that returns an enrollment key or device credential.
@MainActor public final class StudioManagedBroker {
    let profile: StudioProfile
    let manifest: StudioManifest
    private let client: StudioManagedClient
    private let device: StudioManagedDevice
    private var root: UUID?
    private var grants: [String: StudioRunGrant] = [:]
    public init(profile: StudioProfile, manifest: StudioManifest, device: StudioManagedDevice, client: StudioManagedClient) throws {
        try manifest.validate(profile: profile)
        guard profile.credentialMode == .managed, let authority = manifest.authority,
              device.authority == authority, StudioManagedClient.validToken(device.token, kind: "device", id: device.deviceID) else { throw StudioError.invalidResponse }
        self.profile = profile; self.manifest = manifest; self.device = device; self.client = client
    }
    public static func enroll(profile: StudioProfile, key: String, client: StudioClient = StudioClient(), managed: StudioManagedClient = StudioManagedClient()) async throws -> StudioManagedBroker {
        guard profile.credentialMode == .managed else { throw StudioError.permissionDenied }
        let manifest = try await client.configuration(origin: profile.origin, key: key)
        try manifest.validate(profile: profile)
        guard manifest.harness != nil else { throw StudioError.permissionDenied }
        // An independent broker instance must not rotate another running device.
        let device: StudioManagedDevice = try await managed.post(profile.origin, "devices", credential: key,
            body: ["installation_id": .string(UUID().uuidString.lowercased())])
        return try StudioManagedBroker(profile: profile, manifest: manifest, device: device, client: managed)
    }
    public func start(operation: UUID, effort: String, taskClass: String) async throws -> StudioRunGrant {
        guard root == nil, ["", "off", "minimal", "low", "medium", "high", "xhigh", "max"].contains(effort), ["simple", "standard", "complex"].contains(taskClass) else { throw StudioError.permissionDenied }
        let grant: StudioRunGrant = try await client.post(profile.origin, "runs", credential: device.token,
            body: ["operation_id": .string(operation.uuidString.lowercased()), "effort": .string(effort), "task_class": .string(taskClass)])
        try grant.validate(authority: device.authority)
        guard grant.role == "main" else { throw StudioError.invalidResponse }
        root = grant.runID; grants["main"] = grant; return grant
    }
    public func child(role: String) async throws -> StudioRunGrant {
        guard StudioHarness.helperRoles.contains(role), let root, grants[role] == nil else { throw StudioError.permissionDenied }
        let grant: StudioRunGrant = try await client.post(profile.origin, "runs/\(root.uuidString.lowercased())/children", credential: device.token, body: ["role": .string(role)])
        try grant.validate(authority: device.authority)
        guard grant.runID == root, grant.role == role else { throw StudioError.invalidResponse }
        grants[role] = grant; return grant
    }
    public func recover(runID: UUID) async throws -> StudioRunGrant {
        guard root == nil else { throw StudioError.permissionDenied }
        let grant: StudioRunGrant = try await client.post(profile.origin, "runs/\(runID.uuidString.lowercased())/recover", credential: device.token, body: [:])
        try grant.validate(authority: device.authority)
        guard grant.runID == runID, grant.role == "main" else { throw StudioError.identityChanged }
        root = runID; grants["main"] = grant; return grant
    }
    public func renew(role: String) async throws -> StudioRunGrant {
        guard let old = grants[role] else { throw StudioError.permissionDenied }
        let grant: StudioRunGrant = try await client.post(profile.origin, "roles/\(old.roleID.uuidString.lowercased())/renew", credential: device.token, body: ["fence": .number(Double(old.fence))])
        try grant.validate(authority: device.authority)
        guard grant.runID == old.runID, grant.roleID == old.roleID, grant.role == role, grant.fence > old.fence,
              grant.modelID == old.modelID, grant.providerModelID == old.providerModelID, grant.profileID == old.profileID else { throw StudioError.identityChanged }
        grants[role] = grant; return grant
    }
    /// Closing the run may carry the runtime's process report (counts and
    /// outcomes only). It goes to a Studio that sends a workflow: an older
    /// Studio refuses unknown fields.
    public func close(role: String = "", process: [String: StudioJSONValue]? = nil) async throws {
        guard let root else { return }
        guard role.isEmpty || grants[role] != nil else { throw StudioError.permissionDenied }
        var body: [String: StudioJSONValue] = ["role": .string(role)]
        if let process {
            guard role.isEmpty || role == "main", StudioProcessReport.valid(process, versions: manifest.processVersions ?? [1]) else { throw StudioError.invalidResponse }
            if manifest.harness?.configuration.workflow != nil { body["process"] = .object(process) }
        }
        _ = try await client.request(profile.origin, "runs/\(root.uuidString.lowercased())/close", credential: device.token, body: body)
        if role.isEmpty || role == "main" { self.root = nil; grants.removeAll() } else { grants.removeValue(forKey: role) }
    }
}

/// Shape check of a process report before it leaves the machine: known keys
/// and value types only, so no text (prompts, findings, paths) is forwarded.
/// Studio validates the meaning. Version 2 adds `plan_skipped` and
/// `unknown_tools`, and is sent only to a Studio that lists it.
public enum StudioProcessReport {
    static let baseCounts: Set<String> = ["plan_steps", "plan_done", "checks", "checks_failed", "reviews", "blocking", "blocking_open", "fix_loops"]
    static let baseFlags: Set<String> = ["changed", "verified", "reviewed"]
    static let outcomes: Set<String> = ["no_change", "interrupted", "blocking_open", "unverified", "review_unavailable", "unreviewed", "clean"]
    static let modes: Set<String> = ["off", "suggest", "require"]
    public static func valid(_ report: [String: StudioJSONValue], versions: [Int] = [1]) -> Bool {
        guard case .number(let raw)? = report["version"], let version = Int(exactly: raw), [1, 2].contains(version), versions.contains(version) else { return false }
        let counts = version == 2 ? baseCounts.union(["unknown_tools"]) : baseCounts, flags = version == 2 ? baseFlags.union(["plan_skipped"]) : baseFlags
        guard Set(report.keys) == counts.union(flags).union(["version", "policy", "outcome"]) else { return false }
        for (key, value) in report {
            switch (key, value) {
            case ("version", .number): break
            case ("outcome", .string(let s)): if !outcomes.contains(s) { return false }
            case ("policy", .object(let p)):
                guard Set(p.keys) == ["plan", "verify", "review"], p.values.allSatisfy({ if case .string(let m) = $0 { return modes.contains(m) }; return false }) else { return false }
            case (_, .bool): if !flags.contains(key) { return false }
            case (_, .number(let n)): if !counts.contains(key) || n < 0 || n > 1000 || n.rounded() != n { return false }
            default: return false
            }
        }
        return true
    }
}
