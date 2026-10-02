// Integration-test executable only. It uses synthetic keys in a private test
// directory, never the application's Keychain or preferences.
import Foundation
import AgentWatchCore
@main struct ManagedBrokerFixture {
    struct Boot: Decodable { let origin: StudioOrigin; let key: String; let orgID: UUID; let userID: UUID; let keyID: UUID }
    @MainActor static func main() async {
        let file = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("fixture.json")
        do {
            let boot = try JSONDecoder().decode(Boot.self, from: Data(contentsOf: file))
            let profile = try StudioProfile(origin: boot.origin, id: boot.origin.credentialSlotID(orgID: boot.orgID, ownerID: boot.userID, keyID: boot.keyID, mode: .managed), connectionID: boot.origin.profileID(orgID: boot.orgID, ownerID: boot.userID), keyID: boot.keyID, credentialMode: .managed)
            let status = await StudioManagedBrokerCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2)), factory: { id in
                guard id == profile.id else { throw StudioError.identityChanged }
                return try await StudioManagedBroker.enroll(profile: profile, key: boot.key)
            })
            exit(status)
        } catch { exit(70) }
    }
}
