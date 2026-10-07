using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AgentWatch;

// Where Agent Watch for Windows keeps its data: %LOCALAPPDATA%\AgentWatch
// (AGENTWATCH_DATA_DIR for tests and development on other systems).
public static class AgentWatchPaths
{
    public static string DataDirectory =>
        Environment.GetEnvironmentVariable("AGENTWATCH_DATA_DIR") is { Length: > 0 } custom ? custom
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentWatch");
}

// Saved connections (at most 64 key slots) and which one is in use.
public sealed class StudioProfileStore(string? directory = null)
{
    readonly string file = Path.Combine(directory ?? AgentWatchPaths.DataDirectory, "profiles.json");

    sealed record Saved(
        [property: JsonPropertyName("profiles")] List<StudioProfile> Profiles,
        [property: JsonPropertyName("active")] string? Active,
        [property: JsonPropertyName("blocked")] List<string>? Blocked = null);

    Saved Read()
    {
        try
        {
            var saved = JsonSerializer.Deserialize<Saved>(File.ReadAllBytes(file), StudioJson.Options);
            if (saved?.Profiles is null || saved.Profiles.Any(p => p is null || !p.Valid)) throw new StudioException(StudioError.storage);
            return saved;
        }
        catch (FileNotFoundException) { return new([], null); }
        catch (DirectoryNotFoundException) { return new([], null); }
        catch (JsonException) { throw new StudioException(StudioError.storage); }
    }

    void Write(Saved saved)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        var temporary = file + "." + Environment.ProcessId + ".tmp";
        File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(saved, StudioJson.Options));
        File.Move(temporary, file, overwrite: true);
    }

    public IReadOnlyList<StudioProfile> Profiles() => Read().Profiles;
    public StudioProfile? Active() { var saved = Read(); return saved.Profiles.FirstOrDefault(p => p.Id == saved.Active); }
    public StudioProfile? Find(string id) => Read().Profiles.FirstOrDefault(p => p.Id == id);
    public bool Blocked(string id) => Read().Blocked?.Contains(id) == true;

    public void Save(StudioProfile profile)
    {
        if (!profile.Valid) throw new StudioException(StudioError.storage);
        var saved = Read();
        var profiles = saved.Profiles.Where(p => p.Id != profile.Id).Append(profile).ToList();
        if (profiles.Count > 64) throw new StudioException(StudioError.storage);
        Write(new(profiles, profile.Id, saved.Blocked?.Where(id => id != profile.Id).ToList()));
    }

    public void Remove(string id)
    {
        var saved = Read();
        Write(new(saved.Profiles.Where(p => p.Id != id).ToList(), saved.Active == id ? null : saved.Active, saved.Blocked));
    }
}

public interface IStudioKeyStore
{
    string? Load(string profileId);
    void Save(string profileId, string key);
    void Delete(string profileId);
}

// Keys encrypted for this Windows user with DPAPI; another user, or the same
// files copied to another machine, cannot read them.
public sealed class StudioKeyStore(string? directory = null) : IStudioKeyStore
{
    readonly string root = Path.Combine(directory ?? AgentWatchPaths.DataDirectory, "keys");
    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("agentwatch-studio-key-v1");

    string FileFor(string profileId) => profileId.Length == 64 && profileId.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f')
        ? Path.Combine(root, profileId + ".key") : throw new StudioException(StudioError.storage);

    public string? Load(string profileId)
    {
        byte[] stored;
        try { stored = File.ReadAllBytes(FileFor(profileId)); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        try
        {
            var key = Encoding.UTF8.GetString(Unprotect(stored));
            return StudioKeys.Valid(key) ? key : null;
        }
        catch (CryptographicException) { throw new StudioException(StudioError.keychainApprovalRequired); }
    }

    public void Save(string profileId, string key)
    {
        if (!StudioKeys.Valid(key)) throw new StudioException(StudioError.invalidKey);
        Directory.CreateDirectory(root);
        var file = FileFor(profileId); var temporary = file + "." + Environment.ProcessId + ".tmp";
        File.WriteAllBytes(temporary, Protect(Encoding.UTF8.GetBytes(key)));
        File.Move(temporary, file, overwrite: true);
    }

    public void Delete(string profileId) { try { File.Delete(FileFor(profileId)); } catch (DirectoryNotFoundException) { } }

    static byte[] Protect(byte[] value) => OperatingSystem.IsWindows() ? ProtectWindows(value) : DevelopmentOnly(value);
    static byte[] Unprotect(byte[] value) => OperatingSystem.IsWindows() ? UnprotectWindows(value) : DevelopmentOnly(value);
    [SupportedOSPlatform("windows")] static byte[] ProtectWindows(byte[] value) => ProtectedData.Protect(value, Entropy, DataProtectionScope.CurrentUser);
    [SupportedOSPlatform("windows")] static byte[] UnprotectWindows(byte[] value) => ProtectedData.Unprotect(value, Entropy, DataProtectionScope.CurrentUser);
    // Tests and development on macOS or Linux only; releases are Windows builds.
    static byte[] DevelopmentOnly(byte[] value) => Environment.GetEnvironmentVariable("AGENTWATCH_DATA_DIR") is { Length: > 0 } ? value
        : throw new PlatformNotSupportedException("Agent Watch for Windows stores keys with DPAPI.");
}

// Connecting with an admin-issued code: the key is checked with Studio, saved
// for its slot, and the slot becomes the active connection.
public sealed class StudioConnector(StudioProfileStore profiles, IStudioKeyStore keys, StudioClient? client = null)
{
    readonly StudioClient client = client ?? new StudioClient();

    public async Task<(StudioProfile Profile, StudioConnection Connection)> ConnectAsync(string code, CancellationToken cancellation = default)
    {
        var result = await VerifyAsync(code, cancellation);
        var key = StudioConnectionCode.Split(code)!.Value.Key;
        var previousKey = keys.Load(result.Profile.Id);
        keys.Save(result.Profile.Id, key);
        try { profiles.Save(result.Profile); }
        catch
        {
            if (previousKey is not null) keys.Save(result.Profile.Id, previousKey);
            else keys.Delete(result.Profile.Id);
            throw;
        }
        return result;
    }

    // Preview identity and models without persisting the submitted credential.
    public async Task<(StudioProfile Profile, StudioConnection Connection)> VerifyAsync(string code, CancellationToken cancellation = default)
    {
        if (StudioConnectionCode.Split(code) is not var (originText, key)) throw new StudioException(StudioError.invalidKey);
        var origin = new StudioOrigin(originText);
        var connection = await client.ConnectAsync(origin, key, cancellation);
        var active = profiles.Active();
        if (active is not null && active.Origin != origin.Value) throw new StudioException(StudioError.disconnectFirst);
        var connectionId = origin.ProfileId(connection.Identity.OrgId, connection.Identity.User.Id);
        if (active is not null && active.ConnectionId != connectionId) throw new StudioException(StudioError.disconnectFirst);
        var mode = connection.Identity.CredentialMode ?? StudioCredentialMode.direct;
        var id = connection.Identity.KeyId is { } keyId ? origin.CredentialSlotId(connection.Identity.OrgId, connection.Identity.User.Id, keyId, mode) : connectionId;
        var profile = new StudioProfile(origin.Value, id, connectionId, connection.Identity.KeyId, mode);
        return (profile, connection);
    }

    public void Disconnect(string profileId) { keys.Delete(profileId); profiles.Remove(profileId); }
}
