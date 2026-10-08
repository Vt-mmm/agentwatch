import Foundation
import Observation

public enum StudioSyncTarget: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex, pi, piagent
    public var id: String { rawValue }
    public var title: String { switch self { case .claude: "Claude Code"; case .codex: "Codex CLI"; case .pi: "Pi"; case .piagent: "Piagent" } }
    public var tool: StudioConfiguredTool { switch self { case .claude: .claude; case .codex: .codex; case .pi, .piagent: .pi } }
    public var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(tool == .pi ? ".pi/agent" : "." + rawValue)
    }
}
public struct StudioSyncResult: Codable, Identifiable, Sendable {
    public let target: StudioSyncTarget
    public let count: Int
    public let message: String
    public let success: Bool
    /// Stable failure code shared with Studio (see StudioSyncErrorCode).
    public var code: String? = nil
    public var id: String { target.rawValue }
}

/// App-lifetime coordinator: selected targets only, no inference or directory scans.
@MainActor @Observable public final class StudioSyncStore {
    public static let shared = StudioSyncStore()
    public var selected: Set<StudioSyncTarget> { didSet { if !loadingPreferences { persistPreferences(); if oldValue != selected { invalidateConfiguration() } } } }
    public var directories: [String: String] { didSet { if !loadingPreferences { persistPreferences(); if oldValue != directories { invalidateConfiguration() } } } }
    public internal(set) var results: [StudioSyncResult] = []
    public private(set) var models: [StudioModel] = []
    public private(set) var busy = false
    public private(set) var status = "Chọn công cụ để tự động cấu hình."
    public internal(set) var lastChecked: Date?
    public private(set) var lastError: String?
    /// The background sync could not read the key without asking macOS (often
    /// right after Agent Watch updated): Piagent's company binding is stale
    /// until the member allows it.
    public private(set) var needsKeychainApproval = false
    public var enabled: Bool { didSet { if !loadingPreferences { persistPreferences() } } }
    /// Key facts from the last manifest; kept after an invalid-key failure so
    /// the app can explain an expiry without reading the secret.
    public internal(set) var keyInfo: StudioKeyInfo?
    public internal(set) var lastReport: StudioClientStatusReport?
    public internal(set) var lastReportAt: Date?
    public enum ReportState: Equatable, Sendable { case idle, sent, unsupported, failed }
    public internal(set) var reportState: ReportState = .idle
    /// Enabled by the app. Tests and the CLI never report status implicitly.
    @ObservationIgnored public var statusReporting = false
    @ObservationIgnored public var launchAtLoginStatus: () -> String = { "unavailable" }
    @ObservationIgnored public let installationID: UUID
    @ObservationIgnored private var cliVersions: [String: String]
    @ObservationIgnored private var lastReportBody: Data?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: StudioClient
    @ObservationIgnored private let settings: any StudioSettingsStorage
    @ObservationIgnored private let keys: (any StudioKeyStorage)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cachedManifest: StudioManifest?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var revisions: [String: String] = [:]
    @ObservationIgnored private var activeProfile: StudioProfile?
    @ObservationIgnored private var loadingPreferences = false
    @ObservationIgnored private var backgroundBusy = false
    @ObservationIgnored private var slotWorkers: [String: StudioSyncStore] = [:]
    private struct Preferences: Codable {
        var targets: Set<StudioSyncTarget>
        var directories: [String: String]
        var enabled: Bool
        var keyInfo: StudioKeyInfo?
    }
    static func preferencesKey(_ profile: StudioProfile) -> String { "studio.sync.profile." + profile.id }

    public init(defaults: UserDefaults = StudioPreferences.applicationDefaults, client: StudioClient = StudioClient(),
                settings: (any StudioSettingsStorage)? = nil, keys: (any StudioKeyStorage)? = nil) {
        self.defaults = defaults; self.client = client
        self.settings = settings ?? StudioPreferences(defaults: defaults); self.keys = keys
        selected = Set((defaults.stringArray(forKey: "studio.sync.targets") ?? []).compactMap(StudioSyncTarget.init))
        directories = defaults.dictionary(forKey: "studio.sync.directories") as? [String: String] ?? [:]
        enabled = defaults.bool(forKey: "studio.sync.enabled")
        keyInfo = defaults.data(forKey: "studio.sync.keyInfo").flatMap { try? JSONDecoder().decode(StudioKeyInfo.self, from: $0) }
        cliVersions = defaults.dictionary(forKey: "studio.sync.cliVersions") as? [String: String] ?? [:]
        if let stored = defaults.string(forKey: "studio.installationID").flatMap(UUID.init(uuidString:)) { installationID = stored }
        else { installationID = UUID(); defaults.set(installationID.uuidString.lowercased(), forKey: "studio.installationID") }
        activateProfile()
    }
    private func persistPreferences() {
        guard let activeProfile else { return }
        let value = Preferences(targets: selected, directories: directories, enabled: enabled, keyInfo: keyInfo)
        defaults.set(try? JSONEncoder().encode(value), forKey: Self.preferencesKey(activeProfile))
    }
    /// Called on selection changes and before every sync. ETags, revisions and
    /// status never cross credential slots, even if the same owner has both.
    public func activateProfile(adoptSelection: Bool = false) {
        let next = try? settings.load()
        guard next != activeProfile else { return }
        let draftTargets = selected, draftDirectories = directories
        activeProfile = next; generation += 1; loadingPreferences = true
        defer { loadingPreferences = false }
        results = []; models = []; cachedManifest = nil; revisions = [:]; lastChecked = nil; lastError = nil
        keyInfo = nil; lastReport = nil; lastReportAt = nil; lastReportBody = nil; reportState = .idle
        selected = []; directories = [:]; enabled = false
        guard let next else { status = "Chọn kết nối Studio."; return }
        if let data = defaults.data(forKey: Self.preferencesKey(next)) {
            guard let saved = try? JSONDecoder().decode(Preferences.self, from: data) else {
                lastError = StudioError.storage.localizedDescription; status = lastError!; return
            }
            selected = saved.targets; directories = saved.directories; enabled = saved.enabled; keyInfo = saved.keyInfo
        } else if adoptSelection {
            selected = draftTargets; directories = draftDirectories
        } else if next.id == next.connectionID && next.credentialMode == .direct {
            // Only a legacy connection may adopt the old global preferences.
            selected = Set((defaults.stringArray(forKey: "studio.sync.targets") ?? []).compactMap(StudioSyncTarget.init))
            directories = defaults.dictionary(forKey: "studio.sync.directories") as? [String: String] ?? [:]
            enabled = defaults.bool(forKey: "studio.sync.enabled")
            keyInfo = defaults.data(forKey: "studio.sync.keyInfo").flatMap { try? JSONDecoder().decode(StudioKeyInfo.self, from: $0) }
        }
        if next.credentialMode == .managed { selected.formIntersection([.piagent]) }
        persistPreferences()
        status = selected.isEmpty ? "Chọn công cụ cho key này." : "Cấu hình chưa được kiểm tra cho key này."
    }
    private func invalidateConfiguration() {
        generation += 1; revisions = [:]; results = []; lastError = nil
        status = selected.isEmpty ? "Chọn công cụ để tự động cấu hình." : "Thay đổi chưa được áp dụng."
    }
    private func loadKey(_ profile: StudioProfile) throws -> String? {
        if let keys { return try keys.load(profileID: profile.id, allowInteraction: false) }
        return try StudioKeychainStorage().load(profileID: profile.id, allowInteraction: false)
    }
    public func directory(_ target: StudioSyncTarget) -> URL {
        directories[target.rawValue].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? target.defaultDirectory
    }
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let self { await self.synchronizeSavedProfiles() }
                try? await Task.sleep(for: .seconds(300 + Int.random(in: 0...20)))
            }
        }
    }
    public func stop() { task?.cancel(); task = nil }
    /// Sequential, bounded work. Each inactive slot has its own ETag/report
    /// state; its activity never selects a different key in the UI.
    public func synchronizeSavedProfiles() async {
        guard !backgroundBusy, !busy else { return }
        backgroundBusy = true; defer { backgroundBusy = false }
        activateProfile()
        guard let profiles = try? settings.profiles() else { return }
        let retained = Set(profiles.map(\.id))
        slotWorkers = slotWorkers.filter { retained.contains($0.key) && $0.key != activeProfile?.id }
        if enabled { await synchronize() }
        for profile in profiles where profile.id != activeProfile?.id {
            guard !Task.isCancelled else { return }
            let worker = slotWorkers[profile.id] ?? StudioSyncStore(defaults: defaults, client: client,
                settings: StudioSlotSettings(source: settings, profileID: profile.id), keys: keys)
            slotWorkers[profile.id] = worker
            worker.reloadSavedPreferences()
            worker.statusReporting = statusReporting; worker.launchAtLoginStatus = launchAtLoginStatus
            if worker.enabled { await worker.synchronize() }
        }
    }
    private func reloadSavedPreferences() {
        activateProfile()
        guard !busy, let activeProfile else { return }
        loadingPreferences = true
        defer { loadingPreferences = false }
        guard let data = defaults.data(forKey: Self.preferencesKey(activeProfile)),
              let value = try? JSONDecoder().decode(Preferences.self, from: data) else { enabled = false; return }
        let changed = selected != value.targets || directories != value.directories
        selected = value.targets; directories = value.directories; enabled = value.enabled; keyInfo = value.keyInfo
        if changed { invalidateConfiguration() }
    }
    public func reset() {
        generation += 1; enabled = false; results = []; models = []; cachedManifest = nil; revisions = [:]; lastChecked = nil; lastError = nil
        keyInfo = nil; lastReport = nil; lastReportAt = nil; lastReportBody = nil; reportState = .idle
        persistPreferences()
        status = "Đã ngắt đồng bộ Studio."
    }
    public func synchronize(helper: URL? = Bundle.main.executableURL, force: Bool = false) async {
        activateProfile()
        // A company (managed) key only configures Piagent. A tool ticked before
        // the key mode was known must not block Piagent through the shared Pi folder.
        if activeProfile?.credentialMode == .managed, !selected.isSubset(of: [.piagent]) {
            loadingPreferences = true; selected.formIntersection([.piagent]); loadingPreferences = false
            persistPreferences(); results.removeAll { $0.target != .piagent }
        }
        guard !busy, !selected.isEmpty else { return }
        busy = true; defer { busy = false }
        let targets = selected, paths = directories, attempt = generation, requestedProfile = activeProfile
        do {
            guard let profile = try settings.load(), let helper,
                  let key = try loadKey(profile) else { throw StudioError.invalidKey }
            let manifest = try await client.configuration(origin: profile.origin, key: key, previous: cachedManifest)
            try manifest.validate(profile: profile)
            guard generation == attempt else { return }
            guard try settings.load() == profile, selected == targets, directories == paths,
                  try loadKey(profile) == key else { throw StudioError.identityChanged }
            settings.clearCredentialBlock(profileID: profile.id)
            cachedManifest = manifest; models = manifest.models; lastChecked = Date()
            let info = StudioKeyInfo(keyID: manifest.keyID, label: manifest.keyLabel, prefix: manifest.keyPrefix, expiresAt: manifest.expiresAt)
            if info != keyInfo { keyInfo = info; persistPreferences() }
            var completed: [String: StudioSyncResult] = [:]
            var next: [StudioSyncResult] = []
            // Unreadable slot storage never takes over another receipt.
            let saved = try? settings.savedProfileIDs()
            for target in StudioSyncTarget.allCases where targets.contains(target) {
                guard generation == attempt else { return }
                let dir = directory(target), physical = target.tool.rawValue + "\0" + dir.standardizedFileURL.path
                if let result = completed[physical] {
                    next.append(StudioSyncResult(target: target, count: result.count, message: "Dùng chung cấu hình với Pi/Piagent. " + result.message, success: result.success)); continue
                }
                let count = manifest.models.filter { profile.credentialMode == .managed || !StudioVendor.valid($0.ownedBy) && (target.tool == .pi || $0.ownedBy == target.tool.rawValue) }.count
                do {
                    if profile.credentialMode == .managed {
                        guard target == .piagent else { throw StudioError.permissionDenied }
                        if let saved { try StudioClientConfiguration.adoptOrphanedReceipt(StudioManagedConfiguration.receiptURL(directory: dir), owner: profile.id, savedProfiles: saved) }
                        let plan = try StudioManagedConfiguration.prepare(directory: dir, connection: profile, manifest: manifest, helper: helper)
                        try StudioClientConfiguration.apply(plan, receipt: StudioManagedConfiguration.receiptURL(directory: dir))
                        revisions[physical] = manifest.revision
                        let result = StudioSyncResult(target: target, count: 1, message: "agent-watch-auto · đã nhập Harness.", success: true)
                        next.append(result); completed[physical] = result; continue
                    }
                    let receipt = StudioClientConfiguration.receiptURL(tool: target.tool, directory: dir)
                    if let saved { try StudioClientConfiguration.adoptOrphanedReceipt(receipt, owner: profile.id, savedProfiles: saved) }
                    if !force, revisions[physical] == manifest.revision, let data = try StudioClientConfiguration.read(receipt),
                       let saved = try? JSONDecoder().decode(StudioConfigurationPlan.self, from: data),
                       saved.edits.allSatisfy({ (try? StudioClientConfiguration.read($0.file)) == $0.after }) {
                        let result = StudioSyncResult(target: target, count: count, message: "Đã đồng bộ · không có thay đổi.", success: true)
                        next.append(result); completed[physical] = result; continue
                    }
                    if count == 0 {
                        if let plan = try StudioClientConfiguration.prepareDisabled(tool: target.tool, directory: dir, connection: profile) {
                            try StudioClientConfiguration.apply(plan, receipt: receipt)
                        }
                        let result = StudioSyncResult(target: target, count: 0, message: "Key không được cấp model cho công cụ này. Đã tắt cấu hình Studio cũ nếu có.", success: false, code: "no_models_granted")
                        next.append(result); completed[physical] = result; revisions.removeValue(forKey: physical); continue
                    }
                    if let provider = StudioCLIProvider(rawValue: target.tool.rawValue) {
                        // One `--version` process per changed revision; the version is kept for status reports.
                        let raw = try await StudioCLIPreflight.installedVersion(StudioCLIExecutable.resolve(provider))
                        rememberCLI(target, version: raw)
                        guard raw == provider.qualifiedVersion else { throw StudioCLIError.unsupportedVersion }
                    }
                    guard generation == attempt, try settings.load() == profile, selected == targets, directories == paths,
                          try loadKey(profile) == key else { return }
                    var pi: [String: Data] = [:]
                    if target.tool == .pi {
                        let executable = try StudioClientConfiguration.piExecutable()
                        for model in manifest.models { pi[model.id] = try StudioClientConfiguration.catalogModel(for: model, piExecutable: executable) }
                    }
                    let plan = try StudioClientConfiguration.prepareAll(tool: target.tool, directory: dir, connection: profile,
                        models: manifest.models, helper: helper, codexCatalog: JSONEncoder().encode(manifest.codexCatalog), piCatalogModels: pi, piagentExtensions: target.tool == .pi && targets.contains(.piagent) && directory(.piagent) == dir ? try StudioClientConfiguration.piagentExtensions() : [])
                    try StudioClientConfiguration.apply(plan, receipt: receipt)
                    revisions[physical] = manifest.revision
                    let result = StudioSyncResult(target: target, count: count, message: "Đã cấu hình \(count) model · sẵn sàng cho phiên mới.", success: true)
                    next.append(result); completed[physical] = result
                } catch {
                    let result = StudioSyncResult(target: target, count: count, message: error.localizedDescription, success: false, code: StudioSyncErrorCode.code(for: error, target: target))
                    next.append(result); completed[physical] = result
                }
            }
            guard generation == attempt else { return }
            results = next; lastError = nil; needsKeychainApproval = false
            status = next.allSatisfy(\.success) ? "Đã đồng bộ tất cả công cụ đã chọn." : "Có công cụ cần xử lý."
            await report(profile: profile, key: key, manifest: manifest)
        } catch {
            guard generation == attempt, (try? settings.load()) == requestedProfile else { return }
            if error as? StudioError == .invalidKey {
                if let profile = activeProfile {
                    let blocked = Set(defaults.stringArray(forKey: "studio.blockedProfiles.v2") ?? []).union([profile.id])
                    defaults.set(blocked.sorted(), forKey: "studio.blockedProfiles.v2")
                }
                models = []; results = []; cachedManifest = nil
            }
            needsKeychainApproval = error as? StudioError == .keychainApprovalRequired
            lastError = error.localizedDescription; status = error.localizedDescription
        }
    }
    /// Reads the active key once with macOS's prompt (the member chooses
    /// "Always Allow"), then synchronizes at once so Piagent's binding follows.
    public func authorizeKeychain() async -> Bool {
        activateProfile()
        guard let profile = activeProfile else { return false }
        do {
            _ = try (keys ?? StudioKeychainStorage()).load(profileID: profile.id, allowInteraction: true)
        } catch { return false }
        await synchronize(force: true)
        return !needsKeychainApproval && lastError == nil
    }
    private func rememberCLI(_ target: StudioSyncTarget, version raw: String) {
        guard let version = StudioClientStatusReport.number(in: raw), cliVersions[target.rawValue] != version else { return }
        cliVersions[target.rawValue] = version; defaults.set(cliVersions, forKey: "studio.sync.cliVersions")
    }
    /// Sends the status report when it changed, or every 30 minutes so Studio
    /// can tell a live client from a lost one. Failures never retry in a loop.
    private func report(profile: StudioProfile, key: String, manifest: StudioManifest) async {
        guard statusReporting, reportState != .unsupported else { return }
        let attempt = generation
        let bundle = Bundle.main.infoDictionary, os = ProcessInfo.processInfo.operatingSystemVersion
        let value = StudioClientStatusReport.make(installationID: installationID, appVersion: bundle?["CFBundleShortVersionString"] as? String ?? "0",
            appBuild: bundle?["CFBundleVersion"] as? String, osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            revision: manifest.revision, autoSync: enabled, launchAtLogin: launchAtLoginStatus(), selected: selected, results: results,
            cliVersions: cliVersions, syncedAt: lastChecked)
        // synced_at changes on every sync; compare without it to throttle identical reports.
        let comparable = StudioClientStatusReport(installation_id: value.installation_id, app: value.app, os: value.os, config_revision: value.config_revision,
            background: value.background, tools: value.tools.map { var t = $0; t.synced_at = nil; return t })
        let body = try? comparable.encoded()
        if body != nil, body == lastReportBody, let at = lastReportAt, Date().timeIntervalSince(at) < 1800 { return }
        do {
            try await client.postClientStatus(origin: profile.origin, key: key, report: value)
            guard attempt == generation, (try? settings.load()) == profile else { return }
            lastReport = value; lastReportAt = Date(); lastReportBody = body; reportState = .sent
        } catch StudioError.incompatibleVersion {
            guard attempt == generation, (try? settings.load()) == profile else { return }
            reportState = .unsupported
        } catch { if attempt == generation, (try? settings.load()) == profile { reportState = .failed } }
    }
    public func restore(_ target: StudioSyncTarget) {
        do {
            guard let profile = activeProfile else { throw StudioError.invalidKey }
            // A company key's Piagent import has its own receipt beside Pi's.
            let receipt = profile.credentialMode == .managed && target == .piagent
                ? StudioManagedConfiguration.receiptURL(directory: directory(target))
                : StudioClientConfiguration.receiptURL(tool: target.tool, directory: directory(target))
            if let saved = try? settings.savedProfileIDs() {
                try StudioClientConfiguration.adoptOrphanedReceipt(receipt, owner: profile.id, savedProfiles: saved)
            }
            try StudioClientConfiguration.validateBinding(connection: profile, receipt: receipt)
            try StudioClientConfiguration.restoreReceipt(at: receipt)
            selected.remove(target)
            if target == .pi || target == .piagent {
                let other: StudioSyncTarget = target == .pi ? .piagent : .pi
                if directory(other) == directory(target) { selected.remove(other) }
            }
            results.removeAll { !selected.contains($0.target) }; revisions = [:]
            status = "Đã khôi phục cấu hình \(target.title)."
        } catch { status = error.localizedDescription }
    }
}
