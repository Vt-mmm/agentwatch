import Foundation
import Observation
import Security
import LocalAuthentication

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
    func load(profileID: String, allowInteraction: Bool) throws -> String?
    func save(_ key: String, profileID: String) throws
    func delete(profileID: String) throws
}
extension StudioKeyStorage {
    public func load(profileID: String, allowInteraction: Bool) throws -> String? { try load(profileID: profileID) }
}
@MainActor public protocol StudioSettingsStorage {
    func load() throws -> StudioProfile?
    func save(_ profile: StudioProfile?)
    func clearCredentialBlock()
}
extension StudioSettingsStorage {
    public func clearCredentialBlock() {}
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
        try load(profileID: profileID, allowInteraction: true)
    }
    public func load(profileID: String, allowInteraction: Bool) throws -> String? {
        var q = query(profileID); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction
        q[kSecUseAuthenticationContext as String] = context
        // Existing macOS login-keychain items use the legacy backend, which can
        // ignore the per-query UI flag. Suppress that UI for this synchronous
        // read and restore its prior setting; never change an item's ACL.
        var previousInteraction = DarwinBoolean(false)
        if !allowInteraction {
            guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw StudioError.keychainApprovalRequired }
        }
        defer { if !allowInteraction { SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) } }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if !allowInteraction && (status == errSecInteractionNotAllowed || status == errSecAuthFailed) {
            throw StudioError.keychainApprovalRequired
        }
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
    public static var applicationDefaults: UserDefaults {
        let id = "com.vtamm.claudewatch.ClaudeWatchMac"
        return Bundle.main.bundleIdentifier == id ? .standard : (UserDefaults(suiteName: id) ?? .standard)
    }
    private let defaults: UserDefaults
    private let name = "studio.activeProfile.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() throws -> StudioProfile? {
        guard let data = defaults.data(forKey: name) else { return nil }
        do { return try JSONDecoder().decode(StudioProfile.self, from: data) }
        catch { throw StudioError.storage }
    }
    public func clearCredentialBlock() { defaults.removeObject(forKey: "studio.blockedProfile") }
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
    public enum DashboardState: Equatable { case empty, loading, current, stale, failed }
    public private(set) var dashboard: StudioDashboardSnapshot?
    public private(set) var dashboardState: DashboardState = .empty
    public private(set) var dashboardError: StudioError?
    public private(set) var sessionReportsRevision: UInt64 = 0
    public private(set) var cacheUnavailable = false
    public private(set) var quotaModelID: String?
    @ObservationIgnored private let client: any StudioConnecting
    @ObservationIgnored private let keys: any StudioKeyStorage
    @ObservationIgnored private let settings: any StudioSettingsStorage
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let reporting: (any StudioReporting)?
    @ObservationIgnored private let cache: any StudioDashboardCaching

    public init(client: any StudioConnecting = StudioClient(), keys: any StudioKeyStorage = StudioKeychainStorage(),
                settings: any StudioSettingsStorage = StudioPreferences(), reporting: (any StudioReporting)? = nil,
                cache: any StudioDashboardCaching = StudioDashboardCache()) {
        self.client = client; self.keys = keys; self.settings = settings
        self.reporting = reporting ?? (client as? any StudioReporting); self.cache = cache
        do { profile = try settings.load(); if profile != nil { state = .saved } }
        catch { self.error = .storage; state = .failed }
        if let profile {
            do {
                if try keys.load(profileID: profile.id, allowInteraction: false) != nil {
                    dashboard = try cache.load(profile: profile)
                    if dashboard != nil { dashboardState = .stale; quotaModelID = dashboard?.quotaModel?.id }
                } else { try cache.delete(profile: profile) }
            } catch { cacheUnavailable = true }
        }
    }

    public func connect(origin input: String, key: String) async {
        sessionReportsRevision &+= 1; generation &+= 1; let attempt = generation
        snapshot = nil; error = nil; state = .checking
        clearDashboard()
        do {
            if let profile { try cache.delete(profile: profile) }
            let origin = try StudioOrigin(input)
            if let profile, profile.origin != origin { throw StudioError.disconnectFirst }
            let result = try await client.connect(origin: origin, key: key)
            try Task.checkCancellation()
            guard generation == attempt else { return }
            let id = origin.profileID(orgID: result.identity.orgID, ownerID: result.identity.user.id)
            if let profile, profile.id != id { throw StudioError.disconnectFirst }
            let next = try StudioProfile(origin: origin, id: id)
            try keys.save(key, profileID: id)
            settings.clearCredentialBlock()
            settings.save(next); profile = next; snapshot = result; state = .connected
            await updateDashboard(key: key, result: result, attempt: attempt)
        } catch {
            guard generation == attempt else { return }
            self.error = error is CancellationError ? nil : (error as? StudioError ?? .offline)
            state = error is CancellationError ? (profile == nil ? .disconnected : .saved) : .failed
        }
    }

    public func refresh(allowInteraction: Bool = true) async {
        guard let profile, state != .checking else { return }
        sessionReportsRevision &+= 1; generation &+= 1; let attempt = generation
        error = nil; state = .checking
        if reporting != nil { dashboardState = .loading }
        do {
            guard let key = try keys.load(profileID: profile.id, allowInteraction: allowInteraction) else { throw StudioError.invalidKey }
            let result = try await client.connect(origin: profile.origin, key: key)
            try Task.checkCancellation()
            guard generation == attempt else { return }
            guard profile.origin.profileID(orgID: result.identity.orgID, ownerID: result.identity.user.id) == profile.id else {
                throw StudioError.identityChanged
            }
            snapshot = result; state = .connected
            await updateDashboard(key: key, result: result, attempt: attempt)
        } catch {
            guard generation == attempt else { return }
            let failure = error as? StudioError ?? .offline
            let transient = [.offline, .serverUnavailable, .upstreamUnavailable, .rateLimited, .quotaExceeded].contains(failure) || error is CancellationError
            if !transient {
                snapshot = nil; clearDashboard()
                do { try cache.delete(profile: profile) } catch { cacheUnavailable = true }
            }
            if reporting != nil {
                dashboardState = dashboard == nil ? .failed : .stale
                dashboardError = error is CancellationError ? nil : failure
            }
            self.error = error is CancellationError ? nil : failure
            state = snapshot == nil ? .failed : .stale
        }
    }

    public func disconnect() {
        sessionReportsRevision &+= 1; generation &+= 1; snapshot = nil; error = nil
        quotaModelID = nil
        clearDashboard()
        do {
            if let profile {
                // Attempt both removals, even when one storage layer is unavailable.
                var failed = false
                do { try cache.delete(profile: profile) } catch { failed = true }
                do { try keys.delete(profileID: profile.id) } catch { failed = true }
                if failed { throw StudioError.storage }
            }
            settings.save(nil); profile = nil; state = .disconnected
        } catch { self.error = .storage; state = .failed }
    }

    public func selectQuotaModel(_ id: String) async {
        guard case .available(let models) = snapshot?.models, models.contains(where: { $0.id == id }), state != .checking else { return }
        quotaModelID = id; clearDashboard()
        if let profile { do { try cache.delete(profile: profile) } catch { cacheUnavailable = true } }
        await refresh()
    }

    public func compareSession(_ local: StudioLocalSession, range: Range<Date>, coveragePartial: Bool) async throws -> StudioSessionComparison {
        guard let digest = StudioSessionComparison.digest(sessionID: local.sessionID) else { return .unavailable(.unsupportedIdentity) }
        guard state == .connected, let profile, profile.id == local.profileID, let identity = snapshot?.identity,
              profile.origin.profileID(orgID: identity.orgID, ownerID: identity.user.id) == profile.id,
              let reporting = client as? any StudioSessionReporting else { throw StudioError.offline }
        let attempt = generation
        guard let key = try keys.load(profileID: profile.id) else { throw StudioError.invalidKey }
        do {
            let report = try await reporting.sessionUsage(origin: profile.origin, key: key, identity: identity, provider: local.provider, digest: digest, range: range)
            try Task.checkCancellation()
            guard attempt == generation, self.profile == profile, state == .connected,
                  try keys.load(profileID: profile.id) == key else { throw CancellationError() }
            try report.validate(identity: identity, provider: local.provider, digest: digest, range: range)
            return StudioSessionComparison.compare(local: local, report: report, coveragePartial: coveragePartial)
        } catch {
            guard attempt == generation else { throw CancellationError() }
            if error as? StudioError == .invalidKey {
                sessionReportsRevision &+= 1; generation &+= 1
                snapshot = nil; clearDashboard(); state = .failed; self.error = .invalidKey
                do { try cache.delete(profile: profile) } catch { cacheUnavailable = true }
            }
            throw error
        }
    }

    private func clearDashboard() {
        dashboard = nil; dashboardState = .empty; dashboardError = nil
    }
    private func updateDashboard(key: String, result: StudioConnectionSnapshot, attempt: UInt64) async {
        guard let reporting, let profile, generation == attempt else { return }
        let model: StudioModel?
        if case .available(let models) = result.models { model = models.first(where: { $0.id == quotaModelID }) ?? models.first }
        else { model = nil }
        if let dashboard, dashboard.quotaModel?.id != model?.id {
            clearDashboard()
            do { try cache.delete(profile: profile) } catch { cacheUnavailable = true }
        }
        quotaModelID = model?.id
        dashboardState = .loading; dashboardError = nil
        do {
            let report = try await reporting.dashboard(origin: profile.origin, key: key, identity: result.identity, model: model, now: Date(), timezone: .current)
            try Task.checkCancellation()
            guard generation == attempt else { return }
            guard report.identity == result.identity else { throw StudioError.identityChanged }
            dashboard = report; dashboardState = .current
            do { try cache.save(report, profile: profile); cacheUnavailable = false }
            catch { cacheUnavailable = true }
        } catch {
            guard generation == attempt else { return }
            let failure = error as? StudioError ?? .offline
            let transient = [.offline, .serverUnavailable, .upstreamUnavailable, .rateLimited, .quotaExceeded].contains(failure) || error is CancellationError
            if !transient {
                clearDashboard(); snapshot = nil; state = .failed; self.error = failure
                do { try cache.delete(profile: profile) } catch { cacheUnavailable = true }
            }
            dashboardError = failure; dashboardState = dashboard == nil ? .failed : .stale
        }
    }
}
