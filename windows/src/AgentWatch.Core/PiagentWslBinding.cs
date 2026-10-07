using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AgentWatch;

// Runs a program inside a WSL distribution (wsl.exe -d <distro> -e …).
public interface IWsl
{
    Task<string> RunAsync(string? distro, string? input, params string[] command);
}

// A WSL command that failed, with what the member needs to see: its exit code
// and first error line (never the command's input).
public sealed class WslCommandException(string detail) : InvalidOperationException("wsl-command-failed")
{
    public string Detail { get; } = detail;
}

public sealed class WslExe : IWsl
{
    public async Task<string> RunAsync(string? distro, string? input, params string[] command)
    {
        var start = new ProcessStartInfo("wsl.exe") { RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = input is not null,
            UseShellExecute = false, CreateNoWindow = true, StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false) };
        if (distro is not null) { start.ArgumentList.Add("-d"); start.ArgumentList.Add(distro); }
        start.ArgumentList.Add("-e");
        foreach (var part in command) start.ArgumentList.Add(part);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("wsl-unavailable");
        if (input is not null)
        {
            await process.StandardInput.BaseStream.WriteAsync(new UTF8Encoding(false).GetBytes(input));
            process.StandardInput.Close();
        }
        // Both streams at once: an unread stderr could fill and stall the command.
        var reading = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        var output = await reading;
        if (process.ExitCode != 0)
        {
            // wsl.exe's own messages are UTF-16: drop the NULs read as UTF-8.
            var error = (await errors).Replace("\0", "").Trim();
            if (error.Contains("no-runtime", StringComparison.Ordinal)) throw new InvalidOperationException("wsl-runtime-unreadable");
            var first = error.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault() ?? "";
            throw new WslCommandException($"exit {process.ExitCode}{(first.Length > 0 ? ": " + first[..Math.Min(first.Length, 200)] : "")}");
        }
        return output;
    }
}

// Company conversations on Windows run in WSL2: Piagent there starts this
// app's broker (a Windows program, through WSL's interop) and checks the
// binding Agent Watch writes into the distribution, as on macOS
// (StudioManagedConfiguration.swift): the Piagent launcher, the Node running
// it and the broker, each pinned by its SHA-256.
public static class PiagentWslBinding
{
    public sealed record Result(string Distro, string File, string Entrypoint, string Node, string Broker);
    // What a binding would pin, read inside WSL without writing anything.
    public sealed record Runtime(string Distro, string User, string Home, string Entrypoint, string Node, string SdkRoot, string EntrypointSha256, string NodeSha256, string PiVersion);

    // The script runs in WSL with the runtime Piagent recorded
    // (~/.pi/agent/piagent-runtime.json, written by every `piagent` command)
    // and prints the resolved paths and digests.
    const string Inspect = """
        set -eu
        file="$HOME/.pi/agent/piagent-runtime.json"
        [ -f "$file" ] || { echo "no-runtime" >&2; exit 3; }
        cat "$file"
        echo
        echo "--home--"
        printf '%s\n' "$HOME"
        echo "--user--"
        id -un
        """;

    public static async Task<Runtime> InspectAsync(IWsl wsl, string? distro = null)
    {
        distro ??= (await wsl.RunAsync(null, null, "sh", "-c", "printf %s \"$WSL_DISTRO_NAME\"")).Trim();
        if (distro.Length == 0) throw new InvalidOperationException("wsl-distro-unknown");
        var inspected = await wsl.RunAsync(distro, null, "sh", "-c", Inspect);
        var parts = inspected.Split("--home--", 2);
        if (parts.Length != 2) throw new InvalidOperationException("wsl-runtime-unreadable");
        var tail = parts[1].Split("--user--", 2);
        var (home, user) = (tail[0].Trim(), tail.Length == 2 ? tail[1].Trim() : "");
        var runtime = JsonNode.Parse(parts[0]) as JsonObject;
        string Path(string name) => runtime?[name]?.GetValue<string>() is { } value && value.StartsWith('/') ? value : throw new InvalidOperationException("wsl-runtime-invalid");
        if (runtime?["schema_version"]?.GetValue<int>() != 1) throw new InvalidOperationException("wsl-runtime-invalid");
        var (entrypoint, node, sdk) = (Path("entrypoint"), Path("node"), Path("pi_sdk_root"));
        // Real paths, digests and the Pi host's version, read inside WSL.
        var facts = (await wsl.RunAsync(distro, null, "sh", "-c",
            "set -eu; e=$(realpath \"$1\"); n=$(realpath \"$2\"); s=$(realpath \"$3\"); printf '%s\\n%s\\n%s\\n' \"$e\" \"$n\" \"$s\"; sha256sum \"$e\" \"$n\" | cut -d ' ' -f 1; \"$n\" -p 'require(process.argv[1]).version' \"$s/package.json\"",
            "piagent-binding", entrypoint, node, sdk)).Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (facts.Length != 6 || !facts[0].EndsWith("/scripts/piagent-studio.mjs", StringComparison.Ordinal) || facts[5] != "0.87.1"
            || facts[3].Length != 64 || facts[4].Length != 64) throw new InvalidOperationException("wsl-runtime-unsupported");
        return new Runtime(distro, user, home, facts[0], facts[1], facts[2], facts[3], facts[4], facts[5]);
    }

    public static async Task<Result> BindAsync(StudioProfile profile, StudioManifest manifest, string brokerWindowsPath, IWsl wsl, string? distro = null)
    {
        if (profile.CredentialMode != StudioCredentialMode.managed || manifest.Harness is null) throw new StudioException(StudioError.permissionDenied);
        manifest.Validate(profile);
        var runtime = await InspectAsync(wsl, distro);
        distro = runtime.Distro;
        var broker = (await wsl.RunAsync(distro, null, "wslpath", "-u", brokerWindowsPath)).Trim();
        if (!broker.StartsWith("/mnt/", StringComparison.Ordinal)) throw new InvalidOperationException("wsl-broker-path");
        var binding = new JsonObject
        {
            ["schema_version"] = 1, ["model"] = "agent-watch-auto", ["profile_id"] = profile.Id, ["origin"] = profile.Origin,
            ["node"] = runtime.Node, ["entrypoint"] = runtime.Entrypoint, ["node_sha256"] = runtime.NodeSha256, ["entrypoint_sha256"] = runtime.EntrypointSha256,
            ["sdk_root"] = runtime.SdkRoot, ["broker"] = broker, ["broker_sha256"] = Sha256(brokerWindowsPath),
            ["configuration_revision"] = manifest.Revision,
        };
        await wsl.RunAsync(distro, binding.ToJsonString(new() { WriteIndented = true }) + "\n", "sh", "-c",
            "set -eu; umask 077; d=\"$HOME/.pi/agent\"; mkdir -p \"$d\"; cat > \"$d/agent-watch-managed.json.tmp\"; mv \"$d/agent-watch-managed.json.tmp\" \"$d/agent-watch-managed.json\"");
        return new Result(distro, runtime.Home + "/.pi/agent/agent-watch-managed.json", runtime.Entrypoint, runtime.Node, broker);
    }

    // The distribution last bound, kept so a later start of the app (after an
    // update changed agentwatch.exe) writes the binding again.
    public static string RememberedFile => Path.Combine(AgentWatchPaths.DataDirectory, "wsl.json");

    public static void Remember(string distro)
    {
        Directory.CreateDirectory(AgentWatchPaths.DataDirectory);
        File.WriteAllText(RememberedFile, JsonSerializer.Serialize(new { distro }));
    }

    public static string? Remembered()
    {
        try { return JsonDocument.Parse(File.ReadAllText(RememberedFile)).RootElement.GetProperty("distro").GetString(); }
        catch (Exception error) when (error is IOException or JsonException or KeyNotFoundException or InvalidOperationException or UnauthorizedAccessException) { return null; }
    }

    static string Sha256(string file)
    {
        using var stream = File.OpenRead(file);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }
}
