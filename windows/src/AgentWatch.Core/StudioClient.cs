using System.Net;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AgentWatch;

public sealed record StudioHttpResponse(int Status, string ContentType, byte[] Body);

public interface IStudioTransport
{
    Task<StudioHttpResponse> SendAsync(HttpRequestMessage request, StudioOrigin origin, CancellationToken cancellation = default);
}

// Uses only the chosen origin: no cookies, cached credentials or redirects can
// carry a key elsewhere, and a response is read up to 1 MiB.
public sealed class StudioHttpTransport : IStudioTransport
{
    public const int MaxResponseBytes = 1_048_576;
    static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, Credentials = null, PreAuthenticate = false,
        AutomaticDecompression = DecompressionMethods.None, ConnectTimeout = TimeSpan.FromSeconds(15),
    }) { Timeout = TimeSpan.FromSeconds(20) };

    public async Task<StudioHttpResponse> SendAsync(HttpRequestMessage request, StudioOrigin origin, CancellationToken cancellation = default)
    {
        if (request.RequestUri is null || !origin.Contains(request.RequestUri)) throw new StudioException(StudioError.invalidOrigin);
        HttpResponseMessage response;
        try { response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation); }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { throw; }
        catch (Exception) { throw new StudioException(StudioError.offline); }
        using (response)
        {
            var status = (int)response.StatusCode;
            if (status != 304 && status is >= 300 and < 400) throw new StudioException(StudioError.redirectDenied);
            if (response.Content.Headers.ContentLength > MaxResponseBytes) throw new StudioException(StudioError.invalidResponse);
            await using var stream = await response.Content.ReadAsStreamAsync(cancellation);
            var body = new MemoryStream(); var buffer = new byte[16384];
            for (int read; (read = await stream.ReadAsync(buffer, cancellation)) > 0;)
            {
                if (body.Length + read > MaxResponseBytes) throw new StudioException(StudioError.invalidResponse);
                body.Write(buffer, 0, read);
            }
            return new StudioHttpResponse(status, response.Content.Headers.ContentType?.ToString() ?? "", body.ToArray());
        }
    }
}

public sealed record StudioConnection(StudioIdentity Identity, StudioCapabilities Capabilities, StudioModel[]? Models, StudioError? ModelsError);

public sealed class StudioClient(IStudioTransport? transport = null)
{
    readonly IStudioTransport transport = transport ?? new StudioHttpTransport();
    // Identifies the client to Studio (its installations list); no user or device data.
    public static readonly string UserAgent = "AgentWatch/" + (typeof(StudioClient).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0") + "-windows";

    static bool Json(StudioHttpResponse response) =>
        response.ContentType.Split(';')[0].Trim().Equals("application/json", StringComparison.OrdinalIgnoreCase);

    internal static T Decode<T>(byte[] body)
    {
        var value = StudioJson.Parse<T>(body);
        RequiredFields.Check(value);
        return value;
    }

    public async Task<T> GetAsync<T>(StudioOrigin origin, string path, string? key, CancellationToken cancellation = default)
    {
        if (key is not null && !StudioKeys.Valid(key)) throw new StudioException(StudioError.invalidKey);
        using var request = new HttpRequestMessage(HttpMethod.Get, origin.Url(path));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        request.Headers.TryAddWithoutValidation("X-Studio-Client-Features", StudioVendor.ClientFeatures);
        if (key is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        var response = await transport.SendAsync(request, origin, cancellation);
        if (response.Status != 200)
        {
            string code = "";
            try { code = JsonNode.Parse(response.Body)?["error"]?["code"]?.GetValue<string>() ?? ""; } catch (Exception) { /* no body */ }
            throw new StudioException(response.Status switch
            {
                400 => code == "key_target_unavailable" ? StudioError.permissionDenied : StudioError.invalidResponse,
                401 => StudioError.invalidKey,
                403 => StudioError.permissionDenied,
                404 when path == "studio/v1/client-config" => StudioError.incompatibleVersion,
                429 => code == "token_quota_exhausted" ? StudioError.quotaExceeded : StudioError.rateLimited,
                _ => code.StartsWith("upstream_", StringComparison.Ordinal) ? StudioError.upstreamUnavailable : StudioError.serverUnavailable,
            });
        }
        if (!Json(response)) throw new StudioException(StudioError.invalidResponse);
        return Decode<T>(response.Body);
    }

    sealed record ModelList(string Object, StudioModel[] Data, bool AdmissionRequired);

    // The member's connection: Studio's API version, who the key belongs to,
    // and the models it may use (unavailable models do not fail the check).
    public async Task<StudioConnection> ConnectAsync(StudioOrigin origin, string key, CancellationToken cancellation = default)
    {
        if (!StudioKeys.Valid(key)) throw new StudioException(StudioError.invalidKey);
        var capabilities = await GetAsync<StudioCapabilities>(origin, "studio/v1/capabilities", null, cancellation);
        if (capabilities.ApiVersion != "studio/v1" || !capabilities.Auth.Contains("bearer")) throw new StudioException(StudioError.incompatibleVersion);
        var identity = await GetAsync<StudioIdentity>(origin, "studio/v1/me", key, cancellation);
        if (identity.ApiVersion != "studio/v1") throw new StudioException(StudioError.incompatibleVersion);
        if (!identity.User.Active || identity.User.Version <= 0 || !new[] { "owner", "admin", "viewer", "member" }.Contains(identity.User.Role)
            || identity.User.DisplayName.Length == 0 || Encoding.UTF8.GetByteCount(identity.User.DisplayName) > 120) throw new StudioException(StudioError.invalidResponse);
        try
        {
            var raw = await GetAsync<JsonObject>(origin, "v1/models", key, cancellation);
            var list = new ModelList(raw["object"]?.GetValue<string>() ?? "", raw["data"]?.Deserialize<StudioModel[]>(StudioJson.Options) ?? [],
                raw["admission_required"]?.GetValue<bool>() ?? false);
            if (list.Object != "list" || !list.AdmissionRequired || list.Data.Length > 1000 || list.Data.Select(m => m.Id).Distinct().Count() != list.Data.Length
                || !list.Data.All(m => m.Id.Length is > 0 and <= 160 && StudioVendor.ValidModel(m.OwnedBy, m.NativeProtocol))) throw new StudioException(StudioError.invalidResponse);
            return new StudioConnection(identity, capabilities, list.Data, null);
        }
        catch (StudioException error) when (error.Code is not (StudioError.invalidKey or StudioError.incompatibleVersion or StudioError.redirectDenied or StudioError.invalidResponse))
        {
            return new StudioConnection(identity, capabilities, null, error.Code);
        }
    }

    public async Task<StudioManifest> ConfigurationAsync(StudioOrigin origin, string key, CancellationToken cancellation = default)
    {
        var manifest = await GetAsync<StudioManifest>(origin, "studio/v1/client-config", key, cancellation);
        manifest.Validate();
        return manifest;
    }
}

// What Codable enforces in the macOS app: a field the type does not mark
// optional must be there. System.Text.Json fills a missing one with null.
static class RequiredFields
{
    static readonly NullabilityInfoContext Nullability = new();

    public static void Check(object? value)
    {
        if (value is null) throw new StudioException(StudioError.invalidResponse);
        var type = value.GetType();
        if (type.IsArray) { foreach (var item in (Array)value) Check(item); return; }
        if (type.Namespace != typeof(RequiredFields).Namespace || !type.IsClass) return;
        foreach (var property in type.GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            if (property.GetIndexParameters().Length > 0 || property.GetCustomAttributes(typeof(System.Text.Json.Serialization.JsonPropertyNameAttribute), false).Length == 0) continue;
            var item = property.GetValue(value);
            if (item is null)
            {
                if (!property.PropertyType.IsValueType && Nullability.Create(property).ReadState != NullabilityState.Nullable) throw new StudioException(StudioError.invalidResponse);
                continue;
            }
            if (item is not string && item is not JsonElement) Check(item);
        }
    }
}
