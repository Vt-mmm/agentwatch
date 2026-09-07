import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentWatchCore

struct ReportTeamSettings: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dailyReport.organizationID") private var organizationID = ""
    @AppStorage("dailyReport.employeeID") private var employeeID = ""
    @State private var policy: ReportTeamPolicy?
    @State private var candidatePolicy: ReportTeamPolicy?
    @State private var candidateData: Data?
    @State private var policyConfirmed = false
    @State private var ownerConfirmation = ""
    @State private var schedules: [ReportDeliverySchedule] = []
    @State private var samples: [QuotaSnapshot] = []
    @State private var selectedSample = ""
    @State private var accountLabel = ""
    @State private var validFrom = Date()
    @State private var validUntil = Date().addingTimeInterval(86_400)
    @State private var mappingConfirmed = false
    @State private var mappings: [ReportAccountMapping] = []
    @State private var reconciliations: [ReportReconciliation] = []
    @State private var reconciliationCandidate: ReportReconciliation?
    @State private var retention: ReportRetentionPlan?
    @State private var retentionConfirmed = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Vận hành report nhóm").font(.title2.bold()); Spacer(); Button("Làm mới") { load() }; Button("Đóng") { dismiss() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    policySection
                    scheduleSection
                    mappingSection
                    reconciliationSection
                    retentionSection
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }.padding(5)
            }
        }.padding(20).frame(width: 870, height: 750).onAppear { load() }
    }
    private var policySection: some View {
        GroupBox("Chính sách công ty") {
            VStack(alignment: .leading, spacing: 8) {
                if let policy {
                    Text("\(policy.organizationID) · phiên bản \(policy.revision) · chủ chính sách: \(policy.owner)")
                    Text("Hiệu lực \(policy.effectiveFrom.formatted()) → \(policy.expiresAt.formatted()) · lưu nội dung \(policy.retentionDays) ngày").font(.caption)
                } else { Text("Chưa cài chính sách nhóm. Chỉ gửi thủ công sau duyệt; lịch gửi cần chính sách cho phép.") }
                Text("Bản import local là cấu hình do operator duyệt. Quản trị tập trung có thể cài file do hệ thống sở hữu; UI không thay thế đăng nhập quản trị hoặc MDM.").font(.caption).foregroundStyle(.secondary)
                Text("Google account key hiện tại: \(UserDefaults.standard.string(forKey: "google.accountKey") ?? "Chưa kết nối")").font(.caption).textSelection(.enabled)
                Button("Chọn file chính sách để xem trước…") { importPolicy() }
                if let candidatePolicy {
                    Text("Sắp áp dụng: \(candidatePolicy.organizationID) · r\(candidatePolicy.revision) · owner \(candidatePolicy.owner)")
                    Text("Drive: \(candidatePolicy.allowDrive ? "cho phép" : "tắt") · Gmail: \(candidatePolicy.allowGmail ? "cho phép" : "tắt") · lịch: \(candidatePolicy.allowScheduledDelivery ? "cho phép" : "tắt") · gửi nội dung cho model: \(candidatePolicy.allowNarrativeExport ? "cho phép" : "tắt")")
                    ForEach(candidatePolicy.employees, id: \.employeeID) { entry in
                        Text("\(entry.employeeID):\nTài khoản: \(entry.googleAccountKeys.joined(separator: ", "))\nNgười nhận: \(entry.recipients.joined(separator: ", "))\nThư mục: \(entry.driveFolderIDs.joined(separator: ", "))").font(.caption).textSelection(.enabled)
                    }
                    TextField("Nhập đúng owner chính sách để ghi nhận người duyệt", text: $ownerConfirmation)
                    Toggle("Tôi được giao áp dụng và đã kiểm tra cấu hình trên", isOn: $policyConfirmed)
                    Button("Áp dụng chính sách đã xem") { installPolicy() }.disabled(!policyConfirmed || ownerConfirmation != candidatePolicy.owner)
                }
            }.padding(6)
        }
    }
    private var scheduleSection: some View {
        GroupBox("Lịch và quyền xử lý khi máy offline") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Đặt lịch tại bước xem trước Drive/Gmail cho đúng bản đã duyệt. Ứng dụng xử lý khi đang chạy; không gửi báo cáo mới hay gửi bù quá hạn tự động.").font(.caption)
                ForEach(schedules.sorted { $0.scheduledAt > $1.scheduledAt }) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(item.channel.rawValue) · \(item.employeeID) · \(item.state.rawValue)")
                            Text("\(item.scheduledAt.formatted()) → \(item.expiresAt.formatted()) · \(item.timeZone)").font(.caption)
                            if let note = item.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if [.queued, .needsReview, .missed].contains(item.state) && item.employeeID == employeeID {
                            Button("Hủy lịch") { do { try ReportDeliveryScheduleStore.local.cancel(item.id, employeeID: employeeID); load() } catch { self.error = error.localizedDescription } }
                        }
                    }
                }
                if let schedulerError = ReportDeliveryScheduler.shared.lastError { Text(schedulerError).foregroundStyle(.red) }
            }.padding(6)
        }
    }
    private var mappingSection: some View {
        GroupBox("Ánh xạ quota vào tài khoản provider") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chỉ ánh xạ khi đã kiểm tra tài khoản thực. Cùng tên tài khoản trong cùng tổ chức/provider dùng chung quota; không biến quota thành usage của nhân viên. Pi cần snapshot của provider bên dưới.").font(.caption)
                Picker("Nguồn đã thu", selection: $selectedSample) {
                    Text("Chọn snapshot").tag("")
                    ForEach(samples, id: \.id) { sample in Text("\(sample.provider) · \(sample.source) · \(sample.capturedAt.formatted())").tag(sample.id) }
                }
                TextField("Nhãn tài khoản nội bộ (cùng tài khoản dùng cùng nhãn)", text: $accountLabel)
                DatePicker("Áp dụng từ", selection: $validFrom)
                DatePicker("Đến, không gồm thời điểm này", selection: $validUntil)
                Toggle("Tôi xác nhận nguồn này dùng tài khoản trên trong đúng khoảng thời gian", isOn: $mappingConfirmed)
                Button("Lưu ánh xạ có thời hạn") { saveMapping() }.disabled(!mappingConfirmed || selectedSample.isEmpty || employeeID.isEmpty)
                Text("Đã có \(mappings.count) ánh xạ. Không ghi đè khoảng thời gian đã xác nhận; report đã chốt giữ nguyên số liệu.").font(.caption)
            }.padding(6)
            .onChange(of: [selectedSample, accountLabel]) { _, _ in mappingConfirmed = false }
            .onChange(of: validFrom) { _, _ in mappingConfirmed = false }
            .onChange(of: validUntil) { _, _ in mappingConfirmed = false }
        }
    }
    private var reconciliationSection: some View {
        GroupBox("Đối soát có nguồn và kỳ gốc") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Import record đã chuẩn hóa từ dữ liệu tổ chức được phép dùng. Ứng dụng không đọc admin key hay tự lấy hóa đơn. Không cộng estimate với billed cost hoặc chia ngày UTC theo tỷ lệ.").font(.caption)
                Button("Chọn record đối soát JSON để xem…") { importReconciliation() }
                if let record = reconciliationCandidate {
                    Text("\(record.left.source): \(record.left.value) \(record.left.unit) / \(record.left.basis)\n\(record.right.source): \(record.right.value) \(record.right.unit) / \(record.right.basis)")
                    Text(record.comparability)
                    Text(record.note).font(.caption)
                    Button("Lưu record đã kiểm tra") {
                        do { try ReportReconciliationStore.local.save(record); reconciliationCandidate = nil; load() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                ForEach(reconciliations) { record in
                    Text("\(record.owner) · \(record.recordedAt.formatted()) · \(record.comparability) \(record.difference.map { "Δ=" + NSDecimalNumber(decimal: $0).stringValue } ?? "")").font(.caption)
                }
            }.padding(6)
        }
    }
    private var retentionSection: some View {
        GroupBox("Thời hạn lưu nội dung trên máy") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chỉ dọn snapshot và payload đã quá hạn, giữ nguyên bản nháp, hàng đợi chưa xong, lịch cần xử lý và receipt. Không xóa Google Drive, Gmail hay agent log.").font(.caption)
                Button("Lập danh sách dọn theo chính sách") {
                    do {
                        guard let policy = try ReportTeamPolicyStore.local.load() else { throw GoogleServiceError.permissionDenied }
                        retention = try ReportRetentionService().preview(retentionDays: policy.retentionDays); retentionConfirmed = false
                    } catch { self.error = error.localizedDescription }
                }
                if let retention {
                    Text("\(retention.candidates.count) mục dọn · \(retention.candidates.filter { $0.action == .deleteFile }.reduce(0) { $0 + $1.bytes }) byte file sẽ xóa")
                    DisclosureGroup("Danh sách chính xác") { ForEach(retention.candidates) { Text("\($0.action == .deleteFile ? "Xóa file" : "Xóa nội dung preview, giữ receipt"): \($0.relativePath)").font(.caption).textSelection(.enabled) } }
                    Toggle("Tôi đã xem và đồng ý xóa đúng nội dung local trong danh sách này", isOn: $retentionConfirmed)
                    Button("Xóa các file đã duyệt", role: .destructive) {
                        do {
                            let count = try ReportRetentionService().execute(retention, expectedDigest: retention.digest)
                            self.retention = nil; retentionConfirmed = false; notice = "Đã dọn \(count) mục local. Receipt và hàng đợi được giữ lại."; load()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!retentionConfirmed || retention.candidates.isEmpty)
                }
            }.padding(6)
        }
    }
    private func pickJSON() throws -> Data? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try Data(contentsOf: url)
    }
    private func importPolicy() {
        do { guard let data = try pickJSON() else { return }; candidatePolicy = try ReportTeamPolicyStore.local.decode(data); candidateData = data; policyConfirmed = false; ownerConfirmation = "" }
        catch { self.error = error.localizedDescription }
    }
    private func installPolicy() {
        do {
            guard let candidateData, let candidatePolicy, policyConfirmed else { return }
            try ReportTeamPolicyStore.local.install(candidateData, expectedHash: candidatePolicy.digest, confirmedBy: ownerConfirmation)
            self.candidateData = nil; self.candidatePolicy = nil; policyConfirmed = false; load()
        } catch { self.error = error.localizedDescription }
    }
    private func saveMapping() {
        do {
            guard let sample = samples.first(where: { $0.id == selectedSample }), mappingConfirmed else { return }
            let mapping = try ReportAccountMapping(organizationID: organizationID, provider: sample.provider, source: sample.source,
                sourceAccountKey: sample.accountKey, captureKey: sample.captureKey, accountLabel: accountLabel, confirmedBy: employeeID, validFrom: validFrom, validUntil: validUntil)
            try ReportAccountMappingStore.local.save(mapping); mappingConfirmed = false; load()
        } catch { self.error = error.localizedDescription }
    }
    private func importReconciliation() {
        do {
            guard let data = try pickJSON() else { return }
            let record = try ReportEncoding.decode(ReportReconciliation.self, from: data); try record.validate()
            guard record.organizationID == organizationID else { throw GoogleServiceError.wrongAccount }
            reconciliationCandidate = record
        } catch { self.error = error.localizedDescription }
    }
    private func load() {
        do {
            policy = try ReportTeamPolicyStore.local.load(); schedules = try ReportDeliveryScheduleStore.local.all()
            mappings = try ReportAccountMappingStore.local.all(); reconciliations = try ReportReconciliationStore.local.all()
            var seen: Set<String> = []
            samples = try QuotaSnapshotStore.local.load().filter { seen.insert($0.id).inserted }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
