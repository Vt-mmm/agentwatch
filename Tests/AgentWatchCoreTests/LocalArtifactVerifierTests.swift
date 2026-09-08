import XCTest
@testable import AgentWatchCore

final class LocalArtifactVerifierTests: XCTestCase {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testFileHashesActualContentWithProvenance() throws {
        let root = try root()
        try Data("hello".utf8).write(to: root.appendingPathComponent("output.txt"))
        let result = try LocalArtifactVerifier.file(project: root, relativePath: "output.txt")
        XCTAssertEqual(result.kind, .artifactVerified)
        XCTAssertTrue(result.summary.contains("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
        XCTAssertTrue(result.summary.contains("5 byte"))
        XCTAssertTrue(result.localRef.hasSuffix("/output.txt"))
        XCTAssertNotEqual(result.kind, .humanAcceptance)
    }
    func testTraversalSymlinkDirectoryAndSizeRejected() throws {
        let root = try self.root(), outside = try self.root()
        try Data("hello".utf8).write(to: outside.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file-link"), withDestinationURL: outside.appendingPathComponent("outside.txt"))
        for path in ["../outside.txt", outside.path, "link/outside.txt", "file-link", "missing", "./file"] {
            XCTAssertThrowsError(try LocalArtifactVerifier.file(project: root, relativePath: path), path)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try LocalArtifactVerifier.file(project: root, relativePath: "directory"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("large"))
        XCTAssertThrowsError(try LocalArtifactVerifier.file(project: root, relativePath: "large", maxBytes: 4))
    }
    func git(_ root: URL, _ args: [String], input: String = "") throws -> String {
        let process = Process(), out = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.test", "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.test"]
        process.standardOutput = out; process.standardError = FileHandle.nullDevice; process.standardInput = stdin
        try process.run(); try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try stdin.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func testCommitMustExistAndBeCommitRatherThanBlob() throws {
        let root = try root()
        _ = try git(root, ["init", "--template="])
        let tree = try git(root, ["mktree"])
        let commit = try git(root, ["commit-tree", tree, "-m", "Synthetic commit"])
        let result = try LocalArtifactVerifier.commit(project: root, objectID: commit)
        XCTAssertEqual(result.kind, .commitVerified)
        XCTAssertTrue(result.summary.contains(commit))
        XCTAssertThrowsError(try LocalArtifactVerifier.commit(project: root, objectID: tree))
        XCTAssertThrowsError(try LocalArtifactVerifier.commit(project: root, objectID: String(repeating: "0", count: 40)))
        XCTAssertThrowsError(try LocalArtifactVerifier.commit(project: root, objectID: "HEAD"))
        XCTAssertThrowsError(try LocalArtifactVerifier.commit(project: root, objectID: "--help; touch unsafe"))
    }
}
