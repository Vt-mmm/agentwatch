import Foundation

// Invoked only by Studio's opt-in PostgreSQL integration fixture. Credentials
// belong to its temporary schema and stay in this process environment/memory.
@main struct StudioDashboardProbe {
    static func main() async throws {
        guard let raw = ProcessInfo.processInfo.environment["STUDIO_FIXTURE_ORIGIN"],
              raw.hasPrefix("http://127.0.0.1:"),
              let key = ProcessInfo.processInfo.environment["STUDIO_FIXTURE_KEY"] else { throw StudioError.invalidOrigin }
        let origin = try StudioOrigin(raw), client = StudioClient()
        if CommandLine.arguments.contains("revoked") {
            do { _ = try await client.connect(origin: origin, key: key) }
            catch StudioError.invalidKey { print("PASS native employee key revocation"); return }
            throw StudioError.invalidResponse
        }
        let connection = try await client.connect(origin: origin, key: key)
        guard case .available(let models) = connection.models, let model = models.first, model.id == "studio-model" else { throw StudioError.invalidResponse }
        let report = try await client.dashboard(origin: origin, key: key, identity: connection.identity, model: model, timezone: TimeZone(identifier: "UTC")!)
        guard report.today.summary.requests.value == "2", report.month.summary.requests.value == "2",
              report.month.summary.confirmed.total_tokens?.value == "15",
              report.month.summary.unresolved_requests.value == "1",
              report.recent.requests.count == 2,
              report.recent.requests.filter({ $0.confirmed.total_tokens == nil }).count == 1,
              let quota = report.quota, quota.policy_allowed, quota.windows.count == 2,
              quota.windows.allSatisfy({ $0.confirmed_tokens.value == "15" && $0.reserved_tokens.value != "0" }) else { throw StudioError.invalidResponse }
        print("PASS native Studio client + real PostgreSQL: owner/model, 2 requests, 15 confirmed fixture tokens, 1 unresolved, 2 shared quota windows with retained reservation")
    }
}
