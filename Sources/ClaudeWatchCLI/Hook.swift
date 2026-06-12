// `claudewatch hook <event>` — Claude Code hook handler. Output đi vào
// conversation luôn (Claude Code in stdout của hook command như system msg).
//
// Wire config trong ~/.claude/settings.json (claudewatch setup tự làm):
//   "hooks": {
//     "SessionStart": [{ "matcher": "*", "hooks":
//       [{"type":"command","command":"claudewatch hook session-start"}] }],
//     "Stop":         [{ "matcher": "*", "hooks":
//       [{"type":"command","command":"claudewatch hook stop"}] }]
//   }
//
// Output: ASCII pet 3 dòng + 1 dòng message. Compact để không spam conversation.

import Foundation
import ClaudeWatchCore

struct HookCommand {
    let event: String

    func run() {
        let info = readStdinJSON()
        let stats = loadStats(from: info?["transcript_path"] as? String)

        switch event {
        case "session-start":
            renderHook(state: .happy,
                       message: greetMessage(stats: stats))
        case "stop":
            renderHook(state: petStateForStop(stats: stats),
                       message: stopMessage(stats: stats))
        case "pre-compact":
            renderHook(state: .sleepy,
                       message: "Đang nén context — em chợp mắt tí 💤")
        default:
            FileHandle.standardError.write(
                "Unknown hook event: \(event)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    private func readStdinJSON() -> [String: Any]? {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func loadStats(from path: String?) -> SessionStats? {
        guard let path, !path.isEmpty else { return nil }
        return JsonlParser.parseSession(at: URL(fileURLWithPath: path))
    }

    /// State cho Stop event: outlier cost → worried, nhiều agent → dizzy,
    /// else excited (task xong).
    private func petStateForStop(stats: SessionStats?) -> PetState {
        guard let s = stats else { return .happy }
        if s.activeAgents.count >= 5 { return .dizzy }
        if s.cost > 5 { return .worried }
        return .excited
    }

    private func greetMessage(stats: SessionStats?) -> String {
        if let s = stats {
            let proj = ProjectPath.displayPath(for: s.projectSlug)
            return "Cậu Chủ! Em watch project \(proj) đây ạ."
        }
        return "Cậu Chủ! Em ở đây rồi, code chuẩn nhé!"
    }

    private func stopMessage(stats: SessionStats?) -> String {
        guard let s = stats else { return "Done! Pet xin chúc mừng." }
        let cost = String(format: "$%.3f", s.cost)
        let agents = s.activeAgents.count
        if agents >= 5 {
            return "Done — nhưng \(agents) agent active, coi chừng loop nha!"
        }
        if s.cost > 5 {
            return "Done! Phiên này tốn \(cost) — review thử coi đáng không."
        }
        return "Done! Cậu Chủ tốn \(cost) thôi, ok nhỉ 🎉"
    }

    /// Render ASCII art + message vào stdout. Claude Code hiển thị inline
    /// conversation. Dùng ANSI color để pet nổi bật.
    private func renderHook(state: PetState, message: String) {
        let color = petColor(state)
        let lines = state.asciiArt
        var out = ""
        out += colorize("┄┄ \(message) ┄┄", Ansi.dim) + "\n"
        for line in lines {
            out += colorize(line, color) + "\n"
        }
        FileHandle.standardOutput.write(out.data(using: .utf8) ?? Data())
    }
}
