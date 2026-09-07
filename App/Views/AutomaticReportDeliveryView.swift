import SwiftUI
import AgentWatchCore

/// Local exports are drafts. Reviewing for delivery creates an immutable version;
/// each provider then requires approval of its exact payload and destination.
struct AutomaticReportDeliveryView: View {
    let draft: DailyReportDraft
    var savedSnapshot: ReportSnapshot? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ReportSnapshot?
    @State private var preview: Data?
    @State private var reviewed = false
    private enum Step { case review, drive, gmail }
    @State private var step = Step.review
    @State private var error: String?
    var body: some View {
        Group {
            switch step {
            case .review: review
            case .drive:
                if let snapshot { GoogleDriveDeliveryView(snapshot: snapshot, onBack: { step = .review }, onGmail: { step = .gmail }) }
            case .gmail:
                if let snapshot { GmailDeliveryView(snapshot: snapshot, onBack: { step = .review }) }
            }
        }
    }
    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Gửi report ngày").font(.title2.bold()); Spacer(); Button("Đóng") { dismiss() } }
            Text(draft.employee.displayName + " · " + DailyReportRenderer.dateLabel(draft.period.start, zone: draft.period.timeZone))
            Text("Report có nội dung prompt và lịch sử ứng dụng. Xem PDF trước khi chọn nơi gửi.").foregroundStyle(.secondary)
            if let preview { ReportPDFPreview(data: preview).frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text("Bước tiếp theo hiển thị nơi nhận và nút gửi cuối cùng.").font(.caption).foregroundStyle(.secondary)
            Toggle("Tôi đã xem nội dung report và đồng ý dùng bản này để chuẩn bị gửi", isOn: $reviewed)
            HStack {
                Button("Tiếp tục với Drive →") { prepare(drive: true) }.buttonStyle(.borderedProminent).disabled(!reviewed || preview == nil)
                Button("Tiếp tục với Gmail →") { prepare(drive: false) }.disabled(!reviewed || preview == nil)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.padding(22).frame(width: 850, height: 760)
         .task {
            guard preview == nil else { return }
            do {
                snapshot = savedSnapshot; reviewed = savedSnapshot != nil
                preview = try DailyReportRenderer.pdf(draft, revision: savedSnapshot?.revision)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func prepare(drive: Bool) {
        guard reviewed, let identity = SupervisorLockStore.shared.reportIdentity,
              identity.employeeID == draft.employee.employeeID else { error = "Cần nhập đúng key của report."; return }
        do {
            if snapshot == nil { snapshot = try ReportSnapshotStore.local.save(draft, reviewedBy: identity.employeeID) }
            step = drive ? .drive : .gmail
        } catch { self.error = error.localizedDescription }
    }
}
