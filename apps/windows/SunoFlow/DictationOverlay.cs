using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// A small floating "bubble" at the top-center of the screen shown during
/// recording (animated waveform) and processing (spinner text). Windows
/// counterpart of <c>DictationOverlay.swift</c>. It's a borderless, non-activating
/// topmost form so it never steals focus from the field the user is dictating
/// into — equivalent to the macOS <c>NonActivatingPanel</c>.
/// </summary>
internal sealed class DictationOverlay : Form
{
    public enum Mode { Recording, Processing }

    private Mode _mode = Mode.Recording;
    private float _level;
    private readonly System.Windows.Forms.Timer _animTimer;
    private int _tick;

    public DictationOverlay()
    {
        // No borders, no title bar, always on top, never steals focus.
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        ShowInTaskbar = false;
        ShowActivated = false; // critical: don't take focus on show
        BackColor = Color.FromArgb(28, 28, 30);
        TransparencyKey = Color.FromArgb(1, 0, 1); // not used (we're opaque), kept for safety
        DoubleBuffered = true;
        Width = 260;
        Height = 56;

        _animTimer = new System.Windows.Forms.Timer { Interval = 50 };
        _animTimer.Tick += (s, e) => { _tick++; Invalidate(); };
    }

    /// <summary>Bring up the overlay in the given mode.</summary>
    public void Show(Mode mode)
    {
        _mode = mode;
        PositionTopCenter();
        if (!Visible) base.Show();
        if (mode == Mode.Recording) _animTimer.Start();
        else _animTimer.Stop();
        Invalidate();
    }

    public void UpdateMode(Mode mode)
    {
        _mode = mode;
        if (mode == Mode.Recording) _animTimer.Start();
        else _animTimer.Stop();
        Invalidate();
    }

    /// <summary>Feed the latest mic level (0–1) to animate the waveform.</summary>
    public void UpdateLevel(float level)
    {
        _level = Math.Clamp(level, 0f, 1f);
        // Invalidate only when actually recording to drive the animation.
        if (_mode == Mode.Recording) Invalidate();
    }

    public void HideOverlay()
    {
        _animTimer.Stop();
        if (Visible) Hide();
    }

    private void PositionTopCenter()
    {
        var screen = Screen.PrimaryScreen?.WorkingArea ?? Rectangle.Empty;
        Location = new Point(
            screen.Left + (screen.Width - Width) / 2,
            screen.Top + 24
        );
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var rect = new Rectangle(0, 0, Width - 1, Height - 1);

        // Rounded capsule background.
        using var path = RoundedPath(rect, 28);
        using (var b = new SolidBrush(Color.FromArgb(38, 38, 42)))
            g.FillPath(b, path);
        using var pen = new Pen(Color.FromArgb(70, 70, 74), 1);
            g.DrawPath(pen, path);

        if (_mode == Mode.Recording)
            DrawWaveform(g);
        else
            DrawProcessingText(g);
    }

    private void DrawWaveform(Graphics g)
    {
        var barColor = Color.FromArgb(120, 180, 255);
        var barWidth = 4;
        var gap = 4;
        var barCount = 16;
        var totalBars = barCount * (barWidth + gap) - gap;
        var startX = (Width - totalBars) / 2;
        var centerY = Height / 2;
        var maxBar = Height / 2 - 10;

        // Pseudo-random seed from the tick + level so it looks like a live meter.
        var rng = new Random(_tick);
        for (int i = 0; i < barCount; i++)
        {
            // Base each bar on the current level, with a little per-bar jitter.
            var jitter = rng.NextDouble() * 0.5 + 0.5;
            var h = (float)(_level * jitter * maxBar * 2);
            h = Math.Max(3, h);
            var x = startX + i * (barWidth + gap);
            var y = centerY - h / 2;
            using var b = new SolidBrush(barColor);
            g.FillRectangle(b, x, y, barWidth, h);
        }

        // Label.
        using var font = new Font("Segoe UI", 9f);
        var label = "Recording…  Alt+Space to stop";
        var size = g.MeasureString(label, font);
        g.DrawString(label, font, Brushes.LightGray,
            (Width - size.Width) / 2, Height - 16);
    }

    private void DrawProcessingText(Graphics g)
    {
        using var font = new Font("Segoe UI", 11f);
        var label = "Transcribing…";
        var size = g.MeasureString(label, font);
        g.DrawString(label, font, Brushes.White,
            (Width - size.Width) / 2, (Height - size.Height) / 2);
    }

    private static GraphicsPath RoundedPath(Rectangle r, int radius)
    {
        var path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            // WS_EX_NOACTIVATE keeps the form from taking focus when shown/moved,
            // mirroring the macOS NonActivatingPanel behaviour.
            var cp = base.CreateParams;
            const int WS_EX_NOACTIVATE = 0x08000000;
            cp.ExStyle |= WS_EX_NOACTIVATE;
            return cp;
        }
    }
}