// Mini paginator dùng chung cho mọi list dài: Sessions, Prompts, Events, Agents.
// ‹ 1/N › — ẩn hoàn toàn khi chỉ có 1 trang để không gây nhiễu UI.

import SwiftUI

struct Paginator: View {
    let page: Int          // 0-based
    let totalPages: Int
    let onChange: (Int) -> Void

    var body: some View {
        if totalPages > 1 {
            HStack(spacing: 4) {
                Button { onChange(max(0, page - 1)) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(page == 0)

                Text("\(page + 1) / \(totalPages)")
                    .font(ClaudeFont.mono(11))
                    .foregroundStyle(Claude.textMuted)
                    .frame(minWidth: 44)

                Button { onChange(min(totalPages - 1, page + 1)) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(page >= totalPages - 1)
            }
        }
    }
}

/// Tính số trang + slice index 1 cách an toàn (clamp page nếu vượt).
enum Pagination {
    static func info<T>(items: [T], page: Int, pageSize: Int)
        -> (slice: ArraySlice<T>, page: Int, totalPages: Int) {
        let total = items.count
        let totalPages = max(1, Int(ceil(Double(total) / Double(pageSize))))
        let safePage = min(max(0, page), totalPages - 1)
        let start = safePage * pageSize
        let end = min(start + pageSize, total)
        let slice: ArraySlice<T> = total > 0 ? items[start..<end] : []
        return (slice, safePage, totalPages)
    }
}
