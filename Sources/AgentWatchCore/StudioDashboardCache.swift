import Foundation

@MainActor public protocol StudioDashboardCaching {
    func load(profile: StudioProfile) throws -> StudioDashboardSnapshot?
    func save(_ snapshot: StudioDashboardSnapshot, profile: StudioProfile) throws
    func delete(profile: StudioProfile) throws
}

/// Stores only typed personal ledger projections, never keys or raw responses.
/// The OS may evict this cache; it is not evidence or a second ledger.
@MainActor public final class StudioDashboardCache: StudioDashboardCaching {
    private struct Envelope: Codable { let version: Int; let profile: StudioProfile; let dashboard: StudioDashboardSnapshot }
    private let directory: URL
    private let manager = FileManager.default
    private static let maxBytes = 4 * 1024 * 1024
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.vtamm.agentwatch.studio")
    }
    private func file(_ profile: StudioProfile) throws -> URL {
        guard directory.isFileURL else { throw StudioError.storage }
        let file = directory.appendingPathComponent(profile.id + ".json")
        for path in [directory, file] {
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw StudioError.storage }
        }
        return file
    }
    public func load(profile: StudioProfile) throws -> StudioDashboardSnapshot? {
        do {
            let url = try file(profile)
            guard manager.fileExists(atPath: url.path) else { return nil }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= Self.maxBytes else { throw StudioError.storage }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maxBytes else { throw StudioError.storage }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.profile == profile,
                  profile.matches(envelope.dashboard.identity) else { throw StudioError.storage }
            try envelope.dashboard.validate()
            return envelope.dashboard
        } catch { throw StudioError.storage }
    }
    public func save(_ snapshot: StudioDashboardSnapshot, profile: StudioProfile) throws {
        do {
            let url = try file(profile)
            guard profile.matches(snapshot.identity) else { throw StudioError.storage }
            try snapshot.validate()
            let data = try JSONEncoder().encode(Envelope(version: 1, profile: profile, dashboard: snapshot))
            guard data.count <= Self.maxBytes else { throw StudioError.storage }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw StudioError.storage }
    }
    public func delete(profile: StudioProfile) throws {
        do { let url = try file(profile); if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) } }
        catch { throw StudioError.storage }
    }
}
