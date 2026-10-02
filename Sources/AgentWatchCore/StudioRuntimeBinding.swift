import Foundation
import CryptoKit
import Darwin

/// Pins the interpreter as well as the entrypoint. A JS shebang must never
/// choose a different Node in a GUI, login shell or managed HOME.
public struct StudioRuntimeBinding: Codable, Equatable, Sendable {
    public let entrypoint: URL
    public let interpreter: URL?
    public let entrypointSHA256: String
    public let interpreterSHA256: String?
    public var executable: URL { interpreter ?? entrypoint }
    public var prefixArguments: [String] { interpreter == nil ? [] : [entrypoint.path] }

    public static func resolve(entrypoint: URL, node: URL? = nil, nodeCandidates: [URL]? = nil) throws -> Self {
        let entry = entrypoint.resolvingSymlinksInPath().standardizedFileURL
        guard entrypoint.isFileURL, FileManager.default.isExecutableFile(atPath: entry.path),
              (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw StudioCLIError.binaryMissing }
        let handle = try FileHandle(forReadingFrom: entry)
        let header = try handle.read(upToCount: 256) ?? Data(); try handle.close()
        let first = String(decoding: header, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let isNode = first.hasPrefix("#!") && first.split(whereSeparator: { $0 == " " || $0 == "\t" }).contains(where: { $0 == "node" || $0.hasSuffix("/node") })
        if !isNode {
            guard node == nil else { throw StudioCLIError.invalidArguments }
            return try Self(entrypoint: entry, interpreter: nil, entrypointSHA256: digest(entry), interpreterSHA256: nil)
        }
        // Interpreter flags in a shebang require explicit qualification; do not
        // silently drop them or let env resolve an unexpected executable.
        guard ["#!/usr/bin/env node", "#!/usr/bin/node", "#!/usr/local/bin/node", "#!/opt/homebrew/bin/node"].contains(first.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw StudioCLIError.unsupportedVersion }
        let candidates = node.map { [$0] } ?? nodeCandidates ?? defaultNodeCandidates()
        for candidate in candidates {
            guard candidate.isFileURL else { continue }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard !resolved.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
                  FileManager.default.isExecutableFile(atPath: resolved.path), nodeRuns(resolved) else { continue }
            return try Self(entrypoint: entry, interpreter: resolved, entrypointSHA256: digest(entry), interpreterSHA256: digest(resolved))
        }
        throw StudioCLIError.runtimeMissing
    }

    /// Installer and Homebrew locations (Apple Silicon and Intel), then Node
    /// versions from nvm/fnm/asdf/mise/Volta, newest first.
    public static func defaultNodeCandidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/opt/homebrew/opt/node@22/bin/node", "/usr/local/opt/node@22/bin/node"].map { URL(fileURLWithPath: $0) }
            + StudioInstallLocations.versionManagedPrefixes(home: home).map { $0.appendingPathComponent("bin/node") }
    }

    public func validate() throws {
        guard entrypoint.resolvingSymlinksInPath().standardizedFileURL == entrypoint,
              try Self.digest(entrypoint) == entrypointSHA256 else { throw StudioCLIError.runtimeChanged }
        if let interpreter {
            guard interpreter.resolvingSymlinksInPath().standardizedFileURL == interpreter,
                  try Self.digest(interpreter) == interpreterSHA256 else { throw StudioCLIError.runtimeChanged }
        }
    }

    private static func digest(_ path: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: path, options: [.mappedIfSafe])).map { String(format: "%02x", $0) }.joined()
    }

    private static func nodeRuns(_ executable: URL) -> Bool {
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = ["--version"]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = output
        do { try process.run() } catch { return false }
        // A first launch can be slow (Gatekeeper scan, Rosetta, cold disk).
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        defer { try? output.fileHandleForReading.close() }
        guard process.terminationStatus == 0, let data = try? output.fileHandleForReading.read(upToCount: 128),
              let version = String(data: data, encoding: .utf8), version.hasPrefix("v") else { return false }
        let parts = version.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), Int(parts[2]) != nil else { return false }
        return major > 22 || (major == 22 && minor >= 19)
    }
}
