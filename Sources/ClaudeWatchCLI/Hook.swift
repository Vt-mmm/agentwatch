// `claudewatch hook <event>` — Claude Code hook handler. Output đi vào
// conversation luôn (Claude Code in stdout của hook command như system msg).
//
// Wire config trong ~/.claude/settings.json (claudewatch setup tự làm):
//   "hooks": {
//     "SessionStart":      [...],
//     "Stop":              [...],
//     "PreCompact":        [...],
//     "UserPromptSubmit":  [...],
//     "PostToolUse":       [...],
//     "SubagentStop":      [...]
//   }
//
// Output: ASCII pet 3 dòng + 1 dòng message. Compact để không spam conversation.
// ADDITIVE: ngoài stdout, còn gửi PetEvent qua Unix socket tới app nếu đang chạy.

import Foundation
import ClaudeWatchCore

struct HookCommand {
    let event: String

    func run() {
        let info = readStdinJSON()
        let transcriptPath = info?["transcript_path"] as? String
        let sessionId = info?["session_id"] as? String
        let stats = loadStats(from: transcriptPath)

        switch event {
        case "session-start":
            let msg = greetMessage(stats: stats)
            renderHook(state: .happy, message: msg)
            sendSocketEvent(PetEvent(kind: .sessionStart,
                                    sessionId: sessionId,
                                    transcriptPath: transcriptPath))

        case "stop":
            let state = petStateForStop(stats: stats)
            let msg = stopMessage(stats: stats)
            renderHook(state: state, message: msg)
            sendSocketEvent(PetEvent(kind: .stop,
                                    sessionId: sessionId,
                                    transcriptPath: transcriptPath))

        case "pre-compact":
            renderHook(state: .sleepy,
                       message: "Đang nén context — em chợp mắt tí 💤")
            sendSocketEvent(PetEvent(kind: .preCompact,
                                    sessionId: sessionId,
                                    transcriptPath: transcriptPath))

        case "user-prompt":
            // Rotate qua 3 câu theo giây modulo 3 để tránh luôn cùng câu.
            let pool = ["Em đang nghĩ ạ!", "Để em xem...", "Vâng Cậu Chủ!"]
            let idx = Int(Date().timeIntervalSince1970) % pool.count
            renderHook(state: .happy, message: pool[idx])
            sendSocketEvent(PetEvent(kind: .userPrompt, sessionId: sessionId))

        case "post-tool-use":
            // Silent — chỉ bounce state .excited, không in message vào conversation.
            let toolName = info?["tool_name"] as? String
            sendSocketEvent(PetEvent(kind: .postToolUse,
                                    sessionId: sessionId,
                                    toolName: toolName))

        case "subagent-stop":
            let agents = stats?.activeAgents.count ?? 0
            let state: PetState = agents >= 5 ? .dizzy : .happy
            renderHook(state: state, message: "Agent xong rồi!")
            sendSocketEvent(PetEvent(kind: .subagentStop,
                                    sessionId: sessionId,
                                    transcriptPath: transcriptPath))

        default:
            FileHandle.standardError.write(
                "Unknown hook event: \(event)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    // MARK: - Socket send (additive, silent fail)

    /// Gửi PetEvent tới app socket. Nếu app không chạy → silent skip.
    /// KHÔNG bao giờ throw hoặc exit — hook không được phép fail vì socket.
    private func sendSocketEvent(_ event: PetEvent) {
        PetEventSender.send(event)
    }

    // MARK: - Stdin

    private func readStdinJSON() -> [String: Any]? {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func loadStats(from path: String?) -> SessionStats? {
        guard let path, !path.isEmpty else { return nil }
        return JsonlParser.parseSession(at: URL(fileURLWithPath: path))
    }

    // MARK: - State helpers

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

    // MARK: - Render

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
