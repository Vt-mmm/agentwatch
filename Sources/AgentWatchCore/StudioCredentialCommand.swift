import Foundation
import Security

/// Noninteractive credential helper for CLI-owned HTTP requests. No network or
/// environment-based key lookup; the saved profile must still be the same one.
@MainActor public enum StudioCredentialCommand {
    /// The saved key for `profileID` if it is still the connected, unblocked
    /// profile. Never shows a Keychain dialog. Used by the helper and by the
    /// app when it answers the helper over `StudioCredentialChannel`.
    public static func savedKey(profileID: String) -> String? {
        let defaults = StudioPreferences.applicationDefaults
        return savedKey(profileID: profileID, defaults: defaults, settings: StudioPreferences(defaults: defaults), keys: StudioKeychainStorage())
    }
    static func savedKey(profileID: String, defaults: UserDefaults, settings: any StudioSettingsStorage, keys: any StudioKeyStorage) -> String? {
        guard let profile = try? settings.profiles().first(where: { $0.id == profileID }), profile.credentialMode == .direct,
              defaults.string(forKey: "studio.blockedProfile") != profile.id,
              !(defaults.stringArray(forKey: "studio.blockedProfiles.v2") ?? []).contains(profile.id),
              let key = try? keys.load(profileID: profile.id, allowInteraction: false) else { return nil }
        return key
    }

    public static func run(arguments: [String]) -> Int32 {
        // Legacy macOS file-keychain queries can ignore the per-query UI flag.
        // This process exists only to supply a credential to a CLI: never wait
        // for a hidden authorization dialog in its stdout pipe.
        SecKeychainSetUserInteractionAllowed(false)
        // Ask the running app first (its Keychain approval survives in-app use);
        // fall back to this helper's own Keychain access when the app is closed.
        guard arguments.count == 2, arguments[0] == "--profile",
              let key = StudioCredentialChannel.request(profileID: arguments[1]) ?? savedKey(profileID: arguments[1]) else {
            FileHandle.standardError.write(Data("Không đọc được key Studio. Mở Agent Watch và kiểm tra tab Studio.\n".utf8))
            return 1
        }
        FileHandle.standardOutput.write(Data((key + "\n").utf8))
        return 0
    }
}
