using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace SunoFlow;

/// <summary>
/// What the OS knows about where a dictation is going — the Windows counterpart
/// of <c>ForegroundApp.swift</c>: which process owns the foreground window and what
/// that window is called.
///
/// This is the cheapest context the app collects. Screen OCR costs a capture, a
/// downscale and an OCR pass; this costs two Win32 calls and no pixels, and
/// unlike anything inferred from a screenshot it is <b>observed</b> rather than
/// guessed — the process name is the application's own name for itself.
///
/// It travels to the cleanup gateway for two purposes, and the split matters:
/// the <b>prompt</b> gets the app, its kind and the window title as reference
/// material, in the same sense the cursor context and the screen words are;
/// <b>analytics</b> gets only the category and, for applications the gateway
/// already has a name for, that name. The title is never counted — it is the
/// part that carries content.
///
/// <b>No permission is required and none is requested.</b> The foreground
/// window's title is readable by any process; there is no Windows analogue of
/// the macOS Accessibility grant for this.
///
/// Best-effort throughout: every failure is an empty field, never an exception
/// and never a blocked dictation.
/// </summary>
internal static class ForegroundApp
{
    /// <summary>One reading of the foreground application.</summary>
    internal readonly record struct Snapshot(string Id, string Site, string Detail)
    {
        public static Snapshot Empty => new("", "", "");
        public bool IsEmpty => Id.Length == 0 && Site.Length == 0 && Detail.Length == 0;
    }

    /// Titles longer than this are truncated before they are sent. The gateway
    /// caps them again; this just avoids carrying a pathological one over the
    /// wire. A browser tab can hold a whole headline.
    private const int MaxTitle = 200;

    /// <summary>
    /// Reads the foreground application. Returns <see cref="Snapshot.Empty"/>
    /// rather than throwing.
    /// </summary>
    /// <remarks>
    /// The site is left empty on Windows. macOS reads the address straight out
    /// of the browser's Accessibility tree; the equivalent here is UI Automation,
    /// which is not in-box for this project's target framework and would be a new
    /// dependency for one field. Until then the gateway recovers well-known
    /// services from the tab title instead, which is why the title is worth
    /// sending even when it looks redundant.
    /// </remarks>
    public static Snapshot Capture()
    {
        try
        {
            var hwnd = GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return Snapshot.Empty;

            // Our own windows are never a dictation target, and reporting
            // SunoFlow as the app someone dictates into would be self-referential
            // noise in the numbers.
            GetWindowThreadProcessId(hwnd, out uint pid);
            if (pid == 0 || pid == (uint)Environment.ProcessId) return Snapshot.Empty;

            string id = "";
            try
            {
                using var proc = Process.GetProcessById((int)pid);
                // The catalog is keyed on the executable name, which is what
                // matches the macOS bundle id for the same product.
                if (!string.IsNullOrEmpty(proc.ProcessName)) id = proc.ProcessName + ".exe";
            }
            catch { /* process gone, or access denied for an elevated app */ }

            return new Snapshot(id, "", Title(hwnd));
        }
        catch (Exception ex)
        {
            AppLog.Log($"App context failed: {ex.Message}");
            return Snapshot.Empty;
        }
    }

    private static string Title(IntPtr hwnd)
    {
        int length = GetWindowTextLength(hwnd);
        if (length <= 0) return "";
        var buffer = new StringBuilder(length + 1);
        if (GetWindowText(hwnd, buffer, buffer.Capacity) == 0) return "";
        var title = buffer.ToString().Trim();
        return title.Length > MaxTitle ? title[..MaxTitle] : title;
    }

    // --- Win32 -------------------------------------------------------------------

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
}
