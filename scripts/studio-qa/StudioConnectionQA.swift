import AppKit
import SwiftUI

private struct FixtureClient: StudioConnecting {
    func connect(origin: StudioOrigin, key: String) async throws -> StudioConnectionSnapshot {
        let identity = StudioIdentity(user: StudioUser(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, displayName: "Nhân viên mẫu", role: "member", active: true, version: 1), orgID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, apiVersion: "studio/v1")
        return StudioConnectionSnapshot(identity: identity, capabilities: StudioCapabilities(apiVersion: "studio/v1", protocols: [], auth: ["bearer"]), models: .available([StudioModel(id: "claude-haiku", displayName: "Claude Haiku", ownedBy: "claude", nativeProtocol: "messages")]))
    }
}
@MainActor private final class FixtureKeys: StudioKeyStorage {
    func load(profileID: String) throws -> String? { "fixture_key" }
    func save(_ key: String, profileID: String) throws {}
    func delete(profileID: String) throws {}
}
@MainActor private final class FixtureSettings: StudioSettingsStorage {
    func load() throws -> StudioProfile? { nil }
    func save(_ profile: StudioProfile?) {}
}
@main struct Render {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let store = StudioConnectionStore(client: FixtureClient(), keys: FixtureKeys(), settings: FixtureSettings())
            if CommandLine.arguments.contains("connected") { await store.connect(origin: "https://studio.example.com", key: "fixture_key") }
            let view = NSHostingView(rootView: StudioConnectionView().environment(store).frame(width: 720, height: 790).background(Claude.backgroundGradient).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 790), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
            app.terminate(nil)
        }
        app.run()
    }
}
