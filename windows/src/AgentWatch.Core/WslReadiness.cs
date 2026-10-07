namespace AgentWatch;

public sealed record WslReadiness(string Distro)
{
    public static async Task<WslReadiness> CheckAsync(IWsl wsl, string? distro)
    {
        var runtime = await PiagentWslBinding.InspectAsync(wsl, string.IsNullOrWhiteSpace(distro) ? null : distro.Trim());
        if (runtime.User == "root") throw new InvalidOperationException("wsl-root-user");
        var selected = runtime.Distro;
        await wsl.RunAsync(selected, null, "bash", "-c", """
            set -eu
            uname -r | grep -Eiq 'WSL2|microsoft-standard'
            [ "$(id -u)" != 0 ]
            [ -e /proc/sys/fs/binfmt_misc/WSLInterop ]
            [ -f "$HOME/.pi/agent/piagent-runtime.json" ]
            command -v bwrap >/dev/null
            bwrap --unshare-user --unshare-pid --ro-bind / / --proc /proc --dev /dev true
            """.ReplaceLineEndings("\n"));
        return new(selected);
    }
}
