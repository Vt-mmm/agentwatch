using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AgentWatch;

// The commands Piagent and the coding CLIs run (StudioManagedBrokerCommand.swift,
// StudioCredentialCommand.swift), same arguments, exit codes and protocol.
public static class StudioCommands
{
    static bool ProfileArgument(string[] arguments, out string profileId)
    {
        profileId = arguments.Length == 2 && arguments[0] == "--profile" ? arguments[1] : "";
        return profileId.Length == 64 && profileId.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    }

    // Launch preparation: 67 when the slot is no longer a saved company key
    // (disconnected), 77 when its key cannot be read here.
    public static int Authorize(string[] arguments, StudioProfileStore profiles, IStudioKeyStore keys)
    {
        if (!ProfileArgument(arguments, out var id)) return 64;
        try
        {
            if (profiles.Find(id) is not { CredentialMode: StudioCredentialMode.managed }) return 67;
            return keys.Load(id) is not null ? 0 : 77;
        }
        catch (StudioException) { return 77; }
    }

    // The saved key for a connected, unblocked direct profile, for a CLI's own
    // requests (Claude Code apiKeyHelper, Codex, Pi).
    public static int Credential(string[] arguments, StudioProfileStore profiles, IStudioKeyStore keys, TextWriter output, TextWriter error)
    {
        try
        {
            if (ProfileArgument(arguments, out var id) && profiles.Find(id) is { CredentialMode: StudioCredentialMode.direct } && !profiles.Blocked(id) && keys.Load(id) is { } key)
            {
                output.Write(key + "\n"); output.Flush(); return 0;
            }
        }
        catch (StudioException) { /* reported below */ }
        error.Write("Không đọc được key Studio. Mở Agent Watch và kiểm tra phần Studio.\n");
        return 1;
    }

    static readonly HashSet<string> Fields = ["id", "action", "operation_id", "effort", "task_class", "role", "run_id", "process"];

    // Private stdio RPC for the pinned managed runtime: one JSON request per
    // line, one answer per line. The first request must be `config`.
    public static async Task<int> BrokerAsync(string[] arguments, TextReader input, TextWriter output,
        Func<string, Task<StudioManagedBroker>> enroll, CancellationToken cancellation = default)
    {
        if (arguments.Length != 2 || arguments[0] != "--profile" || arguments[1].Length != 64) return 64;
        StudioManagedBroker? broker = null;
        void Answer(string id, JsonNode? value, string? failure = null, string? studioCode = null)
        {
            var result = new JsonObject { ["id"] = id };
            if (value is not null) result["result"] = value;
            if (failure is not null) result["error"] = failure;
            if (studioCode is not null) result["studio_code"] = studioCode;
            output.Write(result.ToJsonString() + "\n"); output.Flush();
        }
        for (string? line; (line = await input.ReadLineAsync(cancellation)) is not null;)
        {
            if (Encoding.UTF8.GetByteCount(line) > 65_536) { Answer("", null, "broker_request_too_large"); break; }
            var id = "";
            try
            {
                if (JsonNode.Parse(line) is not JsonObject message || message["id"]?.GetValueKind() != JsonValueKind.String
                    || !Guid.TryParseExact(message["id"]!.GetValue<string>(), "D", out _) || message["action"]?.GetValueKind() != JsonValueKind.String
                    || !message.All(pair => Fields.Contains(pair.Key))) throw new StudioException(StudioError.invalidResponse);
                id = message["id"]!.GetValue<string>();
                var action = message["action"]!.GetValue<string>();
                string Text(string name) => message[name]?.GetValueKind() == JsonValueKind.String ? message[name]!.GetValue<string>() : throw new StudioException(StudioError.invalidResponse);
                if (broker is null)
                {
                    if (action != "config") throw new StudioException(StudioError.permissionDenied);
                    broker = await enroll(arguments[1]);
                }
                switch (action)
                {
                    case "config": Answer(id, broker.ConfigValue()); break;
                    case "start":
                        if (!Guid.TryParseExact(Text("operation_id"), "D", out var operation)) throw new StudioException(StudioError.invalidResponse);
                        Answer(id, StudioJson.ToNode(await broker.StartAsync(operation, Text("effort"), Text("task_class"), cancellation))); break;
                    case "child": Answer(id, StudioJson.ToNode(await broker.ChildAsync(Text("role"), cancellation))); break;
                    case "recover":
                        if (!Guid.TryParseExact(Text("run_id"), "D", out var run)) throw new StudioException(StudioError.invalidResponse);
                        Answer(id, StudioJson.ToNode(await broker.RecoverAsync(run, cancellation))); break;
                    case "renew": Answer(id, StudioJson.ToNode(await broker.RenewAsync(Text("role"), cancellation))); break;
                    case "close":
                        var process = message["process"] switch { null => null, JsonObject report => report, _ => throw new StudioException(StudioError.invalidResponse) };
                        await broker.CloseAsync(message["role"]?.GetValueKind() == JsonValueKind.String ? message["role"]!.GetValue<string>() : "", process, cancellation);
                        Answer(id, JsonValue.Create(true)); break;
                    default: throw new StudioException(StudioError.permissionDenied);
                }
            }
            catch (StudioException failure) { Answer(id, null, failure.Code.ToString(), failure.StudioCode); }
            catch (OperationCanceledException) { throw; }
            catch (Exception) { Answer(id, null, "broker_failed"); }
        }
        if (broker is not null) try { await broker.CloseAsync(cancellation: CancellationToken.None); } catch (Exception) { /* the run expires on its own */ }
        return 0;
    }

    public static Func<string, Task<StudioManagedBroker>> Enroll(StudioProfileStore profiles, IStudioKeyStore keys) => async id =>
    {
        if (profiles.Find(id) is not { CredentialMode: StudioCredentialMode.managed } profile || keys.Load(id) is not { } key)
            throw new StudioException(StudioError.permissionDenied);
        return await StudioManagedBroker.EnrollAsync(profile, key);
    };
}
