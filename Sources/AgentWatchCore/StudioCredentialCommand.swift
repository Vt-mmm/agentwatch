import Foundation
import Security

/// Noninteractive credential helper for CLI-owned HTTP requests. No network or
/// environment-based key lookup; the saved profile must still be the same one.
@MainActor public enum StudioCredentialCommand {
    public static func run(arguments: [String]) -> Int32 {
        // Legacy macOS file-keychain queries can ignore the per-query UI flag.
        // This process exists only to supply a credential to a CLI: never wait
        // for a hidden authorization dialog in its stdout pipe.
        SecKeychainSetUserInteractionAllowed(false)
        do {
            guard arguments.count == 2, arguments[0] == "--profile",
                  let profile = try StudioPreferences(defaults: StudioPreferences.applicationDefaults).load(),
                  profile.id == arguments[1],
                  let key = try StudioKeychainStorage().load(profileID: profile.id, allowInteraction: false) else { throw StudioError.invalidKey }
            FileHandle.standardOutput.write(Data((key + "\n").utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("Không đọc được key của profile Studio đang kết nối.\n".utf8))
            return 1
        }
    }
}
