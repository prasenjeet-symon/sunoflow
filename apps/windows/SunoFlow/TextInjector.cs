using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// Inserts text at the current cursor position in whatever app is focused, by
/// swapping the clipboard contents and simulating Ctrl+V. This is the Windows
/// counterpart of <c>TextInjector.swift</c> (which simulates Cmd+V via
/// <c>CGEvent</c>) and the only approach that reliably works across arbitrary
/// apps (native fields, Electron, browsers, terminals).
/// </summary>
internal static class TextInjector
{
    // Virtual-key code for 'V'.
    private const byte VkV = 0x56;

    /// <summary>Insert text by putting it on the clipboard and sending Ctrl+V,
    /// then restoring the clipboard's previous contents. No-op on empty text.</summary>
    public static void Insert(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        // Save the user's clipboard so we don't clobber it.
        string? previous = null;
        try
        {
            if (Clipboard.ContainsText())
                previous = Clipboard.GetText();
        }
        catch { /* clipboard locked by another app — proceed anyway */ }

        try
        {
            Clipboard.SetText(text);
        }
        catch (Exception ex)
        {
            AppLog.Log($"Clipboard.SetText failed: {ex.Message}");
            return;
        }

        // Give the clipboard a moment to settle, then send Ctrl+V.
        Thread.Sleep(60);
        SendCtrlV();

        // Restore the user's clipboard after the paste has had time to land.
        // Matches the macOS 0.3s restore delay.
        ThreadPool.QueueUserWorkItem(_ =>
        {
            Thread.Sleep(300);
            try
            {
                if (previous != null) Clipboard.SetText(previous);
                else Clipboard.Clear();
            }
            catch { /* best-effort */ }
        });
    }

    private static void SendCtrlV()
    {
        var inputs = new INPUT[4];
        // Ctrl down
        inputs[0] = MakeKey(VK_CONTROL, down: true);
        // V down + up
        inputs[1] = MakeKey(VkV, down: true);
        inputs[2] = MakeKey(VkV, down: false);
        // Ctrl up
        inputs[3] = MakeKey(VK_CONTROL, down: false);

        if (SendInput(inputs.Length, inputs, INPUT.Size) == 0)
            AppLog.Log($"SendInput failed: {Marshal.GetLastWin32Error()}");
    }

    private static INPUT MakeKey(byte vk, bool down)
    {
        return new INPUT
        {
            type = INPUT_KEYBOARD,
            ki = new KEYBDINPUT
            {
                wVk = vk,
                dwFlags = down ? 0u : KEYEVENTF_KEYUP,
                time = 0,
                dwExtraInfo = IntPtr.Zero,
            }
        };
    }

    // --- Win32 SendInput ---------------------------------------------------------
    // INPUT is a C-style union. We lay it out explicitly: the `type` int at
    // offset 0, then 4 bytes of padding on x64, then the union members at offset
    // 8. Making INPUT itself Explicit (rather than nesting a union struct) keeps
    // Marshal.SizeOf<INPUT>() == 40 on x64 — the real Win32 size — so an INPUT[]
    // is indexed exactly the way SendInput expects.

    private const byte VK_CONTROL = 0x11;
    private const int INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(int nInputs, INPUT[] pInputs, int cbSize);

    // FieldOffset(8) on x64 (4-byte type + 4 bytes padding before the 8-byte-aligned
    // union). We pin the build to x64 in the .csproj, so this is unambiguous.
    [StructLayout(LayoutKind.Explicit)]
    private struct INPUT
    {
        [FieldOffset(0)] public int type;
        [FieldOffset(8)] public MOUSEINPUT mi;
        [FieldOffset(8)] public KEYBDINPUT ki;
        [FieldOffset(8)] public HARDWAREINPUT hi;
        public static readonly int Size = Marshal.SizeOf<INPUT>();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public int uMsg;
        public short wParamL;
        public short wParamH;
    }
}