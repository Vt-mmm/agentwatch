// claudewatch CLI — terminal pet mascot + live token/cost dashboard.
//
// Subcommands:
//   claudewatch watch         live mode, refresh 2s, ASCII pet phản ánh state
//   claudewatch status        snapshot 1 lần rồi exit (CI/script friendly)
//   claudewatch report [day|week]   stats coaching kỳ vừa qua
//
// Mặc định scan ~/.claude/projects + Desktop sessions, tự pick session mới nhất
// đang active. Tái sử dụng ClaudeWatchCore (PetState, JsonlParser, …) — không
// duplicate logic.

import Foundation
import ClaudeWatchCore

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
let sub = args.first ?? "watch"

switch sub {
case "watch":  WatchCommand().run()
case "status": StatusCommand().run()
case "report": ReportCommand(arg: args.dropFirst().first).run()
case "-h", "--help", "help":
    printHelp()
default:
    FileHandle.standardError.write("Unknown subcommand: \(sub)\n".data(using: .utf8)!)
    printHelp(); exit(1)
}

func printHelp() {
    let txt = """
    claudewatch — terminal companion cho Claude Code sessions.

    Usage:
      claudewatch watch                 live dashboard với pet (Ctrl+C để thoát)
      claudewatch status                snapshot 1 lần
      claudewatch report [day|week]     stats coaching ngày/tuần

    Pet state phản ánh coaching signals:
      😺 happy    — burn rate ổn
      ★_★ excited — chất lượng prompt tăng
      😟 worried  — outlier session (cost vượt 2σ)
      @_@ dizzy   — agent loop (≥10 Agent/session)
      -_- sleepy  — không có hoạt động
    """
    print(txt)
}

// MARK: - ANSI helpers

enum Ansi {
    static let reset = "\u{001B}[0m"
    static let bold  = "\u{001B}[1m"
    static let dim   = "\u{001B}[2m"
    static let orange = "\u{001B}[38;5;208m"
    static let yellow = "\u{001B}[33m"
    static let red    = "\u{001B}[31m"
    static let green  = "\u{001B}[32m"
    static let cyan   = "\u{001B}[36m"
    static let clearScreen = "\u{001B}[2J\u{001B}[H"
    static let hideCursor = "\u{001B}[?25l"
    static let showCursor = "\u{001B}[?25h"
}

func colorize(_ s: String, _ ansi: String) -> String { "\(ansi)\(s)\(Ansi.reset)" }

func petColor(_ state: PetState) -> String {
    switch state {
    case .happy, .excited: return Ansi.orange
    case .worried:         return Ansi.yellow
    case .dizzy:           return Ansi.red
    case .sleepy:          return Ansi.dim
    }
}

func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
    if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

func fmtUsd(_ c: Double) -> String { String(format: "$%.3f", c) }

// MARK: - Data helpers

/// Pick most-recent active session từ cả ~/.claude/projects + Desktop sessions.
func pickActiveStats() -> SessionStats? {
    if let url = ProjectPath.mostRecentSessionAcrossAllProjects() {
        return JsonlParser.parseSession(at: url)
    }
    return nil
}

/// Compute pet state từ session list (1-day window cho watch/status).
func computePet(_ sessions: [SessionSummary]) -> PetState {
    let signals = PetSignals(
        hasActivity: !sessions.isEmpty,
        outlierCount: CoachingInsights.outlierSessions(sessions).count,
        agentLoopCount: CoachingInsights.agentLoopSessions(sessions).count,
        avgStarsDelta: 0)  // CLI watch không track delta — chỉ instant signals
    return PetMood.resolve(signals)
}

// MARK: - Subcommands

struct StatusCommand {
    func run() {
        let sessions = scanDaySessions()
        let stats = pickActiveStats()
        let pet = computePet(sessions)
        render(pet: pet, sessions: sessions, active: stats, talk: nil)
    }
}

struct WatchCommand {
    func run() {
        signal(SIGINT) { _ in
            print(Ansi.showCursor, terminator: "")
            exit(0)
        }
        print(Ansi.hideCursor, terminator: "")

        // State để detect change → emit chat bubble.
        var warnedOutliers: Set<String> = []
        var warnedLoops: Set<String> = []
        var lastSessionCount: Int = -1
        var variant: Int = 0
        var lastTalk: PetTalk? = PetTalkOracle.line(for: .startup, variant: 0)
        var talkExpireAt: Date = Date().addingTimeInterval(5)

        while true {
            let sessions = scanDaySessions()
            let active = pickActiveStats()
            let petState = computePet(sessions)

            // Emit talk theo event mới phát sinh giữa 2 tick.
            if lastSessionCount >= 0, sessions.count > lastSessionCount,
               let proj = active?.projectSlug {
                variant += 1
                lastTalk = PetTalkOracle.line(
                    for: .sessionStarted(project: ProjectPath.displayPath(for: proj)),
                    variant: variant)
                talkExpireAt = Date().addingTimeInterval(6)
            }
            lastSessionCount = sessions.count
            for sid in CoachingInsights.outlierSessions(sessions)
                where !warnedOutliers.contains(sid) {
                warnedOutliers.insert(sid)
                if let s = sessions.first(where: { $0.id == sid }) {
                    variant += 1
                    lastTalk = PetTalkOracle.line(
                        for: .outlierDetected(cost: s.cost), variant: variant)
                    talkExpireAt = Date().addingTimeInterval(8)
                }
            }
            for sid in CoachingInsights.agentLoopSessions(sessions)
                where !warnedLoops.contains(sid) {
                warnedLoops.insert(sid)
                if let s = sessions.first(where: { $0.id == sid }) {
                    variant += 1
                    lastTalk = PetTalkOracle.line(
                        for: .agentLoopDetected(agentCount: s.agentCount),
                        variant: variant)
                    talkExpireAt = Date().addingTimeInterval(8)
                }
            }

            let showTalk: PetTalk? = (Date() < talkExpireAt) ? lastTalk : nil

            print(Ansi.clearScreen, terminator: "")
            render(pet: petState, sessions: sessions, active: active, talk: showTalk)
            print("\n\(colorize("(Ctrl+C để thoát, refresh mỗi 2s)", Ansi.dim))")
            Thread.sleep(forTimeInterval: 2.0)
        }
    }
}

struct ReportCommand {
    let arg: String?
    func run() {
        let sessions: [SessionSummary]
        let title: String
        if arg == "week" {
            sessions = scanRange(daysBack: 7)
            title = "7 ngày gần nhất"
        } else {
            sessions = scanDaySessions()
            title = "Hôm nay"
        }
        let pet = computePet(sessions)
        print("\(colorize("Coaching report — \(title)", Ansi.bold))\n")
        renderArt(pet)
        print()
        renderSessions(sessions, limit: 10)
        renderInsights(sessions)
    }
}

// MARK: - Scanners

/// Tất cả session có hoạt động hôm nay (local time).
func scanDaySessions() -> [SessionSummary] {
    let cal = Calendar.current
    let start = cal.startOfDay(for: Date())
    let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date()
    return SessionInventory.list(in: start...end.addingTimeInterval(-1))
        .sorted { $0.cost > $1.cost }
}

/// Session trong N ngày gần nhất.
func scanRange(daysBack: Int) -> [SessionSummary] {
    let cal = Calendar.current
    let start = cal.date(byAdding: .day, value: -daysBack + 1,
                         to: cal.startOfDay(for: Date())) ?? Date()
    return SessionInventory.list(in: start...Date())
        .sorted { $0.cost > $1.cost }
}

// MARK: - Renderers

func render(pet: PetState, sessions: [SessionSummary],
            active: SessionStats?, talk: PetTalk?) {
    print(colorize("claudewatch", Ansi.bold) +
          colorize("  \(now())", Ansi.dim))
    print()
    if let t = talk { renderBubble(t) }
    renderArt(pet)
    print()
    renderTotals(sessions)
    if let s = active {
        print()
        renderActive(s)
    }
    renderInsights(sessions)
}

/// Bubble chat ASCII đặt trên đầu pet. Width tự co theo message length.
func renderBubble(_ talk: PetTalk) {
    let msg = talk.message
    let color: String = {
        switch talk.tone {
        case .alert:   return Ansi.red
        case .warning: return Ansi.yellow
        default:       return Ansi.cyan
        }
    }()
    let w = msg.count + 4
    let top = "  ╭" + String(repeating: "─", count: w - 2) + "╮"
    let mid = "  │ " + msg + " │"
    let bot = "  ╰" + String(repeating: "─", count: w - 2) + "╯"
    let tail = "       v"
    print(colorize(top, color))
    print(colorize(mid, color))
    print(colorize(bot, color))
    print(colorize(tail, color))
}

func renderArt(_ state: PetState) {
    let lines = state.asciiArt
    let color = petColor(state)
    for line in lines { print(colorize(line, color)) }
    print(colorize(state.caption, Ansi.dim))
}

func renderTotals(_ sessions: [SessionSummary]) {
    let total = sessions.reduce(0.0) { $0 + $1.cost }
    let tokens = sessions.reduce(0) { $0 + $1.totalTokens }
    let tools = sessions.reduce(0) { $0 + $1.toolCallCount }
    print(colorize("[Tổng hôm nay]", Ansi.cyan))
    print("  sessions: \(sessions.count)   tokens: \(fmtTokens(tokens))   tools: \(tools)")
    print("  cost:     \(colorize(fmtUsd(total), Ansi.orange))")
}

func renderActive(_ s: SessionStats) {
    print(colorize("[Session đang chạy]", Ansi.green))
    let proj = ProjectPath.displayPath(for: s.projectSlug)
    print("  project: \(proj)")
    let model = s.model.isEmpty ? "?" : s.model
    print("  model:   \(model) (\(s.modelFamily.rawValue))")
    print("  tokens:  in=\(fmtTokens(s.inputTokens)) out=\(fmtTokens(s.outputTokens)) cR=\(fmtTokens(s.cacheReadTokens)) cW=\(fmtTokens(s.cacheWriteTokens))")
    print("  cost:    \(colorize(fmtUsd(s.cost), Ansi.orange))   tools: \(s.toolCalls)   agents: \(s.activeAgents.count)/\(s.agents.count)")
}

func renderSessions(_ sessions: [SessionSummary], limit: Int) {
    let top = Array(sessions.prefix(limit))
    guard !top.isEmpty else { return }
    print(colorize("[Top sessions theo cost]", Ansi.cyan))
    for (i, s) in top.enumerated() {
        let cost = fmtUsd(s.cost)
        let proj = s.projectDisplay
        let model = s.model.isEmpty ? "?" : s.model
        let row = String(format: "  %2d. %-10s  %-32s  %@",
                         i + 1, cost, proj, model)
        print(row)
    }
}

func renderInsights(_ sessions: [SessionSummary]) {
    let outliers = CoachingInsights.outlierSessions(sessions)
    let loops = CoachingInsights.agentLoopSessions(sessions)
    guard !outliers.isEmpty || !loops.isEmpty else { return }
    print()
    print(colorize("[Cảnh báo]", Ansi.yellow))
    if !outliers.isEmpty {
        print(colorize("  🚨 \(outliers.count) outlier session", Ansi.red) +
              " (cost > mean + 2σ)")
    }
    if !loops.isEmpty {
        print(colorize("  ⚠️  \(loops.count) session có agent loop", Ansi.yellow) +
              " (≥\(CoachingInsights.agentLoopThreshold) Agent)")
    }
}

func now() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss dd/MM/yyyy"
    f.timeZone = .current
    return f.string(from: Date())
}
