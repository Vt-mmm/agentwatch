using System.Reflection;
using System.Xml.Linq;

namespace AgentWatch;

// Is a newer Agent Watch for Windows published? The installer installs the
// version named in windows/Directory.Build.props on main, so the app reads
// the same file. Releases ship several times a day: the app asks every hour.
public static class ReleaseCheck
{
    public static readonly Uri Feed = new("https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows/Directory.Build.props");
    public const string InstallCommand = "irm https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows/install.ps1 | iex";
    // What the update dialog runs: a failed update keeps its window open with
    // the reason, instead of closing before the member can read it.
    public const string UpdaterCommand = "try { " + InstallCommand + " } catch { Write-Host $_.Exception.Message -ForegroundColor Red; "
        + "Write-Host 'Chưa cập nhật được. Agent Watch đang dùng vẫn giữ nguyên; thử lại sau hoặc chạy lại lệnh cài.'; Read-Host 'Nhấn Enter để đóng' }";
    public static readonly TimeSpan Every = TimeSpan.FromHours(1);

    // How the update dialog opens the updater, tried in order. Seen on
    // 2026-10-08: an Agent Watch first started from an administrator
    // PowerShell (working directory C:\WINDOWS\system32) got "Access is
    // denied" from ShellExecute for a bare "powershell.exe". So: the full
    // path, a working directory the member owns (never app\, which the
    // installer replaces), and a plain CreateProcess first; a GUI parent has
    // no console, so the updater still gets its own window.
    public static IEnumerable<System.Diagnostics.ProcessStartInfo> UpdaterStarts(string windowsDirectory, string workingDirectory)
    {
        var arguments = $"-NoProfile -ExecutionPolicy Bypass -Command \"{UpdaterCommand}\"";
        var powershell = Path.Combine(windowsDirectory, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        yield return new(powershell, arguments) { UseShellExecute = false, WorkingDirectory = workingDirectory };
        yield return new(powershell, arguments) { UseShellExecute = true, WorkingDirectory = workingDirectory };
        yield return new("powershell.exe", arguments) { UseShellExecute = true, WorkingDirectory = workingDirectory };
    }

    public static Version? Installed(Assembly? assembly = null)
    {
        var version = (assembly ?? Assembly.GetEntryAssembly())?.GetName().Version;
        return version is null ? null : new Version(version.Major, version.Minor, Math.Max(0, version.Build));
    }

    // Only a plain x.y.z from the <Version> element counts; anything else is no answer.
    public static Version? Parse(string props)
    {
        try
        {
            var text = XDocument.Parse(props).Descendants("Version").FirstOrDefault()?.Value.Trim();
            if (text is null || text.Length > 32 || text.Count(c => c == '.') != 2 || !text.All(c => char.IsAsciiDigit(c) || c == '.')) return null;
            return Version.TryParse(text, out var version) ? version : null;
        }
        catch (System.Xml.XmlException) { return null; }
    }

    public static Version? Newer(Version? latest, Version? installed) => latest is not null && installed is not null && latest > installed ? latest : null;

    public static async Task<Version?> LatestAsync(HttpClient http, CancellationToken cancel = default)
    {
        try
        {
            using var response = await http.GetAsync(Feed, cancel);
            if (!response.IsSuccessStatusCode) return null;
            var body = await response.Content.ReadAsStringAsync(cancel);
            return body.Length > 16_384 ? null : Parse(body);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException) { return null; }
    }
}
