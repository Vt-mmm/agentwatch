import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentWatchCore

struct GoogleSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var connection = GoogleConnectionStore()
    @AppStorage("google.defaultRecipient") private var recipient = ""
    @State private var status = ""
    @State private var error: String?
    @State private var memberFolder = ""
    @State private var memberBusy = false
    @State private var memberStatus = ""
    @State private var hasBinding = false
    @State private var showAdvanced = false
    @State private var operation: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Kết nối Google cho report").font(.title2.bold())
                Spacer()
                Button("Đóng") { dismiss() }.disabled(connection.isConnecting || memberBusy)
            }
            Text("Nhập JSON → đăng nhập Gmail của bạn → chọn thư mục riêng. App lưu lại cho những lần gửi sau.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("1. Kết nối tài khoản") {
                        VStack(alignment: .leading, spacing: 10) {
                            if connection.email.isEmpty {
                                Text("Chưa đăng nhập Google")
                            } else {
                                Label(connection.email, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("Đã lưu kết nối trên máy. Không cần nhập lại JSON mỗi lần gửi.").font(.caption).foregroundStyle(.secondary)
                            }
                            if connection.clientID.isEmpty {
                                Text("Chọn file JSON do quản trị viên gửi cho bạn.").font(.caption)
                                Button("Nhập file JSON…") { importFile() }.disabled(connection.isConnecting || memberBusy)
                            }
                            Button(connection.isConnecting ? "Đang chờ Google…" : (connection.email.isEmpty ? "Đăng nhập Google…" : "Đăng nhập lại…")) { connect() }
                                .disabled(connection.isConnecting || memberBusy || connection.clientID.isEmpty)
                            if connection.isConnecting { Button("Hủy") { operation?.cancel() } }
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("2. Nơi nhận report") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Email nhận report").font(.caption).foregroundStyle(.secondary)
                            TextField("Email sếp", text: $recipient)
                            Divider()
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Thư mục Drive của bạn").font(.headline)
                                    Text(memberStatus.isEmpty ? "Chưa gắn thư mục với key" : memberStatus).foregroundStyle(hasBinding ? Color.green : Color.secondary)
                                }
                                Spacer()
                                if !hasBinding {
                                    Button("Chọn thư mục của tôi…") { bindMember(usePicker: true) }
                                        .disabled(connection.accountKey.isEmpty || connection.isConnecting || memberBusy)
                                }
                            }
                            Text(hasBinding ? "Những lần upload sau sẽ tự dùng đúng thư mục đã gắn. Không tạo thêm thư mục." : "Mở thư mục riêng được quản trị viên chia sẻ, chọn và bấm Chèn trên Google. Không cần chọn folder tổng.").font(.caption).foregroundStyle(.secondary)
                        }.padding(6).disabled(memberBusy)
                    }
                    DisclosureGroup("Cấu hình nâng cao dành cho quản trị viên", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("OAuth client: " + (connection.clientID.isEmpty ? "Chưa cấu hình" : connection.clientID)).font(.caption).textSelection(.enabled)
                            Button("Thay file cấu hình Google (.json)…") { importFile() }
                            TextField("Email Google dự kiến đăng nhập", text: $connection.expectedEmail)
                            TextField("Link hoặc ID folder nhân viên (tùy chọn)", text: $memberFolder).disabled(hasBinding)
                            if !hasBinding {
                                Button("Kiểm tra và gắn folder từ link đã nhập") { bindMember(usePicker: false) }.disabled(memberFolder.isEmpty || connection.accountKey.isEmpty)
                            } else {
                                Button("Cấp lại quyền thư mục đã lưu…") { bindMember(usePicker: true) }
                            }
                            Text("Google Cloud cần bật Drive API, Gmail API và Google Picker API; thêm tài khoản vào Test users khi đang Testing.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8).disabled(connection.isConnecting || memberBusy)
                    }
                }
            }
            if memberBusy { ProgressView("Đang kiểm tra thư mục…").controlSize(.small) }
            if !status.isEmpty { Text(status).font(.caption) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(24).frame(width: 740, height: 680)
        .task(id: connection.accountKey) { await loadSavedSetup() }
    }
    private func connect() {
        error = nil; status = ""
        operation = Task {
            do { try await connection.connect(clientSecret: "", enableGmail: true); status = "Đã kết nối " + connection.email; error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    private func loadSavedSetup() async {
        hasBinding = false; memberStatus = ""
        memberFolder = UserDefaults.standard.string(forKey: "google.memberFolder.suggested") ?? ""
        guard !connection.accountKey.isEmpty, let identity = SupervisorLockStore.shared.reportIdentity else { return }
        do {
            if let binding = try ReportFolderBindingStore.local.read(organizationID: organization, employeeID: identity.employeeID, accountKey: connection.accountKey) {
                memberFolder = binding.folderID; memberStatus = binding.folderName; hasBinding = true
            }
        } catch { self.error = error.localizedDescription }
    }
    private var organization: String {
        let value = UserDefaults.standard.string(forKey: "dailyReport.organizationID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Chưa cấu hình tổ chức" : value
    }
    private func bindMember(usePicker: Bool) {
        guard let identity = SupervisorLockStore.shared.reportIdentity else { error = "Nhập key của máy trước khi gắn thư mục."; return }
        memberBusy = true; error = nil
        operation = Task {
            defer { memberBusy = false }
            do {
                var selectedID = memberFolder.isEmpty ? nil : try GoogleDesktopClientFile.folderID(memberFolder)
                let expected = selectedID
                if usePicker {
                    let picked = try await connection.pickFolder()
                    if let expected, picked.id != expected { throw ReportValidationError.invalid("Folder nhân viên vừa chọn khác link đã điền.") }
                    selectedID = picked.id
                }
                guard let selectedID else { throw ReportValidationError.invalid("Chọn thư mục riêng của bạn trước.") }
                let credential = try await connection.credential(requiring: [GoogleScopes.driveFile])
                let zone = UserDefaults.standard.string(forKey: "dailyReport.timeZone") ?? "Asia/Ho_Chi_Minh"
                let binding = try await ReportFolderBindingService().bind(folderID: selectedID, organizationID: organization,
                    identity: identity, credential: credential, timeZone: zone)
                memberFolder = binding.folderID; memberStatus = binding.folderName; hasBinding = true
                UserDefaults.standard.removeObject(forKey: "google.memberFolder.suggested")
                error = nil
            } catch { self.error = error.localizedDescription + (usePicker ? "" : " Nếu chưa cấp quyền, bấm Chọn thư mục của tôi.") }
        }
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try connection.importClient(from: url); status = "Đã nhập file JSON. Tiếp theo, đăng nhập Google bằng Gmail của bạn."; error = nil }
        catch { self.error = "Không nhập được cấu hình Desktop. " + error.localizedDescription }
    }
}
