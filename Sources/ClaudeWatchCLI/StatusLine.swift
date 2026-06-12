// `claudewatch statusline` — single-line output cho Claude Code statusLine.
//
// Cách wire: thêm vào ~/.claude/settings.json:
//   {
//     "statusLine": {
//       "type": "command",
//       "command": "claudewatch statusline"
//     }
//   }
//
// Claude Code gọi command mỗi tick, đẩy JSON session info qua stdin. Mình
// đọc transcript path → parse → render pet face + tokens + cost + chat bubble
// snippet trên 1 dòng. Animation tick-based (frame xoay theo thời gian thực).

import Foundation
import ClaudeWatchCore

struct StatusLineCommand {
    func run() {
        let info = readStdinJSON()
        let stats = loadStats(from: info?["transcript_path"] as? String)
        let line = renderStatusLine(stats: stats, info: info)
        // statusLine output không xuống dòng — Claude Code tự cắt.
        FileHandle.standardOutput.write(line.data(using: .utf8) ?? Data())
    }

    private func readStdinJSON() -> [String: Any]? {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func loadStats(from path: String?) -> SessionStats? {
        guard let path, !path.isEmpty else {
            // Fallback: pick session mới nhất nếu Claude Code không cung cấp path.
            if let url = ProjectPath.mostRecentSessionAcrossAllProjects() {
                return JsonlParser.parseSession(at: url)
            }
            return nil
        }
        return JsonlParser.parseSession(at: URL(fileURLWithPath: path))
    }
}

// MARK: - Render

/// Pet animation frames — 4 frames, cycle ~2Hz theo Date.now.
/// Mỗi state có pool frame riêng để pet "động" khi statusLine refresh.
private func petFrame(_ state: PetState) -> String {
    let frames: [String]
    switch state {
    case .happy:
        frames = ["( ^.^ )", "( ^_^ )", "( ^.^ )", "( ^o^ )"]
    case .excited:
        frames = ["(*^o^*)", "(*^O^*)", "(*\\o/*)", "(*^O^*)"]
    case .worried:
        frames = ["( O.o )", "( o.O )", "( O.o )", "( T.T )"]
    case .dizzy:
        frames = ["( @.@ )", "( x.x )", "( @_@ )", "( x_x )"]
    case .sleepy:
        frames = ["( -.- )", "( -.- )", "( z.z )", "( -.- )"]
    }
    let idx = Int(Date().timeIntervalSince1970 * 2) % frames.count
    return frames[idx]
}

func renderStatusLine(stats: SessionStats?, info: [String: Any]?) -> String {
    // Compute pet state — single session signal nếu có, else sleepy.
    let petState: PetState = {
        guard let s = stats else { return .sleepy }
        if s.toolCalls > 0 && s.cost > 5 { return .worried }
        if s.activeAgents.count >= 5 { return .dizzy }
        if s.toolCalls > 0 { return .happy }
        return .sleepy
    }()

    let face = colorize(petFrame(petState), petColor(petState))

    // Chat snippet — xoay 1 câu mỗi 8s, dùng tone phù hợp state.
    let bubble = pickBubble(for: petState, stats: stats)

    // Stats: cost orange, tokens dim. Sep bằng │ thanh đứng.
    let sep = colorize(" │ ", Ansi.dim)
    var parts: [String] = [face]
    if let s = stats {
        let cost = colorize(String(format: "$%.2f", s.cost), Ansi.orange)
        let tok = colorize("\(fmtTokens(s.inputTokens))/\(fmtTokens(s.outputTokens))",
                            Ansi.dim)
        parts.append(cost)
        parts.append(tok)
        if s.activeAgents.count > 0 {
            parts.append(colorize("\(s.activeAgents.count) agent",
                                  s.activeAgents.count >= 5 ? Ansi.red : Ansi.cyan))
        }
    } else if let model = (info?["model"] as? [String: Any])?["display_name"] as? String {
        parts.append(colorize(model, Ansi.dim))
    }
    if !bubble.isEmpty {
        parts.append(colorize("💬 \(bubble)", Ansi.cyan))
    }
    return parts.joined(separator: sep)
}

/// Pick 1 câu chat ngắn cho statusLine. Rotate theo phút để không nhấp nháy
/// quá nhanh. Trả "" nếu không có gì đáng nói.
private func pickBubble(for state: PetState, stats: SessionStats?) -> String {
    let minute = Int(Date().timeIntervalSince1970 / 60)
    let pool: [String]
    switch state {
    case .happy:
        pool = ["coding ổn nhỉ", "keep going", "chill"]
    case .excited:
        pool = ["🚀 nice!", "tăng tốc!", "good prompt!"]
    case .worried:
        if let cost = stats?.cost {
            pool = [String(format: "$%.2f rồi 👀", cost), "cẩn thận cost", "review thử?"]
        } else {
            pool = ["watch out", "cẩn thận"]
        }
    case .dizzy:
        let n = stats?.activeAgents.count ?? 0
        pool = ["\(n) agents @_@", "loop?", "quá nhiều subagent"]
    case .sleepy:
        pool = ["💤 ngủ tí...", "đang chờ", "không có việc"]
    }
    return pool[abs(minute) % pool.count]
}
