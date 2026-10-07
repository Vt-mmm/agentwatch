using System.Diagnostics;
using System.Net.Http;
using System.Windows;
using System.Windows.Threading;

namespace AgentWatch.App;

// A newer Agent Watch is said in a dialog, not left for the member to find:
// asked 30 seconds after start and then every hour. "Later" asks again at the
// next hourly check. Updating runs the same installer as the install command,
// in a visible PowerShell window; it closes this app and opens the new one.
sealed class UpdateOffer
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    readonly Window owner;
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(30) };
    bool asking;

    public UpdateOffer(Window owner)
    {
        this.owner = owner;
        Http.DefaultRequestHeaders.UserAgent.ParseAdd("AgentWatch-Windows-update-check");
        timer.Tick += async (_, _) => { timer.Interval = ReleaseCheck.Every; await CheckAsync(); };
        timer.Start();
    }

    async Task CheckAsync()
    {
        if (asking) return;
        var installed = ReleaseCheck.Installed();
        if (ReleaseCheck.Newer(await ReleaseCheck.LatestAsync(Http), installed) is not { } latest) return;
        asking = true;
        try
        {
            var text = $"Có bản Agent Watch mới: {latest} (máy đang dùng {installed}).\n\n"
                + "Cập nhật ngay sẽ đóng Agent Watch và các phiên Piagent công ty đang mở, cài bản mới rồi mở lại. "
                + "Nên cập nhật khi không có cuộc trò chuyện công ty đang chạy.\n\nChọn No để được nhắc lại sau 1 giờ.";
            var visible = owner.IsVisible ? owner : null;
            var answer = visible is null
                ? MessageBox.Show(text, "Agent Watch — Có bản mới", MessageBoxButton.YesNo, MessageBoxImage.Information, MessageBoxResult.Yes, MessageBoxOptions.DefaultDesktopOnly)
                : MessageBox.Show(visible, text, "Agent Watch — Có bản mới", MessageBoxButton.YesNo, MessageBoxImage.Information, MessageBoxResult.Yes);
            if (answer == MessageBoxResult.Yes) Install();
        }
        finally { asking = false; }
    }

    static void Install()
    {
        try
        {
            Process.Start(new ProcessStartInfo("powershell.exe", $"-NoProfile -ExecutionPolicy Bypass -Command \"{ReleaseCheck.InstallCommand}\"")
                { UseShellExecute = true });
        }
        catch (Exception error)
        {
            MessageBox.Show($"Chưa mở được trình cập nhật: {error.Message}\n\nChạy lệnh sau trong PowerShell:\n{ReleaseCheck.InstallCommand}",
                "Agent Watch", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }
}
