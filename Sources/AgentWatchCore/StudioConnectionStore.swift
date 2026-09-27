import Foundation
import Observation
import Security

public struct StudioProfile: Codable, Equatable, Sendable {
    public let origin: StudioOrigin
    public let id: String
    public init(origin: StudioOrigin, id: String) throws {
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw StudioError.storage
        }
        self.origin = origin; self.id = id
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(origin: c.decode(StudioOrigin.self, forKey: .origin), id: c.decode(String.self, forKey: .id))
    }
}

@MainActor public protocol StudioKeyStorage {
    func load(profileID: String) throws -> String?
    func save(_ key: String, profileID: String) throws
    func delete(profileID: String) throws
}
@MainActor public protocol StudioSettingsStorage {
    func load() throws -> StudioProfile?
    func save(_ profile: StudioProfile?)
}

/// Separate from provider OAuth, personal CLI credentials and supervisor enrollment.
@MainActor public final class StudioKeychainStorage: StudioKeyStorage {
    private let service: String
    public init() { service = "com.vtamm.agentwatch.studio.employee" }
    // Tests use a unique service and synthetic keys, never the application's namespace.
    init(testService: String) { service = testService }
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
    }
    public func load(profileID: String) throws -> String? {
        var q = query(profileID); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8),
              StudioClient.validKey(key) else { throw StudioError.storage }
        return key
    }
    public func save(_ key: String, profileID: String) throws {
        guard StudioClient.validKey(key) else { throw StudioError.invalidKey }
        let q = query(profileID)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(q.merging(attributes) { _, value in value } as CFDictionary, nil) == errSecSuccess else { throw StudioError.storage }
        } else if status != errSecSuccess { throw StudioError.storage }
    }
    public func delete(profileID: String) throws {
        let status = SecItemDelete(query(profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StudioError.storage }
    }
}

@MainActor public final class StudioPreferences: StudioSettingsStorage {
    private let defaults: UserDefaults
    private let name = "studio.activeProfile.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() throws -> StudioProfile? {
        guard let data = defaults.data(forKey: name) else { return nil }
        do { return try JSONDecoder().decode(StudioProfile.self, from: data) }
        catch { throw StudioError.storage }
    }
    public func save(_ profile: StudioProfile?) {
        if let profile { defaults.set(try? JSONEncoder().encode(profile), forKey: name) }
        else { defaults.removeObject(forKey: name) }
    }
}

@MainActor @Observable public final class StudioConnectionStore {
    public enum State: Equatable { case disconnected, saved, checking, connected, stale, failed }
    public private(set) var profile: StudioProfile?
    public private(set) var snapshot: StudioConnectionSnapshot?
    public private(set) var state: State = .disconnected
    public private(set) var error: StudioError?
    @ObservationIgnored private let client: any StudioConnecting
    @ObservationIgnored private let keys: any StudioKeyStorage
    @ObservationIgnored private let settings: any StudioSettingsStorage
    @ObservationIgnored private var generation: UInt64 = 0

    public init(client: any StudioConnecting = StudioClient(), keys: any StudioKeyStorage = StudioKeychainStorage(),
                settings: any StudioSettingsStorage = StudioPreferences()) {
        self.client = client; self.keys = keys; self.settings = settings
        do { profile = try settings.load(); if profile != nil { state = .saved } }
        catch { self.error = .storage; state = .failed }
    }

    public func connect(origin input: String, key: String) async {
        generation &+= 1; let attempt = generation
        snapshot = nil; error = nil; state = .checking
        do {
            let origin = try StudioOrigin(input)
            if let profile, profile.origin != origin { throw StudioError.disconnectFirst }
            let result = try await client.connect(origin: origin, key: key)
            try Task.checkCancellation()
            guard generation == attempt else { return }
            let id = origin.profileID(orgID: result.identity.orgID, ownerID: result.identity.user.id)
            if let profile, profile.id != id { throw StudioError.disconnectFirst }
            let next = try StudioProfile(origin: origin, id: id)
            try keys.save(key, profileID: id)
            settings.save(next); profile = next; snapshot = result; state = .connected
        } catch {
            guard generation == attempt else { return }
            self.error = error is CancellationError ? nil : (error as? StudioError ?? .offline)
            state = error is CancellationError ? (profile == nil ? .disconnected : .saved) : .failed
        }
    }

    public func refresh() async {
        guard let profile, state != .checking else { return }
        generation &+= 1; let attempt = generation
        error = nil; state = .checking
        do {
            guard let key = try keys.load(profileID: profile.id) else { throw StudioError.invalidKey }
            let result = try await client.connect(origin: profile.origin, key: key)
            try Task.checkCancellation()
            guard generation == attempt else { return }
            guard profile.origin.profileID(orgID: result.identity.orgID, ownerID: result.identity.user.id) == profile.id else {
                throw StudioError.identityChanged
            }
            snapshot = result; state = .connected
        } catch {
            guard generation == attempt else { return }
            let failure = error as? StudioError ?? .offline
            let transient = [.offline, .serverUnavailable, .upstreamUnavailable, .rateLimited, .quotaExceeded].contains(failure) || error is CancellationError
            if !transient { snapshot = nil }
            self.error = error is CancellationError ? nil : failure
            state = snapshot == nil ? .failed : .stale
        }
    }

    public func disconnect() {
        generation &+= 1; snapshot = nil; error = nil
        do {
            if let profile { try keys.delete(profileID: profile.id) }
            settings.save(nil); profile = nil; state = .disconnected
        } catch { self.error = .storage; state = .failed }
    }
}
