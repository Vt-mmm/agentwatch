import SwiftUI
import AppKit
import AgentWatchCore

struct AutomaticDailyReportExportButton: View {
    var day: Date? = nil
    @State private var busy = false
    @State private var progress = ""
    @State private var error: String?
    @State private var preparingDelivery = false
    private struct Delivery: Identifiable {
        let report: DailyReportDraft
        var id: String { report.reportID }
    }
    @State private var delivery: Delivery?
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 8) {
            Button { export() } label: {
                Label(busy && !preparingDelivery ? "Đang xuất…" : (day == nil ? "Xuất báo cáo hôm nay" : "Xuất báo cáo ngày này"), systemImage: "arrow.down.doc")
            }
            .buttonStyle(.borderedProminent).disabled(busy)
            .help("Tự lấy dữ liệu đã chuẩn bị, lưu PDF và mở ngay")
            Button { export(forDelivery: true) } label: {
                Label(busy && preparingDelivery ? "Đang chuẩn bị…" : "Gửi Google", systemImage: "paperplane")
            }
            .buttonStyle(.bordered).disabled(busy)
            .help("Tự chuẩn bị báo cáo để gửi qua Google Drive hoặc Gmail")
            }
            if busy { Text(progress).font(.caption2).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: 260) }
        }
        .sheet(item: $delivery) { item in
            AutomaticReportDeliveryView(draft: item.report)
        }
    }
    private func export(forDelivery: Bool = false) {
        guard let identity = SupervisorLockStore.shared.reportIdentity else {
            error = "Nhập key mở app trước khi xuất report."; return
        }
        preparingDelivery = forDelivery
        busy = true; error = nil; progress = "Đang chuẩn bị dữ liệu theo ngày…"
        let selectedDay = day ?? Date()
        let defaults = UserDefaults.standard
        let organization = defaults.string(forKey: "dailyReport.organizationID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let zone = defaults.string(forKey: "dailyReport.timeZone") ?? "Asia/Ho_Chi_Minh"
        let profile = EmployeeProfile(organizationID: organization.isEmpty ? "Chưa cấu hình tổ chức" : organization,
            employeeID: identity.employeeID, displayName: identity.name, timeZone: zone)
        Task {
            do {
                let period = try DailyReportPeriod(day: selectedDay, timeZone: zone, cutoff: Date())
                let cached = try await DailyActivityQuery.shared.cached(profile: profile, day: selectedDay)
                var report: DailyReportDraft
                if let cached, cached.period.cutoff >= period.end || Date().timeIntervalSince(cached.period.cutoff) < 90 {
                    report = cached
                } else {
                    progress = "Đang cập nhật nhật ký ngày…"
                    await DesktopAppActivityCollector.shared.flush()
                    report = try await DailyActivityQuery.shared.refresh(profile: profile, day: selectedDay)
                }
                let collectionError = DesktopAppActivityCollector.shared.error
                if let collectionError { report.warnings.append("Thu thập ứng dụng có lỗi: " + collectionError) }
                if forDelivery {
                    delivery = Delivery(report: report)
                    busy = false
                    return
                }
                progress = "Đang tạo PDF…"
                let preparedReport = report
                let result = try await Task.detached(priority: .userInitiated) {
                    let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AgentWatch Reports")
                    return (try AutomaticDailyReport.savePDF(preparedReport, directory: directory), preparedReport)
                }.value
                let url = result.0
                if !NSWorkspace.shared.open(url) {
                    self.error = "Đã lưu PDF tại " + url.path + "; chưa mở được ứng dụng đọc PDF."
                }
                SupervisorLockStore.shared.recordReportExport(format: "automatic-pdf", scope: .day(selectedDay), url: url)
            } catch {
                self.error = error.localizedDescription
                if !forDelivery { SupervisorLockStore.shared.recordReportExportFailure(format: "automatic-pdf", scope: .day(selectedDay), error: error) }
            }
            busy = false
        }
    }
}
