using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace AgentWatch;

public enum StudioCredentialMode { direct, managed }

// JSON as the macOS app reads and writes it (Codable, StudioManifest.swift):
// snake_case keys, absent optionals left out, UUIDs written upper-case and
// dates as ISO 8601 without fractions, so the managed runtime sees the same
// values from either app.
public static class StudioJson
{
    public static readonly JsonSerializerOptions Options = Create();

    static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            NumberHandling = JsonNumberHandling.Strict,
            Converters = { new UpperGuid(), new IsoDate(), new JsonStringEnumConverter() },
        };
        return options;
    }

    sealed class UpperGuid : JsonConverter<Guid>
    {
        public override Guid Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
            reader.TokenType == JsonTokenType.String && Guid.TryParseExact(reader.GetString(), "D", out var value) ? value : throw new JsonException("uuid");
        public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) => writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
    }

    sealed class IsoDate : JsonConverter<DateTimeOffset>
    {
        public override DateTimeOffset Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
            reader.TokenType == JsonTokenType.String && DateTimeOffset.TryParse(reader.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var value)
                ? value : throw new JsonException("date");
        public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
    }

    public static T Parse<T>(byte[] body)
    {
        try { return JsonSerializer.Deserialize<T>(body, Options) ?? throw new StudioException(StudioError.invalidResponse); }
        catch (JsonException) { throw new StudioException(StudioError.invalidResponse); }
    }

    public static JsonNode ToNode<T>(T value) => JsonSerializer.SerializeToNode(value, Options)!;
}

public sealed record StudioAuthority(
    [property: JsonPropertyName("studio_instance_id")] Guid InstanceId,
    [property: JsonPropertyName("dataset_epoch")] Guid Epoch,
    [property: JsonPropertyName("auth_generation")] long Generation);

public sealed record StudioUser(
    [property: JsonPropertyName("id")] Guid Id,
    [property: JsonPropertyName("display_name")] string DisplayName,
    [property: JsonPropertyName("role")] string Role,
    [property: JsonPropertyName("active")] bool Active,
    [property: JsonPropertyName("version")] long Version,
    [property: JsonPropertyName("team_id")] Guid? TeamId = null,
    [property: JsonPropertyName("team_name")] string? TeamName = null);

public sealed record StudioIdentity(
    [property: JsonPropertyName("user")] StudioUser User,
    [property: JsonPropertyName("org_id")] Guid OrgId,
    [property: JsonPropertyName("api_version")] string ApiVersion,
    [property: JsonPropertyName("key_id")] Guid? KeyId = null,
    [property: JsonPropertyName("credential_mode")] StudioCredentialMode? CredentialMode = null);

public sealed record StudioCapabilities(
    [property: JsonPropertyName("api_version")] string ApiVersion,
    [property: JsonPropertyName("protocols")] string[] Protocols,
    [property: JsonPropertyName("auth")] string[] Auth);

public sealed record StudioModel(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("display_name")] string DisplayName,
    [property: JsonPropertyName("owned_by")] string OwnedBy,
    [property: JsonPropertyName("protocol")] string NativeProtocol,
    [property: JsonPropertyName("provider_model_id")] string? ProviderModel = null,
    [property: JsonPropertyName("client_model_id")] string? ClientModel = null,
    [property: JsonPropertyName("max_output_tokens")] long? MaxOutputTokens = null,
    [property: JsonPropertyName("output_accounting")] string? OutputAccounting = null,
    [property: JsonPropertyName("context_mode")] string? ContextMode = null);

public static class StudioVendor
{
    // Sent to Studio so it may list API-key vendor models.
    public const string ClientFeatures = "api-vendors";

    public static bool Valid(string id) => id != "claude" && id != "codex" && id.Length is >= 2 and <= 40 && id[0] is >= 'a' and <= 'z'
        && id.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-');

    public static bool ValidModel(string ownedBy, string nativeProtocol) =>
        (ownedBy == "claude" && nativeProtocol == "messages") || (ownedBy == "codex" && nativeProtocol == "responses") || (Valid(ownedBy) && nativeProtocol == "chat");
}

public sealed record StudioHarnessRole(
    [property: JsonPropertyName("mode")] string Mode,
    [property: JsonPropertyName("model_ids")] string[] ModelIds,
    [property: JsonPropertyName("effort")] string? Effort = null)
{
    static readonly string[] Levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
    public bool Valid => Mode is "fixed" or "auto" && ModelIds.Length is >= 1 and <= 20 && ModelIds.Distinct().Count() == ModelIds.Length
        && (Mode != "fixed" || ModelIds.Length == 1) && ModelIds.All(id => id.Length is > 0 and <= 160) && (Effort is null || Levels.Contains(Effort));
}

public sealed record StudioWorkflow(
    [property: JsonPropertyName("plan")] string Plan,
    [property: JsonPropertyName("verify")] string Verify,
    [property: JsonPropertyName("review")] string Review,
    [property: JsonPropertyName("max_fix_loops")] int MaxFixLoops)
{
    public bool Valid => new[] { Plan, Verify, Review }.All(mode => mode is "off" or "suggest" or "require") && MaxFixLoops is >= 0 and <= 3;
}

public sealed record StudioHarnessConfiguration(
    [property: JsonPropertyName("main")] StudioHarnessRole Main,
    [property: JsonPropertyName("research")] StudioHarnessRole? Research = null,
    [property: JsonPropertyName("review")] StudioHarnessRole? Review = null,
    [property: JsonPropertyName("workflow")] StudioWorkflow? Workflow = null,
    [property: JsonPropertyName("scout")] StudioHarnessRole? Scout = null,
    [property: JsonPropertyName("verify")] StudioHarnessRole? Verify = null);

public sealed record StudioHarness(
    [property: JsonPropertyName("id")] Guid Id,
    [property: JsonPropertyName("team_id")] Guid TeamId,
    [property: JsonPropertyName("revision")] long Revision,
    [property: JsonPropertyName("configuration")] StudioHarnessConfiguration Configuration)
{
    // The roles the main agent may delegate to.
    public static readonly string[] HelperRoles = ["scout", "research", "verify", "review"];
    public bool Valid => Revision > 0 && Configuration.Main.Valid
        && new[] { Configuration.Scout, Configuration.Research, Configuration.Verify, Configuration.Review }.All(role => role?.Valid ?? true)
        && (Configuration.Workflow?.Valid ?? true);
}

public sealed record StudioManifest(
    [property: JsonPropertyName("schema_version")] int SchemaVersion,
    [property: JsonPropertyName("revision")] string Revision,
    [property: JsonPropertyName("org_id")] Guid OrgId,
    [property: JsonPropertyName("user")] StudioUser User,
    [property: JsonPropertyName("key_id")] Guid KeyId,
    [property: JsonPropertyName("expires_at")] DateTimeOffset ExpiresAt,
    [property: JsonPropertyName("refresh_seconds")] int RefreshSeconds,
    [property: JsonPropertyName("models")] StudioModel[] Models,
    [property: JsonPropertyName("codex_catalog")] JsonElement CodexCatalog,
    [property: JsonPropertyName("authority")] StudioAuthority? Authority = null,
    [property: JsonPropertyName("harness")] StudioHarness? Harness = null,
    [property: JsonPropertyName("thinking_levels")] string[]? ThinkingLevels = null,
    [property: JsonPropertyName("process_versions")] int[]? ProcessVersions = null,
    [property: JsonPropertyName("key_label")] string? KeyLabel = null,
    [property: JsonPropertyName("key_prefix")] string? KeyPrefix = null,
    [property: JsonPropertyName("credential_mode")] StudioCredentialMode? CredentialMode = null)
{
    public void Validate(StudioProfile? profile = null, DateTimeOffset? now = null)
    {
        var direct = SchemaVersion == 1 && (CredentialMode ?? StudioCredentialMode.direct) == StudioCredentialMode.direct && Authority is null && Harness is null;
        var managed = SchemaVersion == 2 && CredentialMode == StudioCredentialMode.managed && (Authority?.Generation ?? 0) > 0 && (Harness?.Valid ?? true);
        if (!(direct || managed) || Revision.Length != 64 || !Revision.All(Uri.IsHexDigit)
            || !User.Active || User.TeamId is null || User.Version <= 0
            || Models.Length > 1000 || Models.Select(m => m.Id).Distinct().Count() != Models.Length
            || !Models.All(m => m.Id.Length is > 0 and <= 160 && m.ContextMode == "provider_default" && StudioVendor.ValidModel(m.OwnedBy, m.NativeProtocol)))
            throw new StudioException(StudioError.invalidResponse);
        if (Harness is not null && Harness.TeamId != User.TeamId) throw new StudioException(StudioError.invalidResponse);
        if (ExpiresAt <= (now ?? DateTimeOffset.UtcNow)) throw new StudioException(StudioError.invalidKey);
        if (profile is not null && (!profile.BelongsTo(OrgId, User.Id) || (profile.KeyId is { } keyId && keyId != KeyId)
            || profile.CredentialMode != (CredentialMode ?? StudioCredentialMode.direct))) throw new StudioException(StudioError.identityChanged);
    }
}

public sealed record StudioManagedDevice(
    [property: JsonPropertyName("device_id")] Guid DeviceId,
    [property: JsonPropertyName("token")] string Token,
    [property: JsonPropertyName("expires_at")] DateTimeOffset ExpiresAt,
    [property: JsonPropertyName("studio_instance_id")] Guid InstanceId,
    [property: JsonPropertyName("dataset_epoch")] Guid Epoch,
    [property: JsonPropertyName("auth_generation")] long Generation)
{
    public StudioAuthority Authority => new(InstanceId, Epoch, Generation);
}

public sealed record StudioRunGrant(
    [property: JsonPropertyName("run_id")] Guid RunId,
    [property: JsonPropertyName("role_id")] Guid RoleId,
    [property: JsonPropertyName("role")] string Role,
    [property: JsonPropertyName("model_id")] string ModelId,
    [property: JsonPropertyName("provider")] string Provider,
    [property: JsonPropertyName("provider_model_id")] string ProviderModelId,
    [property: JsonPropertyName("effort")] string Effort,
    [property: JsonPropertyName("fence")] long Fence,
    [property: JsonPropertyName("token")] string Token,
    [property: JsonPropertyName("expires_at")] DateTimeOffset ExpiresAt,
    [property: JsonPropertyName("profile_id")] Guid ProfileId,
    [property: JsonPropertyName("studio_instance_id")] Guid InstanceId,
    [property: JsonPropertyName("dataset_epoch")] Guid Epoch,
    [property: JsonPropertyName("auth_generation")] long Generation)
{
    public StudioAuthority Authority => new(InstanceId, Epoch, Generation);

    // Lease validity is enforced with server time; the laptop clock is not trusted.
    public void Validate(StudioAuthority authority)
    {
        if (Authority != authority || !(Role == "main" || StudioHarness.HelperRoles.Contains(Role))
            || !(Provider is "claude" or "codex" || StudioVendor.Valid(Provider)) || Fence <= 0
            || ModelId.Length is 0 or > 160 || ProviderModelId.Length is 0 or > 160 || !StudioKeys.ValidToken(Token, "run", RoleId))
            throw new StudioException(StudioError.invalidResponse);
    }
}

// A saved connection: the Studio origin, this key's slot (`Id`, what Piagent's
// binding names as profile_id) and the member it belongs to.
public sealed record StudioProfile(
    [property: JsonPropertyName("origin")] string Origin,
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("connectionID")] string ConnectionId,
    [property: JsonPropertyName("keyID")] Guid? KeyId,
    [property: JsonPropertyName("credentialMode")] StudioCredentialMode CredentialMode)
{
    static bool Hex64(string value) => value.Length == 64 && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    public bool Valid => Hex64(Id) && Hex64(ConnectionId) && (CredentialMode != StudioCredentialMode.managed || KeyId is not null);
    public StudioOrigin StudioOrigin => new(Origin);
    public bool BelongsTo(Guid orgId, Guid ownerId) => StudioOrigin.ProfileId(orgId, ownerId) == ConnectionId;
    public bool Matches(StudioIdentity identity) => BelongsTo(identity.OrgId, identity.User.Id)
        && (KeyId is null || KeyId == identity.KeyId) && CredentialMode == (identity.CredentialMode ?? StudioCredentialMode.direct);
}
