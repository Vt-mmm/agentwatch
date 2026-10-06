using System.ComponentModel;
using System.IO;
using System.Windows;
using Microsoft.Win32;

namespace AgentWatch.App;

public partial class MainWindow : Window
{
    readonly StudioProfileStore profiles = new();
    readonly StudioKeyStore keys = new();
    static string Broker => Path.Combine(AppContext.BaseDirectory, "agentwatch.exe");
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public MainWindow()
    {
        InitializeComponent();
        using (var run = Registry.CurrentUser.OpenSubKey(RunKey)) StartAtLogin.IsChecked = run?.GetValue("AgentWatch") is not null;
        // The distribution setup (or an earlier bind) used, rather than WSL's default.
        Distro.Text = PiagentWslBinding.Remembered() ?? "";
        ShowStatus();
    }

    public void ShowFront() { Show(); if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal; Activate(); }

    // Closing the window keeps Agent Watch in the notification area.
    protected override void OnClosing(CancelEventArgs e) { e.Cancel = true; Hide(); }

    void ShowStatus(string? note = null)
    {
        var active = profiles.Active();
        Status.Text = note ?? (active is null ? "Chưa kết nối Studio."
            : $"Đã kết nối {active.Origin} · {(active.CredentialMode == StudioCredentialMode.managed ? "key công ty" : "key cá nhân")}.");
        DisconnectButton.IsEnabled = active is not null;
        BindButton.IsEnabled = active?.CredentialMode == StudioCredentialMode.managed;
    }

    async void Connect(object sender, RoutedEventArgs e)
    {
        ConnectButton.IsEnabled = false;
        try
        {
            var (profile, connection) = await new StudioConnector(profiles, keys).ConnectAsync(Code.Password);
            Code.Clear();
            ShowStatus($"Đã kết nối {connection.Identity.User.DisplayName} với {profile.Origin}.");
            if (profile.CredentialMode == StudioCredentialMode.managed && PiagentWslBinding.Remembered() is not null) await RefreshWslBindingAsync();
        }
        catch (StudioException error) { ShowStatus(StudioException.Describe(error.Code)); }
        finally { ConnectButton.IsEnabled = true; }
    }

    void Disconnect(object sender, RoutedEventArgs e)
    {
        if (profiles.Active() is not { } active) return;
        new StudioConnector(profiles, keys).Disconnect(active.Id);
        ShowStatus("Đã ngắt kết nối và xoá key khỏi máy này.");
    }

    async void BindWsl(object sender, RoutedEventArgs e)
    {
        BindButton.IsEnabled = false;
        await Bind(string.IsNullOrWhiteSpace(Distro.Text) ? null : Distro.Text.Trim());
        BindButton.IsEnabled = true;
    }

    public async Task RefreshWslBindingAsync()
    {
        if (PiagentWslBinding.Remembered() is not { } distro) return;
        try { await Bind(distro, quiet: true); }
        catch (Exception) { /* shown when the member binds again */ }
    }

    async Task Bind(string? distro, bool quiet = false)
    {
        try
        {
            if (profiles.Active() is not { CredentialMode: StudioCredentialMode.managed } profile || keys.Load(profile.Id) is not { } key)
            { WslStatus.Text = "Cần kết nối bằng key công ty trước."; return; }
            var manifest = await new StudioClient().ConfigurationAsync(profile.StudioOrigin, key);
            var result = await PiagentWslBinding.BindAsync(profile, manifest, Broker, new WslExe(), distro);
            PiagentWslBinding.Remember(result.Distro);
            WslStatus.Text = $"Piagent trong WSL ({result.Distro}) đã dùng được key công ty. Trong WSL chạy `piagent dashboard`.";
        }
        catch (StudioException error) { if (!quiet) WslStatus.Text = StudioException.Describe(error.Code); }
        catch (InvalidOperationException error) when (!quiet)
        {
            WslStatus.Text = error.Message switch
            {
                "wsl-runtime-unreadable" or "wsl-runtime-invalid" => "Chưa thấy Piagent trong WSL. Trong WSL: npm install -g @piagent/platform, rồi chạy `piagent --help` một lần.",
                "wsl-runtime-unsupported" => "Piagent hoặc Pi trong WSL chưa đúng bản (cần Pi 0.87.1). Chạy `piagent-update` trong WSL.",
                _ => "Không chạy được lệnh trong WSL. Cài WSL (wsl --install) với Ubuntu rồi thử lại.",
            };
        }
    }

    void ToggleStartup(object sender, RoutedEventArgs e)
    {
        using var run = Registry.CurrentUser.CreateSubKey(RunKey);
        if (StartAtLogin.IsChecked == true) run.SetValue("AgentWatch", $"\"{Environment.ProcessPath}\" --background");
        else run.DeleteValue("AgentWatch", throwOnMissingValue: false);
    }
}
