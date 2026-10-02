import Foundation
import Darwin

/// Private stdio RPC for the pinned managed runtime. Provider requests do not
/// transit the GUI, so restarting Watch does not interrupt an active stream.
public enum StudioManagedBrokerCommand {
    /// Foreground-only launch preparation. macOS may ask the user to permit
    /// this exact helper after an ad-hoc update; no credential is returned.
    @MainActor public static func authorize(arguments: [String]) -> Int32 {
        guard arguments.count == 2, arguments[0] == "--profile", arguments[1].count == 64,
              arguments[1].allSatisfy({ $0.isHexDigit }) else { return 64 }
        // 67: the imported slot is no longer a saved company key (disconnected);
        // 77: macOS did not release the key. Launchers report them differently.
        do {
            guard let profile = try StudioPreferences(defaults: StudioPreferences.applicationDefaults).profiles().first(where: { $0.id == arguments[1] }),
                  profile.credentialMode == .managed else { return 67 }
            return try StudioKeychainStorage().load(profileID: profile.id, allowInteraction: true) != nil ? 0 : 77
        } catch { return 77 }
    }
    /// The manifest for the runtime, with broker_features: what this broker
    /// accepts beyond the first protocol, so a newer runtime never sends an
    /// older broker a field it refuses.
    static func configValue(_ manifest: StudioManifest) throws -> StudioJSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard case .object(var out) = try JSONDecoder().decode(StudioJSONValue.self, from: encoder.encode(manifest)) else { throw StudioError.invalidResponse }
        // Version 2 reports only to a Studio that lists them.
        out["broker_features"] = .array([.string("process")] + (manifest.processVersions?.contains(2) == true ? [.string("process-v2")] : []))
        return .object(out)
    }
    static func processValue(_ raw: Any?) throws -> [String: StudioJSONValue]? {
        guard let raw else { return nil }
        guard let object = raw as? [String: Any], JSONSerialization.isValidJSONObject(object),
              case .object(let decoded) = try JSONDecoder().decode(StudioJSONValue.self, from: JSONSerialization.data(withJSONObject: object)) else { throw StudioError.invalidResponse }
        return decoded
    }
    @MainActor public static func run(arguments: [String], factory: (@MainActor (String) async throws -> StudioManagedBroker)? = nil) async -> Int32 {
        guard arguments.count == 2, arguments[0] == "--profile", arguments[1].count == 64 else { return 64 }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var broker: StudioManagedBroker?
        func output(_ id: String, _ value: StudioJSONValue?, error: String? = nil) {
            var result: [String: StudioJSONValue] = ["id": .string(id)]
            if let value { result["result"] = value }
            if let error { result["error"] = .string(error) }
            if let data = try? encoder.encode(result) { FileHandle.standardOutput.write(data + Data([10])) }
        }
        func value<T: Encodable>(_ input: T) throws -> StudioJSONValue {
            try JSONDecoder().decode(StudioJSONValue.self, from: encoder.encode(input))
        }
        var buffer = Data()
        while true {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; break }
            if count == 0 { break }
            let chunk = Data(bytes.prefix(count))
            buffer.append(chunk)
            if buffer.count > 65_536 { output("", nil, error: "broker_request_too_large"); break }
            while let lineEnd = buffer.firstIndex(of: 10) {
                let line = buffer[..<lineEnd]; buffer.removeSubrange(...lineEnd)
                var id = ""
                do {
                    guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let requestID = message["id"] as? String, UUID(uuidString: requestID) != nil,
                          let action = message["action"] as? String,
                          Set(message.keys).isSubset(of: ["id", "action", "operation_id", "effort", "task_class", "role", "run_id", "process"]) else { throw StudioError.invalidResponse }
                    id = requestID
                    if broker == nil {
                        guard action == "config" else { throw StudioError.permissionDenied }
                        if let factory { broker = try await factory(arguments[1]) }
                        else {
                            guard let profile = try StudioPreferences(defaults: StudioPreferences.applicationDefaults).profiles().first(where: { $0.id == arguments[1] }), profile.credentialMode == .managed,
                                  let key = try StudioKeychainStorage().load(profileID: profile.id, allowInteraction: false) else { throw StudioError.permissionDenied }
                            broker = try await StudioManagedBroker.enroll(profile: profile, key: key)
                        }
                    }
                    guard let active = broker else { throw StudioError.invalidResponse }
                    switch action {
                    case "config": output(id, try configValue(active.manifest))
                    case "start":
                        guard let raw = message["operation_id"] as? String, let operation = UUID(uuidString: raw),
                              let effort = message["effort"] as? String, let taskClass = message["task_class"] as? String else { throw StudioError.invalidResponse }
                        output(id, try value(await active.start(operation: operation, effort: effort, taskClass: taskClass)))
                    case "child":
                        guard let role = message["role"] as? String else { throw StudioError.invalidResponse }
                        output(id, try value(await active.child(role: role)))
                    case "recover":
                        guard let raw = message["run_id"] as? String, let runID = UUID(uuidString: raw) else { throw StudioError.invalidResponse }
                        output(id, try value(await active.recover(runID: runID)))
                    case "renew":
                        guard let role = message["role"] as? String else { throw StudioError.invalidResponse }
                        output(id, try value(await active.renew(role: role)))
                    case "close":
                        try await active.close(role: message["role"] as? String ?? "", process: try processValue(message["process"])); output(id, .bool(true))
                    default: throw StudioError.permissionDenied
                    }
                } catch let error as StudioError { output(id, nil, error: error.rawValue) }
                catch { output(id, nil, error: "broker_failed") }
            }
        }
        try? await broker?.close()
        return 0
    }
}
