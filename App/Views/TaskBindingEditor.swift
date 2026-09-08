import SwiftUI
import AgentWatchCore

struct TaskBindingEditor: View {
    let projectPath: String
    var store: TaskBindingStore = .local
    let onSaved: () -> Void
    @State private var bindings: [TaskSessionBinding] = []
    @State private var prior: [TaskSessionBinding] = []
    @State private var selected: TaskSessionBinding?
    @State private var task = ""
    @State private var run = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var hasEnd = true
    @State private var message: String?

    var body: some View {
        DisclosureGroup("Sửa liên kết session đã lưu") {
            VStack(alignment: .leading, spacing: 8) {
                Button("Đọc liên kết của dự án") { load() }
                ForEach(bindings) { binding in
                    Button("\(binding.source.vendor.label) · \(binding.sessionID) → \(binding.taskID) / \(binding.taskRunID)") {
                        selected = binding; task = binding.taskID; run = binding.taskRunID
                        start = binding.start; end = binding.end ?? Date(); hasEnd = binding.end != nil; message = nil
                        do { prior = try store.previousVersions(id: binding.id) } catch { prior = []; message = error.localizedDescription }
                    }.buttonStyle(.link)
                }
                if let selected {
                    Text("Sửa session: " + selected.sessionID).font(.caption)
                    TextField("Task ID", text: $task)
                    TextField("Run ID", text: $run)
                    DatePicker("Bắt đầu", selection: $start)
                    Toggle("Có thời điểm kết thúc", isOn: $hasEnd)
                    if hasEnd { DatePicker("Kết thúc (không gồm thời điểm này)", selection: $end) }
                    ForEach(Array(prior.enumerated()), id: \.offset) { _, old in
                        Button("Dùng lại: \(old.taskID) / \(old.taskRunID) · \(old.recordedAt.formatted(date: .abbreviated, time: .shortened))") {
                            task = old.taskID; run = old.taskRunID; start = old.start
                            end = old.end ?? Date(); hasEnd = old.end != nil
                        }.buttonStyle(.link)
                    }
                    Button("Lưu điều chỉnh", action: save)
                    Text("Không sửa log nguồn. Liên kết chồng lấn sẽ bị từ chối; số liệu cần đọc lại sau khi sửa.").font(.caption).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.caption) }
            }.padding(.vertical, 8)
        }.onChange(of: projectPath) { _, _ in bindings = []; selected = nil; message = nil }
    }
    private func load() {
        do { bindings = try store.load().filter { $0.projectPath == projectPath }; message = bindings.isEmpty ? "Dự án chưa có liên kết thủ công." : nil }
        catch { message = error.localizedDescription }
    }
    private func save() {
        guard let selected else { return }
        var edited = TaskSessionBinding(projectPath: projectPath, taskID: task.trimmingCharacters(in: .whitespacesAndNewlines),
            taskRunID: run.trimmingCharacters(in: .whitespacesAndNewlines), source: selected.source, sessionID: selected.sessionID,
            start: start, end: hasEnd ? end : nil)
        edited.id = selected.id
        do {
            _ = try store.save(edited); load(); self.selected = nil; message = "Đã lưu điều chỉnh."; onSaved()
        } catch { message = error.localizedDescription }
    }
}
