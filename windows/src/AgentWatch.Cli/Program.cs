using System.Text;
using AgentWatch;

// agentwatch.exe: what Piagent (in WSL) and the coding CLIs run, and the same
// connection steps the app offers, for a terminal.
var utf8 = new UTF8Encoding(false);
// A member's console reads bytes in its own code page, which showed the
// Vietnamese messages garbled; pipes (the broker, setup.ps1) get UTF-8 anyway.
if (!Console.IsOutputRedirected || !Console.IsErrorRedirected) Console.OutputEncoding = utf8;
var stdout = new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = true };
var stderr = new StreamWriter(Console.OpenStandardError(), utf8) { AutoFlush = true };
var profiles = new StudioProfileStore();
var keys = new StudioKeyStore();
var rest = args.Skip(1).ToArray();

try
{
    switch (args.FirstOrDefault())
    {
        case "managed-broker":
            return await StudioCommands.BrokerAsync(rest, new StreamReader(Console.OpenStandardInput(), utf8), stdout, StudioCommands.Enroll(profiles, keys));
        case "managed-authorize":
            return StudioCommands.Authorize(rest, profiles, keys);
        case "credential":
            return StudioCommands.Credential(rest, profiles, keys, stdout, stderr);
        case "connect" when rest.Length == 1:
        {
            // "-" reads the code from standard input, where no other process can list it.
            var code = rest[0] == "-" ? (Console.In.ReadLine() ?? "").Trim() : rest[0];
            var (profile, connection) = await new StudioConnector(profiles, keys).ConnectAsync(code);
            stdout.WriteLine($"Đã kết nối {connection.Identity.User.DisplayName} ({(profile.CredentialMode == StudioCredentialMode.managed ? "key công ty" : "key cá nhân")}) với {profile.Origin}.");
            if (profile.CredentialMode == StudioCredentialMode.managed) stdout.WriteLine("Chạy `agentwatch bind-wsl` để Piagent trong WSL dùng key này.");
            return 0;
        }
        case "status":
        {
            var active = profiles.Active();
            if (profiles.Profiles().Count == 0) { stdout.WriteLine("Chưa kết nối Studio. Chạy `agentwatch connect \"<mã kết nối>\"`."); return 0; }
            foreach (var profile in profiles.Profiles())
                stdout.WriteLine($"{(profile.Id == active?.Id ? "*" : " ")} {profile.Origin} · {profile.CredentialMode} · {profile.Id[..12]}");
            return 0;
        }
        case "disconnect" when rest.Length == 0 || (rest.Length == 2 && rest[0] == "--profile"):
        {
            var target = rest.Length == 2 && rest[0] == "--profile" ? profiles.Find(rest[1]) : profiles.Active();
            if (target is null) { stderr.WriteLine("Không có kết nối nào để ngắt."); return 1; }
            new StudioConnector(profiles, keys).Disconnect(target.Id);
            stdout.WriteLine("Đã ngắt kết nối và xoá key khỏi máy này.");
            return 0;
        }
        case "bind-wsl" when rest.Length == 0 || (rest.Length == 2 && rest[0] == "--distro" && !string.IsNullOrWhiteSpace(rest[1])):
        {
            if (profiles.Active() is not { CredentialMode: StudioCredentialMode.managed } profile || keys.Load(profile.Id) is not { } key)
            { stderr.WriteLine("Cần kết nối bằng key công ty trước (agentwatch connect)."); return 1; }
            var manifest = await new StudioClient().ConfigurationAsync(profile.StudioOrigin, key);
            var distro = rest.Length == 2 && rest[0] == "--distro" ? rest[1] : null;
            var result = await PiagentWslBinding.BindAsync(profile, manifest, Environment.ProcessPath!, new WslExe(), distro);
            PiagentWslBinding.Remember(result.Distro);
            stdout.WriteLine($"Piagent trong WSL ({result.Distro}) đã dùng được key công ty: {result.File}");
            stdout.WriteLine("Trong WSL, chạy `piagent dashboard` hoặc `piagent studio --project <folder>`.");
            return 0;
        }
        case "check-wsl" when rest.Length == 0 || (rest.Length == 2 && rest[0] == "--distro" && !string.IsNullOrWhiteSpace(rest[1])):
        {
            // What bind-wsl would read, without a key or a write: for support.
            var distro = rest.Length == 2 && rest[0] == "--distro" ? rest[1] : null;
            var runtime = await PiagentWslBinding.InspectAsync(new WslExe(), distro);
            stdout.WriteLine($"WSL: {runtime.Distro} · user {runtime.User} · {runtime.Home}");
            stdout.WriteLine($"Piagent: {runtime.Entrypoint}");
            stdout.WriteLine($"Node: {runtime.Node}");
            stdout.WriteLine($"Pi: {runtime.PiVersion}");
            if (runtime.User == "root") { stderr.WriteLine("Ubuntu đang mở bằng root: chạy lại lệnh cài, hoặc đặt user mặc định (wsl --manage <bản WSL> --set-default-user <user>)."); return 1; }
            stdout.WriteLine("Sẵn sàng nối với key công ty (agentwatch bind-wsl).");
            return 0;
        }
        case "--version":
            stdout.WriteLine(StudioClient.UserAgent);
            return 0;
        default:
            stderr.WriteLine("agentwatch connect \"<mã kết nối>\"|- | status | disconnect | bind-wsl [--distro <tên>] | check-wsl [--distro <tên>] | credential --profile <id> | managed-broker --profile <id> | managed-authorize --profile <id>");
            return 64;
    }
}
catch (StudioException error) { stderr.WriteLine(StudioException.Describe(error.Code)); return 1; }
catch (InvalidOperationException error) when (error.Message.StartsWith("wsl-", StringComparison.Ordinal))
{
    stderr.WriteLine(error.Message switch
    {
        "wsl-runtime-unreadable" or "wsl-runtime-invalid" => "Chưa thấy Piagent trong WSL. Trong WSL, cài Piagent (npm install -g @piagent/platform) rồi chạy `piagent --help` một lần.",
        "wsl-runtime-unsupported" => "Piagent hoặc Pi trong WSL chưa đúng bản (cần Pi 0.87.1). Chạy `piagent-update` trong WSL.",
        _ => "Không chạy được lệnh trong WSL" + (error is WslCommandException failed ? $" ({failed.Detail})" : "") + ". Kiểm tra WSL đã cài (wsl --install), có một bản Ubuntu, và Ubuntu mở bằng user của bạn (không phải root).",
    });
    return 1;
}

catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or System.Text.Json.JsonException)
{
    stderr.WriteLine("Không đọc được dữ liệu hoặc khởi chạy WSL. Kiểm tra quyền truy cập, mở Ubuntu rồi thử lại.");
    return 1;
}
