// Sheet show full 5★ template + worked example từ project này.
// Mở từ PromptDetailSheet khi score ≤ 2 — coaching mạnh, copy về điền.
//
// 13 section trùng rubric PromptScorer:
// mucTieu, userRole, input, output, flow, edgeCase, constrainedBy,
// definitionDone, examples, motivation, xmlStructure, codebaseContext, verification.

import SwiftUI
import AppKit
import ClaudeWatchCore

struct FiveStarTemplateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copiedSkeleton: Bool = false
    @State private var copiedExample: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "star.circle.fill")
                    .foregroundStyle(.yellow)
                Text("5★ Template")
                    .font(ClaudeFont.heading())
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.escape)
            }

            Text("13 section chuẩn rubric — copy về điền content của anh. Skeleton dưới là khung trống; phía dưới là 1 prompt 5★ thực từ project ClaudeWatchMac để tham khảo phong cách.")
                .font(ClaudeFont.body(12))
                .foregroundStyle(Claude.textMuted)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("Skeleton (copy + điền)", icon: "doc.text", action: copySkeleton, copied: copiedSkeleton)
                    codeBlock(FiveStarTemplate.skeleton)

                    sectionHeader("Worked example (real prompt từ ClaudeWatchMac)",
                                  icon: "checkmark.seal.fill",
                                  action: copyExample, copied: copiedExample)
                    codeBlock(FiveStarTemplate.workedExample)
                        .background(Claude.Chip.successBg.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 700)
        .background(Claude.background)
    }

    @ViewBuilder
    private func sectionHeader(_ text: String, icon: String,
                               action: @escaping () -> Void, copied: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Claude.orange)
            Text(text)
                .font(ClaudeFont.body(13))
                .fontWeight(.semibold)
                .foregroundStyle(Claude.textPrimary)
            Spacer()
            Button(action: action) {
                Label(copied ? "Copied!" : "Copy",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(ClaudeFont.label(11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? .green : Claude.orange)
        }
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(ClaudeFont.mono(11))
            .foregroundStyle(Claude.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Claude.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copySkeleton() {
        copy(FiveStarTemplate.skeleton)
        copiedSkeleton = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedSkeleton = false }
    }

    private func copyExample() {
        copy(FiveStarTemplate.workedExample)
        copiedExample = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedExample = false }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Templates

enum FiveStarTemplate {

    /// Skeleton trống — user copy + điền nội dung. Mỗi section là 1 dòng.
    static let skeleton: String = """
    ## Mục tiêu
    [1 câu — task này làm gì, kết quả đầu ra mong muốn]

    ## User Role
    [admin / regular user / system — ai dùng feature này]

    ## Input
    - field1: <type>, required, validation rule
    - field2: <type>, optional, default = X

    ## Output
    - Success: { status: "ok", data: {...} }
    - Error: { status: "error", code: "...", message: "..." }

    ## Flow chính
    1. [bước 1 — verb + object]
    2. [bước 2]
    3. [bước 3]

    ## Edge Case
    - [tình huống xấu 1] → behavior X
    - [tình huống xấu 2] → behavior Y

    ## constrained_by
    - [ràng buộc 1 — không được làm gì]
    - [ràng buộc 2]

    ## Definition of Done
    - [ ] [tiêu chí 1]
    - [ ] [tiêu chí 2]
    - [ ] Build pass, no warnings

    ## Codebase context
    - File: `path/to/file.swift`
    - Function: `funcName()` tại `file.swift:42`
    - Library: <name> v<x.y>

    ## Verification
    - Verify by: `<command>` → expected `<output>`
    - Kiểm tra: behavior X khi input Y

    ## Examples (few-shot)
    Input: ...
    Expected output: ...

    ## Motivation (Why)
    Lý do làm: [vì cần X / để đảm bảo Y / so that Z]

    ## XML structure (optional, advanced)
    <instructions>
      <task>...</task>
      <constraints>...</constraints>
    </instructions>

    <context>...existing code / schema...</context>

    <examples>...</examples>
    """

    /// Worked example: 1 prompt 5★ thực sự (P2b MetricKit từ session perf v0.2.1).
    /// Cho user thấy "5★ trông như thế nào" cụ thể, không phải template trống.
    static let workedExample: String = """
    ## Mục tiêu
    Implement MetricKit metrics subscriber để capture daily metric payloads từ
    macOS và write to disk for offline analysis.

    ## User Role
    Developer (advisory background collector — no user-facing UI surface).

    ## Codebase context
    - Tạo mới: `App/MetricsCollector.swift` (under 200 LoC)
    - Edit: `App/ClaudeWatchMacApp.swift` (wire start() in init/onAppear)
    - Framework: MetricKit, macOS 14+ available

    ## Input
    Không có user input. Tự subscribe vào MXMetricManager.shared khi app start.

    ## Output
    - File: `~/Library/Application Support/ClaudeWatch/metrics/<ISO>-metric.json`
    - File: `~/Library/Application Support/ClaudeWatch/metrics/<ISO>-diagnostic.json`
    - Format: payload.jsonRepresentation() (raw từ MetricKit)

    ## Flow chính
    1. Khởi tạo MetricsCollector.shared singleton (@MainActor, NSObject conform MXMetricManagerSubscriber)
    2. Đăng ký MXMetricManager.shared.add(self)
    3. didReceive(_ payloads:) → encode mỗi payload → write atomic
    4. pruneOldMetrics() — giữ 30 file cuối, xóa older

    ## Edge Case
    - File system full → log error, không crash
    - Payload non-Sendable trong Swift 6 → encode trong nonisolated callback, send Data over actor

    ## constrained_by
    - Swift 6 strict concurrency — không bridge non-Sendable types qua MainActor
    - File < 200 LoC
    - No UI changes
    - Không touch JsonlParser, CoachingScan, SpritePet, view files (parallel agent ownership)

    ## Definition of Done
    - [ ] File App/MetricsCollector.swift compile
    - [ ] MetricsCollector.shared.start() wired vào app init
    - [ ] Build SUCCEEDED, no warnings
    - [ ] Disk pruning cap ở 30 file

    ## Verification
    Verify by chạy: `xcodebuild -project ClaudeWatchMac.xcodeproj -scheme ClaudeWatchMac build`
    Expected: `** BUILD SUCCEEDED **`

    ## Motivation (Why)
    Lý do làm: vì cần signal khi user report "app lag" — không có data sẽ chỉ đoán.
    MetricKit là source-of-truth của Apple, không cần custom telemetry pipeline.
    """
}
