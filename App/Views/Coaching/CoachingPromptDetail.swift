// Prompt detail sheet + TipExpander — modal showing full prompt text, checklist, coaching tips.
// Dependency direction: standalone structs, no dependency on CoachingReportView.

import SwiftUI
import ClaudeWatchCore

// MARK: - PromptDetailSheet

struct PromptDetailSheet: View {
    let record: PromptRecord
    @Environment(\.dismiss) private var dismiss
    @State private var showFiveStarTemplate: Bool = false

    /// v0.4.1 fix #11: show 5★ template button CHỈ khi prompt là task prompt yếu
    /// (≤ 2★). Bỏ trường hợp non-task (follow-up "ok") — template không phù hợp.
    private var showsTemplateButton: Bool {
        record.score.isTaskPrompt && record.score.stars <= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(Claude.orange)
                Text("Prompt detail")
                    .font(ClaudeFont.heading())
                Spacer()
                if showsTemplateButton {
                    Button {
                        showFiveStarTemplate = true
                    } label: {
                        Label("Xem 5★ Template", systemImage: "star.circle.fill")
                            .font(ClaudeFont.label(11))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Claude.orange)
                    .help("Khung prompt 5★ + ví dụ thực — copy về điền")
                }
                Button("Đóng") { dismiss() }.keyboardShortcut(.escape)
            }

            HStack(spacing: 8) {
                if record.score.isTaskPrompt {
                    chip("\(record.score.stars)★", Claude.Chip.warningBg, Claude.Chip.warningFg)
                } else {
                    chip("Follow-up", Claude.Chip.infoBg, Claude.Chip.infoFg)
                }
                if let title = record.sessionTitle {
                    chip(title, Claude.Chip.infoBg, Claude.Chip.infoFg)
                }
                chip("\(record.score.charCount) chars", Claude.Chip.infoBg, Claude.Chip.infoFg)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(fullTimestamp(record.timestamp))
                        .font(ClaudeFont.mono(11, weight: .semibold))
                        .foregroundStyle(Claude.textPrimary)
                    Text(record.displayTitle)
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if record.displayTitle != record.projectDisplay {
                        Text(record.projectDisplay)
                            .font(ClaudeFont.mono(9))
                            .foregroundStyle(Claude.textMuted.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if record.score.isTaskPrompt {
                checklistSection
            }

            SectionLabel(text: "Nội dung prompt")
            ScrollView {
                Text(record.text)
                    .font(ClaudeFont.mono(12))
                    .foregroundStyle(Claude.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Claude.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .frame(width: 660, height: 680)
        .background(Claude.background)
        .sheet(isPresented: $showFiveStarTemplate) {
            FiveStarTemplateSheet()
        }
    }

    /// Checklist 11 section. Mục PRESENT chỉ show 1 dòng; mục MISSING expand
    /// thành coaching tip card với template + ví dụ Anthropic-grounded.
    private var checklistSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Checklist Spec + coaching tips")
                ForEach(SpecSection.allCases, id: \.self) { sec in
                    if record.score.sectionsPresent.contains(sec) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(sec.label)
                                .font(ClaudeFont.body(12))
                                .foregroundStyle(Claude.textPrimary)
                        }
                    } else {
                        TipExpander(tip: CoachingTips.tip(for: sec))
                    }
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private func chip(_ text: String, _ bg: Color, _ fg: Color) -> some View {
        Text(text)
            .font(ClaudeFont.body(11))
            .fontWeight(.semibold)
            .foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg).clipShape(Capsule())
    }

    /// "dd/MM/yyyy HH:mm:ss" — full datetime cho detail sheet.
    private func fullTimestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm:ss"
        f.timeZone = .current
        return f.string(from: d)
    }
}

// MARK: - TipExpander

struct TipExpander: View {
    let tip: CoachingTip
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.orange)
                    Text("Thiếu: \(tip.section.label)")
                        .font(ClaudeFont.body(12))
                        .fontWeight(.medium)
                        .foregroundStyle(Claude.textPrimary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Claude.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tip.reason)
                        .font(ClaudeFont.body(11))
                        .foregroundStyle(Claude.textMuted)

                    sectionHeader("Template (copy + sửa)")
                    codeBlock(tip.template)
                        .overlay(alignment: .topTrailing) { copyButton(tip.template) }

                    sectionHeader("Ví dụ pass")
                    codeBlock(tip.example).background(Claude.Chip.successBg.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                        Link(destination: URL(string: tip.sourceUrl)!) {
                            Text("Anthropic source")
                                .font(ClaudeFont.label(10))
                        }
                    }
                    .foregroundStyle(Claude.orange)
                }
                .padding(10)
                .background(Claude.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(ClaudeFont.label(9))
            .tracking(0.6)
            .foregroundStyle(Claude.textMuted)
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(ClaudeFont.mono(11))
            .foregroundStyle(Claude.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Claude.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
                .padding(6)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Claude.orange)
        .help("Copy template")
    }
}
