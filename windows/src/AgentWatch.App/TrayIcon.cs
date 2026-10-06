using System.Drawing;
using System.Windows.Forms;

namespace AgentWatch.App;

// The notification-area icon: open the window, or quit.
sealed class TrayIcon : IDisposable
{
    readonly NotifyIcon icon;

    public TrayIcon(MainWindow window, Action quit)
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Mở Agent Watch", null, (_, _) => window.ShowFront());
        menu.Items.Add("Thoát", null, (_, _) => quit());
        icon = new NotifyIcon { Icon = SystemIcons.Shield, Text = "Agent Watch", ContextMenuStrip = menu, Visible = true };
        icon.DoubleClick += (_, _) => window.ShowFront();
    }

    public void Dispose() { icon.Visible = false; icon.Dispose(); }
}
