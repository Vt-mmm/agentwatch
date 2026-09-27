import AppKit
import SwiftUI

private actor FixtureClient: StudioConnecting, StudioReporting {
    var offline = false
    func setOffline() { offline = true }
    func connect(origin: StudioOrigin, key: String) async throws -> StudioConnectionSnapshot {
        if offline { throw StudioError.offline }
        let identity = StudioIdentity(user: StudioUser(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, displayName: "Nhân viên mẫu", role: "member", active: true, version: 1), orgID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, apiVersion: "studio/v1")
        return StudioConnectionSnapshot(identity: identity, capabilities: StudioCapabilities(apiVersion: "studio/v1", protocols: [], auth: ["bearer"]), models: .available([StudioModel(id: "claude-haiku", displayName: "Claude Haiku", ownedBy: "claude", nativeProtocol: "messages")]))
    }
    func dashboard(origin: StudioOrigin, key: String, identity: StudioIdentity, model: StudioModel?, now: Date, timezone: TimeZone) async throws -> StudioDashboardSnapshot {
        let range = try StudioReportingRange(now: now, timezone: timezone)
        let count: (String) -> StudioCount = { try! StudioCount($0) }
        let tokens = StudioTokenTotals(total_tokens: count("24830"), input_tokens: count("22000"), output_tokens: count("2830"), cache_read_tokens: count("8000"), cache_write_tokens: count("500"), reasoning_tokens: count("120"))
        let unknown = StudioTokenTotals(total_tokens: nil, input_tokens: nil, output_tokens: nil, cache_read_tokens: nil, cache_write_tokens: nil, reasoning_tokens: nil)
        let summary = StudioUsageSummary(requests: count("12"), confirmed_requests: count("10"), unresolved_requests: count("2"), disputed_requests: count("1"), charged_tokens: count("24980"), confirmed: tokens)
        let group = StudioUsageGroup(id: model!.id, label: model!.displayName, requests: count("12"), unresolved_requests: count("2"), charged_tokens: count("24980"), confirmed: tokens)
        let today = StudioOverview(source: "studio_ledger", timezone: range.timezone, observed_at: now, from: range.today, to: range.until, summary: summary, models: [group])
        let month = StudioOverview(source: "studio_ledger", timezone: range.timezone, observed_at: now, from: range.month, to: range.until, summary: summary, models: [group])
        let recent = StudioUsageReport(source: "studio_ledger", timezone: range.timezone, observed_at: now, from: range.month, to: range.until, requests: [
            StudioUsageRequest(id: UUID(), user_id: identity.user.id, key_id: identity.orgID, model_id: model!.id, provider: "claude", accounting_status: "unresolved", created_at: range.today, charged_tokens: count("0"), confirmed: unknown),
            StudioUsageRequest(id: UUID(), user_id: identity.user.id, key_id: identity.orgID, model_id: model!.id, provider: "claude", accounting_status: "confirmed", created_at: range.today, charged_tokens: count("24830"), confirmed: tokens)
        ], limit: 20, offset: 0)
        let window = StudioQuotaWindow(id: identity.orgID, policy_id: identity.orgID, model_id: nil, period: "day", timezone: range.timezone, tokens: 100000, starts_at: range.today, ends_at: range.today.addingTimeInterval(86400), confirmed_tokens: count("24830"), reserved_tokens: count("6000"), remaining_tokens: count("69170"))
        let quota = StudioQuota(policy_allowed: true, admission_required: true, user_id: identity.user.id, key_id: identity.orgID, model_id: model!.id, reason: nil, observed_at: now, windows: [window], policies: [StudioQuotaPolicy(id: identity.orgID, scope: "user")])
        return StudioDashboardSnapshot(identity: identity, today: today, month: month, recent: recent, quotaModel: model, quota: quota, quotaError: nil, fetchedAt: now)
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
@MainActor private final class FixtureCache: StudioDashboardCaching {
    func load(profile: StudioProfile) throws -> StudioDashboardSnapshot? { nil }
    func save(_ snapshot: StudioDashboardSnapshot, profile: StudioProfile) throws {}
    func delete(profile: StudioProfile) throws {}
}
@MainActor private final class FixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@main struct Render {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let client = FixtureClient()
            let store = StudioConnectionStore(client: client, keys: FixtureKeys(), settings: FixtureSettings(), cache: FixtureCache())
            if CommandLine.arguments.contains("connected") { await store.connect(origin: "https://studio.example.com", key: "fixture_key") }
            if CommandLine.arguments.contains("stale") { await client.setOffline(); await store.refresh() }
            let launcher = CommandLine.arguments.contains("launcher")
            let height: CGFloat = launcher ? 620 : (CommandLine.arguments.contains("connected") && !CommandLine.arguments.contains("stale") ? 2300 : 790)
            let content: AnyView = launcher ? AnyView(StudioLauncherView().padding(20)) : AnyView(StudioConnectionView())
            let view = NSHostingView(rootView: content.environment(store).frame(width: 720, height: height).background(Claude.backgroundGradient).environment(\.colorScheme, .light))
            let window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
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
