using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// The floating card shown when a finished dictation has nowhere to go — the
/// Windows counterpart of <c>TranscriptCard.swift</c>.
///
/// Dictation normally ends with a simulated Ctrl+V into whatever is focused.
/// When nothing editable is focused that keystroke lands nowhere and the
/// transcript is gone — the user spoke a paragraph and got silence. Rather than
/// paste blindly, <see cref="TrayApp"/> asks <see cref="FocusInspector"/> first
/// and, when there is no target, hands the text to this card: a sheet of paper
/// at the bottom-centre of the screen holding the whole transcript with one
/// button that copies it.
///
/// It is drawn in the dashboard's design language, not as a system toast: paper,
/// ink, hairline rules, one filled action. Every colour and size comes from
/// <see cref="Theme"/> so the card and the settings sheet stay the same product.
///
/// Like <see cref="DictationOverlay"/> it uses <c>WS_EX_NOACTIVATE</c> so showing
/// it never steals focus — critical, because the focus it would steal is the
/// window the user is about to paste into. Unlike the overlay it must accept
/// clicks, so it is a normal opaque form rather than a layered click-through
/// one: the Copy button has to be pressable.
/// </summary>
internal sealed class TranscriptCard : Form
{
    /// <summary>Why the text could not be typed. Sets the card's kicker.</summary>
    public enum Reason
    {
        /// <summary>Nothing editable was focused when the transcript arrived.</summary>
        NoFocus,
    }

    private const int PaperWidth = 468;
    private const int BottomGap = 28;
    private const int Pad = 18;

    private readonly Label _kicker = new();
    private readonly Label _meta = new();
    private readonly Label _body = new();
    private readonly SunoButton _copy = new("Copy", ButtonKind.Primary);
    private readonly SunoButton _close = new("Dismiss", ButtonKind.Ghost);
    private readonly System.Windows.Forms.Timer _dismiss = new();

    private string _text = "";
    /// <summary>Seconds left before the card takes itself away. Held while the
    /// pointer is over the card — someone reading it is not done with it.</summary>
    private double _remaining;
    private bool _held;

    public TranscriptCard()
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Theme.Paper;
        Width = PaperWidth;
        DoubleBuffered = true;
        Padding = new Padding(Pad);

        _kicker.AutoSize = false;
        _kicker.Font = Theme.Kicker;
        _kicker.ForeColor = Theme.Faint;
        _kicker.TextAlign = ContentAlignment.MiddleLeft;

        _meta.AutoSize = false;
        _meta.Font = Theme.Caption;
        _meta.ForeColor = Theme.Faint;
        _meta.TextAlign = ContentAlignment.MiddleRight;

        _body.AutoSize = false;
        _body.Font = Theme.BodyText;
        _body.ForeColor = Theme.Ink;
        _body.TextAlign = ContentAlignment.TopLeft;

        _copy.Click += (s, e) => CopyAndFinish();
        _close.Click += (s, e) => DismissCard();

        Controls.AddRange(new Control[] { _kicker, _meta, _body, _copy, _close });

        // One tick a second: the countdown only has to be honest to the second,
        // and a card on screen should not spin the CPU.
        _dismiss.Interval = 1000;
        _dismiss.Tick += (s, e) => CountDown();

        foreach (Control c in Controls) HookHover(c);
        MouseEnter += (s, e) => _held = true;
        MouseLeave += (s, e) => _held = false;
    }

    // MARK: - Presenting

    /// <summary>
    /// Shows <paramref name="text"/> and offers to copy it. Safe to call while
    /// already visible — the card re-sizes to the new transcript rather than
    /// stacking.
    /// </summary>
    public void Present(string text, Reason reason)
    {
        var trimmed = (text ?? "").Trim();
        if (trimmed.Length == 0) return;

        _text = trimmed;
        int words = trimmed.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

        _kicker.Text = reason switch
        {
            Reason.NoFocus => "NOTHING WAS FOCUSED",
            _ => "NOT PASTED",
        };
        _meta.Text = words == 1 ? "1 word" : $"{words} words";
        _body.Text = trimmed;
        _copy.SetText("Copy");

        Layout_();
        PositionBottomCenter();
        if (!Visible) Show();
        // Longer transcripts take longer to read, so they get more time — but
        // never so much that the card feels stuck. Same curve as the Mac.
        _remaining = Math.Min(26, 11 + words * 0.35);
        _held = false;
        _dismiss.Start();
    }

    /// <summary>Takes the card away. Safe to call when it is not up.</summary>
    public void DismissCard()
    {
        _dismiss.Stop();
        if (Visible) Hide();
    }

    // MARK: - Copy

    private void CopyAndFinish()
    {
        try
        {
            // The clipboard occasionally refuses when another process holds it.
            // Losing the transcript is the thing this card exists to prevent, so
            // a failure is logged and the card stays up to be tried again.
            Clipboard.SetText(_text);
            _copy.SetText("Copied");
            AppLog.Log($"Transcript copied from the card ({_text.Length} chars)");
            _remaining = 1.2;   // let the label be seen, then go
        }
        catch (Exception ex)
        {
            AppLog.Log($"Could not copy the transcript: {ex.Message}");
            _copy.SetText("Try again");
            _remaining = Math.Max(_remaining, 8);
        }
    }

    // MARK: - Auto-dismissal

    private void CountDown()
    {
        // Someone with the pointer on the card is reading it. Hold, don't hide.
        if (_held) return;
        _remaining -= 1;
        if (_remaining <= 0) DismissCard();
    }

    /// <summary>
    /// WinForms raises enter/leave per control, so the card as a whole only
    /// knows the pointer is on it if every child reports too — otherwise moving
    /// onto the Copy button reads as leaving the card.
    /// </summary>
    private void HookHover(Control c)
    {
        c.MouseEnter += (s, e) => _held = true;
        c.MouseLeave += (s, e) => _held = ClientRectangle.Contains(PointToClient(MousePosition));
        foreach (Control child in c.Controls) HookHover(child);
    }

    // MARK: - Layout

    private void Layout_()
    {
        int inner = PaperWidth - Pad * 2;

        _kicker.SetBounds(Pad, Pad, inner - 90, 14);
        _meta.SetBounds(Pad + inner - 90, Pad, 90, 14);

        // Measure the transcript at the paper's width so the card is exactly as
        // tall as the words need, capped so a very long dictation scrolls the
        // reading rather than the screen.
        int bodyTop = Pad + 14 + 12;
        using (var g = CreateGraphics())
        {
            var size = g.MeasureString(_body.Text, _body.Font, inner);
            int bodyHeight = Math.Min(220, Math.Max(20, (int)Math.Ceiling(size.Height) + 2));
            _body.SetBounds(Pad, bodyTop, inner, bodyHeight);
        }

        int actionsTop = _body.Bottom + 14;
        _copy.SetBounds(Pad + inner - 96, actionsTop, 96, 30);
        _close.SetBounds(Pad + inner - 96 - 8 - 88, actionsTop, 88, 30);
        Height = actionsTop + 30 + Pad;
    }

    private void PositionBottomCenter()
    {
        // The screen the user is working on, not always the primary one.
        var area = Screen.FromPoint(MousePosition).WorkingArea;
        Location = new Point(
            area.Left + (area.Width - Width) / 2,
            area.Bottom - Height - BottomGap);
    }

    // MARK: - Drawing

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;

        // A hairline border and the two rules that bracket the transcript, in the
        // dashboard's language rather than a system panel's.
        using var edge = new Pen(Theme.RuleStrong);
        g.DrawRectangle(edge, 0, 0, Width - 1, Height - 1);

        using var rule = new Pen(Theme.Rule);
        int top = _kicker.Bottom + 6;
        g.DrawLine(rule, Pad, top, Width - Pad, top);
        int bottom = _body.Bottom + 7;
        g.DrawLine(rule, Pad, bottom, Width - Pad, bottom);

        // The countdown, drawn as the bottom rule filling back up. Quieter than a
        // number and it needs no space of its own.
        if (_remaining > 0 && !_held)
        {
            int full = Width - Pad * 2;
            int lit = (int)(full * Math.Min(1.0, _remaining / 26.0));
            using var progress = new Pen(Theme.AccentSoft, 2f);
            g.DrawLine(progress, Pad, bottom, Pad + lit, bottom);
        }
    }

    /// <summary>
    /// Never take focus. The window the user is about to paste into is the focus
    /// this would steal, which would defeat the point of the card.
    /// </summary>
    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
            return cp;
        }
    }

    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
}
