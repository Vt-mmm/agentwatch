using System.Text;
using System.Text.Json.Nodes;
using AgentWatch;
using Xunit;

namespace AgentWatch.Tests;

// A Studio in memory: answers the routes Agent Watch calls, records requests.
sealed class FakeStudio : IStudioTransport
{
    public readonly List<(string Method, string Path, string? Authorization, JsonObject? Body)> Requests = [];
    public Func<string, string, JsonObject?, (int Status, string Body)?>? Override;
    public static readonly Guid Org = Guid.Parse("11111111-2222-4333-8444-555555555555"), User = Guid.Parse("66666666-7777-4888-9999-aaaaaaaaaaaa");
    public static readonly Guid Key = Guid.Parse("bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"), Team = Guid.Parse("12121212-3434-4565-8787-909090909090");
    public static readonly Guid Instance = Guid.Parse("21212121-4343-4656-8787-090909090909"), Epoch = Guid.Parse("31313131-4343-4656-8787-090909090909");
    public static readonly Guid Run = Guid.Parse("41414141-4343-4656-8787-090909090909"), Device = Guid.Parse("51515151-4343-4656-8787-090909090909");
    public bool Workflow = true;
    int fence;
    static string Tail => new('A', 43);
    public static string RunToken(Guid role) => $"as_run_{role:D}_{Tail}";

    public static JsonObject Manifest(bool workflow = true) => new()
    {
        ["schema_version"] = 2, ["revision"] = new string('a', 64), ["org_id"] = Org.ToString(), ["key_id"] = Key.ToString(),
        ["credential_mode"] = "managed", ["expires_at"] = "2099-01-01T00:00:00.123Z", ["refresh_seconds"] = 300,
        ["user"] = new JsonObject { ["id"] = User.ToString(), ["display_name"] = "Nguyễn Văn A", ["role"] = "member", ["active"] = true, ["version"] = 3, ["team_id"] = Team.ToString() },
        ["models"] = new JsonArray(new JsonObject { ["id"] = "gpt-6-sol", ["display_name"] = "Sol", ["owned_by"] = "codex", ["protocol"] = "responses",
            ["provider_model_id"] = "gpt-6-sol", ["context_mode"] = "provider_default" }),
        ["codex_catalog"] = new JsonObject { ["models"] = new JsonArray() },
        ["authority"] = new JsonObject { ["studio_instance_id"] = Instance.ToString(), ["dataset_epoch"] = Epoch.ToString(), ["auth_generation"] = 4 },
        ["harness"] = new JsonObject { ["id"] = Guid.NewGuid().ToString(), ["team_id"] = Team.ToString(), ["revision"] = 2,
            ["configuration"] = new JsonObject { ["main"] = new JsonObject { ["mode"] = "fixed", ["model_ids"] = new JsonArray("gpt-6-sol") },
                ["review"] = new JsonObject { ["mode"] = "auto", ["model_ids"] = new JsonArray("gpt-6-sol") },
                ["workflow"] = workflow ? new JsonObject { ["plan"] = "suggest", ["verify"] = "require", ["review"] = "require", ["max_fix_loops"] = 2 } : null } },
        ["thinking_levels"] = new JsonArray("low", "medium", "high"), ["process_versions"] = new JsonArray(1, 2, 3),
    };

    JsonObject Grant(string role, Guid roleId) => new()
    {
        ["run_id"] = Run.ToString(), ["role_id"] = roleId.ToString(), ["role"] = role, ["model_id"] = "gpt-6-sol", ["provider"] = "codex",
        ["provider_model_id"] = "gpt-6-sol", ["effort"] = "medium", ["fence"] = ++fence, ["token"] = RunToken(roleId),
        ["expires_at"] = "2099-01-01T00:00:00Z", ["profile_id"] = Guid.Empty.ToString().Replace('0', '9'),
        ["studio_instance_id"] = Instance.ToString(), ["dataset_epoch"] = Epoch.ToString(), ["auth_generation"] = 4,
    };
    readonly Dictionary<string, Guid> roles = [];

    public async Task<StudioHttpResponse> SendAsync(HttpRequestMessage request, StudioOrigin origin, CancellationToken cancellation = default)
    {
        var path = request.RequestUri!.AbsolutePath.TrimStart('/');
        var body = request.Content is null ? null : JsonNode.Parse(await request.Content.ReadAsStringAsync(cancellation)) as JsonObject;
        Requests.Add((request.Method.Method, path, request.Headers.Authorization?.ToString(), body));
        if (Override?.Invoke(request.Method.Method, path, body) is { } custom) return new(custom.Status, "application/json", Encoding.UTF8.GetBytes(custom.Body));
        JsonNode? answer = path switch
        {
            "studio/v1/capabilities" => new JsonObject { ["api_version"] = "studio/v1", ["protocols"] = new JsonArray("responses"), ["auth"] = new JsonArray("bearer") },
            "studio/v1/me" => new JsonObject { ["api_version"] = "studio/v1", ["org_id"] = Org.ToString(), ["key_id"] = Key.ToString(), ["credential_mode"] = "managed",
                ["user"] = new JsonObject { ["id"] = User.ToString(), ["display_name"] = "Nguyễn Văn A", ["role"] = "member", ["active"] = true, ["version"] = 3 } },
            "v1/models" => new JsonObject { ["object"] = "list", ["admission_required"] = true, ["data"] = new JsonArray(new JsonObject { ["id"] = "gpt-6-sol",
                ["display_name"] = "Sol", ["owned_by"] = "codex", ["protocol"] = "responses" }) },
            "studio/v1/client-config" => Manifest(Workflow),
            "studio/v1/managed/devices" => new JsonObject { ["device_id"] = Device.ToString(), ["token"] = $"as_device_{Device:D}_{Tail}", ["expires_at"] = "2099-01-01T00:00:00Z",
                ["studio_instance_id"] = Instance.ToString(), ["dataset_epoch"] = Epoch.ToString(), ["auth_generation"] = 4 },
            "studio/v1/managed/runs" => Grant("main", roles["main"] = Guid.NewGuid()),
            _ when path.EndsWith("/children") => Grant(body!["role"]!.GetValue<string>(), roles[body["role"]!.GetValue<string>()] = Guid.NewGuid()),
            _ when path.StartsWith("studio/v1/managed/roles/") => Grant(roles.First(r => path.Contains(r.Value.ToString())).Key, roles.First(r => path.Contains(r.Value.ToString())).Value),
            _ when path.EndsWith("/close") => null,
            _ => throw new InvalidOperationException(path),
        };
        return answer is null ? new(204, "", []) : new(200, "application/json", Encoding.UTF8.GetBytes(answer.ToJsonString()));
    }
}

public class OriginAndKeyTests
{
    [Theory]
    [InlineData("https://studio.example.com", "https://studio.example.com")]
    [InlineData("HTTPS://Studio.Example.com:443/", "https://studio.example.com")]
    [InlineData("https://studio.example.com:8443", "https://studio.example.com:8443")]
    [InlineData("http://127.0.0.1:17922", "http://127.0.0.1:17922")]
    [InlineData("http://[::1]:17922", "http://[::1]:17922")]
    public void AcceptsStudioOrigins(string input, string expected) => Assert.Equal(expected, new StudioOrigin(input).Value);

    [Theory]
    [InlineData("http://studio.example.com")]
    [InlineData("https://studio.example.com/api")]
    [InlineData("https://user:pw@studio.example.com")]
    [InlineData("https://studio.example.com?x=1")]
    [InlineData("https://studio.example.com#as_live_x")]
    [InlineData("https://studio example.com")]
    [InlineData("https://studio.example.com/%2e")]
    [InlineData("")]
    public void RefusesOtherOrigins(string input) => Assert.Equal(StudioError.invalidOrigin, Assert.Throws<StudioException>(() => new StudioOrigin(input)).Code);

    [Fact]
    public void SlotIdsMatchTheMacApp()
    {
        var origin = new StudioOrigin("https://studio.example.com");
        Assert.Equal("4b137be603fe4d9ea2d586c1ff5c06dbcefeeadc8c53594fe01cfadd6d7ec9e2", origin.ProfileId(FakeStudio.Org, FakeStudio.User));
        Assert.Equal("093114ceb41394ba33be4196f591fdc324b0305bc100bdb46d298fb0bfda14d7", origin.CredentialSlotId(FakeStudio.Org, FakeStudio.User, FakeStudio.Key, StudioCredentialMode.managed));
    }

    [Fact]
    public void SplitsAConnectionCodeAndChecksTokens()
    {
        Assert.Equal(("https://studio.example.com", "as_live_abc_DEF-123456"), StudioConnectionCode.Split(" https://studio.example.com#as_live_abc_DEF-123456 "));
        Assert.Null(StudioConnectionCode.Split("https://studio.example.com#as_live_"));
        Assert.Null(StudioConnectionCode.Split("http://studio.example.com#as_live_abcdefghij"));
        var role = Guid.NewGuid();
        Assert.True(StudioKeys.ValidToken(FakeStudio.RunToken(role), "run", role));
        Assert.False(StudioKeys.ValidToken(FakeStudio.RunToken(role), "run", Guid.NewGuid()));
        Assert.False(StudioKeys.ValidToken(FakeStudio.RunToken(role) + "x", "run"));
        Assert.False(StudioKeys.Valid("key with space"));
    }
}

public class ManifestTests
{
    static StudioManifest Parse(JsonObject manifest) => StudioClient.Decode<StudioManifest>(Encoding.UTF8.GetBytes(manifest.ToJsonString()));

    [Fact]
    public void AcceptsACompanyManifestAndRefusesBrokenOnes()
    {
        Parse(FakeStudio.Manifest()).Validate();
        foreach (var broken in new Action<JsonObject>[]
        {
            m => m["revision"] = "short",
            m => m["schema_version"] = 1,
            m => m["user"]!["team_id"] = null,
            m => ((JsonArray)m["models"]!)[0]!["owned_by"] = "codex2!",
            m => ((JsonArray)m["models"]!)[0]!["context_mode"] = "custom",
            m => m["harness"]!["team_id"] = Guid.NewGuid().ToString(),
            m => m["harness"]!["configuration"]!["main"]!["model_ids"] = new JsonArray("a", "b"),
        })
        {
            var manifest = FakeStudio.Manifest(); broken(manifest);
            Assert.Equal(StudioError.invalidResponse, Assert.Throws<StudioException>(() => Parse(manifest).Validate()).Code);
        }
        var missing = FakeStudio.Manifest(); missing.Remove("revision");
        Assert.Equal(StudioError.invalidResponse, Assert.Throws<StudioException>(() => Parse(missing)).Code);
        var expired = FakeStudio.Manifest(); expired["expires_at"] = "2001-01-01T00:00:00Z";
        Assert.Equal(StudioError.invalidKey, Assert.Throws<StudioException>(() => Parse(expired).Validate()).Code);
    }

    [Fact]
    public void ProcessReportsCarryCountsAndOutcomesOnly()
    {
        JsonObject Report() => new()
        {
            ["version"] = 2, ["policy"] = new JsonObject { ["plan"] = "suggest", ["verify"] = "require", ["review"] = "off" }, ["outcome"] = "clean",
            ["plan_steps"] = 2, ["plan_done"] = 2, ["checks"] = 1, ["checks_failed"] = 0, ["reviews"] = 1, ["blocking"] = 0, ["blocking_open"] = 0, ["fix_loops"] = 0,
            ["unknown_tools"] = 0, ["changed"] = true, ["verified"] = true, ["reviewed"] = true, ["plan_skipped"] = false,
        };
        Assert.True(StudioProcessReport.Valid(Report(), [1, 2]));
        Assert.False(StudioProcessReport.Valid(Report(), [1]), "a version Studio does not take");
        var text = Report(); text["outcome"] = "the agent said: secret"; Assert.False(StudioProcessReport.Valid(text, [2]));
        var extra = Report(); extra["prompt"] = "x"; Assert.False(StudioProcessReport.Valid(extra, [2]));
        var fraction = Report(); fraction["checks"] = 1.5; Assert.False(StudioProcessReport.Valid(fraction, [2]));
    }
}

public class BrokerTests : IDisposable
{
    readonly string directory = Directory.CreateTempSubdirectory("agentwatch-tests-").FullName;
    public BrokerTests() => Environment.SetEnvironmentVariable("AGENTWATCH_DATA_DIR", directory);
    public void Dispose() => Directory.Delete(directory, true);

    static async Task<List<JsonObject>> Talk(FakeStudio studio, StudioProfile profile, string key, params JsonObject[] requests)
    {
        var input = new StringReader(string.Join("\n", requests.Select(r => r.ToJsonString())) + "\n");
        var output = new StringWriter();
        var code = await StudioCommands.BrokerAsync(["--profile", profile.Id], input, output, _ => StudioManagedBroker.EnrollAsync(profile, key, studio));
        Assert.Equal(0, code);
        return output.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => (JsonObject)JsonNode.Parse(line)!).ToList();
    }
    static JsonObject Ask(string action, JsonObject? extra = null)
    {
        var message = new JsonObject { ["id"] = Guid.NewGuid().ToString(), ["action"] = action };
        foreach (var (k, v) in extra ?? []) message[k] = v?.DeepClone();
        return message;
    }

    // bind-wsl (CLI) and the app record the distribution, so the app binds it
    // again after an update; an unreadable record means no rebind, not a crash.
    [Fact]
    public void RemembersTheBoundDistributionForTheNextStart()
    {
        Assert.Null(PiagentWslBinding.Remembered());
        PiagentWslBinding.Remember("Ubuntu-24.04");
        Assert.Equal("Ubuntu-24.04", PiagentWslBinding.Remembered());
        File.WriteAllText(PiagentWslBinding.RememberedFile, "{");
        Assert.Null(PiagentWslBinding.Remembered());
    }

    async Task<(FakeStudio, StudioProfile, string)> Connected()
    {
        var studio = new FakeStudio();
        var (profile, connection) = await new StudioConnector(new StudioProfileStore(), new StudioKeyStore(), new StudioClient(studio)).ConnectAsync("https://studio.example.com#as_live_test-key_0123456789");
        Assert.Equal(StudioCredentialMode.managed, profile.CredentialMode);
        Assert.Equal("Nguyễn Văn A", connection.Identity.User.DisplayName);
        Assert.Equal("as_live_test-key_0123456789", new StudioKeyStore().Load(profile.Id));
        return (studio, profile, "as_live_test-key_0123456789");
    }

    [Fact]
    public async Task ARunGoesThroughConfigStartChildRenewAndClose()
    {
        var (studio, profile, key) = await Connected();
        var answers = await Talk(studio, profile, key, Ask("config"), Ask("start", new() { ["operation_id"] = Guid.NewGuid().ToString(), ["effort"] = "medium", ["task_class"] = "standard" }),
            Ask("child", new() { ["role"] = "review" }), Ask("renew", new() { ["role"] = "main" }),
            Ask("close", new() { ["role"] = "", ["process"] = new JsonObject { ["version"] = 1, ["policy"] = new JsonObject { ["plan"] = "off", ["verify"] = "off", ["review"] = "off" },
                ["outcome"] = "no_change", ["plan_steps"] = 0, ["plan_done"] = 0, ["checks"] = 0, ["checks_failed"] = 0, ["reviews"] = 0, ["blocking"] = 0, ["blocking_open"] = 0,
                ["fix_loops"] = 0, ["changed"] = false, ["verified"] = false, ["reviewed"] = false } }));
        Assert.All(answers, a => Assert.Null(a["error"]));
        var config = answers[0]["result"]!;
        Assert.Equal("managed", config["credential_mode"]!.GetValue<string>());
        Assert.Equal(FakeStudio.Instance.ToString().ToUpperInvariant(), config["authority"]!["studio_instance_id"]!.GetValue<string>());
        Assert.Equal("2099-01-01T00:00:00Z", config["expires_at"]!.GetValue<string>());
        Assert.Equal(["process", "process-v2", "process-v3"], config["broker_features"]!.AsArray().Select(n => n!.GetValue<string>()));
        Assert.False(config.AsObject().ContainsKey("key_label"), "absent optionals stay absent");
        var start = answers[1]["result"]!;
        Assert.Equal("main", start["role"]!.GetValue<string>());
        Assert.Matches("^as_run_[a-f0-9-]{36}_[\\w-]{43}$", start["token"]!.GetValue<string>());
        Assert.Equal(2, answers[3]["result"]!["fence"]!.GetValue<long>() - 1);
        Assert.True(answers[4]["result"]!.GetValue<bool>());
        var close = studio.Requests.Last(r => r.Path.EndsWith("/close"));
        Assert.Equal("no_change", close.Body!["process"]!["outcome"]!.GetValue<string>());
        Assert.StartsWith("Bearer as_device_", close.Authorization);
        // The member's key enrolls the device; runs use the device token only.
        Assert.DoesNotContain(studio.Requests, r => r.Path.StartsWith("studio/v1/managed/") && r.Path != "studio/v1/managed/devices" && r.Authorization!.Contains("as_live_"));
    }

    [Fact]
    public async Task RefusesAnythingBeforeConfigAndReportsStudioCodes()
    {
        var (studio, profile, key) = await Connected();
        var answers = await Talk(studio, profile, key, Ask("start", new() { ["operation_id"] = Guid.NewGuid().ToString(), ["effort"] = "x", ["task_class"] = "standard" }));
        Assert.Equal("permissionDenied", answers[0]["error"]!.GetValue<string>());
        studio.Override = (method, path, body) => path == "studio/v1/managed/runs" ? (429, "{}") : null;
        answers = await Talk(studio, profile, key, Ask("config"), Ask("start", new() { ["operation_id"] = Guid.NewGuid().ToString(), ["effort"] = "high", ["task_class"] = "complex" }),
            new JsonObject { ["id"] = "not-a-uuid", ["action"] = "config" }, Ask("config", new() { ["unexpected"] = 1 }));
        Assert.Equal("rateLimited", answers[1]["error"]!.GetValue<string>());
        Assert.Equal("", answers[2]["id"]!.GetValue<string>());
        Assert.Equal("invalidResponse", answers[3]["error"]!.GetValue<string>());
    }

    [Fact]
    public async Task AuthorizeAndCredentialFollowTheSavedSlot()
    {
        var (_, profile, _) = await Connected();
        var profiles = new StudioProfileStore(); var keys = new StudioKeyStore();
        Assert.Equal(0, StudioCommands.Authorize(["--profile", profile.Id], profiles, keys));
        Assert.Equal(67, StudioCommands.Authorize(["--profile", new string('0', 64)], profiles, keys));
        Assert.Equal(64, StudioCommands.Authorize(["--profile", "x"], profiles, keys));
        var output = new StringWriter(); var error = new StringWriter();
        Assert.Equal(1, StudioCommands.Credential(["--profile", profile.Id], profiles, keys, output, error));
        Assert.Equal("", output.ToString()); // a company key never leaves through the helper
        new StudioConnector(profiles, keys).Disconnect(profile.Id);
        Assert.Equal(67, StudioCommands.Authorize(["--profile", profile.Id], profiles, keys));
        Assert.Null(keys.Load(profile.Id));
    }
}

sealed class FakeWsl : IWsl
{
    public readonly List<(string? Distro, string? Input, string[] Command)> Calls = [];
    public Task<string> RunAsync(string? distro, string? input, params string[] command)
    {
        Calls.Add((distro, input, command));
        var script = string.Join(' ', command);
        return Task.FromResult(script switch
        {
            _ when script.Contains("WSL_DISTRO_NAME") => "Ubuntu",
            _ when script.Contains("piagent-runtime.json") => "{\"schema_version\":1,\"entrypoint\":\"/home/dev/.local/lib/node_modules/@piagent/platform/scripts/piagent-studio.mjs\",\"node\":\"/usr/bin/node\",\"pi_sdk_root\":\"/home/dev/.pi/sdk\"}\n--home--\n/home/dev\n",
            _ when script.Contains("sha256sum") => "/home/dev/.local/lib/node_modules/@piagent/platform/scripts/piagent-studio.mjs\n/usr/bin/node\n/home/dev/.pi/sdk\n" + new string('e', 64) + "\n" + new string('f', 64) + "\n0.87.1\n",
            _ when command[0] == "wslpath" => "/mnt/c/Users/dev/AppData/Local/AgentWatch/agentwatch.exe\n",
            _ => "",
        });
    }
}

public class WslBindingTests
{
    [Fact]
    public async Task WritesTheBindingPiagentChecksIntoTheDistribution()
    {
        var manifest = StudioClient.Decode<StudioManifest>(Encoding.UTF8.GetBytes(FakeStudio.Manifest().ToJsonString()));
        var origin = new StudioOrigin("https://studio.example.com");
        var profile = new StudioProfile(origin.Value, origin.CredentialSlotId(FakeStudio.Org, FakeStudio.User, FakeStudio.Key, StudioCredentialMode.managed),
            origin.ProfileId(FakeStudio.Org, FakeStudio.User), FakeStudio.Key, StudioCredentialMode.managed);
        var broker = Path.GetTempFileName(); File.WriteAllText(broker, "exe");
        var wsl = new FakeWsl();
        var result = await PiagentWslBinding.BindAsync(profile, manifest, broker, wsl);
        Assert.Equal("Ubuntu", result.Distro);
        var written = (JsonObject)JsonNode.Parse(wsl.Calls.Last().Input!)!;
        Assert.Equal(profile.Id, written["profile_id"]!.GetValue<string>());
        Assert.Equal("/mnt/c/Users/dev/AppData/Local/AgentWatch/agentwatch.exe", written["broker"]!.GetValue<string>());
        Assert.Equal(new string('e', 64), written["entrypoint_sha256"]!.GetValue<string>());
        Assert.Equal(new string('f', 64), written["node_sha256"]!.GetValue<string>());
        Assert.Equal("d0d2b6a4d4f3d3f8f5f6d4b6f9b0b9aa8ba1e4f2c0b0c4a5ff4a5f4f6c1b5f4a".Length, written["broker_sha256"]!.GetValue<string>().Length);
        Assert.Equal(new string('a', 64), written["configuration_revision"]!.GetValue<string>());
        Assert.Contains("umask 077", string.Join(' ', wsl.Calls.Last().Command));
        File.Delete(broker);
    }
}
