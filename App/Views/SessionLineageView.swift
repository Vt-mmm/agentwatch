import SwiftUI
import AgentWatchCore

struct SessionLineageView: View {
    let sessions: [SessionSummary]
    let before: Date
    @State private var snapshot: SessionLineageSnapshot?
    @State private var busy = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        DisclosureGroup("Nguồn gốc và các lần gọi agent của session") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quan hệ phiên độc lập với liên kết task. Phiên cha không tự được cộng token vào task này.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(busy ? "Đang đọc…" : "Đọc quan hệ session", action: load).disabled(busy)
                if let snapshot {
                    ForEach(snapshot.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    if snapshot.relations.isEmpty { Text("Chưa thấy quan hệ được hỗ trợ trong phần log đã đọc; không khẳng định session không có phiên cha.").font(.caption) }
                    ForEach(Array(snapshot.relations.suffix(100))) { relation in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(relation.kind.label) · \(relation.timestamp.formatted(date: .abbreviated, time: .shortened))").font(.caption.bold())
                            Text(relation.sessionRef + " → " + (relation.relatedRef ?? "Chưa có ID agent đích")).font(.caption).textSelection(.enabled)
                            Text(relation.explanation).font(.caption2).foregroundStyle(.secondary)
                            Text(relation.localRef).font(.caption2).textSelection(.enabled)
                        }
                    }
                    if snapshot.relations.count > 100 { Text("Hiện 100 quan hệ cuối trong mẫu.").font(.caption) }
                }
            }.padding(.vertical, 8)
        }.onDisappear { work?.cancel() }
    }
    private func load() {
        work?.cancel(); busy = true
        let sources = sessions, cutoff = before
        work = Task {
            let reader = Task.detached(priority: .userInitiated) { SessionLineageReader.read(sessions: sources, before: cutoff) }
            let result = await withTaskCancellationHandler(operation: { await reader.value }, onCancel: { reader.cancel() })
            guard !Task.isCancelled else { return }
            snapshot = result; busy = false
        }
    }
}
