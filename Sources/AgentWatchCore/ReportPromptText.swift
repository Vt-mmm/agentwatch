import Foundation

/// Remove known injected context, preserve the employee's request, redact before
/// excerpts are taken (so truncation cannot cut a credential before matching).
public enum ReportPromptText {
    public static func origin(_ raw: String) -> ReportPromptOrigin {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<codex_internal_context") { return .agentContinuation }
        let cleaned = clean(raw).replacingOccurrences(of: "[Ngữ cảnh tự động đã lược]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? .context : .employee
    }
    public static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "&#x20;", with: " ").replacingOccurrences(of: "&#32;", with: " ")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# Files mentioned by the user:"),
           let request = text.range(of: "## My request:") {
            let manifest = String(text[..<request.lowerBound])
            let names = manifest.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.map {
                String($0.dropFirst(3).components(separatedBy: ": /").first ?? "Tệp đính kèm")
            }
            text = String(text[request.upperBound...]) + (names.isEmpty ? "" : "\nTệp đính kèm: " + names.joined(separator: "; "))
        }
        text = text.replacingOccurrences(of: #"(?is)<image\b[^>]*>.*?</image>"#, with: "[Ảnh đính kèm]", options: .regularExpression)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<codex_internal_context") {
            let expression = try! NSRegularExpression(pattern: "(?is)<objective>(.*?)</objective>")
            if let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) {
                text = "Agent tự tiếp tục mục tiêu đã giao: " + String(text[range])
            } else { text = "Sự kiện điều phối tự động của agent; không phải prompt mới của nhân viên." }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<send_user_message_question_reply>") {
            let json = text.replacingOccurrences(of: "<send_user_message_question_reply>", with: "").replacingOccurrences(of: "</send_user_message_question_reply>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = json.data(using: .utf8), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               rows.allSatisfy({ $0["answer"] is String }) {
                text = rows.map { "Agent hỏi: " + ($0["question"] as? String ?? "") + "\nNhân viên trả lời: " + ($0["answer"] as? String ?? "") }.joined(separator: "\n\n")
            }
        }
        for tag in ["environment_context", "permissions", "permissions_instructions", "app-context", "skills_instructions", "recommended_plugins", "system-reminder", "turn_aborted"] {
            text = text.replacingOccurrences(of: "(?is)<" + tag + "(?:\\s[^>]*)?>.*?</" + tag + ">", with: "[Ngữ cảnh tự động đã lược]", options: .regularExpression)
        }
        for pattern in [
            #"(?i)\bAW-LOCK-[A-Z0-9-]+\b"#,
            #"(?is)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#,
            #"(?i)\bBearer\s+[A-Za-z0-9_.~+/=-]+"#,
            #"\bGOCSPX-[A-Za-z0-9_-]+\b"#,
            #"\bAIza[A-Za-z0-9_-]{30,}\b"#,
            #"\bAKIA[A-Z0-9]{16}\b"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
            #"(?i)[\"']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|client_secret|authorization)[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,}]+)"#
        ] {
            text = text.replacingOccurrences(of: pattern, with: "[đã ẩn thông tin xác thực]", options: .regularExpression)
        }
        return ShareText.clean(text).replacingOccurrences(of: #"\n{4,}"#, with: "\n\n", options: .regularExpression)
    }

    public static func excerpt(_ raw: String, limit: Int = 220) -> String {
        let text = clean(raw).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard text.count > limit else { return text }
        var prefix = String(text.prefix(limit))
        if let space = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: space) > limit / 2 { prefix = String(prefix[..<space]) }
        return prefix + "…"
    }

    public static func toolObservation(_ evidence: ReportEvidence, zone: String) -> String {
        let tool = String(evidence.summary.prefix { $0 != ":" })
        let label: String
        let lower = tool.lowercased()
        if lower.contains("exec") || lower == "bash" { label = "Gọi công cụ thực thi lệnh" }
        else if lower.contains("patch") || lower.contains("edit") || lower.contains("write") { label = "Gọi công cụ chỉnh sửa/ghi tệp" }
        else if lower.contains("read") || lower.contains("search") || lower.contains("glob") || lower.contains("grep") { label = "Gọi công cụ đọc/tìm kiếm" }
        else if lower.contains("web") { label = "Gọi công cụ tra cứu web" }
        else if lower.contains("cua") { label = "Gọi công cụ thao tác ứng dụng" }
        else { label = "Gọi công cụ " + ShareText.clean(tool) }
        let response = evidence.summary.contains("Đã có phản hồi công cụ") ? "Có phản hồi" : "Chưa có phản hồi trong nguồn"
        return DailyReportRenderer.dateLabel(evidence.observedAt, zone: zone, format: "HH:mm:ss") + " · " + label + " · " + response
    }
}
