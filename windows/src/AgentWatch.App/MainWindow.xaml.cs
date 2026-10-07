using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;

namespace AgentWatch.App;

public partial class MainWindow : Window
{
    readonly StudioProfileStore profiles = new();
    readonly StudioKeyStore keys = new();
    readonly SetupProgress setup = new();
    static string WslFile => Path.Combine(AgentWatchPaths.DataDirectory, "wsl.json");
    static string Broker => Path.Combine(AppContext.BaseDirectory, "agentwatch.exe");
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string SetupCommand = "irm https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows/setup.ps1 | iex";
    bool busy, initialized, ready;
    string view = "setup", draftCode = "", checkedDistro = "", lastCheck = "Chưa kiểm tra";
    StudioConnection? preview;

    public MainWindow()
    {
        InitializeComponent();
        try
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey);
            StartAtLogin.IsChecked = run?.GetValue("AgentWatch") is not null;
            LoadDistributions();
            if (File.Exists(WslFile)) Distro.Text = ReadDistribution() ?? "";
            if (profiles.Active() is { } active)
            {
                ExistingCard.Visibility = Visibility.Visible;
                ExistingSummary.Text = active.Origin + " · Key đã lưu trên máy";
                view = "tools";
            }
            Status.Text = "Thiết lập thủ công · bạn kiểm tra và chọn trước khi áp dụng.";
            UpdateConnection();
        }
        catch (Exception error) { Status.Text = Describe(error); }
        initialized = true;
        Render();
    }

    public void ShowFront() { Show(); if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal; Activate(); }
    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        // Discard an uncommitted key when leaving setup. Saved profiles survive.
        if (!busy) ClearDraft();
        Hide();
    }

    static string? ReadDistribution()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(WslFile));
        return document.RootElement.GetProperty("distro").GetString();
    }

    static string Describe(Exception error) => error switch
    {
        StudioException studio => StudioException.Describe(studio.Code),
        WslCommandException failed => "Không chạy được WSL (" + failed.Detail + "). Mở Ubuntu để kiểm tra rồi thử lại.",
        InvalidOperationException invalid => invalid.Message switch
        {
            "wsl-runtime-unreadable" or "wsl-runtime-invalid" => "Chưa thấy Piagent hợp lệ trong WSL. Chạy trình thiết lập ở bước 3 rồi kiểm tra lại.",
            "wsl-runtime-unsupported" => "Piagent hoặc Pi trong WSL chưa tương thích (cần Pi 0.87.1). Cập nhật Piagent rồi thử lại.",
            "wsl-root-user" => "Ubuntu đang dùng root. Chạy lại trình thiết lập để đặt tài khoản Linux của bạn rồi kiểm tra lại.",
            "wsl-timeout" => "WSL không phản hồi sau 2 phút. Mở Ubuntu để hoàn tất thiết lập rồi thử lại.",
            _ => "Chưa kiểm tra được WSL2, tài khoản Linux hoặc sandbox. Mở Ubuntu và chạy trình thiết lập để xem bước cần sửa.",
        },
        Win32Exception => "Không khởi chạy được WSL. Cài WSL2, mở Ubuntu một lần rồi thử lại.",
        IOException or UnauthorizedAccessException => "Không đọc hoặc lưu được dữ liệu. Kiểm tra quyền truy cập thư mục Agent Watch rồi thử lại.",
        JsonException or KeyNotFoundException => "Cấu hình đã lưu không hợp lệ. Chạy lại thiết lập WSL hoặc kết nối lại Studio.",
        _ => "Thao tác chưa hoàn tất. Kiểm tra kết nối và thử lại; nếu vẫn lỗi, liên hệ quản trị viên.",
    };

    void Render()
    {
        var pages = new[] { Page0, Page1, Page2, Page3 };
        for (var i = 0; i < pages.Length; i++) { pages[i].Visibility = view == "setup" && setup.Step == i ? Visibility.Visible : Visibility.Collapsed; pages[i].IsEnabled = !busy; }
        Steps.Visibility = Footer.Visibility = view == "setup" ? Visibility.Visible : Visibility.Collapsed;
        ToolsPage.Visibility = view == "tools" ? Visibility.Visible : Visibility.Collapsed;
        DiagnosticsPage.Visibility = view == "diagnostics" ? Visibility.Visible : Visibility.Collapsed;
        ToolsPage.IsEnabled = DiagnosticsPage.IsEnabled = !busy;
        SetupNav.IsEnabled = ToolsNav.IsEnabled = DiagnosticsNav.IsEnabled = !busy;
        BackButton.IsEnabled = !busy && setup.Step > 0;
        NextButton.IsEnabled = !busy && (setup.Step == 3 ? setup.CredentialsVerified && setup.RuntimeVerified : setup.CanAdvance);
        NextButton.Content = setup.Step == 3 ? "Áp dụng thiết lập" : "Tiếp tục →";
        Progress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        var labels = new[] { StepLabel0, StepLabel1, StepLabel2, StepLabel3 };
        for (var i = 0; i < labels.Length; i++)
        {
            labels[i].Foreground = new SolidColorBrush(i == setup.Step ? Color.FromRgb(183, 94, 67) : Color.FromRgb(111, 107, 90));
            labels[i].FontWeight = i == setup.Step ? FontWeights.SemiBold : FontWeights.Normal;
        }
        string[] titles = ["Bắt đầu với Agent Watch", "Kết nối đúng Studio, đúng key", "Chuẩn bị môi trường làm việc", "Mọi lựa chọn, trước khi áp dụng"];
        string[] descriptions = ["Bốn bước rõ ràng để dùng Piagent với tài khoản công ty.", "Xác minh thông tin được cấp. Key chưa được lưu ở bước này.", "Chọn bản WSL, kiểm tra Piagent và sandbox trước khi tiếp tục.", "Xem lại tài khoản, công cụ và tuỳ chọn khởi động."];
        Eyebrow.Text = view == "setup" ? $"THIẾT LẬP · {setup.Step + 1} / 4" : "STUDIO · WINDOWS";
        PageTitle.Text = view == "setup" ? titles[setup.Step] : view == "tools" ? "Công cụ & kết nối" : "Chẩn đoán";
        PageDescription.Text = view == "setup" ? descriptions[setup.Step] : view == "tools" ? "Trạng thái tài khoản và công cụ trên máy của bạn." : "Kiểm tra kết nối và tìm bước cần xử lý.";
        FooterHint.Text = setup.Step switch { 1 => "Kiểm tra key để tiếp tục.", 2 => "Kiểm tra WSL để tiếp tục.", 3 => "Chỉ lưu khi bạn áp dụng.", _ => "Có thể quay lại để sửa lựa chọn." };
        if (setup.Step == 3) ReviewSummary.Text = $"Tài khoản: {preview?.Identity.User.DisplayName}\nStudio: {StudioConnectionCode.Split(draftCode)?.Origin}\nCông cụ: Piagent công ty\nMôi trường: {checkedDistro} · WSL2\nModel: {ModelSummary(preview)}\nKey: được ẩn · lưu bằng Windows DPAPI";
        LaunchButton.IsEnabled = ready && !busy;
    }

    static string ModelSummary(StudioConnection? connection) => connection?.Models is { } models
        ? models.Length == 0 ? "Studio chưa cấp model nào." : string.Join(" · ", models.Select(m => m.DisplayName))
        : "Chưa tải được danh sách model; kiểm tra lại kết nối.";

    async Task RunAsync(string message, Func<Task> action)
    {
        if (busy) return;
        busy = true; Status.Text = message; Render();
        try { await action(); }
        catch (Exception error) { Status.Text = Describe(error); }
        finally { busy = false; if (!IsVisible) ClearDraft(); Render(); }
    }

    void CredentialsChanged(object sender, RoutedEventArgs e)
    {
        if (!initialized) return;
        setup.CredentialsChanged(); draftCode = ""; preview = null;
        IdentitySummary.Text = "Thông tin đã thay đổi. Kiểm tra lại trước khi tiếp tục.";
        Render();
    }
    void ChangeInputMode(object sender, RoutedEventArgs e)
    {
        if (!initialized) return;
        CodeFields.Visibility = CodeMode.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        SeparateFields.Visibility = CodeMode.IsChecked == true ? Visibility.Collapsed : Visibility.Visible;
        CredentialsChanged(sender, e);
    }
    string InputCode() => CodeMode.IsChecked == true ? Code.Password.Trim() : Origin.Text.Trim().TrimEnd('/') + "#" + Key.Password.Trim();

    async Task VerifyCode(string code)
    {
        setup.CredentialsChanged(); draftCode = ""; preview = null;
        var result = await new StudioConnector(profiles, keys).VerifyAsync(code);
        if (result.Profile.CredentialMode != StudioCredentialMode.managed)
            throw new StudioException(StudioError.permissionDenied);
        draftCode = code; preview = result.Connection;
        setup.VerifyCredentials();
        IdentitySummary.Text = $"Đã xác minh · {preview.Identity.User.DisplayName}\n{result.Profile.Origin}\n{ModelSummary(preview)}";
        Status.Text = "Key hợp lệ. Bạn có thể tiếp tục chọn môi trường WSL.";
    }
    async void VerifyCredentials(object sender, RoutedEventArgs e) => await RunAsync("Đang kiểm tra Studio và key…", () => VerifyCode(InputCode()));
    async void ReuseConnection(object sender, RoutedEventArgs e) => await RunAsync("Đang kiểm tra key đã lưu…", async () =>
    {
        if (profiles.Active() is not { } active || keys.Load(active.Id) is not { } key) throw new StudioException(StudioError.invalidKey);
        setup.Reset(); setup.Advance();
        await VerifyCode(active.Origin + "#" + key);
        setup.Advance();
    });

    void LoadDistributions()
    {
        var selected = Distro.Text;
        var names = new List<string>();
        using var root = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss");
        foreach (var name in root?.GetSubKeyNames() ?? [])
        {
            using var distro = root?.OpenSubKey(name);
            if (distro?.GetValue("DistributionName") is string value) names.Add(value);
        }
        Distro.ItemsSource = names.OrderBy(n => n).ToArray();
        Distro.Text = selected;
    }
    void ReloadDistributions(object sender, RoutedEventArgs e)
    {
        try { LoadDistributions(); Status.Text = "Đã tải lại danh sách WSL. Chọn bản phân phối rồi kiểm tra."; }
        catch (Exception error) { Status.Text = Describe(error); }
    }
    void DistributionChanged(object sender, TextChangedEventArgs e)
    {
        if (!initialized) return;
        setup.RuntimeChanged(); checkedDistro = "";
        WslStatus.Text = "Lựa chọn đã thay đổi. Kiểm tra lại WSL trước khi tiếp tục.";
        Render();
    }
    async void CheckWsl(object sender, RoutedEventArgs e) => await RunAsync("Đang kiểm tra WSL2, Piagent và sandbox…", async () =>
    {
        setup.RuntimeChanged();
        WslStatus.Text = "Đang kiểm tra…";
        try
        {
            var result = await WslReadiness.CheckAsync(new WslExe(), Distro.Text);
            Distro.Text = result.Distro;
            checkedDistro = result.Distro;
            setup.VerifyRuntime();
            WslStatus.Text = $"Đã kiểm tra · {result.Distro}\nWSL2 · tài khoản Linux · runtime Piagent · sandbox · Windows interop";
            Status.Text = "Môi trường sẵn sàng. Tiếp tục để xem lại lựa chọn.";
        }
        catch (Exception error) { WslStatus.Text = Describe(error); throw; }
    });

    async void GoNext(object sender, RoutedEventArgs e)
    {
        if (setup.Step != 3) { if (setup.CanAdvance) setup.Advance(); Render(); return; }
        await RunAsync("Đang lưu kết nối và áp dụng Piagent…", async () =>
        {
            await WslReadiness.CheckAsync(new WslExe(), checkedDistro);
            var (profile, connection) = await new StudioConnector(profiles, keys).ConnectAsync(draftCode);
            // A failed binding keeps the valid saved key so retrying can finish.
            ApplySummary.Text = "Đã lưu key. Đang kết nối Piagent…";
            ready = false;
            var key = keys.Load(profile.Id) ?? throw new StudioException(StudioError.invalidKey);
            await Bind(profile, key, checkedDistro);
            SetStartup();
            setup.Complete();
            UpdateConnection(connection);
            ClearDraft();
            view = "tools";
            Status.Text = "Đã hoàn tất thiết lập. Mở Piagent để bắt đầu làm việc.";
        });
    }
    void GoBack(object sender, RoutedEventArgs e) { setup.Back(); Render(); }
    void ClearDraft()
    {
        initialized = false;
        Code.Clear(); Key.Clear(); draftCode = ""; preview = null; setup.Reset();
        IdentitySummary.Text = ""; ApplySummary.Text = "";
        initialized = true;
        Render();
    }
    void ShowSetup(object sender, RoutedEventArgs e) { view = "setup"; Render(); }
    void ShowTools(object sender, RoutedEventArgs e) { ClearDraft(); view = "tools"; Render(); }
    void ShowDiagnostics(object sender, RoutedEventArgs e) { ClearDraft(); view = "diagnostics"; Render(); }

    void SetStartup()
    {
        using var run = Registry.CurrentUser.CreateSubKey(RunKey);
        if (StartAtLogin.IsChecked == true) run.SetValue("AgentWatch", $"\"{Environment.ProcessPath}\" --background");
        else run.DeleteValue("AgentWatch", throwOnMissingValue: false);
    }
    async Task Bind(StudioProfile profile, string key, string? distro)
    {
        var manifest = await new StudioClient().ConfigurationAsync(profile.StudioOrigin, key);
        var result = await PiagentWslBinding.BindAsync(profile, manifest, Broker, new WslExe(), distro);
        PiagentWslBinding.Remember(result.Distro);
        ready = true; checkedDistro = result.Distro;
        ToolBadge.Text = "Đã kết nối";
        ToolDetail.Text = $"Piagent công ty · {result.Distro} / WSL2\nMở dashboard để chọn project và bắt đầu.";
    }
    void UpdateConnection(StudioConnection? connection = null)
    {
        var active = profiles.Active();
        ConnectionTitle.Text = connection?.Identity.User.DisplayName ?? (active is null ? "Chưa kết nối Studio" : "Key đã lưu · cần kiểm tra");
        ConnectionSummary.Text = active?.Origin ?? "Mở Thiết lập từng bước để kết nối tài khoản công ty.";
        DisconnectButton.IsEnabled = active is not null;
        ExistingCard.Visibility = active is null ? Visibility.Collapsed : Visibility.Visible;
        ExistingSummary.Text = active?.Origin ?? "";
        ModelsSummary.Text = ModelSummary(connection);
        DiagnosticsSummary.Text = $"Phiên bản: {StudioClient.UserAgent}\nStudio: {active?.Origin ?? "Chưa kết nối"}\nKey: {(active is null ? "Chưa lưu" : "Đã lưu bằng Windows DPAPI")}\nWSL: {(ready ? checkedDistro : "Chưa xác minh")}\nPiagent: {(ready ? "Đã kết nối" : "Chưa xác minh")}\nKiểm tra gần nhất: {lastCheck}";
    }
    public async Task RefreshWslBindingAsync() => await Refresh();
    async void RefreshConnection(object sender, RoutedEventArgs e) => await Refresh();
    async Task Refresh() => await RunAsync("Đang kiểm tra lại Studio và Piagent…", async () =>
    {
        ready = false; ToolBadge.Text = "Chưa xác minh";
        lastCheck = DateTimeOffset.Now.ToString("HH:mm dd/MM/yyyy");
        try
        {
            if (profiles.Active() is not { } active || keys.Load(active.Id) is not { } key)
            { UpdateConnection(); Status.Text = "Chưa có kết nối. Mở Thiết lập từng bước để bắt đầu."; return; }
            var connection = await new StudioClient().ConnectAsync(active.StudioOrigin, key);
            UpdateConnection(connection);
            if (active.CredentialMode == StudioCredentialMode.managed && File.Exists(WslFile))
            {
                var distro = ReadDistribution();
                await WslReadiness.CheckAsync(new WslExe(), distro);
                await Bind(active, key, distro);
                UpdateConnection(connection);
            }
            Status.Text = ready ? "Đã kiểm tra kết nối Studio và Piagent." : "Đã xác minh Studio. Mở Thiết lập để kết nối Piagent trong WSL.";
        }
        catch { UpdateConnection(); throw; }
    });
    async void Disconnect(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "Xoá key đã lưu trên máy? Các phiên Piagent đang chạy có thể còn quyền đến khi token hết hạn. Đóng các phiên đó hoặc nhờ quản trị viên thu hồi key nếu cần ngắt ngay.", "Ngắt kết nối Studio", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        await RunAsync("Đang ngắt kết nối…", () =>
        {
            if (profiles.Active() is { } active) new StudioConnector(profiles, keys).Disconnect(active.Id);
            ready = false; ToolBadge.Text = "Chưa kết nối"; ToolDetail.Text = "Thiết lập lại để dùng Piagent công ty.";
            ClearDraft(); UpdateConnection(); view = "setup";
            Status.Text = "Đã xoá key trên máy. Project và hội thoại được giữ lại.";
            return Task.CompletedTask;
        });
    }
    void CopySetup(object sender, RoutedEventArgs e) => Copy(SetupCommand, "Đã sao chép. Chạy lệnh trong PowerShell rồi quay lại kiểm tra WSL.");
    void CopyDiagnostics(object sender, RoutedEventArgs e) => Copy(DiagnosticsSummary.Text, "Đã sao chép thông tin hỗ trợ, không kèm key hoặc nội dung hội thoại.");
    void Copy(string value, string success)
    {
        try { Clipboard.SetText(value); Status.Text = success; }
        catch (Exception) { Status.Text = "Clipboard chưa sẵn sàng. Thử sao chép lại."; }
    }
    void LaunchPiagent(object sender, RoutedEventArgs e)
    {
        if (!ready) return;
        try
        {
            var start = new ProcessStartInfo("wsl.exe") { UseShellExecute = false };
            foreach (var arg in new[] { "-d", checkedDistro, "--cd", "~", "-e", "bash", "-lic", "piagent dashboard; exec bash" }) start.ArgumentList.Add(arg);
            Process.Start(start);
        }
        catch (Exception error) { Status.Text = Describe(error); }
    }
}
