import SwiftUI
import AgentWatchCore

struct InsightHistoryView: View {
    let projectPath: String
    let revision: Date?
    var store: InsightHistoryStore = .shared
    var roots: AgentLogRoots = .current
    var queryStore: CoachingQueryStore = .shared
    var bindingStore: TaskBindingStore = .local
    @State private var start = Date()
    @State private var end = Date()
    @State private var search = ""
    @State private var result: InsightHistoryResult?
    @State private var error: String?
    @State private var busy = false
    @State private var offset = 0
    @State private var work: Task<Void, Never>?

    var body: some View {
        GroupBox("Tra cứu lịch sử đã lưu trên máy") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tự chuẩn bị dữ liệu theo ngày và tìm khi anh nhập từ khóa.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    DatePicker("Từ", selection: $start, displayedComponents: .date)
                    DatePicker("Đến", selection: $end, displayedComponents: .date)
                }.disabled(busy)
                HStack {
                    TextField("Tìm prompt, task hoặc model…", text: $search).onSubmit { query() }
                    Button("Tìm") { query() }.disabled(busy || projectPath.isEmpty || start > end)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                if let result {
                    Text(result.fullyIndexed ? "Khoảng ngày đã có chỉ mục" : "Khoảng ngày chưa có đủ chỉ mục")
                        .font(.subheadline)
                    if let time = result.indexedThrough {
                        Text("Lần cập nhật cũ nhất trong khoảng: \(time.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    }
                    Text("\(result.ledger.normalizedTokens.total) token đã ghi nhận trong khoảng ngày (không phụ thuộc từ khóa tìm)").font(.caption)
                    ForEach(result.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    if result.records.isEmpty { Text("Không có kết quả trong phần dữ liệu đã lưu.").foregroundStyle(.secondary) }
                    ForEach(result.records) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(record.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(record.kind.rawValue) · \(record.sessionID)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(record.text).lineLimit(4).textSelection(.enabled)
                            if let ref = record.localRef { Text(ref).font(.caption2).textSelection(.enabled) }
                        }
                        Divider()
                    }
                    HStack {
                        Button("Trang trước") { query(page: max(0, offset - 100)) }.disabled(busy || offset == 0)
                        Text("Trang \(offset / 100 + 1)").font(.caption)
                        Button("Trang sau") { query(page: offset + 100) }.disabled(busy || !result.hasMore)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: projectPath + "|" + String(start.timeIntervalSince1970) + "|" + String(end.timeIntervalSince1970) + "|" + search + "|" + String(describing: revision)) {
            clear()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !projectPath.isEmpty else { return }
            query()
        }
        .onDisappear { work?.cancel() }
    }
    private func clear() { work?.cancel(); result = nil; error = nil; offset = 0; busy = false }
    private func query(page: Int = 0) {
        guard start <= end else { return }
        work?.cancel(); busy = true; error = nil
        let lower = Calendar.current.startOfDay(for: start)
        let upper = ReportTime.range(for: .day(end)).upperBound
        let project = projectPath, term = search
        work = Task {
            do {
                var value = try await store.query(project: project, range: lower..<upper, search: term, offset: page)
                guard !Task.isCancelled else { return }
                result = value; offset = page
                if !value.fullyIndexed {
                    let range = lower..<upper
                    let roots = roots, queryStore = queryStore, bindingStore = bindingStore
                    let prepared = try await Task.detached(priority: .utility) {
                        let scan = await CoachingScan.scan(in: range, roots: roots, store: queryStore)
                        let journal = PiTaskJournal.read(project: URL(fileURLWithPath: project), range: range)
                        let bindings = try bindingStore.load()
                        let lifecycle = TaskLifecycleBuilder.build(scan: scan, journals: [journal], bindings: bindings, range: range, projectPath: project)
                        return (InsightHistoryRecord.collect(scan: scan, lifecycle: lifecycle, projectPath: project), lifecycle.warnings)
                    }.value
                    guard !Task.isCancelled else { return }
                    try await store.replace(project: project, range: range, records: prepared.0.filter { range.contains($0.timestamp) }, warnings: prepared.1, capturedAt: Date())
                    value = try await store.query(project: project, range: range, search: term, offset: page)
                    guard !Task.isCancelled else { return }
                    result = value
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { busy = false }
        }
    }
}
