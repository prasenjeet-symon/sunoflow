using System;
using System.IO;
using System.Text;

namespace SunoFlow;

/// <summary>
/// Simple append-only file logger mirroring the macOS <c>AppLog</c>. Logs go
/// to <c>%LOCALAPPDATA%/SunoFlow/app-debug.log</c> — a stable, user-writable
/// path that survives reinstalls, matching the macOS <c>~/Library/Logs</c>
/// convention.
/// </summary>
internal static class AppLog
{
    private static readonly string LogDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SunoFlow");

    private static readonly string LogPath = Path.Combine(LogDir, "app-debug.log");

    internal static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(LogDir);
            var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}{Environment.NewLine}";
            File.AppendAllText(LogPath, line, Encoding.UTF8);
        }
        catch
        {
            // Logging is best-effort — never crash the app because we couldn't write a log.
        }
    }
}