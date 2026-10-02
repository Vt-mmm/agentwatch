import SwiftUI
import AgentWatchCore

// Small building blocks for the Studio tab: one status pill, one quota bar,
// compact cards. Explanations live in tooltips (.help) rather than paragraphs.

enum StudioTone {
    case ok, warning, danger, neutral, info
    init(_ tone: StudioEmployeeStatus.Tone) {
        switch tone { case .ok: self = .ok; case .warning: self = .warning; case .danger: self = .danger; case .neutral: self = .neutral }
    }
    var foreground: Color {
        switch self {
        case .ok: Claude.Chip.successFg; case .warning: Claude.Chip.warningFg; case .danger: Claude.Chip.dangerFg
        case .info: Claude.Chip.infoFg; case .neutral: Claude.textMuted
        }
    }
    var background: Color {
        switch self {
        case .ok: Claude.Chip.successBg; case .warning: Claude.Chip.warningBg; case .danger: Claude.Chip.dangerBg
        case .info: Claude.Chip.infoBg; case .neutral: Claude.surfaceAlt
        }
    }
    /// Text/tint color readable on both light and dark card backgrounds.
    var inline: Color {
        switch self {
        case .ok: Claude.live; case .warning: Color(nsColor: .systemOrange); case .danger: Color(nsColor: .systemRed)
        case .info: Color(nsColor: .systemBlue); case .neutral: Claude.textMuted
        }
    }
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .danger: "xmark.octagon.fill"
        case .info: "info.circle.fill"; case .neutral: "circle.dotted"
        }
    }
}

struct StudioPill: View {
    let title: String
    let tone: StudioTone
    var body: some View {
        Label(title, systemImage: tone.symbol)
            .font(ClaudeFont.label(11)).lineLimit(1)
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tone.background, in: Capsule())
    }
}

/// Remaining budget as a thin bar: "Hôm nay  ████░░  72% · 3,1 tr/4,3 tr".
struct StudioQuotaBar: View {
    let summary: StudioQuotaSummary
    var compact = false
    private var tone: StudioTone { summary.remaining == 0 ? .danger : summary.remainingRatio <= StudioEmployeeStatus.nearLimit ? .warning : .ok }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(summary.period == "day" ? "Hôm nay" : "Tháng này").font(ClaudeFont.label(11)).foregroundStyle(Claude.textMuted)
                Spacer(minLength: 4)
                Text("còn \(Int((summary.remainingRatio * 100).rounded()))%").font(ClaudeFont.label(11)).foregroundStyle(tone.inline).monospacedDigit()
            }
            ProgressView(value: summary.remainingRatio).tint(tone.inline).controlSize(.small)
            if !compact {
                Text("\(StudioFormat.tokens(summary.remaining)) / \(StudioFormat.tokens(summary.limit)) token · mở lại \(summary.endsAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(ClaudeFont.body(10.5)).foregroundStyle(Claude.textMuted).monospacedDigit()
            }
        }
        .help("Hạn mức nội bộ của key, tính trên token đã xác nhận và phần đang giữ. Không phải hạn mức thuê bao Claude/Codex.")
    }
}

/// Employee-facing wording for the stable sync failure codes.
enum StudioSyncReason {
    static func label(_ code: String?) -> String {
        switch code {
        case "no_models_granted": "Key chưa có model"
        case "cli_missing": "Chưa cài CLI"
        case "cli_desktop_binary": "Đang dùng CLI của app desktop"
        case "cli_unsupported_version": "CLI chưa kiểm chứng"
        case "managed_settings": "Cấu hình do tổ chức quản lý"
        case "pi_missing": "Chưa cài Pi"
        case "missing_catalog": "Thiếu thông số model"
        case "native_model_unavailable": "Chưa xác minh model gốc"
        case "config_changed_externally": "Cấu hình bị sửa ngoài app"
        case "config_unwritable": "Không ghi được cấu hình"
        case "config_unsupported": "Cấu hình chưa hỗ trợ"
        case "key_invalid": "Key không hợp lệ"
        case "offline": "Mất kết nối"
        default: "Cần xử lý"
        }
    }
}

enum StudioFormat {
    static func tokens(_ value: Int64) -> String {
        let v = Double(value)
        if v >= 1e9 { return (v / 1e9).formatted(.number.precision(.fractionLength(0...1))) + " tỷ" }
        if v >= 1e6 { return (v / 1e6).formatted(.number.precision(.fractionLength(0...1))) + " tr" }
        if v >= 1e3 { return (v / 1e3).formatted(.number.precision(.fractionLength(0...1))) + " k" }
        return value.formatted()
    }
    static func tokens(_ count: StudioCount?) -> String { count.flatMap { Int64($0.value) }.map(tokens) ?? "—" }
    static func day(_ date: Date) -> String { date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()) }
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).hour().minute())
    }
    static func provider(_ id: String) -> String { id == "claude" ? "Claude" : id == "codex" ? "Codex" : id }
    static func host(_ origin: String) -> String { URL(string: origin)?.host.map { h in URL(string: origin)?.port.map { "\(h):\($0)" } ?? h } ?? origin }
}

extension View {
    /// Compact card used across the Studio tab.
    func studioCard(padding: CGFloat = 14) -> some View { claudeCard(padding: padding) }
}

/// Two columns when there is room, stacked otherwise.
struct StudioColumns<Leading: View, Trailing: View>: View {
    var trailingWidth: CGFloat = 290
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) { leading }.frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) { trailing }.frame(width: trailingWidth, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 14) { leading; trailing }
        }
    }
}

/// Wrapping row of chips for model names.
struct StudioChips: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}
