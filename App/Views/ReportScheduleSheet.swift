import SwiftUI
import AgentWatchCore

struct ReportScheduleSheet: View {
    let jobID: String
    let channel: ReportDeliveryChannel
    let employeeID: String
    let timeZone: String
    @Environment(\.dismiss) private var dismiss
    @State private var scheduledAt = Date().addingTimeInterval(3600)
    @State private var graceHours = 1
    @State private var confirmed = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Đặt lịch cho bản \(channel.rawValue) vừa duyệt").font(.title2.bold())
            Text("Chỉ xử lý đúng email/PDF, người nhận/thư mục và tài khoản vừa xem trước. Đây là một lượt gửi, không phải quyền gửi các báo cáo tương lai.")
            DatePicker("Thời điểm xử lý", selection: $scheduledAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, TimeZone(identifier: timeZone) ?? .current)
            Text("Múi giờ: \(timeZone)").font(.caption)
            Stepper("Cho phép xử lý muộn tối đa \(graceHours) giờ", value: $graceHours, in: 1...12)
            Text("AgentWatch và máy phải hoạt động, có mạng và credential hợp lệ. Nếu mở lại sau khoảng giờ này, lịch báo bị lỡ và cần duyệt lại. Không có backend gửi thay khi máy tắt.").foregroundStyle(.secondary)
            Toggle("Tôi duyệt thời điểm và khoảng trễ trên cho bản đã xem", isOn: $confirmed)
            HStack {
                Button("Hủy") { dismiss() }; Spacer()
                Button("Lưu lịch đã duyệt") { save() }.buttonStyle(.borderedProminent).disabled(!confirmed)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.padding(24).frame(width: 650)
        .onChange(of: scheduledAt) { _, _ in confirmed = false }
        .onChange(of: graceHours) { _, _ in confirmed = false }
    }
    private func save() {
        do {
            let expiry = scheduledAt.addingTimeInterval(Double(graceHours) * 3600)
            switch channel {
            case .gmail:
                guard let job = try GmailOutboxStore.local.read(jobID) else { throw GoogleServiceError.notFound }
                _ = try ReportDeliveryScheduleStore.local.scheduleGmail(job, at: scheduledAt, expiresAt: expiry, timeZone: timeZone, approvedBy: employeeID)
            case .drive:
                guard let job = try DriveUploadStore.local.read(jobID) else { throw GoogleServiceError.notFound }
                _ = try ReportDeliveryScheduleStore.local.scheduleDrive(job, at: scheduledAt, expiresAt: expiry, timeZone: timeZone, approvedBy: employeeID)
            }
            ReportDeliveryScheduler.shared.start(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
