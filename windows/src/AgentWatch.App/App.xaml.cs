using System.Threading;
using System.Windows;

namespace AgentWatch.App;

// One Agent Watch per Windows user: a second start shows the first's window.
public partial class App : Application
{
    Mutex? single;
    TrayIcon? tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        single = new Mutex(true, @"Local\AgentWatch.Windows", out var first);
        if (!first) { Shutdown(); return; }
        var window = new MainWindow();
        tray = new TrayIcon(window, () => { tray?.Dispose(); Shutdown(); });
        if (!e.Args.Contains("--background")) window.Show();
        _ = window.RefreshWslBindingAsync();
    }

    protected override void OnExit(ExitEventArgs e) { tray?.Dispose(); single?.Dispose(); base.OnExit(e); }
}
