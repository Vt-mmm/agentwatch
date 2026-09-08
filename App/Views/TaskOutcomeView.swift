import SwiftUI
import AppKit
import AgentWatchCore

struct TaskOutcomeView: View {
    let item: TaskLifecycleItem
    let sessions: [SessionSummary]
    let range: Range<Date>
    let links: [JournalTaskLink]
    var bindingStore: TaskBindingStore = .local
    var store: TaskAcceptanceStore = .local
    @State private var evidence: [TaskOutcomeEvidence] = []
    @State private var acceptances: [TaskAcceptance] = []
    @State private var selected: Set<String> = []
    @State private var commitID = ""
    @State private var reviewer = ""
    @State private var note = ""
    @State private var error: String?
    @State private var loaded = false
    @State private var busy = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        DisclosureGroup("Bằng chứng kết quả và nghiệm thu") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Lời agent, phản hồi test và thao tác file được trình bày riêng. Không có phản hồi công cụ nào tự xác nhận hoàn thành.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(busy ? "Đang đọc bằng chứng…" : "Đọc bằng chứng của task", action: load).disabled(busy)
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                if loaded {
                    HStack {
                        Button("Kiểm tra file trong dự án…") { chooseArtifact() }.disabled(busy)
                        Button("Đọc báo cáo JUnit…") { chooseArtifact(testReport: true) }.disabled(busy)
                    }
                    HStack {
                        TextField("Mã commit đầy đủ", text: $commitID).disabled(busy)
                        Button("Kiểm tra commit") {
                            let project = URL(fileURLWithPath: item.projectPath), id = commitID.trimmingCharacters(in: .whitespacesAndNewlines)
                            verify { try LocalArtifactVerifier.commit(project: project, objectID: id) }
                        }.disabled(busy || commitID.isEmpty)
                    }
                    Text("\(evidence.count) quan sát (log trong khoảng đã chọn và xác minh hiện tại). Log/đoạn xem trước có thể thiếu; số 0 không chứng minh không có hoạt động.").font(.caption)
                    ForEach(Array(evidence.suffix(100))) { row in
                        HStack(alignment: .top) {
                            Toggle("Chọn", isOn: Binding(get: { selected.contains(row.id) }, set: { value in
                                if value { selected.insert(row.id) } else { selected.remove(row.id) }
                            })).labelsHidden()
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(row.kind.label) · \(row.timestamp.formatted(date: .abbreviated, time: .shortened))").font(.caption.bold())
                                Text(row.summary).font(.caption).lineLimit(6).textSelection(.enabled)
                                Text(row.caveat).font(.caption2).foregroundStyle(.secondary)
                                Text(row.localRef).font(.caption2).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Nguồn") {
                                let path = row.localRef.components(separatedBy: "#").first ?? ""
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                    }
                    if evidence.count > 100 { Text("Hiện 100 quan sát cuối; mở nguồn để xem phần trước.").font(.caption) }
                    Divider()
                    Text("Nghiệm thu thủ công cho run: " + item.runIDs.joined(separator: ", ")).font(.caption.bold())
                    TextField("Tên người xác nhận", text: $reviewer)
                    TextField("Đã kiểm tra gì, kết quả nào được chấp nhận", text: $note)
                    Button("Xác nhận nghiệm thu với bằng chứng đã chọn", action: accept)
                        .disabled(busy || selected.isEmpty || reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Lưu xác nhận cục bộ theo tên tự khai và đúng các run trên; không duyệt thay thành viên khác hoặc gửi báo cáo.")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(acceptances) { acceptance in
                        DisclosureGroup("\(acceptance.reviewer) · \(acceptance.recordedAt.formatted(date: .abbreviated, time: .shortened))") {
                            Text("Run: " + acceptance.runIDs.joined(separator: ", ")).font(.caption)
                            Text(acceptance.note).font(.caption)
                            ForEach(acceptance.evidence) { saved in
                                Text("\(saved.kind.label): \(saved.summary)").font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
            }.padding(.vertical, 8)
        }
        .onDisappear { work?.cancel() }
    }
    private func load() {
        work?.cancel(); busy = true; error = nil
        let linked = Set(item.sessionRefs)
        let sources = sessions.filter { linked.contains($0.auditKey) }
        let range = self.range, store = self.store, project = self.item.projectPath, taskID = self.item.taskID
        let item = self.item, links = self.links, bindingStore = self.bindingStore
        work = Task {
            let reader = Task.detached(priority: .userInitiated) {
                let bindings = try bindingStore.load()
                let rows = TaskOutcomeReader.read(sessions: sources, range: range, item: item, bindings: bindings, links: links)
                return (rows, try store.load(projectPath: project, taskID: taskID))
            }
            do {
                let value = try await withTaskCancellationHandler(operation: { try await reader.value }, onCancel: { reader.cancel() })
                guard !Task.isCancelled else { return }
                evidence = value.0; acceptances = value.1; selected = []; loaded = true
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { busy = false }
        }
    }
    private func chooseArtifact(testReport: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: item.projectPath)
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let project = URL(fileURLWithPath: item.projectPath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = project.path + "/"
        guard file.path.hasPrefix(prefix) else { error = "Chọn file nằm trong dự án của task."; return }
        let relative = String(file.path.dropFirst(prefix.count))
        verify {
            if testReport { return try LocalArtifactVerifier.testReport(project: project, relativePath: relative) }
            return try LocalArtifactVerifier.file(project: project, relativePath: relative)
        }
    }
    private func verify(_ operation: @escaping @Sendable () throws -> TaskOutcomeEvidence) {
        work?.cancel(); busy = true; error = nil
        work = Task {
            let reader = Task.detached(priority: .userInitiated) { try operation() }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await reader.value }, onCancel: { reader.cancel() })
                guard !Task.isCancelled else { return }
                evidence.append(result)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { busy = false }
        }
    }

    private func accept() {
        do {
            let value = TaskAcceptance(projectPath: item.projectPath, taskID: item.taskID,
                runIDs: item.runIDs, evidence: evidence.filter { selected.contains($0.id) }, reviewer: reviewer, note: note)
            try store.append(value)
            acceptances = try store.load(projectPath: item.projectPath, taskID: item.taskID)
            note = ""; selected = []; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
