import SwiftUI
import AppKit
import AgentWatchCore

struct TeamReportOverviewView: View {
    @AppStorage("dailyReport.employeeID") private var employeeID = ""
    @State private var day = Date()
    @State private var overview: TeamReportOverview?
    @State private var importResult: TeamReportImportResult?
    @State private var error: String?
    @State private var busy = false
    @State private var work: Task<Void, Never>?
    var inbox: TeamReportInbox = .local

    var body: some View {
        DisclosureGroup("Tổng hợp báo cáo nhóm đã duyệt") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Kho cục bộ dành cho chủ chính sách nhóm còn hiệu lực. Nhập từ thư mục anh chọn; không tự gửi hoặc đồng bộ lên dịch vụ ngoài.").font(.caption).foregroundStyle(.secondary)
                Text("Hồ sơ cục bộ: " + (employeeID.isEmpty ? "Chưa cấu hình" : employeeID)).font(.caption)
                HStack {
                    DatePicker("Ngày báo cáo", selection: $day, displayedComponents: .date).disabled(busy)
                    Button("Đọc tổng hợp") { load() }.disabled(busy || employeeID.isEmpty)
                    Button("Nhập thư mục báo cáo…", action: chooseFolder).disabled(busy || employeeID.isEmpty)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                if let importResult {
                    Text("\(importResult.imported) báo cáo mới · \(importResult.unchanged) bản đã có · \(importResult.rejected.count) vấn đề cần kiểm tra").font(.caption)
                    ForEach(Array(importResult.rejected.enumerated()), id: \.offset) { _, issue in Text(issue).font(.caption).foregroundStyle(.secondary) }
                }
                if let overview {
                    Text("Tổ chức: \(overview.organizationID) · Đọc lúc \(overview.checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    Text("\(overview.members.filter { $0.snapshot == nil }.count)/\(overview.members.count) thành viên chưa có báo cáo trong kho cho ngày này").font(.subheadline)
                    ForEach(overview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    ForEach(overview.members) { member in
                        GroupBox(member.employeeID) {
                            VStack(alignment: .leading, spacing: 5) {
                                if let snapshot = member.snapshot {
                                    Text("Phiên bản \(snapshot.revision) · \(member.outstanding.count) mục chưa hoàn tất · \(member.needsHelp.count) mục cần hỗ trợ").font(.caption)
                                    Text(snapshot.report.summary).font(.caption).textSelection(.enabled)
                                    if member.partialDay { Text("Báo cáo chốt trước cuối ngày; chưa bao phủ cả ngày.").font(.caption).foregroundStyle(.secondary) }
                                    if member.deliveries.isEmpty { Text("Chưa có trạng thái giao nhận trên máy này cho đúng phiên bản báo cáo.").font(.caption).foregroundStyle(.secondary) }
                                    ForEach(member.deliveries) { delivery in
                                        Text("\(delivery.channel): \(delivery.state)" + (delivery.needsAttention ? " · Cần đối chiếu" : "")).font(.caption)
                                    }
                                    ForEach(member.outstanding) { item in
                                        Text("\(item.status.label) · \(item.project) · \(item.title)").font(.caption.bold())
                                        if !item.blockers.isEmpty { Text("Vướng: " + item.blockers).font(.caption) }
                                        if !item.nextActions.isEmpty { Text("Tiếp theo: " + item.nextActions).font(.caption) }
                                    }
                                    ForEach(snapshot.report.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                                } else { Text("Chưa có báo cáo đã nhập. Không kết luận thành viên không làm việc.").font(.caption) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("Dấu kiểm nội dung phát hiện thay đổi tệp; không phải chữ ký số xác thực người gửi. Trạng thái giao nhận của máy khác chưa có trong kho này.").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 8)
        }
        .onChange(of: employeeID) { _, _ in reset() }
        .onChange(of: day) { _, _ in reset() }
        .onDisappear { work?.cancel() }
    }
    private func reset() { work?.cancel(); overview = nil; importResult = nil; error = nil; busy = false }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Nhập báo cáo đã duyệt"
        if panel.runModal() == .OK, let folder = panel.url { load(folder: folder) }
    }
    private func load(folder: URL? = nil) {
        work?.cancel(); busy = true; error = nil; overview = nil
        let employee = self.employeeID, day = self.day, inbox = self.inbox
        work = Task {
            let reader = Task.detached(priority: .userInitiated) {
                let imported = try folder.map { try inbox.importFolder($0, employeeID: employee) }
                return (imported, try inbox.overview(employeeID: employee, day: day))
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await reader.value }, onCancel: { reader.cancel() })
                guard !Task.isCancelled else { return }
                importResult = result.0; overview = result.1
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { busy = false }
        }
    }
}
