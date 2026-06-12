// Tiny CLI to sanity-check the core library against real JSONL.
// Usage: claude-watch-demo [project-path]   (defaults to current working dir)

import Foundation
import ClaudeWatchCore

let args = CommandLine.arguments
let followMode = args.contains("--follow")
let cwdPath = args.dropFirst().first(where: { !$0.hasPrefix("--") })
    ?? FileManager.default.currentDirectoryPath
let cwd = URL(fileURLWithPath: cwdPath)

let stats: SessionStats? = {
    if followMode {
        guard let url = ProjectPath.mostRecentSessionAcrossAllProjects() else { return nil }
        print("[follow] picked: \(url.path)")
        return JsonlParser.parseSession(at: url)
    }
    return JsonlParser.parseLatestSession(for: cwd)
}()

guard let stats else {
    FileHandle.standardError.write("no session found\n".data(using: .utf8)!)
    exit(1)
}

func fmt(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
    if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

print("session : \(stats.sessionId)")
print("project : \(ProjectPath.displayPath(for: stats.projectSlug))")
print("model   : \(stats.model.isEmpty ? "?" : stats.model) (\(stats.modelFamily.rawValue))")
print("tokens  : in=\(fmt(stats.inputTokens)) out=\(fmt(stats.outputTokens)) cR=\(fmt(stats.cacheReadTokens)) cW=\(fmt(stats.cacheWriteTokens))")
print("cost    : $\(String(format: "%.3f", stats.cost))")
print("agents  : \(stats.activeAgents.count) active / \(stats.agents.count) total")
print("messages: \(stats.messageCount)  tool_calls: \(stats.toolCalls)")
print("last evt: \(stats.lastEventAt)")
