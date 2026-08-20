using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// Watches what the user changes after a dictation is pasted, and feeds the
/// (pasted, edited) pair to the sidecar so it can learn recurring corrections.
/// Windows counterpart of <c>EditLearner.swift</c>.
///
/// On macOS the snapshot comes from the Accessibility API (AXUIElement). On
/// Windows there's no single cross-app "focused field text" API; the most
/// reliable broadly-available source is <c>WM_GETTEXT</c> on the focused
/// window's edit control, which works for standard Win32 edit fields and many
/// Electron/Chromium fields. This is a best-effort learner — if we can't read
/// the field, we just don't learn, which is the same graceful degradation as
/// the macOS version when Accessibility isn't granted.
/// </summary>
internal sealed class EditLearner
{
    private class Pending
    {
        public IntPtr Handle { get; set; }
        public string Snapshot { get; set; } = "";
    }

    private Pending? _pending;
    private System.Threading.Timer? _fallbackTimer;

    private const int MaxSnapshotChars = 4000;
    private const int FallbackDelayMs = 30_000;

    /// <summary>Call right after we paste text into the focused field.</summary>
    public void NoteInsertion()
    {
        // Read slightly later so the simulated Ctrl+V has actually landed.
        // Matches the macOS 0.5s delay.
        Task.Delay(500).ContinueWith(_ =>
        {
            var hwnd = GetFocusedEditHandle();
            if (hwnd == IntPtr.Zero) return;
            var text = ReadWindowText(hwnd);
            if (text == null) return;
            _pending = new Pending { Handle = hwnd, Snapshot = Clamp(text) };
            _fallbackTimer?.Dispose();
            _fallbackTimer = new System.Threading.Timer(_ => CaptureIfNeeded(), null, FallbackDelayMs, Timeout.Infinite);
        }, TaskScheduler.Default);
    }

    /// <summary>Compare the snapshot against the field's current text and learn the diff.
    /// Safe to call anytime; a no-op if there's nothing pending.</summary>
    public void CaptureIfNeeded()
    {
        _fallbackTimer?.Dispose();
        _fallbackTimer = null;
        var pending = _pending;
        _pending = null;
        if (pending == null) return;

        var current = ReadWindowText(pending.Handle);
        if (current == null) return;
        var edited = Clamp(current);
        if (string.IsNullOrEmpty(edited) || edited == pending.Snapshot) return;

        _ = TranscriptionClient.LearnAsync(pending.Snapshot, edited).ContinueWith(t =>
        {
            if (t.IsCompletedSuccessfully && t.Result > 0)
                AppLog.Log($"Learned {t.Result} correction(s) from your edits");
        });
    }

    /// <summary>Get the focused window's edit-control handle (best-effort).</summary>
    private static IntPtr GetFocusedEditHandle()
    {
        var focused = GetForegroundWindow();
        if (focused == IntPtr.Zero) return IntPtr.Zero;
        var gui = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        var tid = GetWindowThreadProcessId(focused, out _);
        if (GetGUIThreadInfo(tid, ref gui))
        {
            if (gui.hwndFocus != IntPtr.Zero) return gui.hwndFocus;
        }
        return focused;
    }

    private static string? ReadWindowText(IntPtr hwnd)
    {
        try
        {
            int len = SendMessage(hwnd, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero).ToInt32();
            if (len <= 0) return null;
            var sb = new StringBuilder(len + 1);
            SendMessage(hwnd, WM_GETTEXT, (IntPtr)(len + 1), sb);
            return sb.ToString();
        }
        catch { return null; }
    }

    private static string Clamp(string text) =>
        text.Length > MaxSnapshotChars ? text[^MaxSnapshotChars..] : text;

    // --- Win32 -------------------------------------------------------------------

    private const int WM_GETTEXT = 0x000D;
    private const int WM_GETTEXTLENGTH = 0x000E;

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    private static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, StringBuilder lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct GUITHREADINFO
    {
        public int cbSize;
        public uint flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }
}