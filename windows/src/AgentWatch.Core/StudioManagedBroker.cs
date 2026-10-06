using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AgentWatch;

// Run grants for one isolated Piagent process (StudioManaged.swift). No public
// socket and no operation that returns the key or the device credential.
public sealed class StudioManagedBroker
{
    public StudioProfile Profile { get; }
    public StudioManifest Manifest { get; }
    readonly StudioManagedDevice device;
    readonly IStudioTransport transport;
    Guid? root;
    readonly Dictionary<string, StudioRunGrant> grants = [];
    static readonly string[] Efforts = ["", "off", "minimal", "low", "medium", "high", "xhigh", "max"];

    public StudioManagedBroker(StudioProfile profile, StudioManifest manifest, StudioManagedDevice device, IStudioTransport transport)
    {
        manifest.Validate(profile);
        if (profile.CredentialMode != StudioCredentialMode.managed || manifest.Authority is not { } authority
            || device.Authority != authority || !StudioKeys.ValidToken(device.Token, "device", device.DeviceId)) throw new StudioException(StudioError.invalidResponse);
        Profile = profile; Manifest = manifest; this.device = device; this.transport = transport;
    }

    public static async Task<StudioManagedBroker> EnrollAsync(StudioProfile profile, string key, IStudioTransport? transport = null, CancellationToken cancellation = default)
    {
        transport ??= new StudioHttpTransport();
        if (profile.CredentialMode != StudioCredentialMode.managed) throw new StudioException(StudioError.permissionDenied);
        var manifest = await new StudioClient(transport).ConfigurationAsync(profile.StudioOrigin, key, cancellation);
        manifest.Validate(profile);
        if (manifest.Harness is null) throw new StudioException(StudioError.permissionDenied);
        // An independent broker must not rotate another running device.
        var body = await Post(transport, profile.StudioOrigin, "devices", key, new JsonObject { ["installation_id"] = Guid.NewGuid().ToString("D") }, cancellation);
        return new StudioManagedBroker(profile, manifest, StudioClient.Decode<StudioManagedDevice>(body), transport);
    }

    internal static async Task<byte[]> Post(IStudioTransport transport, StudioOrigin origin, string path, string credential, JsonObject body, CancellationToken cancellation = default)
    {
        if (!StudioKeys.Valid(credential)) throw new StudioException(StudioError.invalidKey);
        using var request = new HttpRequestMessage(HttpMethod.Post, origin.Url("studio/v1/managed/" + path))
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", credential);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.TryAddWithoutValidation("User-Agent", StudioClient.UserAgent);
        var response = await transport.SendAsync(request, origin, cancellation);
        if (response.Status is >= 300 and < 400) throw new StudioException(StudioError.redirectDenied);
        switch (response.Status)
        {
            case 200 or 201:
                if (!response.ContentType.Split(';')[0].Trim().Equals("application/json", StringComparison.OrdinalIgnoreCase)) throw new StudioException(StudioError.invalidResponse);
                return response.Body;
            case 204: return [];
            case 401: throw new StudioException(StudioError.invalidKey);
            case 403: throw new StudioException(StudioError.permissionDenied);
            case 409: throw new StudioException(StudioError.identityChanged);
            case 429: throw new StudioException(StudioError.rateLimited);
            case 400: throw new StudioException(StudioError.invalidResponse);
            default: throw new StudioException(StudioError.serverUnavailable);
        }
    }

    async Task<StudioRunGrant> Grant(string path, JsonObject body, CancellationToken cancellation)
    {
        var grant = StudioClient.Decode<StudioRunGrant>(await Post(transport, Profile.StudioOrigin, path, device.Token, body, cancellation));
        grant.Validate(device.Authority);
        return grant;
    }

    static string Id(Guid value) => value.ToString("D");

    public async Task<StudioRunGrant> StartAsync(Guid operation, string effort, string taskClass, CancellationToken cancellation = default)
    {
        if (root is not null || !Efforts.Contains(effort) || taskClass is not ("simple" or "standard" or "complex")) throw new StudioException(StudioError.permissionDenied);
        var grant = await Grant("runs", new JsonObject { ["operation_id"] = Id(operation), ["effort"] = effort, ["task_class"] = taskClass }, cancellation);
        if (grant.Role != "main") throw new StudioException(StudioError.invalidResponse);
        root = grant.RunId; grants["main"] = grant; return grant;
    }

    public async Task<StudioRunGrant> ChildAsync(string role, CancellationToken cancellation = default)
    {
        if (!StudioHarness.HelperRoles.Contains(role) || root is not { } run || grants.ContainsKey(role)) throw new StudioException(StudioError.permissionDenied);
        var grant = await Grant($"runs/{Id(run)}/children", new JsonObject { ["role"] = role }, cancellation);
        if (grant.RunId != run || grant.Role != role) throw new StudioException(StudioError.invalidResponse);
        grants[role] = grant; return grant;
    }

    public async Task<StudioRunGrant> RecoverAsync(Guid runId, CancellationToken cancellation = default)
    {
        if (root is not null) throw new StudioException(StudioError.permissionDenied);
        var grant = await Grant($"runs/{Id(runId)}/recover", [], cancellation);
        if (grant.RunId != runId || grant.Role != "main") throw new StudioException(StudioError.identityChanged);
        root = runId; grants["main"] = grant; return grant;
    }

    public async Task<StudioRunGrant> RenewAsync(string role, CancellationToken cancellation = default)
    {
        if (!grants.TryGetValue(role, out var old)) throw new StudioException(StudioError.permissionDenied);
        var grant = await Grant($"roles/{Id(old.RoleId)}/renew", new JsonObject { ["fence"] = old.Fence }, cancellation);
        if (grant.RunId != old.RunId || grant.RoleId != old.RoleId || grant.Role != role || grant.Fence <= old.Fence
            || grant.ModelId != old.ModelId || grant.ProviderModelId != old.ProviderModelId || grant.ProfileId != old.ProfileId) throw new StudioException(StudioError.identityChanged);
        grants[role] = grant; return grant;
    }

    // Closing the run may carry the runtime's process report (counts and
    // outcomes only), sent to a Studio whose Harness has a workflow.
    public async Task CloseAsync(string role = "", JsonObject? process = null, CancellationToken cancellation = default)
    {
        if (root is not { } run) return;
        if (role.Length > 0 && !grants.ContainsKey(role)) throw new StudioException(StudioError.permissionDenied);
        var body = new JsonObject { ["role"] = role };
        if (process is not null)
        {
            if (!(role.Length == 0 || role == "main") || !StudioProcessReport.Valid(process, Manifest.ProcessVersions ?? [1])) throw new StudioException(StudioError.invalidResponse);
            if (Manifest.Harness?.Configuration.Workflow is not null) body["process"] = process.DeepClone();
        }
        await Post(transport, Profile.StudioOrigin, $"runs/{Id(run)}/close", device.Token, body, cancellation);
        if (role.Length == 0 || role == "main") { root = null; grants.Clear(); } else grants.Remove(role);
    }

    // The manifest for the runtime, with what this broker accepts beyond the
    // first protocol, so a newer runtime never sends it a field it refuses.
    public JsonObject ConfigValue()
    {
        var value = (JsonObject)StudioJson.ToNode(Manifest);
        var features = new JsonArray("process");
        foreach (var version in new[] { 2, 3 }.Where(v => Manifest.ProcessVersions?.Contains(v) == true)) features.Add($"process-v{version}");
        value["broker_features"] = features;
        return value;
    }
}

// Shape check of a process report before it leaves the machine: known keys and
// value types only, so no text (prompts, findings, paths) is forwarded.
public static class StudioProcessReport
{
    static readonly string[] BaseCounts = ["plan_steps", "plan_done", "checks", "checks_failed", "reviews", "blocking", "blocking_open", "fix_loops"];
    static readonly string[] BaseFlags = ["changed", "verified", "reviewed"];
    static readonly string[] Outcomes = ["no_change", "interrupted", "blocking_open", "unverified", "review_unavailable", "unreviewed", "clean"];
    static readonly string[] V3Counts = ["objections", "objections_answered", "disputes"];
    static readonly string[] Modes = ["off", "suggest", "require"];

    // A JSON number, whether the node was parsed or built in code.
    static double? Number(JsonNode? node) => node is JsonValue value && value.GetValueKind() == JsonValueKind.Number
        && double.TryParse(value.ToJsonString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var number) ? number : null;

    public static bool Valid(JsonObject report, int[] versions)
    {
        if (Number(report["version"]) is not { } number || number % 1 != 0 || (int)number is not (1 or 2 or 3) || !versions.Contains((int)number)) return false;
        var version = (int)number;
        var counts = BaseCounts.Concat(version >= 2 ? ["unknown_tools"] : []).Concat(version == 3 ? V3Counts : []).ToHashSet();
        var flags = (version >= 2 ? BaseFlags.Append("plan_skipped") : BaseFlags).ToHashSet();
        var expected = counts.Concat(flags).Concat(["version", "policy", "outcome"]).ToHashSet();
        if (!expected.SetEquals(report.Select(pair => pair.Key))) return false;
        foreach (var (key, value) in report)
        {
            switch (key)
            {
                case "version": break;
                case "outcome":
                    if (value is not JsonValue o || o.GetValueKind() != JsonValueKind.String || !(Outcomes.Contains(o.GetValue<string>()) || version == 3 && o.GetValue<string>() == "disputed")) return false;
                    break;
                case "policy":
                    if (value is not JsonObject p || !new HashSet<string>(["plan", "verify", "review"]).SetEquals(p.Select(x => x.Key))
                        || !p.All(x => x.Value is JsonValue m && m.GetValueKind() == JsonValueKind.String && Modes.Contains(m.GetValue<string>()))) return false;
                    break;
                default:
                    if (value is not JsonValue v) return false;
                    var kind = v.GetValueKind();
                    if (kind is JsonValueKind.True or JsonValueKind.False) { if (!flags.Contains(key)) return false; }
                    else if (Number(v) is { } n)
                    {
                        if (!counts.Contains(key) || n < 0 || n > 1000 || n % 1 != 0) return false;
                    }
                    else return false;
                    break;
            }
        }
        return true;
    }
}
