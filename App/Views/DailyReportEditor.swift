import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentWatchCore

struct DailyReportEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dailyReport.organizationID") private var organization = ""
    @AppStorage("dailyReport.employeeID") private var employeeID = ""
    @AppStorage("dailyReport.displayName") private var displayName = ""
    @AppStorage("dailyReport.timeZone") private var timeZone = "Asia/Ho_Chi_Minh"
    @State var day: Date
    @State private var draft: DailyReportDraft?
    @State private var snapshot: ReportSnapshot?
    @State private var history: [ReportSnapshot] = []
    @State private var journalProjects: [URL] = []
    @State private var busy = false
    @State private var reviewed = false
    @State private var error: String?
    @State private var showPreview = false
    @State private var showRebuildConfirmation = false
    @State private var narrativeJSON = ""
    @State private var driveSnapshot: ReportSnapshot?
    @State private var gmailSnapshot: ReportSnapshot?
    @State private var showTeamSettings = false
    @State private var localPromptText: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Báo cáo công việc ngày").font(.title2.bold())
                Spacer()
                Button("Vận hành nhóm…") { showTeamSettings = true }
                Button("Đóng") { dismiss() }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    profileSection
                    if let draft {
                        HStack {
                            Text("Dữ liệu ngày \(DailyReportRenderer.dateLabel(draft.period.start, zone: draft.period.timeZone))").font(.headline)
                            Spacer()
                            Text(snapshot.map { "Đã lưu phiên bản \($0.revision)" } ?? "Bản nháp").foregroundStyle(.secondary)
                        }
                        TextField("Tổng quan trong ngày (nhân viên bổ sung)", text: textBinding(\.summary), axis: .vertical)
                        ForEach(Array(draft.workItems.enumerated()), id: \.element.id) { index, item in
                            workItemSection(index, item: item)
                        }
                        Button("Thêm công việc thủ công") { addManualItem() }
                        dailyActivitySection
                        TextField("Ghi chú chung", text: textBinding(\.notes), axis: .vertical)
                        DisclosureGroup("Số liệu và phạm vi đã thu") {
                            Text("\(draft.totalTokens) token · \(draft.unallocatedTokens) chưa phân bổ task · \(draft.missingCostCount) dòng chưa có giá")
                            ForEach(draft.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }
                        DisclosureGroup("Gợi ý từ coding agent (tùy chọn)") {
                            Text("Sao chép prompt và bản nội dung đã lọc để nhờ coding agent gợi ý. Dán JSON trả về để kiểm tra; việc gửi dữ liệu đến model do anh/chị chủ động thực hiện.").font(.caption)
                            Button("Sao chép prompt và dữ liệu đã lọc") {
                                do {
                                    if let policy = try ReportTeamPolicyStore.local.load(), !policy.allowNarrativeExport {
                                        throw ReportValidationError.invalid("Chính sách công ty chưa cho phép sao chép nội dung report để gửi model.")
                                    }
                                    let text = ReportNarrative.prompt + "\n\n" + narrativeInput(draft)
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                                } catch { self.error = error.localizedDescription }
                            }
                            TextEditor(text: $narrativeJSON).frame(height: 100).font(.system(.caption, design: .monospaced))
                            Button("Kiểm tra và áp dụng gợi ý") {
                                do { self.draft = try ReportNarrative.apply(Data(narrativeJSON.utf8), to: draft); changed() }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        Divider()
                        Toggle("Tôi đã rà soát nội dung, kết quả và phạm vi dữ liệu của bản này", isOn: $reviewed)
                        HStack {
                            Button("Xem trước bản cho quản lý") { showPreview = true }
                            Button("Chốt phiên bản") { saveSnapshot() }.disabled(!reviewed || busy || snapshot != nil)
                                .buttonStyle(.borderedProminent)
                            if let snapshot { exportMenu(snapshot) }
                        }
                    }
                    if !history.isEmpty {
                        DisclosureGroup("Các phiên bản đã chốt (\(history.count))") {
                            ForEach(history) { saved in
                                HStack {
                                    Text("\(DailyReportRenderer.dateLabel(saved.report.period.start, zone: saved.report.period.timeZone)) · \(saved.report.employee.displayName) · v\(saved.revision)")
                                    Spacer()
                                    Button("Mở") { draft = saved.report; snapshot = saved; reviewed = true }
                                    exportMenu(saved)
                                }
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(22)
            }
        }
        .frame(minWidth: 780, idealWidth: 920, minHeight: 650)
        .onAppear {
            loadHistory()
            do { draft = try DailyReportDraftStore.local.load() }
            catch { self.error = "Không khôi phục được bản nháp: " + error.localizedDescription }
        }
        .task(id: draft) {
            guard let draft, snapshot == nil else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                try DailyReportDraftStore.local.save(draft)
            } catch is CancellationError { }
            catch { self.error = "Không lưu được bản nháp: " + error.localizedDescription }
        }
        .sheet(item: $driveSnapshot) { GoogleDriveDeliveryView(snapshot: $0) }
        .sheet(item: $gmailSnapshot) { GmailDeliveryView(snapshot: $0) }
        .sheet(isPresented: $showTeamSettings) { ReportTeamSettings() }
        .sheet(isPresented: $showPreview) {
            if let draft {
                VStack(alignment: .leading) {
                    HStack { Text("Nội dung gửi quản lý").font(.headline); Spacer(); Button("Đóng") { showPreview = false } }
                    ScrollView { Text(DailyReportRenderer.plainText(draft, revision: snapshot?.revision)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(24).frame(width: 760, height: 650)
            }
        }
        .confirmationDialog("Tạo bản nháp mới sẽ thay phần đang chỉnh. Các phiên bản đã chốt vẫn được lưu.", isPresented: $showRebuildConfirmation) {
            Button("Tạo bản nháp mới") { build() }
        }
    }

    private var profileSection: some View {
        GroupBox("Thông tin nhân viên và ngày báo cáo") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Tổ chức", text: $organization)
                    TextField("Mã nhân viên", text: $employeeID).disabled(SupervisorLockStore.shared.reportIdentity != nil)
                    TextField("Họ tên", text: $displayName).disabled(SupervisorLockStore.shared.reportIdentity != nil)
                }
                if let identity = SupervisorLockStore.shared.reportIdentity {
                    Text("Tên theo key: \(identity.name) · Thư mục report: \(identity.folderName)").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    DatePicker("Ngày", selection: $day, in: ...Date(), displayedComponents: .date)
                    TextField("Múi giờ IANA", text: $timeZone).frame(width: 190)
                    Spacer()
                    Button(busy ? "Đang đọc…" : "Đọc log, tạo bản nháp") {
                        if draft == nil { build() } else { showRebuildConfirmation = true }
                    }.disabled(busy || organization.isEmpty || employeeID.isEmpty || displayName.isEmpty)
                }
                HStack {
                    Button("Chọn dự án có Pi task journal…") { selectProjects() }
                    Text("\(journalProjects.count) dự án được chọn").font(.caption).foregroundStyle(.secondary)
                }
                Text("Có thể xuất bù ngày cũ. Thời điểm chốt, múi giờ và phiên bản được lưu cùng report.").font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
    private func workItemSection(_ index: Int, item: ReportWorkItem) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    TextField("Tên công việc", text: itemText(index, \.title)).font(.headline)
                    Picker("Trạng thái", selection: Binding(get: { draft?.workItems[index].status ?? .unknown }, set: { draft?.workItems[index].status = $0; invalidateItem(index) })) {
                        ForEach(WorkStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.frame(width: 225)
                }
                TextField("Dự án", text: itemText(index, \.project))
                TextField("Kết quả đạt được", text: Binding(get: { draft?.workItems[index].claims.first?.text ?? "" }, set: { setResult(index, text: $0) }), axis: .vertical)
                TextField("Vướng mắc / cần hỗ trợ", text: itemText(index, \.blockers), axis: .vertical)
                TextField("Việc tiếp theo", text: itemText(index, \.nextActions), axis: .vertical)
                Toggle("Tôi xác nhận kết quả và trạng thái đầu việc này", isOn: Binding(get: { draft?.workItems[index].humanConfirmed ?? false }, set: { confirmItem(index, value: $0) }))
                Text("\(item.evidenceIDs.count) bằng chứng cục bộ · \(item.sessionRefs.count) session liên quan").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("Tự nhập thời gian", isOn: Binding(get: { draft?.workItems[index].manualMinutes != nil }, set: {
                        draft?.workItems[index].manualMinutes = $0 ? 0 : nil; invalidateItem(index)
                    }))
                    if item.manualMinutes != nil {
                        Stepper("\(item.manualMinutes ?? 0) phút", value: Binding(get: { draft?.workItems[index].manualMinutes ?? 0 }, set: {
                            draft?.workItems[index].manualMinutes = $0; invalidateItem(index)
                        }), in: 0...1440, step: 5)
                    }
                    Spacer()
                    Menu("Gộp vào đầu việc…") {
                        ForEach(draft?.workItems.filter { $0.id != item.id } ?? []) { target in
                            Button(target.title) {
                                guard let draft else { return }
                                do { self.draft = try ReportReviewActions.merge(item.id, into: target.id, draft: draft); changed() }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }.font(.caption)
                DisclosureGroup("Bằng chứng và link chia sẻ") {
                    ForEach(draft?.evidence.filter { item.evidenceIDs.contains($0.id) } ?? []) { evidence in
                        VStack(alignment: .leading) {
                            Text(evidence.summary).font(.caption).textSelection(.enabled)
                            TextField("Link HTTPS được phép chia sẻ (tùy chọn)", text: Binding(get: {
                                draft?.evidence.first { $0.id == evidence.id }?.shareableURL ?? ""
                            }, set: { value in
                                if let i = draft?.evidence.firstIndex(where: { $0.id == evidence.id }) {
                                    draft?.evidence[i].shareableURL = value.isEmpty ? nil : value; invalidateItem(index)
                                }
                            })).font(.caption)
                        }
                    }
                }
            }.padding(7)
        }
    }
    @ViewBuilder private var dailyActivitySection: some View {
        if let activity = draft?.dailyActivity {
            GroupBox("App/agent trong ngày") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(activity.apps) { app in
                        Text("\(app.name): \(app.promptCount) prompt · \(app.sessionCount) session · \(app.usageRecordCount == 0 ? "chưa ghi nhận usage" : "\(app.tokens) token")")
                    }
                    Text("Chỉ gồm coding app/agent có log. Mốc hoạt động không phải giờ công; Codex chưa tách CLI/Desktop.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Prompt → Task → Phạm vi dự án (\(activity.prompts.count))") {
                Text("Gắn task và ghi lý do đối chiếu yêu cầu dự án. Thư mục hoặc tên phiên không đủ chứng minh prompt đúng phạm vi. Phần chưa rõ có thể giữ Chưa xác định.").font(.caption)
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(activity.prompts.enumerated()), id: \.element.id) { index, prompt in
                        promptSection(index, prompt: prompt)
                    }
                }
            }
        } else {
            Text("Tạo lại bản nháp để bổ sung bảng prompt/task và app trong ngày.").font(.caption)
        }
    }
    private func promptSection(_ index: Int, prompt: ReportPromptActivity) -> some View {
        GroupBox("Prompt \(index + 1) · \(DailyReportRenderer.dateLabel(prompt.timestamp, zone: timeZone, format: "HH:mm:ss")) · \(prompt.app)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dự án từ log: \(prompt.observedProject)").font(.caption)
                if let text = localPromptText[prompt.id] {
                    DisclosureGroup("Xem prompt gốc trên máy (không xuất vào report)") {
                        Text(text).font(.caption).textSelection(.enabled)
                    }
                } else {
                    Text("Prompt gốc ở log cục bộ; tạo lại bản nháp để xem tại đây.").font(.caption)
                }
                TextField("Tóm tắt mục đích để gửi quản lý", text: promptText(index, \.summary), axis: .vertical)
                Picker("Task / đầu việc", selection: Binding(get: { draft?.dailyActivity?.prompts[index].workItemID ?? "" }, set: { value in
                    draft?.dailyActivity?.prompts[index].workItemID = value.isEmpty ? nil : value
                    draft?.dailyActivity?.prompts[index].taskBasis = value.isEmpty ? .unassigned : .humanConfirmed
                    draft?.dailyActivity?.prompts[index].scope = .unknown
                    draft?.dailyActivity?.prompts[index].scopeReason = ""
                    changed()
                })) {
                    Text("Chưa gắn task").tag("")
                    ForEach(draft?.workItems ?? []) { item in Text(item.project + " / " + item.title).tag(item.id) }
                }
                Text(prompt.taskBasis == .taskJournal ? "Task được nối từ nhật ký tại thời điểm gửi prompt." : prompt.taskBasis == .unassigned ? "Chưa xác định task." : "Task do người rà soát lựa chọn.").font(.caption)
                Picker("Phạm vi dự án", selection: Binding(get: { draft?.dailyActivity?.prompts[index].scope ?? .unknown }, set: {
                    draft?.dailyActivity?.prompts[index].scope = $0; changed()
                })) {
                    ForEach(PromptProjectScope.allCases, id: \.self) { Text($0.label).tag($0) }
                }.disabled(prompt.workItemID == nil)
                TextField("Lý do / yêu cầu dự án để đối chiếu", text: promptText(index, \.scopeReason), axis: .vertical)
            }.padding(6)
        }
    }
    private func promptText(_ index: Int, _ key: WritableKeyPath<ReportPromptActivity, String>) -> Binding<String> {
        Binding(get: { draft?.dailyActivity?.prompts[index][keyPath: key] ?? "" }, set: {
            draft?.dailyActivity?.prompts[index][keyPath: key] = ShareText.clean($0); changed()
        })
    }

    private func textBinding(_ key: WritableKeyPath<DailyReportDraft, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" }, set: { draft?[keyPath: key] = $0; changed() })
    }
    private func itemText(_ index: Int, _ key: WritableKeyPath<ReportWorkItem, String>) -> Binding<String> {
        Binding(get: { draft?.workItems[index][keyPath: key] ?? "" }, set: {
            draft?.workItems[index][keyPath: key] = $0
            if key == \.project || key == \.title, let id = draft?.workItems[index].id,
               let count = draft?.dailyActivity?.prompts.count {
                for p in 0..<count where draft?.dailyActivity?.prompts[p].workItemID == id {
                    draft?.dailyActivity?.prompts[p].scope = .unknown
                    draft?.dailyActivity?.prompts[p].scopeReason = ""
                }
            }
            invalidateItem(index)
        })
    }
    private func changed() { reviewed = false; snapshot = nil; error = nil }
    private func invalidateItem(_ index: Int) {
        draft?.workItems[index].humanConfirmed = false
        if let count = draft?.workItems[index].claims.count {
            for i in 0..<count where draft?.workItems[index].claims[i].basis == .humanConfirmed {
                draft?.workItems[index].claims[i].basis = .agentReported
            }
        }
        changed()
    }
    private func confirmItem(_ index: Int, value: Bool) {
        draft?.workItems[index].humanConfirmed = value
        if let count = draft?.workItems[index].claims.count {
            for i in 0..<count { draft?.workItems[index].claims[i].basis = value ? .humanConfirmed : .agentReported }
        }
        changed()
    }
    private func setResult(_ index: Int, text: String) {
        guard var value = draft else { return }
        let evidenceID = "employee-note-" + value.workItems[index].id
        value.evidence.removeAll { $0.id == evidenceID }
        value.evidence.append(ReportEvidence(id: evidenceID, sessionRef: nil, kind: .humanConfirmation,
                                            observedAt: Date(), summary: ShareText.clean(text),
                                            digest: ReportEncoding.digest(Data(text.utf8)), appliesToDay: value.period.start))
        value.workItems[index].evidenceIDs = Array(Set(value.workItems[index].evidenceIDs + [evidenceID])).sorted()
        value.workItems[index].claims = text.isEmpty ? [] : [WorkClaim(text: text, basis: .agentReported, evidenceIDs: [evidenceID])]
        value.workItems[index].humanConfirmed = false
        draft = value; changed()
    }
    private func addManualItem() {
        draft?.workItems.append(ReportWorkItem(id: "manual-" + UUID().uuidString, project: "", title: "Công việc bổ sung")); changed()
    }
    private func build() {
        busy = true; error = nil
        let profile = EmployeeProfile(organizationID: organization, employeeID: employeeID, displayName: displayName, timeZone: timeZone)
        let selected = day, projects = journalProjects
        Task {
            do {
                let period = try DailyReportPeriod(day: selected, timeZone: profile.timeZone, cutoff: Date())
                let scanRange = period.scanRange
                let scan = await CoachingScan.scan(in: scanRange, allowRecentGrowth: false, captureManifest: true)
                let value = try await Task.detached(priority: .utility) {
                    let journals = projects.map { PiTaskJournal.read(project: $0, period: period) }
                    let quota = ReportQuotaGrouping.latest(try QuotaSnapshotStore.local.load().filter { period.contains($0.capturedAt) }, organizationID: profile.organizationID,
                                                           mappings: try ReportAccountMappingStore.local.all())
                    return DailyReportBuilder.build(employee: profile, period: period, scan: scan, journals: journals, quota: quota)
                }.value
                try ReportValidator.validate(value)
                localPromptText = Dictionary(scan.prompts.map { (ReportDailyActivity.promptID($0), $0.text) }, uniquingKeysWith: { first, _ in first })
                draft = value; changed()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func saveSnapshot() {
        guard let draft else { return }
        do { snapshot = try ReportSnapshotStore.local.save(draft, reviewedBy: draft.employee.employeeID); loadHistory() }
        catch { self.error = error.localizedDescription }
    }
    private func loadHistory() {
        do { history = try ReportSnapshotStore.local.history() }
        catch { self.error = error.localizedDescription }
    }
    private func selectProjects() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { journalProjects = panel.urls }
    }
    private func narrativeInput(_ draft: DailyReportDraft) -> String {
        let rows = draft.workItems.map { item in
            ["workItemID": item.id, "title": ShareText.clean(item.title), "evidence": draft.evidence.filter { item.evidenceIDs.contains($0.id) }.map { ["id": $0.id, "summary": ShareText.clean($0.summary)] }] as [String: Any]
        }
        return (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    private func exportMenu(_ saved: ReportSnapshot) -> some View {
        Menu("Xuất / gửi") {
            Button("Upload Google Drive…") { driveSnapshot = saved }
            Button("Gửi report bằng Gmail…") { gmailSnapshot = saved }
            ForEach(["pdf", "html", "md", "csv", "json"], id: \.self) { ext in Button(ext.uppercased()) { export(saved, extension: ext) } }
        }
    }
    private func export(_ saved: ReportSnapshot, extension ext: String) {
        do {
            let report = saved.report
            let bytes: Data
            switch ext {
            case "pdf": bytes = try DailyReportRenderer.pdf(report, revision: saved.revision)
            case "html": bytes = Data(DailyReportRenderer.html(report, revision: saved.revision).utf8)
            case "md": bytes = Data(DailyReportRenderer.markdown(report, revision: saved.revision).utf8)
            case "csv": bytes = Data(DailyReportRenderer.csv(report).utf8)
            default: bytes = try DailyReportRenderer.json(report, revision: saved.revision)
            }
            let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
            panel.nameFieldStringValue = "daily-report-\(DailyReportRenderer.dateLabel(report.period.start, zone: report.period.timeZone, format: "yyyy-MM-dd"))-v\(saved.revision).\(ext)"
            if panel.runModal() == .OK, let url = panel.url { try bytes.write(to: url, options: .atomic) }
        } catch { self.error = error.localizedDescription }
    }
}
