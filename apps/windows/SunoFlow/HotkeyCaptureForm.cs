using System;
using System.Drawing;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// A small modal dialog that captures the next key combination pressed as the
/// new dictation hotkey. Windows counterpart of the macOS
/// <c>HotkeyRecorderNSView</c>. The user presses a key (with optional Ctrl/Alt/
/// Shift/Win modifiers) and we record it; Esc cancels.
/// </summary>
internal sealed class HotkeyCaptureForm : Form
{
    public int KeyCode { get; private set; }
    public int Modifiers { get; private set; }

    public HotkeyCaptureForm()
    {
        Text = "New Shortcut";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterParent;
        MaximizeBox = false;
        MinimizeBox = false;
        ClientSize = new Size(360, 120);
        KeyPreview = true;

        var label = new Label
        {
            Text = "Press the key combination you want to use for dictation.\n(Esc to cancel)",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI", 10),
        };
        Controls.Add(label);

        KeyDown += OnKeyDown;
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape)
        {
            DialogResult = DialogResult.Cancel;
            Close();
            return;
        }

        // WinForms exposes modifiers separately from the key. Reconstruct the
        // Preferences.ModXxx flags from the event. e.Control/Alt/Shift are
        // convenience wrappers over e.Modifiers; the Win key has no such
        // wrapper, so check it directly in the modifier flags.
        int mods = Preferences.ModNone;
        if (e.Control) mods |= Preferences.ModControl;
        if (e.Alt) mods |= Preferences.ModAlt;
        if (e.Shift) mods |= Preferences.ModShift;
        if ((e.Modifiers & (Keys.LWin | Keys.RWin)) != 0) mods |= Preferences.ModWin;

        // Map the WinForms Keys enum to a Win32 virtual-key code.
        var vk = (int)e.KeyCode;

        // Reject pure-modifier presses (Ctrl alone, Alt alone, etc.).
        if (e.KeyCode is Keys.ControlKey or Keys.Menu or Keys.ShiftKey or Keys.LWin or Keys.RWin)
            return;

        KeyCode = vk;
        Modifiers = mods;
        DialogResult = DialogResult.OK;
        Close();
    }
}