import SwiftUI
import PDFKit
import AgentWatchCore

struct ReportPDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; return view }
    final class Coordinator { var bytes: Data? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.bytes != data else { return }
        context.coordinator.bytes = data
        view.document = PDFDocument(data: data)
    }
}

struct GoogleDriveDeliveryView: View {
    let snapshot: ReportSnapshot
    var onBack: (() -> Void)? = nil
    var onGmail: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var connection = GoogleConnectionStore()
    @State private var folderID = ""
    @State private var binding: ReportFolderBinding?
    @State private var folder: DriveFolderAccess?
    @State private var job: DriveUploadJob?
    @State private var preview: Data?
    @State private var approved = false
    @State private var busy = false
    @State private var error: String?
    @State private var outbox: [DriveUploadJob] = []
    @State private var showGmail = false
    @State private var showSchedule = false
    private let store = DriveUploadStore.local
    private var identity: ReportEnrollmentIdentity? { SupervisorLockStore.shared.reportIdentity }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Upload report lên Google Drive").font(.title2.bold()); Spacer(); Button(onBack == nil ? "Đóng" : "← Quay lại") { if let onBack { onBack() } else { dismiss() } }.disabled(busy || connection.isConnecting) }
            if busy { ProgressView("Đang kiểm tra hoặc xử lý upload…").controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if job?.state == .uploaded { Label("Đã upload report thành công", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Tài khoản Google") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(connection.email.isEmpty ? "Chưa kết nối tài khoản" : connection.email)
                                Spacer()
                                Button(connection.isConnecting ? "Đang đăng nhập…" : "Đăng nhập lại…") { connect() }.disabled(connection.isConnecting || busy || connection.clientID.isEmpty)
                                if !connection.accountKey.isEmpty { Button("Ngắt kết nối trên máy") { disconnect() }.disabled(busy || connection.isConnecting) }
                            }
                            Text("Dùng Gmail cá nhân đã được quản trị viên thêm vào danh sách thử nghiệm.").font(.caption).foregroundStyle(.secondary)
                            if connection.clientID.isEmpty { Text("Mở Kết nối Google để nhập file JSON trước.").font(.caption) }
                        }.padding(5)
                    }
                    GroupBox("Thư mục nhận report") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let binding {
                                Label(binding.folderName, systemImage: "folder.fill").font(.headline)
                                Text("Đã lưu cho hồ sơ " + snapshot.report.employee.displayName).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Chọn folder riêng được quản trị viên chia sẻ cho Gmail của bạn. Không cần quyền folder tổng.").font(.callout)
                                Button("Chọn thư mục của tôi…") { bindExistingFolder(usePicker: true) }
                                    .disabled(busy || connection.isConnecting || connection.accountKey.isEmpty)
                                DisclosureGroup("Dùng link thư mục đã có") {
                                    TextField("Link hoặc ID folder riêng", text: $folderID)
                                    Button("Kiểm tra và lưu thư mục") { bindExistingFolder(usePicker: false) }
                                        .disabled(busy || connection.isConnecting || folderID.isEmpty || connection.accountKey.isEmpty)
                                }.disabled(busy)
                            }
                            Button("Làm mới bản xem trước và trạng thái") { prepare() }.disabled(busy || folderID.isEmpty || connection.accountKey.isEmpty)
                        }.padding(5)
                    }
                    if let job, let folder, let preview {
                        Text("\(job.destination.fileName) · \(job.payloadBytes) byte · phiên bản \(job.revision)").font(.headline)
                        Text("Đích: \(folder.name) · \(connection.email)")
                        DisclosureGroup("Quyền hiện có của thư mục (\(folder.permissions.count))") {
                            ForEach(folder.permissions, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        }
                        Text("File có thể kế thừa quyền thư mục. Thao tác upload không tự thêm người nhận hay tạo quyền công khai.").font(.caption).foregroundStyle(.secondary)
                        ReportPDFPreview(data: preview).frame(height: 370)
                        if let retry = job.retryNotBefore { Text("Có thể thử lại từ \(retry.formatted(date: .omitted, time: .standard))").font(.caption) }
                        if job.state != .uploaded {
                            Toggle("Tôi duyệt đúng bản PDF, tài khoản, thư mục và quyền hiển thị ở trên", isOn: $approved)
                            Button(busy ? "Đang xử lý…" : (job.fileID == nil ? "Upload bản đã duyệt" : "Đối chiếu và tiếp tục upload")) { upload() }
                                .buttonStyle(.borderedProminent).disabled(!approved || busy)
                            Button("Đặt lịch cho bản đã duyệt…") { schedule() }.disabled(!approved || busy)
                        }
                        if let link = job.webViewLink, let url = URL(string: link), job.state == .uploaded {
                            Link("Mở report đã upload", destination: url)
                            Button("Tiếp tục gửi report qua Gmail…") { if let onGmail { onGmail() } else { showGmail = true } }
                            Text("Gmail có bước duyệt riêng và gửi PDF đính kèm. Lỗi Gmail không upload lại bản Drive.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !outbox.isEmpty {
                        DisclosureGroup("Lịch sử/hàng đợi của report này") {
                            ForEach(outbox) { saved in
                                HStack {
                                    Text("\(saved.destination.fileName) · \(saved.state.rawValue)")
                                    Spacer()
                                    if saved.state == .uploaded, let link = saved.webViewLink, let url = URL(string: link) { Link("Mở bản Drive", destination: url) }
                                    Button("Khôi phục") { restore(saved) }.disabled(busy)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(22).frame(width: 850, height: 760)
         .onAppear {
            loadBinding(); reload()
            Task { @MainActor in
                await Task.yield()
                if !connection.accountKey.isEmpty && !folderID.isEmpty { prepare() }
            }
        }
        .onChange(of: folderID) { _, _ in approved = false; job = nil; preview = nil; folder = nil }
        .onChange(of: connection.accountKey) { _, _ in approved = false; job = nil; preview = nil; folder = nil; loadBinding() }
        .onChange(of: connection.clientID) { _, _ in approved = false; job = nil; preview = nil; folder = nil }
        .sheet(isPresented: $showGmail) { GmailDeliveryView(snapshot: snapshot) }
        .sheet(isPresented: $showSchedule) {
            if let job { ReportScheduleSheet(jobID: job.id, channel: .drive, employeeID: job.employeeID, timeZone: snapshot.report.period.timeZone) }
        }
    }
    private func connect() {
        Task { do { try await connection.connect(clientSecret: "", enableGmail: true); error = nil }
               catch { self.error = error.localizedDescription } }
    }
    private func disconnect() {
        do { try connection.disconnectLocally(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func prepare() {
        busy = true; error = nil; approved = false
        Task {
            defer { busy = false }
            do {
                let credential = try await connection.credential(requiring: [GoogleScopes.driveFile])
                let access = try await DriveAPI().folder(folderID, credential: credential)
                if let identity {
                    guard identity.employeeID == snapshot.report.employee.employeeID,
                          let saved = try ReportFolderBindingStore.local.read(organizationID: snapshot.report.employee.organizationID, employeeID: identity.employeeID, accountKey: credential.accountKey),
                          saved.folderID == access.id else { throw ReportValidationError.invalid("Cần gắn đúng thư mục cho key của report trước khi upload.") }
                }
                let name = "daily-report-\(DailyReportRenderer.dateLabel(snapshot.report.period.start, zone: snapshot.report.period.timeZone, format: "yyyy-MM-dd"))-v\(snapshot.revision).pdf"
                let destination = DriveDestination(accountKey: credential.accountKey, folderID: access.id, fileName: name)
                let prepared = try store.prepare(snapshot: snapshot, destination: destination, payload: DailyReportRenderer.pdf(snapshot.report, revision: snapshot.revision))
                folder = access; job = prepared; preview = try store.payload(for: prepared); reload()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func upload() {
        guard let job, let folder, approved else { return }
        busy = true; error = nil
        Task {
            defer { busy = false; reload() }
            do {
                let credential = try await connection.credential(requiring: [GoogleScopes.driveFile])
                guard credential.accountKey == job.destination.accountKey else { throw GoogleServiceError.wrongAccount }
                _ = try store.approve(jobID: job.id, approver: snapshot.report.employee.employeeID,
                                      folderPermissionHash: folder.permissionHash, expectedPayloadHash: job.payloadHash)
                self.job = try await DriveDeliveryService().deliver(jobID: job.id, credential: credential)
            } catch {
                self.job = try? store.read(job.id); self.error = error.localizedDescription
            }
        }
    }
    private func schedule() {
        guard let job, let folder, approved else { return }
        do {
            self.job = try store.approve(jobID: job.id, approver: snapshot.report.employee.employeeID,
                                         folderPermissionHash: folder.permissionHash, expectedPayloadHash: job.payloadHash)
            showSchedule = true
        } catch { self.error = error.localizedDescription }
    }
    private func reload() {
        do { outbox = try store.all().filter { $0.reportID == snapshot.reportID && $0.revision == snapshot.revision } }
        catch { self.error = error.localizedDescription }
    }
    private func loadBinding() {
        binding = nil; folderID = ""
        if let identity {
            do {
                binding = try ReportFolderBindingStore.local.read(organizationID: snapshot.report.employee.organizationID, employeeID: identity.employeeID, accountKey: connection.accountKey)
                folderID = binding?.folderID ?? ""
            } catch { self.error = error.localizedDescription }
        } else { folderID = UserDefaults.standard.string(forKey: "google.driveFolderID") ?? "" }
    }
    private func bindExistingFolder(usePicker: Bool) {
        guard let identity, identity.employeeID == snapshot.report.employee.employeeID else {
            error = "Nhập đúng key của report trước khi chọn thư mục."; return
        }
        busy = true; approved = false; job = nil; preview = nil; error = nil
        Task {
            do {
                let expectedID = folderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try GoogleDesktopClientFile.folderID(folderID)
                var selectedID = expectedID
                if usePicker {
                    let picked = try await connection.pickFolder()
                    if let expectedID, picked.id != expectedID { throw ReportValidationError.invalid("Thư mục vừa chọn khác link đã nhập.") }
                    selectedID = picked.id
                }
                guard let selectedID else { throw ReportValidationError.invalid("Chọn thư mục riêng của bạn trước.") }
                let credential = try await connection.credential(requiring: [GoogleScopes.driveFile])
                binding = try await ReportFolderBindingService().bind(folderID: selectedID, organizationID: snapshot.report.employee.organizationID,
                    identity: identity, credential: credential, timeZone: snapshot.report.period.timeZone)
                folderID = selectedID
                busy = false
                await Task.yield()
                prepare()
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }
    private func restore(_ saved: DriveUploadJob) {
        guard saved.destination.accountKey == connection.accountKey else { error = GoogleServiceError.wrongAccount.localizedDescription; return }
        folderID = saved.destination.folderID
        // Re-read folder permissions and use the durable PDF bytes before asking
        // for a fresh approval. No upload occurs from this history button.
        prepare()
    }
}
