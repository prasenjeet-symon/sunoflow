using System;
using System.IO;
using Microsoft.Win32;

namespace SunoFlow;

/// <summary>
/// Manages the <c>SunoFlow</c> entry under the HKCU <c>Run</c> key so the tray
/// app starts automatically when the user logs in — the Windows counterpart of
/// the macOS <c>com.sunoapp.sunoflow.app</c> LaunchAgent. The single source of
/// truth is the registry itself; no mirror preference is stored, so the state
/// always reflects what Windows will actually do at boot.
/// <para>
/// Uses the per-user <c>Run</c> key (not <c>AllUsersRun</c>), which needs no
/// elevation and matches the macOS per-user LaunchAgent. The command launches
/// the app minimized-to-tray (it is a tray app — there is no window to show).
/// </para>
/// </summary>
internal static class AutoStart
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "SunoFlow";

    /// <summary><see langword="true"/> when a <c>SunoFlow</c> entry exists in
    /// the HKCU <c>Run</c> key (i.e. the app will launch at next login).</summary>
    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        return key?.GetValue(ValueName) != null;
    }

    /// <summary>Create the HKCU <c>Run</c> entry so the app launches at login.
    /// Silently logs on failure (e.g. registry locked) — never throws.</summary>
    public static void Enable()
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
            // Quote the path in case the install dir ever contains spaces.
            key?.SetValue(ValueName, $"\"{CurrentExePath}\"");
            AppLog.Log("Auto-start enabled (HKCU Run)");
        }
        catch (Exception ex)
        {
            AppLog.Log($"Failed to enable auto-start: {ex.Message}");
        }
    }

    /// <summary>Remove the HKCU <c>Run</c> entry. Silently logs if the entry
    /// was already absent.</summary>
    public static void Disable()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
            key?.DeleteValue(ValueName, throwOnMissingValue: false);
            AppLog.Log("Auto-start disabled (HKCU Run)");
        }
        catch (Exception ex)
        {
            AppLog.Log($"Failed to disable auto-start: {ex.Message}");
        }
    }

    private static string CurrentExePath =>
        Environment.ProcessPath ??
        Path.Combine(AppContext.BaseDirectory, "SunoFlow.exe");
}