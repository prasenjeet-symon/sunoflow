using System;
using System.Runtime.InteropServices;
using System.Text;

namespace SunoFlow;

/// <summary>Where the next paste would land — the Windows counterpart of the
/// macOS <c>InsertionTarget</c>.</summary>
internal enum InsertionTarget
{
    /// <summary>A text field, editor or terminal has focus, so a simulated
    /// Ctrl+V will land somewhere useful.</summary>
    Editable,
    /// <summary>Something has focus and it is definitely not somewhere text can
    /// go — the desktop, a file list, a window with no focused control.</summary>
    NotEditable,
    /// <summary>Windows cannot say. Treated as "paste anyway": plenty of apps
    /// draw their own text surfaces and tell Win32 nothing about them, and
    /// refusing to type into those would be a worse bug than the one this whole
    /// check exists to prevent.</summary>
    Unknown,
}

/// <summary>
/// Decides whether there is anywhere for a transcript to go — the Windows
/// counterpart of <c>FocusInspector.swift</c>, file for file.
///
/// Dictation ends by simulating Ctrl+V into whatever is focused. When nothing
/// editable is focused that keystroke goes nowhere and the transcript is gone —
/// from the user's side, indistinguishable from dictation failing. This asks
/// Win32 what has focus so the caller can offer the text instead of throwing it
/// away (see <see cref="TranscriptCard"/>).
///
/// <b>The classification is deliberately lopsided</b>, exactly as on the Mac:
/// every plausible signal that a surface takes text counts as
/// <see cref="InsertionTarget.Editable"/>, anything unreadable is
/// <see cref="InsertionTarget.Unknown"/>, and only a clear, positive "this is
/// not a text surface" answer returns <see cref="InsertionTarget.NotEditable"/>.
/// A false NotEditable costs the user one click; a false Editable costs them the
/// dictation.
///
/// Windows makes this harder than macOS, and the asymmetry is worth naming.
/// macOS has one Accessibility tree that nearly every app publishes, so it can
/// ask a focused element for its role. Win32 has no equivalent that Chromium,
/// Electron, Qt and WinUI all answer the same way — UI Automation would come
/// closest and is not in this project's dependency set. So this leans on the two
/// signals that <i>are</i> universal: a blinking caret owned by the foreground
/// thread, and the window class of the focused control.
/// </summary>
internal static class FocusInspector
{
    /// <summary>Window classes that always accept typed text.</summary>
    private static readonly string[] TextClasses =
    {
        "Edit", "RichEdit", "RichEdit20A", "RichEdit20W", "RichEdit50W",
        "TextBox", "ComboBox", "Scintilla", "ConsoleWindowClass",
        "CASCADIA_HOSTING_WINDOW_CLASS",   // Windows Terminal
        "Chrome_RenderWidgetHostHWND",     // Chromium/Electron content
    };

    /// <summary>Window classes that are positively not text surfaces. Kept
    /// short on purpose — this is the only list that can cost a paste.</summary>
    private static readonly string[] NonTextClasses =
    {
        "Progman",           // the desktop
        "WorkerW",           // the desktop's wallpaper host
        "SysListView32",     // Explorer's file list
        "DirectUIHWND",      // Explorer's modern shell surfaces
        "Shell_TrayWnd",     // the taskbar
        "SysTreeView32",     // Explorer's folder tree
    };

    /// <summary>
    /// What a paste right now would hit. Cheap enough to call inline — a handful
    /// of synchronous Win32 reads.
    /// </summary>
    public static InsertionTarget Current()
    {
        try
        {
            var foreground = GetForegroundWindow();
            if (foreground == IntPtr.Zero)
            {
                AppLog.Log("Insertion target: no foreground window → unknown");
                return InsertionTarget.Unknown;
            }

            // Our own windows are never a dictation target. Nothing in SunoFlow
            // takes dictated text, so say so rather than pasting into a form.
            GetWindowThreadProcessId(foreground, out uint pid);
            if (pid == (uint)Environment.ProcessId)
            {
                AppLog.Log("Insertion target: SunoFlow itself is foreground → not editable");
                return InsertionTarget.NotEditable;
            }

            uint thread = GetWindowThreadProcessId(foreground, out _);
            var info = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
            bool haveInfo = GetGUIThreadInfo(thread, ref info);

            // A caret is the strongest signal Win32 offers: something in this
            // thread is hosting a text insertion point right now.
            if (haveInfo && info.hwndCaret != IntPtr.Zero)
                return Decide(InsertionTarget.Editable, "editable (caret present)", foreground);

            var focused = haveInfo && info.hwndFocus != IntPtr.Zero ? info.hwndFocus : foreground;
            var cls = ClassName(focused);

            foreach (var name in TextClasses)
                if (string.Equals(cls, name, StringComparison.OrdinalIgnoreCase))
                    return Decide(InsertionTarget.Editable, $"editable (class {cls})", foreground);

            // ES_* styles only exist on real edit controls, so this catches
            // custom-classed Win32 edits that the list above misses.
            if (IsEditControl(focused))
                return Decide(InsertionTarget.Editable, "editable (edit-control styles)", foreground);

            foreach (var name in NonTextClasses)
                if (string.Equals(cls, name, StringComparison.OrdinalIgnoreCase))
                    return Decide(InsertionTarget.NotEditable, $"not editable (class {cls})", foreground);

            // A window that reports no focused control at all, in a thread that
            // answered the question, really has nothing focused. A thread that
            // would not answer tells us nothing, and its silence must not be
            // read as an empty answer.
            if (haveInfo && info.hwndFocus == IntPtr.Zero)
                return Decide(InsertionTarget.NotEditable, "not editable (nothing focused)", foreground);

            return Decide(InsertionTarget.Unknown, $"unknown (class {cls})", foreground);
        }
        catch (Exception ex)
        {
            // Best-effort: an unanswerable machine still gets to dictate.
            AppLog.Log($"Insertion target: check failed ({ex.Message}) → unknown");
            return InsertionTarget.Unknown;
        }
    }

    private static InsertionTarget Decide(InsertionTarget target, string why, IntPtr foreground)
    {
        AppLog.Log($"Insertion target: {WindowTitle(foreground)} → {why}");
        return target;
    }

    private static bool IsEditControl(IntPtr hwnd)
    {
        try
        {
            long style = GetWindowLongPtr(hwnd, GWL_STYLE).ToInt64();
            // ES_MULTILINE / ES_AUTOHSCROLL / ES_AUTOVSCROLL are edit-only bits,
            // but they overlap with other controls' styles, so this is only
            // consulted after the class checks above have not decided.
            return (style & ES_MULTILINE) != 0 &&
                   SendMessage(hwnd, EM_GETSEL, IntPtr.Zero, IntPtr.Zero) != IntPtr.Zero;
        }
        catch { return false; }
    }

    private static string ClassName(IntPtr hwnd)
    {
        var buffer = new StringBuilder(256);
        return GetClassName(hwnd, buffer, buffer.Capacity) > 0 ? buffer.ToString() : "";
    }

    private static string WindowTitle(IntPtr hwnd)
    {
        int length = GetWindowTextLength(hwnd);
        if (length <= 0) return "?";
        var buffer = new StringBuilder(length + 1);
        return GetWindowText(hwnd, buffer, buffer.Capacity) > 0 ? buffer.ToString() : "?";
    }

    // --- Win32 -------------------------------------------------------------------

    private const int GWL_STYLE = -16;
    private const long ES_MULTILINE = 0x0004;
    private const int EM_GETSEL = 0x00B0;

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

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
