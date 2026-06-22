// Rule-based session intent classifier — borrowed from Cursor's "Conversation
// Insights" pattern (on-device, low-cost). Classify mỗi session dựa trên text
// của 3 prompt đầu + toolCallCount để biết user đang LÀM GÌ.
//
// 6 intent enum: bugFix / refactor / newFeature / docs / exploration / general.
// Không ML — keyword match Vietnamese + English, deterministic, dễ debug.

import Foundation

public enum SessionIntent: String, Codable, Sendable, CaseIterable {
    case bugFix
    case refactor
    case newFeature
    case docs
    case exploration
    case general

    public var label: String {
        switch self {
        case .bugFix:      return "Bug fix"
        case .refactor:    return "Refactor"
        case .newFeature:  return "New feature"
        case .docs:        return "Docs"
        case .exploration: return "Exploration"
        case .general:     return "General"
        }
    }

    public var icon: String {
        switch self {
        case .bugFix:      return "ant"
        case .refactor:    return "wand.and.stars"
        case .newFeature:  return "sparkles"
        case .docs:        return "doc.text"
        case .exploration: return "magnifyingglass"
        case .general:     return "questionmark.circle"
        }
    }

    /// RGB tuple (0-1) cho UI badge — distinct per intent.
    /// Trả tuple thay Color vì ClaudeWatchCore không import SwiftUI.
    public var colorRGB: (r: Double, g: Double, b: Double) {
        switch self {
        case .bugFix:      return (0.86, 0.15, 0.15)   // red
        case .refactor:    return (0.49, 0.23, 0.93)   // purple
        case .newFeature:  return (0.02, 0.59, 0.41)   // green
        case .docs:        return (0.01, 0.52, 0.78)   // blue
        case .exploration: return (0.85, 0.47, 0.02)   // amber
        case .general:     return (0.42, 0.45, 0.50)   // gray
        }
    }
}

public enum SessionIntentClassifier {

    // Order matters: check specific intent trước, .general fallback last.
    // First-match wins → user nói "fix" early-prompt thì priority over "add"
    // ở prompt sau.

    nonisolated(unsafe) private static let bugFixKeywords: [String] = [
        "fix", "bug", "error", "broken", "crash", "exception", "wrong",
        "issue", "fail", "failing", "doesn't work", "not working",
        "sửa lỗi", "lỗi", "vấn đề", "không chạy", "không work", "sai",
    ]

    nonisolated(unsafe) private static let refactorKeywords: [String] = [
        "refactor", "clean up", "cleanup", "extract", "rename", "split",
        "modular", "modularize", "simplify", "restructure", "reorganize",
        "dọn", "tách", "đổi tên", "sắp xếp lại", "tinh gọn",
    ]

    nonisolated(unsafe) private static let docsKeywords: [String] = [
        "readme", "documentation", "doc ", "docs ", "comment", "tài liệu",
        "hướng dẫn", "guide", "explain in code", "write doc",
    ]

    nonisolated(unsafe) private static let newFeatureKeywords: [String] = [
        "add ", "implement", "build", "create ", "make a", "make the",
        "new feature", "new endpoint", "support for",
        "thêm ", "tạo ", "xây dựng", "triển khai", "làm thêm", "ver mới",
        "tính năng mới", "feature mới", "nâng cấp", "thực hiện",
    ]

    nonisolated(unsafe) private static let explorationKeywords: [String] = [
        "how does", "how do i", "what is", "what does", "why does", "why is",
        "explain", "show me", "tell me about", "research",
        "tại sao", "là gì", "giải thích", "show cho", "tìm hiểu", "nghiên cứu",
    ]

    /// Classify dựa trên text của prompts (typically 1-3 prompt đầu) + tool ratio.
    /// - Parameters:
    ///   - prompts: text của user prompts (lowercased ở caller, hoặc raw — ta tự lower)
    ///   - editToolRatio: tỉ lệ edit-like tools (Edit/Write/MultiEdit) trên toàn session.
    ///     Nếu > 0.5 mà chưa match keyword → ưu tiên .newFeature/.refactor; nếu < 0.1
    ///     và prompts hỏi câu hỏi → ưu tiên .exploration.
    public static func classify(prompts: [String], editToolRatio: Double = 0.0) -> SessionIntent {
        let blob = prompts.joined(separator: " ").lowercased()
        guard !blob.isEmpty else { return .general }

        // Keyword match — first wins.
        if containsAny(blob, bugFixKeywords) { return .bugFix }
        if containsAny(blob, refactorKeywords) { return .refactor }
        if containsAny(blob, docsKeywords) { return .docs }
        if containsAny(blob, newFeatureKeywords) { return .newFeature }
        if containsAny(blob, explorationKeywords) { return .exploration }

        // Fallback heuristic dùng tool ratio cho khi prompts không có keyword rõ.
        // editToolRatio cao → likely building/refactor, ratio thấp → exploration.
        if editToolRatio >= 0.4 { return .newFeature }
        if editToolRatio <= 0.05 { return .exploration }

        return .general
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        for kw in keywords where text.contains(kw) { return true }
        return false
    }
}
