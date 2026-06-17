// Coaching tips per Spec section. Mỗi tip có:
//   - reason (lý do Anthropic recommend, bằng tiếng Việt)
//   - sourceUrl (Anthropic docs/blog)
//   - template (snippet dev có thể copy paste vào prompt)
//   - example (ví dụ pass ngắn)
//
// Nội dung GROUND vào Anthropic prompt engineering guides (researcher report
// 260612-1137-prompt-quality-criteria.md) + tài liệu coaching mục 6 của user.

import Foundation

public struct CoachingTip: Sendable, Equatable {
    public let section: SpecSection
    public let reason: String
    public let sourceUrl: String
    public let template: String
    public let example: String
}

public enum CoachingTips {

    public static func tip(for section: SpecSection) -> CoachingTip {
        switch section {

        case .mucTieu:
            return CoachingTip(
                section: section,
                reason: "Anthropic: 'Be clear and direct'. Claude làm tốt hơn khi mục tiêu cụ thể, không mơ hồ — fresher thường copy yêu cầu thay vì diễn giải lại.",
                sourceUrl: "https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct",
                template: """
                ## Mục tiêu
                Mô tả task trong 2–3 câu. Tính năng giải quyết vấn đề gì,
                ai hưởng lợi, và đo lường thành công bằng gì?
                """,
                example: "Tạo endpoint POST /api/voucher/redeem để shop xác nhận voucher khi nhận hàng. Giảm gian lận voucher từ 5% → <1%."
            )

        case .userRole:
            return CoachingTip(
                section: section,
                reason: "Anthropic: 'Giving Claude a role focuses behavior and tone'. Khai báo role + permission tránh bypass quyền trong code AI sinh ra.",
                sourceUrl: "https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/system-prompts",
                template: """
                ## User Role
                - Ai được dùng: …
                - Ai KHÔNG được dùng: …
                - Permission/scope bị giới hạn: …
                """,
                example: """
                - Shop được dùng (role=shop_owner, scope=own_orders)
                - Customer KHÔNG được dùng
                - Admin có thể override nhưng phải log audit
                """
            )

        case .input:
            return CoachingTip(
                section: section,
                reason: "Anthropic: 'Use XML tags' để delimit data input rõ ràng — Claude không tự đoán format. Field bắt buộc + validation chặn AI hallucinate default value.",
                sourceUrl: "https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/use-xml-tags",
                template: """
                ## Input
                - Field bắt buộc: …
                - Field optional: …
                - Validation: regex / range / enum
                """,
                example: """
                - voucher_code (bắt buộc, regex ^[A-Z0-9]{8}$)
                - note (optional, max 200 char)
                - Validation: code phải tồn tại + status=active
                """
            )

        case .output:
            return CoachingTip(
                section: section,
                reason: "Anthropic: 'Control the format of responses'. Khai báo shape success + error giúp AI không phá contract API hiện có.",
                sourceUrl: "https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct",
                template: """
                ## Output
                - Success: <status code> + <payload shape>
                - Error: <status code> + <error code + message>
                """,
                example: """
                - Success: 200 + { redeemed_at, voucher_id }
                - Error: 400 invalid_code, 409 already_redeemed, 410 expired
                """
            )

        case .flow:
            return CoachingTip(
                section: section,
                reason: "Anthropic: 'Sequential instructions using numbered lists when order matters'. Flow viết theo step giúp AI không bỏ bước.",
                sourceUrl: "https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct",
                template: """
                ## Flow chính
                1. <hành động + actor>
                2. <hành động + actor>
                3. <hành động + actor>
                """,
                example: """
                1. Shop POST /redeem với voucher_code
                2. Server check code + status active + chưa redeemed
                3. Mark status=redeemed + ghi audit log
                4. Trả về redeemed_at + voucher_id
                """
            )

        case .edgeCase:
            return CoachingTip(
                section: section,
                reason: "Liệt kê edge case là bộ test định hướng. AI Code không tự nghĩ ra case xấu nếu không nhắc — đây là bước verify VSDD.",
                sourceUrl: "https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/use-examples",
                template: """
                ## Edge Case
                - Case 1: <điều kiện> → <expected behavior>
                - Case 2: <điều kiện> → <expected behavior>
                - Case 3: <điều kiện> → <expected behavior>
                """,
                example: """
                - voucher đã redeem → 409 already_redeemed (không crash)
                - voucher expired → 410 expired
                - shop A redeem code của shop B → 403 forbidden
                - concurrent redeem cùng code → atomic, 1 success only
                """
            )

        case .constrainedBy:
            return CoachingTip(
                section: section,
                reason: "CoDD: khai báo dependency để AI không tự ý mở rộng scope. Anthropic: 'context behind your instructions helps Claude generalize'.",
                sourceUrl: "https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct",
                template: """
                ## constrained_by
                - Schema: …
                - API hiện có: …
                - Business rule không phá: …
                - Module không sửa: …
                """,
                example: """
                - Schema: voucher table có cột status enum(active|redeemed|expired)
                - API /voucher/info đang xài bởi mobile app — KHÔNG đổi response
                - Business rule: 1 voucher chỉ redeem 1 lần
                - KHÔNG sửa file payment_service.py
                """
            )

        case .definitionDone:
            return CoachingTip(
                section: section,
                reason: "DoD chốt scope. Anthropic: 'tell Claude what to do instead of what not to do' — viết tiêu chí pass cụ thể, AI không over-engineer.",
                sourceUrl: "https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct",
                template: """
                ## Definition of Done
                - Code pass test
                - Không phá tính năng cũ
                - Xử lý đủ edge case ở trên
                - Có audit log cho hành động quan trọng
                - CTO/Lead review được ý đồ
                """,
                example: """
                - 3 unit test pass + 1 integration test với DB
                - regression test cũ vẫn pass
                - cover 4 edge case ở mục 7
                - mỗi redeem ghi 1 row vào audit_log
                """
            )

        case .examples:
            return CoachingTip(
                section: section,
                reason: "Anthropic: 'Examples are one of the most reliable ways to steer Claude's output'. Few-shot 3–5 ví dụ giảm misinterpret format mạnh nhất.",
                sourceUrl: "https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/use-examples",
                template: """
                <examples>
                  <example>
                    <input>{ /* sample input */ }</input>
                    <output>{ /* expected output */ }</output>
                  </example>
                  <example>
                    <input>{ /* edge case input */ }</input>
                    <output>{ /* edge case output */ }</output>
                  </example>
                </examples>
                """,
                example: """
                <examples>
                  <example>
                    <input>{"voucher_code":"ABC12345"}</input>
                    <output>{"status":"redeemed","redeemed_at":"2026-06-12T05:00:00Z"}</output>
                  </example>
                  <example>
                    <input>{"voucher_code":"USED9999"}</input>
                    <output>{"error":"already_redeemed","code":409}</output>
                  </example>
                </examples>
                """
            )

        case .motivation:
            return CoachingTip(
                section: section,
                reason: "Anthropic: 'Providing context or motivation behind instructions helps Claude generalize from the explanation'. Nói WHY → AI tự suy luận edge case anh quên.",
                sourceUrl: "https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct",
                template: """
                Thêm vào Mục tiêu hoặc constraint, dùng cụm:
                - "vì cần …"
                - "lý do là …"
                - "để đảm bảo …"
                - "in order to …"
                """,
                example: "Validate code trước rồi mới mark redeemed VÌ cần atomicity — nếu mark trước rồi mới validate, race condition có thể double-redeem."
            )

        case .xmlStructure:
            return CoachingTip(
                section: section,
                reason: "Anthropic: 'XML tags help Claude parse complex prompts unambiguously', đặc biệt khi prompt mix instructions + context + data + examples.",
                sourceUrl: "https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/use-xml-tags",
                template: """
                <instructions>
                  <task>…</task>
                  <constraints>…</constraints>
                </instructions>

                <context>
                  …existing code / schema / API…
                </context>

                <examples>
                  …
                </examples>
                """,
                example: """
                <instructions>
                  <task>Add POST /voucher/redeem endpoint per Spec.</task>
                  <constraints>Don't modify existing /voucher/info shape.</constraints>
                </instructions>
                """
            )

        case .codebaseContext:
            return CoachingTip(
                section: section,
                reason: "Anthropic Claude Code expertise research: experts 'convey deep knowledge of codebase' — mention specific files, identifiers, line refs thay vì mô tả chung chung. Tín hiệu domain expertise quan trọng hơn coding skill.",
                sourceUrl: "https://www.anthropic.com/research/claude-code-expertise",
                template: """
                Trỏ thẳng vào codebase:
                - File path: `src/api/voucher.ts`, `App/Views/SpritePet.swift:42`
                - Identifier: `parseSession()`, `class CoachingDataStore`
                - Error message exact: copy paste nguyên log
                - Library/version: "axios v1.6", "Swift 6 strict concurrency"
                """,
                example: "Fix race condition trong `CoachingDataStore.startAutoRefresh()` (App/CoachingDataStore.swift:125) — `isScopeEmpty` đang flip do `isLoading` race với tick 5s."
            )

        case .verification:
            return CoachingTip(
                section: section,
                reason: "Anthropic research: experts 'know what to ask Claude to verify' — explicit kiểm tra cách (assertion, expected output) → AI tự test cuối, ít lỗi escape. Khác Definition of Done: DoD = WHAT, verification = HOW kiểm tra.",
                sourceUrl: "https://www.anthropic.com/research/claude-code-expertise",
                template: """
                Cuối prompt thêm 1 trong các phrasing:
                - "Verify by: chạy `npm test`, expected ≥ 90% pass"
                - "Kiểm tra: response { ok: true, id: <uuid> }"
                - "Should produce: file X.swift với function Y"
                - "Make sure: build pass, no warnings"
                """,
                example: "Verify by chạy `xcodebuild ... build` → must say '** BUILD SUCCEEDED **'. Expected output: file mới `App/MetricsCollector.swift` < 200 LoC, conform `MXMetricManagerSubscriber`."
            )
        }
    }
}
