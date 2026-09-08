import SwiftUI
import AppKit
import AgentWatchCore

/// Auto-select the latest observed project and prepare local insights in the background.
struct TaskInsightsView: View {
    var roots: AgentLogRoots = .current
    var queryStore: CoachingQueryStore = .shared
    var bindingStore: TaskBindingStore = .local
    var historyStore: InsightHistoryStore = .shared
    var acceptanceStore: TaskAcceptanceStore = .local
    var teamInbox: TeamReportInbox = .local
    @AppStorage("insights.selectedProject") private var projectPath = ""
    @State private var day = Date()
    @State private var days = 1
    private var selectedRange: Range<Date> {
        let last = ReportTime.range(for: .day(day))
        let first = Calendar.current.date(byAdding: .day, value: -(days - 1), to: last.lowerBound) ?? last.lowerBound
        return first..<last.upperBound
    }
    @State private var historyRevision: Date?
    @State private var snapshot: ContextTelemetrySnapshot?
    @State private var analysis: ContextEfficiencyAnalysis?
    @State private var lifecycle: TaskLifecycleSnapshot?
    @State private var scan: CoachingScanResult?
    @State private var journal: PiTaskJournalResult?
    @State private var error: String?
    @State private var selectedSession = ""
    @State private var taskID = ""
    @State private var runID = ""
    @State private var busy = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Phân tích task và context").font(.title2.bold())
                Text("Task cho biết các phiên agent gắn với công việc nào. Context là dữ liệu agent đã đọc hoặc dùng khi xử lý yêu cầu.")
                    .foregroundStyle(.secondary)
                Text("Chỉ dùng phần này khi cần tìm nguyên nhân đọc lặp hoặc tốn dữ liệu. Báo cáo ngày không cần chọn hay gắn task.")
                    .font(.callout).foregroundStyle(.secondary)
                if busy { ProgressView("Đang tự tổng hợp…") }
                if let lifecycle {
                    Text("Đã ghi nhận \(lifecycle.items.count) task trong dự án đang xem.").font(.headline)
                }
                if let analysis {
                    Text(analysis.loops.isEmpty ? "Chưa thấy chuỗi thao tác lặp đủ bằng chứng trong mẫu." : "Có \(analysis.loops.count) chuỗi thao tác lặp cần xem lại.")
                    Text("Dữ liệu thiếu không đồng nghĩa agent làm việc kém.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                DisclosureGroup("Xem chi tiết và tùy chỉnh nâng cao") {
                TeamReportOverviewView(inbox: teamInbox)
                HStack {
                    Button("Chọn dự án…", action: chooseProject).disabled(busy)
                    DatePicker("Đến ngày", selection: $day, in: ...Date(), displayedComponents: .date).disabled(busy)
                    Picker("Khoảng xem", selection: $days) {
                        Text("1 ngày").tag(1)
                        Text("7 ngày").tag(7)
                        Text("30 ngày").tag(30)
                    }.frame(width: 150).disabled(busy)
                    Button(busy ? "Đang đọc…" : "Đọc dữ liệu", action: { refresh() })
                        .disabled(busy || projectPath.isEmpty).buttonStyle(.borderedProminent)
                    if busy { Button("Dừng") { work?.cancel(); busy = false } }
                }
                Button("Kiểm tra kỹ nguồn dữ liệu") { refresh(strict: true) }.disabled(busy || projectPath.isEmpty)
                Text("Kiểm tra kỹ đọc lại từng file; dùng khi cần đối chiếu dữ liệu thiếu hoặc lỗi. Tra cứu lịch sử vẫn đọc chỉ mục đã lưu.").font(.caption).foregroundStyle(.secondary)
                if !projectPath.isEmpty { Text(projectPath).font(.caption).textSelection(.enabled) }
                if let error { Text(error).foregroundStyle(.red) }
                InsightHistoryView(projectPath: projectPath, revision: historyRevision, store: historyStore, roots: roots, queryStore: queryStore, bindingStore: bindingStore)
                TaskBindingEditor(projectPath: projectPath, store: bindingStore) {
                    snapshot = nil; analysis = nil; lifecycle = nil; scan = nil; journal = nil
                    invalidateHistory()
                }.disabled(busy || projectPath.isEmpty)
                if let scan, let snapshot, let lifecycle {
                    let health = InsightDataHealth.build(scan: scan, telemetry: snapshot, lifecycle: lifecycle, checkedAt: snapshot.capturedAt)
                    GroupBox("Sức khỏe nguồn dữ liệu trên máy") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Kiểm tra lúc \(health.checkedAt.formatted(date: .abbreviated, time: .shortened)) · \(health.partialSessionCount) session có dữ liệu một phần")
                            if !scan.sourceFiles.isEmpty {
                                Text("Đã kiểm kê \(scan.sourceFiles.count) file · \(scan.sourceFiles.reduce(0) { $0 + $1.malformedRecordCount }) dòng JSON lỗi hoặc quá lớn").font(.caption)
                            }
                            ForEach(health.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            ForEach(health.sources) { source in
                                Text("\(source.state.label) · \(source.sessionCount) session").font(.subheadline)
                                Text(source.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                if let timestamp = source.lastObservedEvent {
                                    Text("Sự kiện gần nhất trong mẫu: \(timestamp.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                                }
                                ForEach(source.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text("Telemetry Pi: \(health.telemetryCoverage.label) · \(health.telemetryMalformedCount) dòng lỗi · \(health.telemetryUnsupportedCount) dòng chưa hỗ trợ").font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let lifecycle {
                    GroupBox("Vòng đời task") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(lifecycle.items.count) task · \(lifecycle.unallocatedTokens) token chưa phân bổ · \(lifecycle.unlinkedSessionCount) session chưa liên kết")
                            ForEach(lifecycle.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            ForEach(lifecycle.items) { item in
                                taskRow(item)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let scan, !scan.sessions.isEmpty {
                    DisclosureGroup("Gắn session với task trong khoảng đã chọn") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Session", selection: $selectedSession) {
                                Text("Chọn session").tag("")
                                ForEach(scan.sessions) { session in
                                    Text("\(session.source.vendor.label) · \(session.displayTitle) · \(session.id)").tag(session.auditKey)
                                }
                            }
                            TextField("Task ID", text: $taskID)
                            TextField("Run ID — dùng chung khi nhiều session thuộc cùng lượt làm", text: $runID)
                            Button("Lưu liên kết cho khoảng này", action: saveBinding)
                                .disabled(busy || selectedSession.isEmpty || taskID.isEmpty || runID.isEmpty)
                            Text("Liên kết do anh xác nhận; không đổi log nguồn hoặc xác nhận task đã hoàn thành.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let snapshot, let analysis {
                    GroupBox("Phạm vi dữ liệu") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Đã đọc: \(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(analysis.coverage.label)")
                            Text("\(snapshot.events.count) sự kiện trong mẫu · \(analysis.unassignedEvents) sự kiện trong khoảng chưa gắn task/run")
                            ForEach(Array(analysis.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if analysis.groups.isEmpty {
                        Text("Chưa có nhóm task đủ định danh trong khoảng đã chọn. Dữ liệu thiếu không được tính thành 0 lãng phí.")
                    }
                    ForEach(analysis.groups) { group in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(group.taskID ?? "Task chưa rõ tên").font(.headline)
                                Text("Run: \(group.partition.taskRunID) · Session: \(group.partition.sessionID)")
                                    .font(.caption).textSelection(.enabled)
                                Text("\(group.partition.model) · \(group.partition.thinkingLevel)").font(.caption)
                                metric("Đọc lặp", group.duplicateReads)
                                metric("Output lặp", group.duplicateOutput)
                                metric("Context có bằng chứng được sửa sau khi chọn", group.utilization)
                                metric("Tỷ trọng schema tool trong prefix", group.schemaShare)
                                metric("Retrieval có độ tin cậy thấp", group.lowConfidence)
                                if let score = group.wasteScore {
                                    Text("Điểm lãng phí: \(score)/100 · thấp hơn là tốt hơn")
                                } else {
                                    Text("Chưa đủ bằng chứng để chốt điểm lãng phí").foregroundStyle(.secondary)
                                }
                                DisclosureGroup("Bằng chứng (\(group.evidence.count))") {
                                    LazyVStack(alignment: .leading, spacing: 6) {
                                        ForEach(Array(group.evidence.suffix(100))) { event in evidenceRow(event) }
                                    }
                                    if group.evidence.count > 100 { Text("Hiện 100 sự kiện cuối; mở nguồn để xem toàn bộ mẫu.").font(.caption) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("Các chuỗi cần kiểm tra").font(.headline)
                    if analysis.loops.isEmpty { Text("Chưa thấy chuỗi đủ bằng chứng trong mẫu này.").foregroundStyle(.secondary) }
                    ForEach(analysis.loops) { finding in
                        GroupBox(finding.title) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(finding.toolName) · Run \(finding.partition.taskRunID)")
                                Text("\(finding.firstAt.formatted(date: .omitted, time: .standard)) → \(finding.lastAt.formatted(date: .omitted, time: .standard))")
                                    .font(.caption)
                                Text("Đối chiếu input/output hash và các lần gọi riêng biệt; kiểm tra nguyên nhân trước khi chạy lại.").font(.caption)
                                ForEach(finding.evidence) { event in evidenceRow(event) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else if !busy {
                    Text("Đang tự chuẩn bị dữ liệu dự án gần nhất.").foregroundStyle(.secondary)
                }
                }
            }.padding(20)
        }
        .task(id: projectPath + "|" + String(day.timeIntervalSince1970) + "|" + String(days)) {
            if projectPath.isEmpty {
                let found = await CoachingScan.scan(in: selectedRange, roots: roots, store: queryStore)
                guard !Task.isCancelled else { return }
                if let latest = found.sessions.filter({ $0.projectDisplay.hasPrefix("/") })
                    .max(by: { ($0.lastTimestamp ?? .distantPast) < ($1.lastTimestamp ?? .distantPast) }) {
                    projectPath = latest.projectDisplay
                }
            }
            guard !projectPath.isEmpty else { return }
            refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                if !busy { refresh() }
            }
        }
        .onDisappear { work?.cancel(); busy = false }
    }

    private func taskRow(_ item: TaskLifecycleItem) -> some View {
        DisclosureGroup("\(item.taskID) · \(item.runIDs.count) run · \(item.sessionRefs.count) session · \(item.totalTokens) token") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Model: " + item.modelIDs.joined(separator: ", ")).font(.caption)
                let ledger = UsageLedger(entries: item.ledgerEntries)
                if ledger.costCoverage == .unavailable {
                    Text("Chưa có giá để ước tính chi phí").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Tạm tính phần có giá: " + NSDecimalNumber(decimal: item.estimatedUSD).stringValue + " USD").font(.caption)
                    if ledger.missingCostCount > 0 { Text("\(ledger.missingCostCount) lượt gọi chưa có giá").font(.caption) }
                }
                SessionLineageView(sessions: (scan?.sessions ?? []).filter { item.sessionRefs.contains($0.auditKey) }, before: selectedRange.upperBound)
                    .id(String(describing: snapshot?.capturedAt) + item.sessionRefs.joined(separator: "|"))
                TaskOutcomeView(item: item, sessions: scan?.sessions ?? [], range: selectedRange, links: journal?.links ?? [], bindingStore: bindingStore, store: acceptanceStore)
                    .id(String(describing: snapshot?.capturedAt) + item.runIDs.joined(separator: "|") + item.sessionRefs.joined(separator: "|"))
                ForEach(item.timeline) { entry in
                    Text("\(entry.recordedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.title) · \(entry.taskRunID)").font(.caption)
                    Text(entry.basis).font(.caption2).foregroundStyle(.secondary)
                    if let ref = entry.localRef { Text(ref).font(.caption2).textSelection(.enabled) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }


    private func metric(_ name: String, _ ratio: ObservedRatio) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(ratio.value.map { String(format: "%.1f%%", $0 * 100) } ?? "Chưa có")
            Text(ratio.coverage.label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func evidenceRow(_ event: ContextObservation) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(event.recordedAt.formatted(date: .omitted, time: .standard)) · \(event.event) · \(event.toolName ?? "")")
                Text(event.localRef).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Mở nguồn") {
                let path = event.localRef.components(separatedBy: "#").first ?? ""
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }.font(.caption)
    }

    private func chooseProject() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        picker.prompt = "Chọn dự án"
        if picker.runModal() == .OK, let url = picker.url {
            projectPath = url.path; snapshot = nil; analysis = nil; lifecycle = nil; scan = nil; journal = nil; error = nil
        }
    }

    private func refresh(strict: Bool = false) {
        work?.cancel(); busy = true; error = nil
        let project = URL(fileURLWithPath: projectPath)
        let range = selectedRange
        let roots = roots, bindingStore = bindingStore, queryStore = queryStore
        work = Task {
            let reader = Task.detached(priority: .userInitiated) { () throws -> (ContextTelemetrySnapshot, ContextEfficiencyAnalysis, CoachingScanResult, PiTaskJournalResult, TaskLifecycleSnapshot) in
                let snapshot = PiContextTelemetry.read(project: project, before: range.upperBound)
                let journal = PiTaskJournal.read(project: project, range: range)
                let bindings = try bindingStore.load()
                let scan = await CoachingScan.scan(in: range, roots: roots, captureManifest: strict, store: queryStore)
                let lifecycle = TaskLifecycleBuilder.build(scan: scan, journals: [journal], bindings: bindings, range: range, projectPath: project.path)
                return (snapshot, ContextEfficiencyAnalyzer.analyze(snapshot, range: range), scan, journal, lifecycle)
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await reader.value }, onCancel: { reader.cancel() })
                guard !Task.isCancelled else { return }
                snapshot = result.0; analysis = result.1; scan = result.2; journal = result.3; lifecycle = result.4
                let records = InsightHistoryRecord.collect(scan: result.2, lifecycle: result.4, projectPath: project.path)
                    .filter { range.contains($0.timestamp) }
                let warnings = result.4.warnings + result.2.sourceRoots.filter { !$0.exists || !$0.readable }.map { "Nguồn chưa đọc được: " + $0.path }
                try await historyStore.replace(project: project.path, range: range,
                    records: records, warnings: warnings, capturedAt: result.0.capturedAt)
                if !Task.isCancelled { historyRevision = Date() }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { busy = false }
        }
    }
    private func saveBinding() {
        guard let scan, let session = scan.sessions.first(where: { $0.auditKey == selectedSession }) else { return }
        do {
            let range = selectedRange
            let binding = TaskSessionBinding(projectPath: projectPath, taskID: taskID.trimmingCharacters(in: .whitespacesAndNewlines),
                taskRunID: runID.trimmingCharacters(in: .whitespacesAndNewlines), source: session.source,
                sessionID: session.id, start: range.lowerBound, end: range.upperBound)
            let bindings = try bindingStore.save(binding)
            lifecycle = TaskLifecycleBuilder.build(scan: scan, journals: journal.map { [$0] } ?? [], bindings: bindings, range: range, projectPath: projectPath)
            error = nil
            invalidateHistory()
        } catch { self.error = error.localizedDescription }
    }

    private func invalidateHistory() {
        busy = true
        let project = projectPath
        work = Task {
            do { try await historyStore.invalidate(project: project); historyRevision = Date() }
            catch { self.error = error.localizedDescription }
            busy = false
            if error == nil { refresh() }
        }
    }

}
