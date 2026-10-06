using System.Security.Cryptography;
using System.Text;

namespace AgentWatch;

// A Studio API origin, checked as the macOS app checks it: HTTPS (HTTP only
// on 127.0.0.1 or [::1]), no credentials, path, query or fragment.
public sealed record StudioOrigin
{
    public string Value { get; }

    public StudioOrigin(string input)
    {
        var text = (input ?? "").Trim();
        if (text.Length == 0 || Encoding.UTF8.GetByteCount(text) > 2048
            || text.Any(c => char.IsWhiteSpace(c) || c < 32 || c == 127) || text.Contains('\\') || text.Contains('%')
            || !Uri.TryCreate(text, UriKind.Absolute, out var uri)) throw new StudioException(StudioError.invalidOrigin);
        var scheme = uri.Scheme.ToLowerInvariant(); var host = uri.Host.ToLowerInvariant();
        var path = text[(text.IndexOf("://", StringComparison.Ordinal) + 3)..];
        var afterHost = path.IndexOfAny(['/', '?', '#']);
        var rest = afterHost < 0 ? "" : path[afterHost..];
        if (host.Length == 0 || uri.UserInfo.Length > 0 || (rest.Length > 0 && rest != "/")
            || !(scheme == "https" || (scheme == "http" && host is "127.0.0.1" or "[::1]")))
            throw new StudioException(StudioError.invalidOrigin);
        var port = uri.IsDefaultPort ? "" : ":" + uri.Port;
        Value = $"{scheme}://{host}{port}";
    }

    public Uri Url(string path) => new(Value + "/" + path.TrimStart('/'));

    public bool Contains(Uri url)
    {
        if (!url.IsAbsoluteUri || url.UserInfo.Length > 0) return false;
        try { return new StudioOrigin(url.GetLeftPart(UriPartial.Authority)) == this; } catch (StudioException) { return false; }
    }

    static string Sha256(string input) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(input))).ToLowerInvariant();

    public string ProfileId(Guid orgId, Guid ownerId) =>
        Sha256($"agentwatch-studio-profile-v1\0{Value}\0{orgId.ToString("D").ToLowerInvariant()}\0{ownerId.ToString("D").ToLowerInvariant()}");

    public string CredentialSlotId(Guid orgId, Guid ownerId, Guid keyId, StudioCredentialMode mode) =>
        Sha256($"agentwatch-studio-slot-v2\0{ProfileId(orgId, ownerId)}\0{keyId.ToString("D").ToLowerInvariant()}\0{mode.ToString().ToLowerInvariant()}");

    public override string ToString() => Value;
}

// Admin-issued connection code "<Studio origin>#<key>", split locally; the
// combined string is never stored or sent.
public static class StudioConnectionCode
{
    public static (string Origin, string Key)? Split(string input)
    {
        var text = (input ?? "").Trim();
        var mark = text.IndexOf("#as_live_", StringComparison.Ordinal);
        if (mark < 0) return null;
        var key = text[(mark + 1)..];
        if (key.Length <= 8 || key.Any(c => char.IsWhiteSpace(c) || c == '#')) return null;
        try { return (new StudioOrigin(text[..mark]).Value, key); } catch (StudioException) { return null; }
    }
}

public static class StudioKeys
{
    public static bool Valid(string value) => value.Length > 0 && Encoding.UTF8.GetByteCount(value) <= 4096
        && value.All(c => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_');

    // as_<kind>_<uuid>_<43 url-safe characters>; `id`, when given, must match.
    public static bool ValidToken(string value, string kind, Guid? id = null)
    {
        var prefix = "as_" + kind + "_";
        if (!value.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var tail = value[prefix.Length..];
        if (Encoding.UTF8.GetByteCount(tail) != 80 || tail[36] != '_' || !Guid.TryParseExact(tail[..36], "D", out var parsed)) return false;
        if (id is { } expected && expected != parsed) return false;
        return tail[37..].All(c => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_');
    }
}
