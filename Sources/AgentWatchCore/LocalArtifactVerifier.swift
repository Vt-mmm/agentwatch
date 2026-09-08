import Foundation
import CryptoKit
import Darwin

public enum LocalArtifactVerifier {
    /// Descriptor-relative traversal prevents a symlink swap from escaping the
    /// selected root. Only ordinary files are hashed, with bounded memory/size.
    public static func file(project: URL, relativePath: String, maxBytes: Int = 64 * 1024 * 1024,
                            now: Date = Date()) throws -> TaskOutcomeEvidence {
        try inspect(project: project, relativePath: relativePath, maxBytes: maxBytes, now: now, capture: false).0
    }
    public static func testReport(project: URL, relativePath: String, now: Date = Date()) throws -> TaskOutcomeEvidence {
        let (file, data) = try inspect(project: project, relativePath: relativePath, maxBytes: 4 * 1024 * 1024, now: now, capture: true)
        let summary = try JUnitEvidence.parse(data)
        return TaskOutcomeEvidence(id: UUID().uuidString, kind: .testReportObserved, timestamp: now, activityStartedAt: now,
            sessionRef: "local-operator", summary: "JUnit: \(summary.tests) testcase · \(summary.failures) thất bại · \(summary.errors) lỗi · \(summary.skipped) bỏ qua.\n" + file.summary,
            localRef: file.localRef, caveat: "Đọc từ báo cáo được chọn và kiểm tra tổng số; không chứng minh báo cáo thuộc lần chạy mới nhất hoặc task đã được nghiệm thu.")
    }
    private static func inspect(project: URL, relativePath: String, maxBytes: Int, now: Date, capture: Bool) throws -> (TaskOutcomeEvidence, Data) {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), maxBytes >= 0 else {
            throw ReportValidationError.invalid("Cần đường dẫn file tương đối nằm trong dự án.")
        }
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw ReportValidationError.invalid("Không mở được thư mục dự án.") }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw ReportValidationError.invalid("Thư mục không tồn tại hoặc đi qua symlink.") }
            close(directory); directory = next
        }
        let descriptor = openat(directory, String(parts.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ReportValidationError.invalid("File không tồn tại, không đọc được hoặc là symlink.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maxBytes else {
            throw ReportValidationError.invalid("Chỉ xác minh file thường trong giới hạn dung lượng.")
        }
        var hash = SHA256(), count = 0
        var captured = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            count += chunk.count
            guard count <= maxBytes else { throw ReportValidationError.invalid("File tăng vượt giới hạn khi đọc.") }
            hash.update(data: chunk)
            if capture { captured.append(chunk) }
        }
        var after = stat(), named = stat()
        guard fstat(descriptor, &after) == 0,
              fstatat(directory, String(parts.last!), &named, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, after.st_size == count,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              named.st_dev == after.st_dev, named.st_ino == after.st_ino else {
            throw ReportValidationError.invalid("File đã thay đổi khi kiểm tra; cần đọc lại.")
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return (TaskOutcomeEvidence(id: UUID().uuidString, kind: .artifactVerified, timestamp: now, activityStartedAt: now,
            sessionRef: "local-operator", summary: "\(relativePath) · \(count) byte · SHA-256 \(digest)",
            localRef: root.appendingPathComponent(relativePath).path,
            caveat: "Xác minh nội dung file hiện tại; không chứng minh ai đã tạo file, nội dung trước đây hoặc task hoàn thành."), captured)
    }

    /// Exact object ID only, passed as an argument (never shell text). No fetch,
    /// hooks, checkout or provider write; replacement objects are disabled.
    public static func commit(project: URL, objectID: String, now: Date = Date()) throws -> TaskOutcomeEvidence {
        guard objectID.range(of: "^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$", options: .regularExpression) != nil else {
            throw ReportValidationError.invalid("Nhập đầy đủ mã commit gồm 40 hoặc 64 ký tự hex.")
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-C", project.path, "cat-file", "-t", objectID]
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1", "GIT_ALLOW_PROTOCOL": ""]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            throw ReportValidationError.invalid("Dừng kiểm tra commit vì quá thời gian hoặc đã hủy.")
        }
        let data = try output.fileHandleForReading.read(upToCount: 128) ?? Data()
        guard process.terminationStatus == 0, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "commit" else {
            throw ReportValidationError.invalid("Không tìm thấy đối tượng commit này trong kho Git cục bộ.")
        }
        return TaskOutcomeEvidence(id: UUID().uuidString, kind: .commitVerified, timestamp: now, activityStartedAt: now,
            sessionRef: "local-operator", summary: "Commit tồn tại trong Git cục bộ: " + objectID.lowercased(),
            localRef: project.path + "#commit=" + objectID.lowercased(),
            caveat: "Chỉ xác nhận đối tượng commit tồn tại; chưa chứng minh thuộc HEAD, đã push, test pass hoặc được nghiệm thu.")
    }
}
