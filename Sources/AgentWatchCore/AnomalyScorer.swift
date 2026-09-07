// Rule-based anomaly detection cho PromptRecord list — surface prompt/session
// đáng review nhất. KHÔNG dùng ML, chỉ heuristic đơn giản nhưng hữu ích cho
// personal use.
//
// 3 rule chính:
//  1. effortImbalance — 1★ + text > 1000 char (đầu tư công viết dài nhưng vague)
//  2. promptLoop     — ≥3 prompt trong cùng session có prefix-50-char giống nhau
//                      (user lặp lại 1 ý nhiều lần, AI không hiểu hoặc fail)
//  3. driftingSession — session có ≥5 prompt và avg ★ ≤ 2 (session dài lê thê)
//
// Ranking: severity score (effort=2, loop=3, drift=3) — top kind theo session.
// Trả về tối đa N anomalies, sorted theo severity desc rồi timestamp desc.

import Foundation

/// Loại anomaly được detect.
public enum AnomalyKind: String, Sendable, Equatable {
    case effortImbalance  // 1★ + dài
    case promptLoop       // lặp ý
    case driftingSession  // session dài không hiệu quả

    public var label: String {
        switch self {
        case .effortImbalance: return "Effort imbalance"
        case .promptLoop:      return "Prompt loop"
        case .driftingSession: return "Drifting session"
        }
    }

    public var icon: String {
        switch self {
        case .effortImbalance: return "scalemass"
        case .promptLoop:      return "arrow.triangle.2.circlepath"
        case .driftingSession: return "tornado"
        }
    }

    public var severity: Int {
        switch self {
        case .effortImbalance: return 2
        case .promptLoop:      return 3
        case .driftingSession: return 3
        }
    }
}

/// 1 anomaly đã detect — gắn vào 1 prompt cụ thể (representative) + session.
public struct Anomaly: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: AnomalyKind
    public let representative: PromptRecord
    public let reason: String
    public let count: Int   // số prompt liên quan (loop: số lần lặp, drift: tổng prompt)

    public init(id: String, kind: AnomalyKind, representative: PromptRecord,
                reason: String, count: Int) {
        self.id = id
        self.kind = kind
        self.representative = representative
        self.reason = reason
        self.count = count
    }
}

public enum AnomalyScorer {

    /// Scan toàn bộ prompts, trả top N anomalies sorted severity desc.
    /// `limit` default 3 — vừa đủ surface mà không nhiễu UI.
    public static func detect(in prompts: [PromptRecord], limit: Int = 3) -> [Anomaly] {
        var out: [Anomaly] = []
        out.append(contentsOf: detectEffortImbalance(prompts))
        out.append(contentsOf: detectPromptLoops(prompts))
        out.append(contentsOf: detectDriftingSessions(prompts))

        // Sort: severity desc → count desc → timestamp desc (recent first).
        out.sort { a, b in
            if a.kind.severity != b.kind.severity { return a.kind.severity > b.kind.severity }
            if a.count != b.count { return a.count > b.count }
            return a.representative.timestamp > b.representative.timestamp
        }
        return Array(out.prefix(limit))
    }

    // MARK: - Rule 1: Effort imbalance

    /// 1★ + text dài > 1000 char → user viết dài nhưng chưa structured.
    private static func detectEffortImbalance(_ prompts: [PromptRecord]) -> [Anomaly] {
        prompts.compactMap { p in
            guard p.score.stars <= 1, p.text.count > 1000 else { return nil }
            return Anomaly(
                id: "effort-\(p.auditKey)",
                kind: .effortImbalance,
                representative: p,
                reason: "Prompt \(p.text.count) chars nhưng chỉ \(p.score.stars)★ — đầu tư công viết dài chưa đi kèm structure. Thử chia thành các section Mục tiêu / Input / DoD.",
                count: 1
            )
        }
    }

    // MARK: - Rule 2: Prompt loop

    /// ≥3 prompt trong cùng session có prefix-80-char giống nhau + text dài
    /// ≥100 char → user lặp lại ý. v0.4.1 fix #4: bump prefix 50→80 + length gate
    /// để giảm false positive trên prompts ngắn khác task ("Em fix bug A/B/C").
    private static let loopPrefixLength = 80
    private static let loopMinTextLength = 100

    private static func detectPromptLoops(_ prompts: [PromptRecord]) -> [Anomaly] {
        let bySession = Dictionary(grouping: prompts, by: \.sessionAuditKey)
        var out: [Anomaly] = []
        for (_, sessionPrompts) in bySession {
            // Chỉ xem xét prompt đủ dài — prompts ngắn có cùng mở đầu thường là
            // task khác nhau (vd "Em sửa X" / "Em sửa Y").
            let eligible = sessionPrompts.filter { $0.text.count >= loopMinTextLength }
            let byPrefix = Dictionary(grouping: eligible) {
                String($0.text.prefix(loopPrefixLength)).lowercased()
            }
            for (prefix, group) in byPrefix where group.count >= 3 && !prefix.isEmpty {
                guard let rep = group.last else { continue }
                out.append(Anomaly(
                    id: "loop-\(rep.sessionAuditKey)-\(prefix.hashValue)",
                    kind: .promptLoop,
                    representative: rep,
                    reason: "Lặp \(group.count) prompt dài (≥\(loopMinTextLength) char) cùng \(loopPrefixLength) ký tự đầu trong 1 session — khả năng AI fail hoặc thiếu context. Thử rewrite với codebase context + verification criteria.",
                    count: group.count
                ))
            }
        }
        return out
    }

    // MARK: - Rule 3: Drifting session

    /// Session có ≥5 prompt và avg ★ ≤ 2 → session dài lê thê không productive.
    private static func detectDriftingSessions(_ prompts: [PromptRecord]) -> [Anomaly] {
        let bySession = Dictionary(grouping: prompts, by: \.sessionAuditKey)
        var out: [Anomaly] = []
        for (sessionKey, group) in bySession where group.count >= 5 {
            let taskPrompts = group.filter { $0.score.isTaskPrompt }
            guard !taskPrompts.isEmpty else { continue }
            let avg = Double(taskPrompts.map(\.score.stars).reduce(0, +))
                / Double(taskPrompts.count)
            guard avg <= 2.0 else { continue }
            guard let rep = group.last else { continue }
            out.append(Anomaly(
                id: "drift-\(sessionKey)",
                kind: .driftingSession,
                representative: rep,
                reason: "Session \(group.count) prompt, avg \(String(format: "%.1f", avg))★ — work session dài không có prompt structure. Khởi đầu session sau bằng 1 prompt 5★ rõ Mục tiêu + DoD để focus.",
                count: group.count
            ))
        }
        return out
    }
}
