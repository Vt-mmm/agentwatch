// Filter card: scope picker, date nav, source/viewMode/project/model pickers, search field, export buttons.
// Dependency direction: extension on CoachingReportView ← CoachingShared (scopeRangeLabel, shiftAnchor, export).

import SwiftUI
import AppKit
import ClaudeWatchCore

extension CoachingReportView {

    // MARK: - Filter card

    var filterCard: some View {
        VStack(spacing: 10) {
            // Hiển thị rõ range đang được filter — user không bị "nhảy" khi đổi
            // scope/anchor mà không hiểu hệ thống đang đọc data ngày nào.
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .foregroundStyle(Claude.orange)
                Text("Đang xem:")
                    .font(ClaudeFont.label(11))
                    .foregroundStyle(Claude.textMuted)
                Text(scopeRangeLabel)
                    .font(ClaudeFont.mono(13, weight: .semibold))
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
            }

            HStack(spacing: 10) {
                Picker("", selection: $scope) {
                    ForEach(ScopeKind.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                // Prev/next nav: 1 ngày · 7 ngày · 30 ngày tùy scope.
                Button { shiftAnchor(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .help(shiftHelp(forward: false))

                // in: ...Date() chặn DatePicker calendar không cho chọn ngày tương lai.
                DatePicker("", selection: $anchor, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .fixedSize()

                Button { shiftAnchor(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(!canShiftForward)
                .help(shiftHelp(forward: true))

                Button("Hôm nay") { anchor = Date() }
                    .buttonStyle(.bordered)

                Spacer(minLength: 8)

                Button { exportMarkdown() } label: {
                    Image(systemName: "doc.text")
                    Text("MD")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("e", modifiers: [.command])

                Button { exportCSV() } label: {
                    Image(systemName: "tablecells")
                    Text("CSV")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button { exportHTML() } label: {
                    Image(systemName: "globe")
                    Text("HTML")
                }
                .buttonStyle(.borderedProminent)
                .tint(Claude.orange)
            }

            HStack(spacing: 10) {
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { m in
                        Text("\(m.rawValue)\(m == .bookmarks ? " (\(bookmarks.items.count))" : "")").tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Picker("", selection: $sourceFilter) {
                    ForEach(SourceFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
                Text(filterCountLabel)
                    .font(ClaudeFont.mono(11))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                searchField
                projectPicker
                modelPicker
                Spacer()
            }
        }
        .claudeCard()
    }

    // MARK: - Search field

    /// Search box theme Claude — không xài system .roundedBorder vì lệch tông cream.
    var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Claude.textMuted)
            TextField("Search prompt text…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(ClaudeFont.body(12))
                .focused($searchFocused)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Claude.textMuted)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Claude.surfaceAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searchFocused ? Claude.orange : Claude.border,
                              lineWidth: searchFocused ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 320)
    }

    // MARK: - Project picker

    /// Project picker: Menu button thay vì Picker để có style match theme.
    var projectPicker: some View {
        Menu {
            Button("Mọi task/project") { projectFilter = "" }
            Divider()
            ForEach(projectOptions, id: \.self) { p in
                Button(p) { projectFilter = p }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(Claude.textMuted)
                Text(projectFilter.isEmpty ? "Mọi task/project" : truncateMid(projectFilter, max: 28))
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Claude.textMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Claude.surfaceAlt)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Claude.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Model picker

    var modelPicker: some View {
        Menu {
            Button("Mọi model") { modelFilter = "" }
            Divider()
            ForEach(modelOptions, id: \.self) { m in
                Button(m) { modelFilter = m }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10))
                    .foregroundStyle(Claude.textMuted)
                Text(modelFilter.isEmpty ? "Mọi model" : truncateMid(modelFilter, max: 20))
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Claude.textMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Claude.surfaceAlt)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Claude.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Helpers

    /// Đếm hiển thị bên phải segmented, ngắn gọn.
    var filterCountLabel: String {
        let s = sessions.count, p = records.count
        let r = riskSummary.totalFindings
        return "\(s) session · \(p) prompt · \(r) risk"
    }

}
