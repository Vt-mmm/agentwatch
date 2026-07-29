// Local, deterministic risk scoring for company agent usage audit.
// No network calls, no ML dependency: every finding is explainable and exportable.

import Foundation

public enum RiskSeverity: Int, Sendable, CaseIterable, Equatable, Comparable {
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4

    public static func < (lhs: RiskSeverity, rhs: RiskSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .low:      return "Low"
        case .medium:   return "Medium"
        case .high:     return "High"
        case .critical: return "Critical"
        }
    }

    public var shortLabel: String {
        switch self {
        case .low:      return "LOW"
        case .medium:   return "MED"
        case .high:     return "HIGH"
        case .critical: return "CRIT"
        }
    }
}

public enum RiskCategory: String, Sendable, CaseIterable, Equatable {
    case tokenBurn
    case costOutlier
    case agentLoop
    case toolChurn
    case weakPromptHighSpend
    case possibleOffTask
    case sensitiveData
    case policyBypass
    case destructiveAction
    case nonCompanyWorkspace

    public var label: String {
        switch self {
        case .tokenBurn:           return "Token burn"
        case .costOutlier:         return "Cost outlier"
        case .agentLoop:           return "Agent loop"
        case .toolChurn:           return "Tool churn"
        case .weakPromptHighSpend: return "Weak prompt, high spend"
        case .possibleOffTask:     return "Possible off-task"
        case .sensitiveData:       return "Sensitive data"
        case .policyBypass:        return "Policy bypass"
        case .destructiveAction:   return "Destructive action"
        case .nonCompanyWorkspace: return "Non-company workspace"
        }
    }

    public var icon: String {
        switch self {
        case .tokenBurn:           return "flame.fill"
        case .costOutlier:         return "dollarsign.circle.fill"
        case .agentLoop:           return "arrow.triangle.2.circlepath.circle.fill"
        case .toolChurn:           return "hammer.circle.fill"
        case .weakPromptHighSpend: return "exclamationmark.bubble.fill"
        case .possibleOffTask:     return "person.crop.circle.badge.questionmark"
        case .sensitiveData:       return "key.fill"
        case .policyBypass:        return "shield.slash.fill"
        case .destructiveAction:   return "trash.circle.fill"
        case .nonCompanyWorkspace: return "folder.badge.questionmark"
        }
    }
}

public struct RiskFinding: Identifiable, Sendable, Equatable {
    public let id: String
    public let category: RiskCategory
    public let severity: RiskSeverity
    /// 0...100, higher means the finding should be reviewed first.
    public let score: Int
    public let source: SessionSource
    public let projectDisplay: String
    public let sessionId: String
    public let promptId: String?
    public let timestamp: Date?
    public let title: String
    public let reason: String
    public let evidence: String
    public let recommendation: String

    public init(id: String, category: RiskCategory, severity: RiskSeverity,
                score: Int, source: SessionSource, projectDisplay: String,
                sessionId: String, promptId: String?, timestamp: Date?,
                title: String, reason: String, evidence: String,
                recommendation: String) {
        self.id = id
        self.category = category
        self.severity = severity
        self.score = max(0, min(100, score))
        self.source = source
        self.projectDisplay = projectDisplay
        self.sessionId = sessionId
        self.promptId = promptId
        self.timestamp = timestamp
        self.title = title
        self.reason = reason
        self.evidence = evidence
        self.recommendation = recommendation
    }

    public var isPromptLevel: Bool { promptId != nil }
}

public struct RiskSummary: Sendable, Equatable {
    public let totalFindings: Int
    public let criticalCount: Int
    public let highCount: Int
    public let mediumCount: Int
    public let lowCount: Int
    public let maxScore: Int
    public let affectedSessions: Int
    public let affectedPrompts: Int

    public init(totalFindings: Int, criticalCount: Int, highCount: Int,
                mediumCount: Int, lowCount: Int, maxScore: Int,
                affectedSessions: Int, affectedPrompts: Int) {
        self.totalFindings = totalFindings
        self.criticalCount = criticalCount
        self.highCount = highCount
        self.mediumCount = mediumCount
        self.lowCount = lowCount
        self.maxScore = maxScore
        self.affectedSessions = affectedSessions
        self.affectedPrompts = affectedPrompts
    }

    public static let zero = RiskSummary(
        totalFindings: 0, criticalCount: 0, highCount: 0, mediumCount: 0,
        lowCount: 0, maxScore: 0, affectedSessions: 0, affectedPrompts: 0)

    public var highOrCriticalCount: Int { highCount + criticalCount }
}

public struct RiskScoringThresholds: Sendable, Equatable {
    public let mediumTokenSession: Int
    public let highTokenSession: Int
    public let criticalTokenSession: Int
    public let mediumCostSession: Double
    public let highCostSession: Double
    public let criticalCostSession: Double
    public let highToolCallSession: Int
    public let highToolsPerPrompt: Double
    public let weakPromptSpendCost: Double
    public let weakPromptSpendTokens: Int

    public init(mediumTokenSession: Int = 80_000,
                highTokenSession: Int = 200_000,
                criticalTokenSession: Int = 500_000,
                mediumCostSession: Double = 1.0,
                highCostSession: Double = 5.0,
                criticalCostSession: Double = 20.0,
                highToolCallSession: Int = 80,
                highToolsPerPrompt: Double = 30,
                weakPromptSpendCost: Double = 0.50,
                weakPromptSpendTokens: Int = 50_000) {
        self.mediumTokenSession = mediumTokenSession
        self.highTokenSession = highTokenSession
        self.criticalTokenSession = criticalTokenSession
        self.mediumCostSession = mediumCostSession
        self.highCostSession = highCostSession
        self.criticalCostSession = criticalCostSession
        self.highToolCallSession = highToolCallSession
        self.highToolsPerPrompt = highToolsPerPrompt
        self.weakPromptSpendCost = weakPromptSpendCost
        self.weakPromptSpendTokens = weakPromptSpendTokens
    }
}

public enum RiskScorer {
    public static let defaultThresholds = RiskScoringThresholds()

    public static func evaluate(records: [PromptRecord],
                                sessions: [SessionSummary],
                                thresholds: RiskScoringThresholds = defaultThresholds,
                                limit: Int = 100) -> [RiskFinding] {
        var out: [RiskFinding] = []
        let promptsBySession = Dictionary(grouping: records, by: \.sessionUuid)
        let sessionsById = bestSessionsById(sessions)
        let costOutliers = CoachingInsights.outlierSessions(sessions)

        for session in sessions {
            let prompts = promptsBySession[session.id] ?? []
            out.append(contentsOf: sessionFindings(
                session, prompts: prompts, costOutliers: costOutliers,
                thresholds: thresholds))
        }

        for record in records {
            out.append(contentsOf: promptFindings(record, session: sessionsById[record.sessionUuid]))
        }

        out.sort { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            if a.score != b.score { return a.score > b.score }
            return (a.timestamp ?? .distantPast) > (b.timestamp ?? .distantPast)
        }
        return Array(out.prefix(max(0, limit)))
    }

    public static func summary(for findings: [RiskFinding]) -> RiskSummary {
        guard !findings.isEmpty else { return .zero }
        var counts: [RiskSeverity: Int] = [:]
        for finding in findings {
            counts[finding.severity, default: 0] += 1
        }
        return RiskSummary(
            totalFindings: findings.count,
            criticalCount: counts[.critical] ?? 0,
            highCount: counts[.high] ?? 0,
            mediumCount: counts[.medium] ?? 0,
            lowCount: counts[.low] ?? 0,
            maxScore: findings.map(\.score).max() ?? 0,
            affectedSessions: Set(findings.map(\.sessionId)).count,
            affectedPrompts: Set(findings.compactMap(\.promptId)).count
        )
    }

    public static func highestBySession(_ findings: [RiskFinding]) -> [String: RiskFinding] {
        var out: [String: RiskFinding] = [:]
        for finding in findings {
            if let current = out[finding.sessionId] {
                if ranksAbove(finding, current) { out[finding.sessionId] = finding }
            } else {
                out[finding.sessionId] = finding
            }
        }
        return out
    }

    public static func highestByPrompt(_ findings: [RiskFinding]) -> [String: RiskFinding] {
        var out: [String: RiskFinding] = [:]
        for finding in findings {
            guard let promptId = finding.promptId else { continue }
            if let current = out[promptId] {
                if ranksAbove(finding, current) { out[promptId] = finding }
            } else {
                out[promptId] = finding
            }
        }
        return out
    }

    private static func sessionFindings(_ s: SessionSummary,
                                        prompts: [PromptRecord],
                                        costOutliers: Set<String>,
                                        thresholds: RiskScoringThresholds) -> [RiskFinding] {
        var out: [RiskFinding] = []
        let ts = s.lastTimestamp ?? s.firstTimestamp

        if costOutliers.contains(s.id) {
            out.append(sessionFinding(
                s, category: .costOutlier, severity: .high, score: 86,
                title: "Cost vượt nền bình thường",
                reason: "Cost session vượt mean + 2σ trong tập đang xem, nên cần mở timeline để xem agent đã làm gì.",
                evidence: sessionEvidence(s),
                recommendation: "Review prompt đầu phiên, tool calls và subagent. Nếu task đúng nhưng tốn thật, đánh dấu thành baseline mới cho project đó.",
                timestamp: ts
            ))
        }

        if s.agentCount >= CoachingInsights.agentLoopThreshold {
            let critical = s.agentCount >= CoachingInsights.agentLoopThreshold * 2
            out.append(sessionFinding(
                s, category: .agentLoop,
                severity: critical ? .critical : .high,
                score: min(100, 78 + s.agentCount),
                title: "Subagent spawn bất thường",
                reason: "Session spawn \(s.agentCount) subagent, vượt ngưỡng \(CoachingInsights.agentLoopThreshold). Đây là tín hiệu loop hoặc chia task quá rộng.",
                evidence: sessionEvidence(s),
                recommendation: "Mở session detail, kiểm tra subagent nào lặp context/tool. Nên yêu cầu agent dừng, summarize state, rồi chạy lại với scope nhỏ hơn.",
                timestamp: ts
            ))
        }

        if s.totalTokens >= thresholds.mediumTokenSession || s.cost >= thresholds.mediumCostSession {
            let severity: RiskSeverity
            if s.totalTokens >= thresholds.criticalTokenSession || s.cost >= thresholds.criticalCostSession {
                severity = .critical
            } else if s.totalTokens >= thresholds.highTokenSession || s.cost >= thresholds.highCostSession {
                severity = .high
            } else {
                severity = .medium
            }
            let tokenScore = min(55, s.totalTokens / 10_000)
            let costScore = min(35, Int(s.cost * 4))
            out.append(sessionFinding(
                s, category: .tokenBurn, severity: severity,
                score: min(100, severity.rawValue * 18 + tokenScore + costScore),
                title: "Token/cost burn cao",
                reason: "Session vượt ngưỡng token hoặc cost tuyệt đối. Rule này bắt cả Codex subscription có cost thấp nhưng token rất cao.",
                evidence: sessionEvidence(s),
                recommendation: "Kiểm tra xem agent có đọc lặp file lớn, context quá rộng, hoặc chạy subagent không cần thiết không.",
                timestamp: ts
            ))
        }

        let promptsDenom = max(s.promptCount, 1)
        let toolsPerPrompt = Double(s.toolCallCount) / Double(promptsDenom)
        if s.toolCallCount >= thresholds.highToolCallSession
            || (s.toolCallCount >= 30 && toolsPerPrompt >= thresholds.highToolsPerPrompt) {
            out.append(sessionFinding(
                s, category: .toolChurn,
                severity: s.toolCallCount >= thresholds.highToolCallSession ? .high : .medium,
                score: min(94, 50 + s.toolCallCount / 2 + Int(toolsPerPrompt)),
                title: "Tool churn cao",
                reason: "Session có \(s.toolCallCount) tool call, trung bình \(String(format: "%.1f", toolsPerPrompt)) tool/prompt. Đây thường là dấu hiệu agent đang mò hoặc retry quá nhiều.",
                evidence: sessionEvidence(s),
                recommendation: "Review timeline tool call. Nếu thấy đọc/sửa lặp, đổi prompt sang plan ngắn + checklist verify từng bước.",
                timestamp: ts
            ))
        }

        if isWeakPromptHighSpend(s, prompts: prompts, thresholds: thresholds) {
            let avg = averageTaskStars(prompts)
            out.append(sessionFinding(
                s, category: .weakPromptHighSpend,
                severity: s.cost >= thresholds.highCostSession || s.totalTokens >= thresholds.highTokenSession ? .high : .medium,
                score: min(92, 62 + Int(s.cost * 5) + s.totalTokens / 20_000),
                title: "Prompt yếu nhưng spend cao",
                reason: "Session tốn đáng kể trong khi prompt task trung bình chỉ \(String(format: "%.1f", avg))★ hoặc thiếu prompt task rõ ràng.",
                evidence: sessionEvidence(s),
                recommendation: "Bắt buộc prompt khởi đầu có Mục tiêu, Input, Output, constrained_by và Definition of Done trước khi cho agent chạy sâu.",
                timestamp: ts
            ))
        }

        if looksLikeNonCompanyWorkspace(s.projectDisplay)
            && (s.totalTokens >= 10_000 || s.cost >= 0.10 || s.promptCount > 0) {
            out.append(sessionFinding(
                s, category: .nonCompanyWorkspace,
                severity: s.totalTokens >= thresholds.highTokenSession || s.cost >= thresholds.highCostSession ? .high : .medium,
                score: min(88, 58 + s.totalTokens / 30_000 + Int(s.cost * 4)),
                title: "Workspace có vẻ ngoài vùng công ty",
                reason: "Đường dẫn project có tín hiệu personal/temp/downloads/freelance. Đây không phải kết luận sai phạm, nhưng nên review với task được giao.",
                evidence: s.projectDisplay,
                recommendation: "Đối chiếu tên project với danh sách repo/task nội bộ trong tuần. Nếu là repo công ty đặt sai chỗ, thêm allowlist sau.",
                timestamp: ts
            ))
        }

        return out
    }

    private static func promptFindings(_ r: PromptRecord,
                                       session: SessionSummary?) -> [RiskFinding] {
        let lower = normalized(r.text)
        var out: [RiskFinding] = []

        if let match = firstMatch(in: lower, terms: destructiveTerms) {
            out.append(promptFinding(
                r, session: session, category: .destructiveAction,
                severity: .critical, score: 96,
                title: "Prompt có thao tác phá hủy dữ liệu/hệ thống",
                reason: "Prompt chứa yêu cầu hoặc lệnh destructive cần approval rõ ràng trước khi agent chạy.",
                evidence: evidence(match: match, text: r.text),
                recommendation: "Kiểm tra xem đã có approval và backup chưa. Nếu không, dừng session và yêu cầu kế hoạch rollback trước.",
                suffix: match
            ))
        }

        if let match = firstMatch(in: lower, terms: policyBypassTerms) {
            out.append(promptFinding(
                r, session: session, category: .policyBypass,
                severity: .high, score: 88,
                title: "Prompt có tín hiệu bypass policy/audit",
                reason: "Prompt có cụm từ liên quan đến lách kiểm soát, tắt audit, xóa log hoặc bỏ qua approval.",
                evidence: evidence(match: match, text: r.text),
                recommendation: "Review người dùng và mục tiêu task. Với task hợp lệ, yêu cầu viết lại prompt theo hướng minh bạch và có approval.",
                suffix: match
            ))
        }

        if let match = firstMatch(in: lower, terms: sensitiveHighTerms) {
            out.append(promptFinding(
                r, session: session, category: .sensitiveData,
                severity: .high, score: 84,
                title: "Prompt có tín hiệu secret/credential",
                reason: "Prompt nhắc tới secret, key, token truy cập hoặc file nhạy cảm. Agent có thể vô tình đọc/ghi/lộ dữ liệu nội bộ.",
                evidence: evidence(match: match, text: r.text),
                recommendation: "Kiểm tra prompt có paste secret thật không. Nếu có, rotate secret và nhắc team dùng placeholder/redaction.",
                suffix: match
            ))
        } else if let match = firstMatch(in: lower, terms: sensitiveMediumTerms) {
            out.append(promptFinding(
                r, session: session, category: .sensitiveData,
                severity: .medium, score: 68,
                title: "Prompt có dữ liệu nhạy cảm tiềm năng",
                reason: "Prompt nhắc tới dữ liệu khách hàng/cá nhân hoặc credential ở mức cần review.",
                evidence: evidence(match: match, text: r.text),
                recommendation: "Đảm bảo prompt chỉ dùng dữ liệu giả lập hoặc dữ liệu đã được che.",
                suffix: match
            ))
        }

        if let match = firstMatch(in: lower, terms: offTaskTerms) {
            out.append(promptFinding(
                r, session: session, category: .possibleOffTask,
                severity: .medium, score: 64,
                title: "Prompt có tín hiệu ngoài task công ty",
                reason: "Prompt chứa dấu hiệu việc cá nhân, tìm việc, freelance, giải trí hoặc hoạt động ngoài phạm vi công ty.",
                evidence: evidence(match: match, text: r.text),
                recommendation: "Đối chiếu với task/project tuần đó. Nếu là việc công ty hợp lệ, cân nhắc thêm keyword allowlist theo project.",
                suffix: match
            ))
        }

        return out
    }

    private static func isWeakPromptHighSpend(_ s: SessionSummary,
                                              prompts: [PromptRecord],
                                              thresholds: RiskScoringThresholds) -> Bool {
        guard s.cost >= thresholds.weakPromptSpendCost
            || s.totalTokens >= thresholds.weakPromptSpendTokens else {
            return false
        }
        let taskPrompts = prompts.filter(\.score.isTaskPrompt)
        if taskPrompts.isEmpty {
            return s.promptCount <= 2
        }
        let avg = averageTaskStars(prompts)
        let weakCount = taskPrompts.filter { $0.score.stars <= 2 }.count
        return avg <= 2.0 || weakCount >= 2
    }

    private static func averageTaskStars(_ prompts: [PromptRecord]) -> Double {
        let taskPrompts = prompts.filter(\.score.isTaskPrompt)
        guard !taskPrompts.isEmpty else { return 0 }
        return Double(taskPrompts.reduce(0) { $0 + $1.score.stars }) / Double(taskPrompts.count)
    }

    private static func sessionFinding(_ s: SessionSummary,
                                       category: RiskCategory,
                                       severity: RiskSeverity,
                                       score: Int,
                                       title: String,
                                       reason: String,
                                       evidence: String,
                                       recommendation: String,
                                       timestamp: Date?) -> RiskFinding {
        RiskFinding(
            id: "session-\(category.rawValue)-\(s.id)",
            category: category,
            severity: severity,
            score: score,
            source: s.source,
            projectDisplay: s.projectDisplay,
            sessionId: s.id,
            promptId: nil,
            timestamp: timestamp,
            title: title,
            reason: reason,
            evidence: evidence,
            recommendation: recommendation
        )
    }

    private static func promptFinding(_ r: PromptRecord,
                                      session: SessionSummary?,
                                      category: RiskCategory,
                                      severity: RiskSeverity,
                                      score: Int,
                                      title: String,
                                      reason: String,
                                      evidence: String,
                                      recommendation: String,
                                      suffix: String) -> RiskFinding {
        RiskFinding(
            id: "prompt-\(category.rawValue)-\(r.id)-\(stableSuffix(suffix))",
            category: category,
            severity: severity,
            score: score,
            source: r.source,
            projectDisplay: r.projectDisplay,
            sessionId: r.sessionUuid,
            promptId: r.id,
            timestamp: r.timestamp,
            title: title,
            reason: reason,
            evidence: evidence,
            recommendation: recommendation
        )
    }

    private static func sessionEvidence(_ s: SessionSummary) -> String {
        "\(s.source.label) · \(s.model.isEmpty ? "unknown model" : s.model) · "
            + "\(s.totalTokens) tokens · \(String(format: "$%.4f", s.cost)) · "
            + "\(s.promptCount) prompts · \(s.toolCallCount) tools · \(s.agentCount) agents"
    }

    private static func ranksAbove(_ lhs: RiskFinding, _ rhs: RiskFinding) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return (lhs.timestamp ?? .distantPast) > (rhs.timestamp ?? .distantPast)
    }

    private static func bestSessionsById(_ sessions: [SessionSummary]) -> [String: SessionSummary] {
        var out: [String: SessionSummary] = [:]
        for session in sessions {
            guard let current = out[session.id] else {
                out[session.id] = session
                continue
            }
            if session.cost > current.cost
                || (session.cost == current.cost && session.totalTokens > current.totalTokens) {
                out[session.id] = session
            }
        }
        return out
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private static func firstMatch(in text: String, terms: [String]) -> String? {
        terms.first { text.contains($0) }
    }

    private static func evidence(match: String, text: String) -> String {
        let normalizedText = normalized(text)
        guard let range = normalizedText.range(of: match) else {
            return snippet(text, max: 180)
        }
        let lower = normalizedText.distance(from: normalizedText.startIndex, to: range.lowerBound)
        let start = max(0, lower - 70)
        let end = min(text.count, lower + match.count + 90)
        return "matched \"\(match)\" · " + snippet(text, from: start, to: end)
    }

    private static func snippet(_ value: String, max: Int) -> String {
        guard value.count > max else { return value }
        return String(value.prefix(max - 1)) + "…"
    }

    private static func snippet(_ value: String, from start: Int, to end: Int) -> String {
        guard start < end else { return snippet(value, max: 180) }
        let s = value.index(value.startIndex, offsetBy: max(0, min(start, value.count)))
        let e = value.index(value.startIndex, offsetBy: max(0, min(end, value.count)))
        let prefix = start > 0 ? "…" : ""
        let suffix = end < value.count ? "…" : ""
        return prefix + String(value[s..<e]) + suffix
    }

    private static func stableSuffix(_ value: String) -> String {
        String(value.unicodeScalars.reduce(UInt32(5381)) { (($0 << 5) &+ $0) &+ $1.value })
    }

    private static func looksLikeNonCompanyWorkspace(_ project: String) -> Bool {
        let lower = normalized(project)
        let pathTerms = [
            "/desktop/", "/downloads/", "/movies/", "/music/", "/pictures/",
            "/tmp/", "/private/tmp/", "/personal/", "/freelance/", "/side-project",
            "/side_project", "/job-search", "/resume", "/cv/"
        ]
        return pathTerms.contains { lower.contains($0) }
    }

    private static let destructiveTerms: [String] = [
        "rm -rf", "drop database", "drop table", "truncate table",
        "delete production", "delete prod", "wipe database", "wipe server",
        "format disk", "git push --force", "force push", "delete all data",
        "xoa database", "xoa du lieu production", "xoa production",
        "xoa toan bo", "xoa het du lieu"
    ]

    private static let policyBypassTerms: [String] = [
        "ignore policy", "ignore previous instructions", "bypass", "circumvent",
        "without approval", "no approval", "khong can approval", "khong can review",
        "khoi can review", "lach policy", "ne kiem tra", "ne audit",
        "disable audit", "delete logs", "xoa log", "hide from", "an khoi",
        "off the record", "khong log", "khong theo doi"
    ]

    private static let sensitiveHighTerms: [String] = [
        ".env", "auth.json", "id_rsa", "private key", "ssh key", "api key",
        "secret key", "client secret", "access token", "refresh token",
        "bearer token", "session token", "api token", "credentials.json"
    ]

    private static let sensitiveMediumTerms: [String] = [
        "password", "passwd", "cookie", "credential", "dump database",
        "production database", "customer data", "personal data", "pii",
        "credit card", "the tin dung", "cccd", "cmnd", "so dien thoai khach"
    ]

    private static let offTaskTerms: [String] = [
        "viet cv", "sua cv", "cover letter", "xin viec", "apply job",
        "job application", "resume", "linkedin profile", "freelance",
        "fiverr", "upwork", "side project", "du an rieng", "ngoai cong ty",
        "ca cuoc", "betting", "casino", "crypto trading", "tinder", "dating",
        "netflix", "du lich", "travel itinerary", "recipe", "nau an",
        "bai tap ve nha", "homework"
    ]
}
