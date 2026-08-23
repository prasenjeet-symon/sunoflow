using System;
using System.Runtime.InteropServices;
using System.Text;

namespace SunoFlow;

/// <summary>
/// Best-effort reader of the text field the user is currently typing into. The
/// Windows counterpart of <c>AccessibilityContext.swift</c>, and the single place
/// both callers go through:
/// <list type="bullet">
/// <item><see cref="TextBeforeCursor"/> gives the cleanup service reference
///   vocabulary — names, terminology, capitalisation, how the sentence so far
///   runs — so a transcript is polished to match what is already there.</item>
/// <item><see cref="Text"/> lets <see cref="EditLearner"/> snapshot a field and
///   later see what the user changed about what was pasted.</item>
/// </list>
///
/// On macOS this comes from the Accessibility API. Windows has no single
/// cross-app "focused field text" API, so this uses <c>WM_GETTEXT</c> on the
/// focused window's control: reliable for standard Win32 edits and many
/// Electron/Chromium fields, and simply empty everywhere else. That is the whole
/// contract — every failure returns nothing, and dictation never depends on it.
///
/// <b>Password fields are never read.</b> The macOS side skips
/// <c>AXSecureTextField</c>; the equivalent here is the <c>ES_PASSWORD</c> style,
/// checked before any text is pulled out of a control.
/// </summary>
internal static class FocusedField
{
    /// <summary>The focused control's window handle, or <see cref="IntPtr.Zero"/>.</summary>
    public static IntPtr Handle()
    {
        var foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero) return IntPtr.Zero;
        var info = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        uint thread = GetWindowThreadProcessId(foreground, out _);
        if (GetGUIThreadInfo(thread, ref info) && info.hwndFocus != IntPtr.Zero)
            return info.hwndFocus;
        return foreground;
    }

    /// <summary>The control's whole text, or null when it cannot be read — which
    /// includes every password field.</summary>
    public static string? Text(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || IsSecure(hwnd)) return null;
        try
        {
            int length = SendMessage(hwnd, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero).ToInt32();
            if (length <= 0) return null;
            var buffer = new StringBuilder(length + 1);
            SendMessage(hwnd, WM_GETTEXT, (IntPtr)(length + 1), buffer);
            return buffer.ToString();
        }
        catch { return null; }
    }

    /// <summary>
    /// The text immediately before the caret in the focused field, trimmed and
    /// capped at <paramref name="maxChars"/>. Empty when there is nothing to read.
    /// </summary>
    public static string TextBeforeCursor(int maxChars = 800)
    {
        try
        {
            var hwnd = Handle();
            var text = Text(hwnd);
            if (string.IsNullOrEmpty(text)) return "";

            int caret = text.Length;
            long packed = SendMessage(hwnd, EM_GETSEL, IntPtr.Zero, IntPtr.Zero).ToInt64();
            int start = (int)(packed & 0xFFFF);
            int end = (int)((packed >> 16) & 0xFFFF);
            // A control that does not implement EM_GETSEL answers 0, which is
            // indistinguishable from "the caret really is at the very start".
            // Treat both as "we don't know" and fall back to the end of the
            // field: this is reference vocabulary for the cleanup pass, not a
            // strict prefix, so the tail is far more useful than nothing.
            if (start > 0 && start <= text.Length && end >= start) caret = start;

            var before = text[..caret];
            if (before.Length > maxChars) before = before[^maxChars..];
            return before.Trim();
        }
        catch { return ""; }
    }

    /// <summary>Whether the control is a password field. Only native Win32 edits
    /// advertise this; a Chromium password box is not a real edit control, so
    /// <c>WM_GETTEXT</c> returns nothing for it either way.</summary>
    private static bool IsSecure(IntPtr hwnd)
    {
        try
        {
            long style = GetWindowLongPtr(hwnd, GWL_STYLE).ToInt64();
            if ((style & ES_PASSWORD) != 0) return true;
            return SendMessage(hwnd, EM_GETPASSWORDCHAR, IntPtr.Zero, IntPtr.Zero) != IntPtr.Zero;
        }
        catch { return true; }   // unreadable: assume the worst and read nothing
    }

    // --- Win32 -------------------------------------------------------------------

    private const int WM_GETTEXT = 0x000D;
    private const int WM_GETTEXTLENGTH = 0x000E;
    private const int EM_GETSEL = 0x00B0;
    private const int EM_GETPASSWORDCHAR = 0x00D2;
    private const int GWL_STYLE = -16;
    private const long ES_PASSWORD = 0x0020;

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);

    // The build is pinned to x64, so the ...Ptr entry point always exists.
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, StringBuilder lParam);

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
