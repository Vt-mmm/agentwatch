import SwiftUI
import AgentWatchCore

struct GmailDeliveryView: View {
    let snapshot: ReportSnapshot
    var onBack: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var connection = GoogleConnectionStore()
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var job: GmailOutboxJob?
    @State private var pdf: Data?
    @State private var approved = false
    @State private var busy = false
    @State private var error: String?
    @State private var history: [GmailOutboxJob] = []
    @State private var reconciliationNote = ""
    @State private var acceptsDuplicateRisk = false
    @State private var showSchedule = false
    private let store = GmailOutboxStore.local

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Gửi report bằng Gmail").font(.title2.bold()); Spacer(); Button(onBack == nil ? "Đóng" : "← Quay lại") { if let onBack { onBack() } else { dismiss() } }.disabled(busy || connection.isConnecting) }
            if busy { ProgressView("Đang chuẩn bị hoặc gửi email…").controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if job?.state == .accepted { Label("Gmail đã xác nhận gửi report", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Tài khoản gửi") {
                        VStack(alignment: .leading) {
                            Text(connection.email.isEmpty ? "Chưa kết nối" : connection.email).textSelection(.enabled)
                            Button(connection.isConnecting ? "Đang đăng nhập…" : "Đăng nhập lại…") { connect() }
                                .disabled(connection.isConnecting || connection.clientID.isEmpty)
                            Text("Email được gửi từ tài khoản này, kèm PDF report.").font(.caption).foregroundStyle(.secondary)
                            if connection.clientID.isEmpty { Text("Mở Kết nối Google để nhập file JSON trước.").font(.caption) }
                        }.padding(5).disabled(busy)
                    }
                    GroupBox("Người nhận và tiêu đề") {
                        VStack(alignment: .leading) {
                            TextField("To — email, ngăn cách bằng dấu phẩy", text: $to)
                            DisclosureGroup("Thêm Cc/Bcc") {
                                TextField("Cc (tùy chọn)", text: $cc)
                                TextField("Bcc (tùy chọn)", text: $bcc)
                            }
                            TextField("Tiêu đề", text: $subject)
                            Text("Report được gửi bằng nội dung bên dưới và PDF đính kèm; người nhận không cần quyền Drive để đọc PDF.").font(.caption).foregroundStyle(.secondary)
                            Button("Cập nhật bản xem trước") { prepare() }.disabled(connection.accountKey.isEmpty)
                        }.padding(5).disabled(busy || connection.isConnecting)
                    }
                    if let job { preview(job, pdf: pdf) }
                    if !history.isEmpty {
                        DisclosureGroup("Hộp thư đi của report này") {
                            ForEach(history) { saved in
                                HStack {
                                    Text("\(saved.destination.to.joined(separator: ", ")) · \(saved.state.label)")
                                    Spacer(); Button("Xem") { restore(saved) }.disabled(busy)
                                }
                            }
                        }
                    }
                }.padding(5)
            }
        }.padding(20).frame(minWidth: 840, minHeight: 740)
        .onAppear {
            if to.isEmpty { to = UserDefaults.standard.string(forKey: "google.defaultRecipient") ?? "" }
            if subject.isEmpty {
                subject = "Báo cáo ngày \(DailyReportRenderer.dateLabel(snapshot.report.period.start, zone: snapshot.report.period.timeZone)) — \(snapshot.report.employee.displayName)"
            }
            reload()
            Task { @MainActor in
                await Task.yield()
                if !connection.accountKey.isEmpty && !to.isEmpty { prepare() }
            }
        }
        .onChange(of: [to, cc, bcc, subject, connection.accountKey, connection.clientID]) { _, _ in clearPreview() }
        .sheet(isPresented: $showSchedule) {
            if let job { ReportScheduleSheet(jobID: job.id, channel: .gmail, employeeID: job.employeeID, timeZone: snapshot.report.period.timeZone) }
        }
    }
    private func preview(_ job: GmailOutboxJob, pdf: Data?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.state.label).font(.headline)
            Text("Từ: \(job.destination.from)\nTo: \(job.destination.to.joined(separator: ", "))\nCc: \(job.destination.cc.joined(separator: ", "))\nBcc: \(job.destination.bcc.joined(separator: ", "))\nTiêu đề: \(job.destination.subject)").textSelection(.enabled)
            DisclosureGroup("Nội dung email") { Text(job.previewText).textSelection(.enabled) }
            if let pdf { ReportPDFPreview(data: pdf).frame(height: 330) }
            else { Text("PDF local không còn khả dụng; có thể đã được dọn theo retention. Metadata gửi vẫn được lưu.").font(.caption) }
            Text("Mã tra cứu trong Sent: rfc822msgid:\(job.messageID)").font(.caption).textSelection(.enabled)
            if let receipt = job.gmailMessageID {
                Text("Mã Gmail: \(receipt). Gmail đã nhận yêu cầu; chưa xác nhận người nhận nhận hoặc đọc thư.").font(.caption).textSelection(.enabled)
            }
            if [.prepared, .failed].contains(job.state) {
                if let retry = job.retryNotBefore { Text("Thử lại từ: \(retry.formatted())").font(.caption) }
                Toggle("Tôi duyệt người gửi, To/Cc/Bcc, tiêu đề, nội dung và PDF ở trên", isOn: $approved).disabled(busy)
                Button(busy ? "Đang gửi…" : "Gửi bản đã duyệt") { send() }.buttonStyle(.borderedProminent).disabled(!approved || busy || pdf == nil)
                Button("Đặt lịch cho bản đã duyệt…") { schedule() }.disabled(!approved || busy || pdf == nil)
            }
            if job.state == .uncertain || (job.state == .sending && (job.leaseUntil ?? .distantPast) <= Date()) {
                Text("Mở Gmail của tài khoản trên, tìm mã trong Sent và kiểm tra người nhận/nội dung. Ứng dụng không tự gửi lại yêu cầu chưa rõ kết quả.").font(.callout)
                TextField("Ghi chú đối chiếu thực tế", text: $reconciliationNote)
                Button("Tôi đã thấy đúng email trong Sent") { reconcile(observed: true) }.disabled(busy || reconciliationNote.isEmpty)
                Toggle("Tôi đã kiểm tra Sent, chưa thấy email và chấp nhận nguy cơ gửi trùng nếu thử lại", isOn: $acceptsDuplicateRisk)
                Button("Cho phép chuẩn bị gửi lại, cần duyệt lại") { reconcile(observed: false) }
                    .disabled(busy || reconciliationNote.isEmpty || !acceptsDuplicateRisk)
            }
            if let lastError = job.lastError { Text(lastError).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func connect() {
        busy = true
        Task {
            defer { busy = false }
            do { try await connection.connect(clientSecret: "", enableGmail: true); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    private func prepare() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let credential = try await connection.credential(requiring: [GoogleScopes.gmailSend])
                let destination = try ReportMailDestination(accountKey: credential.accountKey, from: credential.email,
                    to: ReportMailDestination.parseAddresses(to), cc: ReportMailDestination.parseAddresses(cc), bcc: ReportMailDestination.parseAddresses(bcc), subject: subject)
                let prepared = try store.prepare(snapshot: snapshot, destination: destination)
                job = prepared; pdf = try store.pdf(for: prepared); approved = false; reload()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func send() {
        guard let job, approved else { return }
        busy = true; error = nil
        Task {
            defer { busy = false; approved = false; reload() }
            do {
                let credential = try await connection.credential(requiring: [GoogleScopes.gmailSend])
                _ = try store.approve(job.id, employeeID: snapshot.report.employee.employeeID, expectedPayloadHash: job.payloadHash)
                self.job = try await GmailDeliveryService().deliver(jobID: job.id, credential: credential)
            } catch { self.job = try? store.read(job.id); self.error = error.localizedDescription }
        }
    }
    private func schedule() {
        guard let job, approved else { return }
        do {
            self.job = try store.approve(job.id, employeeID: snapshot.report.employee.employeeID, expectedPayloadHash: job.payloadHash)
            showSchedule = true
        } catch { self.error = error.localizedDescription }
    }
    private func reconcile(observed: Bool) {
        guard let job else { return }
        do {
            self.job = try store.reconcile(job.id, employeeID: snapshot.report.employee.employeeID, observedInSent: observed,
                acceptsDuplicateRisk: acceptsDuplicateRisk, note: reconciliationNote)
            approved = false; reconciliationNote = ""; acceptsDuplicateRisk = false; error = nil; reload()
        } catch { self.error = error.localizedDescription }
    }
    private func restore(_ saved: GmailOutboxJob) {
        guard saved.destination.accountKey == connection.accountKey else { error = GoogleServiceError.wrongAccount.localizedDescription; return }
        do { job = saved; pdf = try store.pdf(for: saved); approved = false; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func clearPreview() { job = nil; pdf = nil; approved = false; reconciliationNote = ""; acceptsDuplicateRisk = false }
    private func reload() {
        do { history = try store.all().filter { $0.reportID == snapshot.reportID && $0.revision == snapshot.revision } }
        catch { self.error = error.localizedDescription }
    }
}
