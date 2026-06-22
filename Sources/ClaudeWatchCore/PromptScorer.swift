// Chấm chất lượng prompt theo khung SDD/VSDD/CoDD.
// Rule-based, không gọi API — check sự xuất hiện của các Spec section
// trong text prompt. Đầu vào là user message thô từ JSONL.

import Foundation

/// Mỗi tiêu chí trong rubric Minimum Spec Set (mục 6 của tài liệu coaching) +
/// 3 tiêu chí mở rộng theo Anthropic prompt engineering guides:
/// - examples (few-shot), motivation (context why), xmlStructure (advanced parsing).
/// + 2 tiêu chí từ Anthropic Claude Code expertise research (2026-06):
/// - codebaseContext (Domain Knowledge Integration), verification (Verification Requests).
/// Ref: https://www.anthropic.com/research/claude-code-expertise
public enum SpecSection: String, CaseIterable, Sendable {
    case mucTieu          // Mục tiêu / Goal
    case userRole         // User Role
    case input            // Input
    case output           // Output
    case flow             // Flow chính
    case edgeCase         // Edge Case
    case constrainedBy    // constrained_by (CoDD)
    case definitionDone   // Definition of Done
    case examples         // Few-shot examples (Anthropic: most reliable steering signal)
    case motivation       // Context motivation (Why/because/lý do)
    case xmlStructure     // XML tag hierarchy <example>, <context>, <instructions>
    case codebaseContext  // Domain knowledge: file paths, identifiers, line refs
    case verification     // Verification requests: "verify X", "test that", "expected"

    public var label: String {
        switch self {
        case .mucTieu:         return "Mục tiêu"
        case .userRole:        return "User Role"
        case .input:           return "Input"
        case .output:          return "Output"
        case .flow:            return "Flow"
        case .edgeCase:        return "Edge Case"
        case .constrainedBy:   return "constrained_by"
        case .definitionDone:  return "Definition of Done"
        case .examples:        return "Examples (few-shot)"
        case .motivation:      return "Motivation (Why)"
        case .xmlStructure:    return "XML structure"
        case .codebaseContext: return "Codebase context"
        case .verification:    return "Verification request"
        }
    }
}

/// Kết quả chấm 1 prompt.
public struct PromptScore: Sendable, Equatable {
    /// 0–5★. 0 = follow-up/quá ngắn, 5 = đủ Spec.
    public let stars: Int
    /// Số section đã hiện diện.
    public let sectionsPresent: Set<SpecSection>
    /// Số section còn thiếu (gợi ý coaching).
    public let sectionsMissing: [SpecSection]
    /// True nếu prompt được tính là "task prompt" (≥200 char hoặc có heading);
    /// false nếu là follow-up ngắn, không vào rubric.
    public let isTaskPrompt: Bool
    /// Số ký tự prompt (đã trim).
    public let charCount: Int

    public init(stars: Int,
                sectionsPresent: Set<SpecSection>,
                sectionsMissing: [SpecSection],
                isTaskPrompt: Bool,
                charCount: Int) {
        self.stars = stars
        self.sectionsPresent = sectionsPresent
        self.sectionsMissing = sectionsMissing
        self.isTaskPrompt = isTaskPrompt
        self.charCount = charCount
    }
}

public enum PromptScorer {
    /// Chấm 1 prompt thô. Trả PromptScore.
    public static func score(_ raw: String) -> PromptScore {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let count = trimmed.count

        let hasHeading = trimmed.contains("##") || trimmed.contains("# ")
        let isTask = count >= 200 || hasHeading

        guard isTask else {
            return PromptScore(stars: 0,
                               sectionsPresent: [],
                               sectionsMissing: SpecSection.allCases,
                               isTaskPrompt: false,
                               charCount: count)
        }

        var present: Set<SpecSection> = []
        for section in SpecSection.allCases where matches(section, in: lower, raw: trimmed) {
            present.insert(section)
        }

        let missing = SpecSection.allCases.filter { !present.contains($0) }
        let stars = starsFor(presentCount: present.count, charCount: count)

        return PromptScore(stars: stars,
                           sectionsPresent: present,
                           sectionsMissing: missing,
                           isTaskPrompt: true,
                           charCount: count)
    }

    // MARK: - Matching

    /// Mỗi section có 1 tập keyword tiếng Việt + tiếng Anh. Dùng substring
    /// trên `lower` đã hạ chữ — đơn giản, không regex để rẻ và dễ debug.
    /// Riêng codebaseContext + xmlStructure cần regex; codebaseContext còn cần
    /// `raw` (case-preserved) để phát hiện camelCase/PascalCase identifiers.
    private static func matches(_ section: SpecSection, in lower: String, raw: String) -> Bool {
        let keywords: [String]
        switch section {
        case .mucTieu:
            keywords = ["mục tiêu", "muc tieu", "## goal", "# goal", "objective"]
        case .userRole:
            keywords = ["user role", "## role", "# role", "ai được dùng", "phân quyền", "permission"]
        case .input:
            keywords = ["## input", "# input", "input:", "field bắt buộc", "validation:"]
        case .output:
            keywords = ["## output", "# output", "output:", "success response", "error response"]
        case .flow:
            keywords = ["## flow", "# flow", "flow chính", "luồng xử lý", "flow xử lý"]
        case .edgeCase:
            keywords = ["edge case", "edge-case", "trường hợp biên", "## edge", "case xấu"]
        case .constrainedBy:
            keywords = ["constrained_by", "constrained by", "ràng buộc:", "rang buoc:"]
        case .definitionDone:
            keywords = ["definition of done", "## dod", "# dod", "definition_of_done",
                        "tiêu chí hoàn thành", "tieu chi hoan thanh"]
        case .examples:
            // Anthropic emphasizes few-shot examples; dev hay quên show I/O mẫu.
            // Khớp cả XML tag <example>, prose "ví dụ", và code fence ``` (≥2 lần
            // = nhiều khả năng đang show input + output mẫu).
            keywords = ["<example", "<examples>", "ví dụ:", "vi du:", "for example",
                        "e.g.", "sample input", "sample output", "ví dụ:"]
            if keywords.contains(where: { lower.contains($0) }) { return true }
            return lower.components(separatedBy: "```").count >= 3   // ≥2 fence
        case .motivation:
            // "Vì sao". Anthropic: Claude generalizes better when given context why.
            keywords = ["lý do:", "ly do:", "bởi vì", "boi vi", "do đó", "do do",
                        "vì cần", "vi can", "to ensure", "in order to", "so that",
                        "because we", "because the", "because this", "mục đích để",
                        "muc dich de"]
            return keywords.contains(where: { lower.contains($0) })
        case .xmlStructure:
            return hasXmlTagPair(lower)
        case .codebaseContext:
            // Domain knowledge signal: file path, identifier, hoặc line ref.
            // Anthropic research: experts mention specific files/symbols vs novice
            // generic descriptions. 1 trong các pattern = fire.
            // Truyền raw (case-preserved) cho symbolCallRegex bắt camelCase/PascalCase.
            return hasCodebaseContext(lower, raw: raw)
        case .verification:
            // Explicit validation criteria — "verify X", "kiểm tra", "expected output".
            // Khác Definition of Done: DoD là tiêu chí hoàn thành, verification là
            // CÁCH để verify (test, assertion, expected value).
            keywords = ["verify", "kiểm tra", "kiem tra", "test that", "expected output",
                        "should produce", "should return", "should equal", "should match",
                        "đảm bảo", "dam bao", "make sure", "assert that", "validate that",
                        "expected behavior", "expected result", "phải trả về", "phai tra ve"]
            return keywords.contains(where: { lower.contains($0) })
        }
        return keywords.contains(where: { lower.contains($0) })
    }

    /// Detect signal user hiểu codebase: file path (a/b/c.ext), file:line, hoặc
    /// identifier code-like. 1 hit = pass.
    /// - lower: lowercased text — dùng cho codePath + fileLine (path không phụ thuộc case)
    /// - raw: case-preserved — symbolCallRegex cần để bắt camelCase/PascalCase
    private static func hasCodebaseContext(_ lower: String, raw: String) -> Bool {
        // 1. File extension trong path (multi-segment hoặc backtick-wrapped).
        if codePathRegex?.firstMatch(in: lower,
                                     range: NSRange(lower.startIndex..., in: lower)) != nil {
            return true
        }
        // 2. file:line ref (e.g., "main.swift:42").
        if fileLineRegex?.firstMatch(in: lower,
                                     range: NSRange(lower.startIndex..., in: lower)) != nil {
            return true
        }
        // 3. Code-like identifier call — chạy trên raw để bắt camelCase/PascalCase.
        if symbolCallRegex?.firstMatch(in: raw,
                                       range: NSRange(raw.startIndex..., in: raw)) != nil {
            return true
        }
        return false
    }

    // v0.4.1 fix #3: tighter codePathRegex — REQUIRE multi-segment path (có "/")
    // hoặc backtick/code-fence wrapping. Đơn lẻ "readme.md" trong prose KHÔNG
    // còn match — phải là "src/readme.md", "`readme.md`", hoặc trong code fence.
    nonisolated(unsafe) private static let codePathRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            // Pattern 1: backtick-wrapped file (`foo.swift`)
            // Pattern 2: multi-segment path with at least 1 slash (a/b.ext)
            pattern: "`[a-z0-9_./-]+\\.(swift|ts|tsx|js|jsx|py|go|rs|java|kt|m|h|cpp|c|rb|php|sh|yml|yaml|json|toml|md)`"
                + "|(?:^|[\\s(])([a-z0-9_-]+/)+[a-z0-9_-]+\\.(swift|ts|tsx|js|jsx|py|go|rs|java|kt|m|h|cpp|c|rb|php|sh|yml|yaml|json|toml|md)\\b",
            options: [.caseInsensitive]
        )
    }()

    nonisolated(unsafe) private static let fileLineRegex: NSRegularExpression? = {
        // file.ext:NN dạng "main.swift:42" or "foo.ts:100-110" — high signal, giữ nguyên.
        try? NSRegularExpression(
            pattern: "[a-z0-9_-]+\\.[a-z]{1,5}:\\d+",
            options: [.caseInsensitive]
        )
    }()

    // v0.4.1 fix #7: tighter symbolCallRegex — chỉ chấp nhận pattern code-like rõ ràng:
    //   - `Class.method(` (dot notation chained call)
    //   - `funcName(` trong backtick (explicit code marking)
    //   - Snake_case lowercased với ≥6 char (vd: parse_session())
    // Reject "perform(this)" trong prose vì không match camelCase với uppercase boundary.
    nonisolated(unsafe) private static let symbolCallRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            // Pattern 1: backtick-wrapped function call: `funcName(`
            // Pattern 2: Method chain Class.method( where Class starts with UpperCase
            //           OR snake_case_method (≥1 underscore in identifier)
            // Pattern 3: camelCase ≥2 segments (lowerUpper, vd: parseSession)
            pattern: "`[a-z_][a-z0-9_]{2,}\\("
                + "|\\b[A-Z][a-zA-Z0-9_]{2,}\\.[a-z_][a-zA-Z0-9_]{2,}\\("
                + "|\\b[a-z_]+_[a-z_]+\\("
                + "|\\b[a-z][a-z0-9]*[A-Z][a-zA-Z0-9]*\\(",
            options: []   // case-sensitive — quan trọng cho camelCase + UpperCase
        )
    }()

    /// Detect ít nhất 1 cặp `<tag>...</tag>` (tag name ≥3 char, lowercase alphanum).
    /// Chấp nhận tag có attribute, tag tự đóng KHÔNG tính (vì single tag không
    /// chứng minh hierarchy parsing).
    private static func hasXmlTagPair(_ lower: String) -> Bool {
        guard let regex = xmlPairRegex else { return false }
        let range = NSRange(lower.startIndex..., in: lower)
        return regex.firstMatch(in: lower, range: range) != nil
    }

    nonisolated(unsafe) private static let xmlPairRegex: NSRegularExpression? = {
        // <name ...>...</name>, name = [a-z][a-z0-9_-]{2,}
        try? NSRegularExpression(pattern: "<([a-z][a-z0-9_-]{2,})[^>]*>[\\s\\S]*?</\\1>")
    }()

    /// Quy đổi sang 5★ scale dựa trên tỷ lệ section pass / total. Total hiện
    /// tại là 11 (8 SDD + 3 Anthropic extensions). Tỷ lệ dễ scale khi tương lai
    /// thêm/bớt tiêu chí.
    private static func starsFor(presentCount: Int, charCount: Int) -> Int {
        let total = SpecSection.allCases.count
        let pct = Double(presentCount) / Double(total)
        let base: Int
        switch pct {
        case 0:           base = 1  // có heading nhưng không bám rubric
        case 0..<0.20:    base = 1
        case 0.20..<0.40: base = 2
        case 0.40..<0.60: base = 3
        case 0.60..<0.80: base = 4
        default:          base = 5
        }
        // Penalty nếu task prompt quá ngắn (<400 char) — Spec không thể đủ.
        if charCount < 400 && base > 2 { return 2 }
        return min(base, 5)
    }
}
