using System.Threading;
using System.Windows;

namespace AgentWatch.App;

// One Agent Watch per Windows user: a second start (the Start-menu entry
// while the app sits in the notification area) shows the first's window.
public partial class App : Application
{
    Mutex? single;
    EventWaitHandle? showRequest;
    RegisteredWaitHandle? showWait;
    TrayIcon? tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        single = new Mutex(true, @"Local\AgentWatch.Windows", out var first);
        showRequest = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\AgentWatch.Windows.Show");
        if (!first)
        {
            if (!e.Args.Contains("--background")) showRequest.Set();
            Shutdown();
            return;
        }
        var window = new MainWindow();
        showWait = ThreadPool.RegisterWaitForSingleObject(showRequest, (_, _) => Dispatcher.BeginInvoke(window.ShowFront), null, Timeout.Infinite, false);
        tray = new TrayIcon(window, () => { tray?.Dispose(); Shutdown(); });
        if (!e.Args.Contains("--background")) window.Show();
        _ = window.RefreshWslBindingAsync();
    }

    protected override void OnExit(ExitEventArgs e) { showWait?.Unregister(null); showRequest?.Dispose(); tray?.Dispose(); single?.Dispose(); base.OnExit(e); }
}
