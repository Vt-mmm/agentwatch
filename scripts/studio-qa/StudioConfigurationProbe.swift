import Foundation
@testable import AgentWatchCore

// Loopback-only QA adapter. Generates the same files as the UI in an explicitly
// supplied temporary root; helper is synthetic, never production Keychain.
@main struct StudioConfigurationProbe {
    static func main() throws {
        let a = CommandLine.arguments
        guard a.count == 6, let tool = StudioConfiguredTool(rawValue: a[1]), a[3].hasPrefix("http://127.0.0.1:") else { throw StudioConfigurationError.invalid }
        let directory = URL(fileURLWithPath: a[2]), origin = try StudioOrigin(a[3]), provider = a[4]
        var model = StudioModel(id: provider == "claude" ? "claude-haiku-4-5-20251001" : "gpt-6-luna", displayName: "QA", ownedBy: provider, nativeProtocol: provider == "claude" ? "messages" : "responses")
        model.providerModel = model.id; model.clientModel = model.providerModel
        model.maxOutputTokens = 16384; model.contextMode = "provider_default"
        let catalog = tool == .pi ? try StudioClientConfiguration.catalogModel(for: model, piExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/pi")) : nil
        let plan = try StudioClientConfiguration.prepare(tool: tool, directory: directory,
            connection: StudioProfile(origin: origin, id: String(repeating: "a", count: 64)), model: model,
            helper: URL(fileURLWithPath: a[5]), piCatalogModel: catalog)
        try StudioClientConfiguration.apply(plan)
    }
}
