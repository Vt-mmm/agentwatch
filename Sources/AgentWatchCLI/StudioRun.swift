import Foundation
import AgentWatchCore

struct StudioRunCommand {
    let arguments: [String]
    @MainActor func run() async -> Int32 {
        if arguments.contains("--help") || arguments.isEmpty {
            print("""
            agentwatch run claude|codex --model ID [--project PATH] [--binary PATH]
                                       [--resume UUID] [--print TEXT] [--check]

            Kết nối Studio bằng key nhân viên trong app Mac trước khi chạy.
            --check chỉ kiểm tra kết nối/CLI/profile; không gửi inference.
            Không nhận key hoặc tham số cấu hình CLI tùy ý trên dòng lệnh.
            Profile công ty giữ HOME/config riêng; dùng đúng phiên bản CLI đã kiểm chứng.
            """)
            return 0
        }
        do {
            guard let provider = StudioCLIProvider(rawValue: arguments[0]) else { throw StudioCLIError.invalidArguments }
            var values: [String: String] = [:], check = false, index = 1
            while index < arguments.count {
                let option = arguments[index]
                if option == "--check" { guard !check else { throw StudioCLIError.invalidArguments }; check = true; index += 1; continue }
                guard ["--model", "--project", "--binary", "--resume", "--print"].contains(option), values[option] == nil, index + 1 < arguments.count else { throw StudioCLIError.invalidArguments }
                values[option] = arguments[index + 1]; index += 2
            }
            guard let modelID = values["--model"], let defaults = UserDefaults(suiteName: "com.vtamm.claudewatch.ClaudeWatchMac"),
                  let connection = try StudioPreferences(defaults: defaults).load(),
                  let key = try StudioKeychainStorage().load(profileID: connection.id) else { throw StudioError.invalidKey }
            let identity = try await StudioClient().connect(origin: connection.origin, key: key)
            guard connection.origin.profileID(orgID: identity.identity.orgID, ownerID: identity.identity.user.id) == connection.id else { throw StudioError.identityChanged }
            guard case .available(let models) = identity.models, let model = models.first(where: { $0.id == modelID && $0.ownedBy == provider.rawValue }) else { throw StudioError.permissionDenied }
            let executable = try StudioCLIExecutable.resolve(provider, explicit: values["--binary"].map { URL(fileURLWithPath: $0) })
            let profile = try StudioCLIProfiles.prepare(connection: connection, provider: provider)
            let resume = values["--resume"].flatMap(UUID.init(uuidString:))
            if values["--resume"] != nil && resume == nil { throw StudioCLIError.invalidArguments }
            let plan = try StudioCLILaunchPlan(executable: executable, profile: profile, project: URL(fileURLWithPath: values["--project"] ?? FileManager.default.currentDirectoryPath), model: model, resumeID: resume, prompt: values["--print"])
            try await StudioCLIPreflight.verify(plan)
            if check { print("Đã kiểm tra \(provider.rawValue) · \(provider.qualifiedVersion) · model \(model.id) · chưa gửi inference."); return 0 }
            try plan.execute(key: key)
        } catch {
            let message = (error as? StudioError)?.localizedDescription ?? (error as? StudioCLIError)?.localizedDescription ?? "Không chuẩn bị được profile CLI Studio."
            FileHandle.standardError.write(Data((message + "\n").utf8)); return 1
        }
    }
}
