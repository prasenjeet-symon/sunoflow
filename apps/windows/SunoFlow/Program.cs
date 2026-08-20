using System;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// Entry point. SunoFlow is a tray app — it has no main window, just a
/// NotifyIcon with a menu. Double-clicking a Windows Forms app needs the
/// <c>STAThread</c> pump; the tray icon lives for the whole process lifetime.
/// </summary>
internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        // Single-instance: a second launch opens Settings on the running copy.
        if (SingleInstance.TryAcquire("SunoFlow-{A8F3C2E1-1B2D-4E5F-9A6C-7D8E9F0A1B2C}",
            out _))
        {
            // We're the second launch. Tell the running instance to show Settings.
            SingleInstance.NotifyRunningInstance();
            return;
        }

        ApplicationConfiguration.Initialize();
        AppLog.Log("=== SunoFlow launched (Windows) ===");

        using var app = new TrayApp();
        // The running instance listens for the "open settings" ping.
        SingleInstance.OpenSettingsRequested += (s, e) => app.OpenSettings();
        SingleInstance.StartServer();

        Application.Run();
    }
}

/// <summary>WinForms marshalling helpers. A bare lambda can't convert to
/// <c>Delegate</c>, so these wrap the common <c>BeginInvoke(Action)</c> case
/// used across the app's async continuations.</summary>
internal static class ControlExtensions
{
    public static void BeginInvoke(this Control c, Action action) =>
        c.BeginInvoke(action);
}