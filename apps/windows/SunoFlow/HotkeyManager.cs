using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// Registers a single system-wide hotkey via the Win32
/// <c>RegisterHotKey</c>/<c>WM_HOTKEY</c> mechanism. Mirrors the macOS
/// <c>HotkeyManager</c> (which uses Carbon).
///
/// <c>RegisterHotKey</c> delivers <c>WM_HOTKEY</c> to the HWND passed to it. We
/// own a hidden message-only <see cref="NativeWindow"/> (created via
/// <c>CreateHandle</c>) that lives for the manager's lifetime and overrides
/// <c>WndProc</c> to catch <c>WM_HOTKEY</c>. This is the robust pattern for a
/// tray app that has no main window of its own — a hotkey registered against
/// <c>IntPtr.Zero</c> would be posted to the thread queue but nothing would
/// dispatch it (there is no <c>WndProc</c> on a plain class), so it would never
/// fire. The native window must be created and registered on the UI thread,
/// which owns it and runs the message pump.
/// </summary>
internal sealed class HotkeyManager : IDisposable
{
    private readonly HotkeySink _sink = new();
    private int _currentId = -1;

    /// <summary>Fired on the UI thread when the registered hotkey is pressed.</summary>
    public event EventHandler? HotkeyPressed;

    public HotkeyManager() => _sink.HotkeyReceived += () => HotkeyPressed?.Invoke(this, EventArgs.Empty);

    /// <summary>Register a system-wide hotkey. Replaces any prior registration.</summary>
    public void Register(int keyCode, int modifiers)
    {
        Unregister();
        // MOD_NOREPEAT prevents auto-repeat while the key is held — essential for a toggle.
        int id = NextId();
        if (!RegisterHotKey(_sink.Handle, id, modifiers | ModNoRepeat, keyCode))
        {
            AppLog.Log($"RegisterHotKey failed (code={keyCode}, mods={modifiers}) — " +
                       "another app may own this shortcut");
            return;
        }
        _currentId = id;
    }

    /// <summary>Swap the active hotkey for a new key/modifier combination.</summary>
    public void Reregister(int keyCode, int modifiers) => Register(keyCode, modifiers);

    public void Unregister()
    {
        if (_currentId < 0) return;
        UnregisterHotKey(_sink.Handle, _currentId);
        _currentId = -1;
    }

    public void Dispose()
    {
        Unregister();
        _sink.Dispose();
    }

    // App-private hotkey id range (0x0000–0xBFFF). We use a stable base so
    // re-registrations don't collide with stale OS entries from a crash.
    private const int IdBase = 0x9000;
    private static int _nextId = IdBase;
    private static int NextId() => _nextId++;

    private const int ModNoRepeat = 0x4000;

    /// <summary>Hidden message-only window that receives WM_HOTKEY.</summary>
    private sealed class HotkeySink : NativeWindow, IDisposable
    {
        private const int WM_HOTKEY = 0x0312;

        /// <summary>Fired on the UI thread when WM_HOTKEY arrives.</summary>
        public event Action? HotkeyReceived;

        public HotkeySink()
        {
            // Create an invisible message-only window. Size/caption are irrelevant.
            CreateHandle(new CreateParams { Caption = "SunoFlowHotkeySink", Width = 0, Height = 0 });
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY)
                HotkeyReceived?.Invoke();
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (Handle != IntPtr.Zero) DestroyHandle();
        }
    }

    // --- Win32 ---
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, int fsModifiers, int vk);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}

/// <summary>Formatting helpers for turning a (VK code, modifier flags) pair into a label.</summary>
internal static class KeyCombo
{
    public static string Display(int keyCode, int modifiers)
    {
        var s = ModifierString(modifiers);
        var name = KeyName(keyCode);
        return string.IsNullOrEmpty(s) ? name : $"{s}+{name}";
    }

    /// <summary>Canonical Windows order: Ctrl+Alt+Shift+Win.</summary>
    public static string ModifierString(int modifiers)
    {
        var sb = new System.Text.StringBuilder();
        if ((modifiers & Preferences.ModControl) != 0) sb.Append("Ctrl+");
        if ((modifiers & Preferences.ModAlt) != 0) sb.Append("Alt+");
        if ((modifiers & Preferences.ModShift) != 0) sb.Append("Shift+");
        if ((modifiers & Preferences.ModWin) != 0) sb.Append("Win+");
        return sb.ToString().TrimEnd('+');
    }

    /// <summary>Human-readable key name for common virtual key codes.</summary>
    public static string KeyName(int vk)
    {
        // Map the most common keys; fall back to a decimal for anything unusual.
        return vk switch
        {
            0x08 => "Backspace",
            0x09 => "Tab",
            0x0D => "Enter",
            0x10 => "Shift",
            0x11 => "Ctrl",
            0x12 => "Alt",
            0x20 => "Space",
            0x21 => "PageUp",
            0x22 => "PageDown",
            0x23 => "End",
            0x24 => "Home",
            0x25 => "Left",
            0x26 => "Up",
            0x27 => "Right",
            0x28 => "Down",
            0x2D => "Insert",
            0x2E => "Delete",
            >= 0x70 and <= 0x7B => $"F{vk - 0x6F}",
            >= 0x30 and <= 0x39 => ((char)vk).ToString(),
            >= 0x41 and <= 0x5A => ((char)vk).ToString(),
            _ => $"Key {vk}",
        };
    }
}