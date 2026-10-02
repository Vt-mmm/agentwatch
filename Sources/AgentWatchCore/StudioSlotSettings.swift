import Foundation

/// A background sync reads one saved slot without changing the UI selection.
/// Removal is observed on every read, so an old worker cannot revive a slot.
@MainActor final class StudioSlotSettings: StudioSettingsStorage {
    private let source: any StudioSettingsStorage
    private let profileID: String
    init(source: any StudioSettingsStorage, profileID: String) {
        self.source = source; self.profileID = profileID
    }
    func load() throws -> StudioProfile? { try source.profiles().first { $0.id == profileID } }
    func profiles() throws -> [StudioProfile] { try load().map { [$0] } ?? [] }
    func savedProfileIDs() throws -> Set<String> { try source.savedProfileIDs() }
    func save(_ profile: StudioProfile?) {} // No enrollment or selection in the background.
    func clearCredentialBlock(profileID: String) {
        guard profileID == self.profileID else { return }
        source.clearCredentialBlock(profileID: profileID)
    }
}
