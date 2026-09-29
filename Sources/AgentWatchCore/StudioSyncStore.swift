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
    public var id: String { target.rawValue }
}

/// App-lifetime coordinator: selected targets only, no inference or directory scans.
@MainActor @Observable public final class StudioSyncStore {
    public static let shared = StudioSyncStore()
    public var selected: Set<StudioSyncTarget> { didSet { defaults.set(selected.map(\.rawValue).sorted(), forKey: "studio.sync.targets"); if oldValue != selected { invalidateConfiguration() } } }
    public var directories: [String: String] { didSet { defaults.set(directories, forKey: "studio.sync.directories"); if oldValue != directories { invalidateConfiguration() } } }
    public private(set) var results: [StudioSyncResult] = []
    public private(set) var models: [StudioModel] = []
    public private(set) var busy = false
    public private(set) var status = "Chọn công cụ để tự động cấu hình."
    public private(set) var lastChecked: Date?
    public private(set) var lastError: String?
    public var enabled: Bool { didSet { defaults.set(enabled, forKey: "studio.sync.enabled") } }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: StudioClient
    @ObservationIgnored private let settings: any StudioSettingsStorage
    @ObservationIgnored private let keys: (any StudioKeyStorage)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cachedManifest: StudioManifest?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var revisions: [String: String] = [:]

    public init(defaults: UserDefaults = StudioPreferences.applicationDefaults, client: StudioClient = StudioClient(),
                settings: (any StudioSettingsStorage)? = nil, keys: (any StudioKeyStorage)? = nil) {
        self.defaults = defaults; self.client = client
        self.settings = settings ?? StudioPreferences(defaults: defaults); self.keys = keys
        selected = Set((defaults.stringArray(forKey: "studio.sync.targets") ?? []).compactMap(StudioSyncTarget.init))
        directories = defaults.dictionary(forKey: "studio.sync.directories") as? [String: String] ?? [:]
        enabled = defaults.bool(forKey: "studio.sync.enabled")
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
                if let self, self.enabled { await self.synchronize() }
                try? await Task.sleep(for: .seconds(300 + Int.random(in: 0...20)))
            }
        }
    }
    public func stop() { task?.cancel(); task = nil }
    public func reset() { generation += 1; enabled = false; results = []; models = []; cachedManifest = nil; revisions = [:]; lastChecked = nil; lastError = nil; status = "Đã ngắt đồng bộ Studio." }
    public func synchronize(helper: URL? = Bundle.main.executableURL, force: Bool = false) async {
        guard !busy, !selected.isEmpty else { return }
        busy = true; defer { busy = false }
        let targets = selected, paths = directories, attempt = generation
        do {
            guard let profile = try settings.load(), let helper,
                  let key = try loadKey(profile) else { throw StudioError.invalidKey }
            let manifest = try await client.configuration(origin: profile.origin, key: key, previous: cachedManifest)
            try manifest.validate(profile: profile)
            guard generation == attempt else { return }
            guard try settings.load() == profile, selected == targets, directories == paths,
                  try loadKey(profile) == key else { throw StudioError.identityChanged }
            defaults.removeObject(forKey: "studio.blockedProfile")
            cachedManifest = manifest; models = manifest.models; lastChecked = Date()
            var completed: [String: StudioSyncResult] = [:]
            var next: [StudioSyncResult] = []
            for target in StudioSyncTarget.allCases where targets.contains(target) {
                guard generation == attempt else { return }
                let dir = directory(target), physical = target.tool.rawValue + "\0" + dir.standardizedFileURL.path
                if let result = completed[physical] {
                    next.append(StudioSyncResult(target: target, count: result.count, message: "Dùng chung cấu hình với Pi/Piagent. " + result.message, success: result.success)); continue
                }
                let count = manifest.models.filter { target.tool == .pi || $0.ownedBy == target.tool.rawValue }.count
                do {
                    let receipt = StudioClientConfiguration.receiptURL(tool: target.tool, directory: dir)
                    if !force, revisions[physical] == manifest.revision, let data = try StudioClientConfiguration.read(receipt),
                       let saved = try? JSONDecoder().decode(StudioConfigurationPlan.self, from: data),
                       saved.edits.allSatisfy({ (try? StudioClientConfiguration.read($0.file)) == $0.after }) {
                        let result = StudioSyncResult(target: target, count: count, message: "Đã đồng bộ · không có thay đổi.", success: true)
                        next.append(result); completed[physical] = result; continue
                    }
                    if count == 0 {
                        if let plan = try StudioClientConfiguration.prepareDisabled(tool: target.tool, directory: dir) {
                            try StudioClientConfiguration.apply(plan, receipt: receipt)
                        }
                        let result = StudioSyncResult(target: target, count: 0, message: "Key không được cấp model cho công cụ này. Đã tắt cấu hình Studio cũ nếu có.", success: false)
                        next.append(result); completed[physical] = result; revisions.removeValue(forKey: physical); continue
                    }
                    if target.tool == .claude { try await StudioCLIPreflight.verifyVersion(StudioCLIExecutable.resolve(.claude)) }
                    if target.tool == .codex { try await StudioCLIPreflight.verifyVersion(StudioCLIExecutable.resolve(.codex)) }
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
                    let result = StudioSyncResult(target: target, count: count, message: error.localizedDescription, success: false)
                    next.append(result); completed[physical] = result
                }
            }
            guard generation == attempt else { return }
            results = next; lastError = nil
            status = next.allSatisfy(\.success) ? "Đã đồng bộ tất cả công cụ đã chọn." : "Có công cụ cần xử lý."
        } catch {
            guard generation == attempt else { return }
            if error as? StudioError == .invalidKey {
                if let profile = try? settings.load() { defaults.set(profile.id, forKey: "studio.blockedProfile") }
                models = []; results = []; cachedManifest = nil
            }
            lastError = error.localizedDescription; status = error.localizedDescription
        }
    }
    public func restore(_ target: StudioSyncTarget) {
        do {
            try StudioClientConfiguration.restoreReceipt(at: StudioClientConfiguration.receiptURL(tool: target.tool, directory: directory(target)))
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
