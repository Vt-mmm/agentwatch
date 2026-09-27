import AppKit
import AgentWatchCore

@MainActor enum StudioTerminalOpener {
    static func open(_ command: StudioTerminalCommand, activate: Bool = true) async throws {
        do {
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw StudioCLIError.terminalFailed }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = activate
            _ = try await NSWorkspace.shared.open([command.url], withApplicationAt: terminal, configuration: configuration)
        } catch { command.discard(); throw StudioCLIError.terminalFailed }
    }
}
