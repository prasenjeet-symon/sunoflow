using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// The floating dictation bubble — a compact capsule at the top-centre of the
/// screen carrying a waveform that reacts to the voice. The Windows counterpart
/// of <c>DictationOverlay.swift</c>, and deliberately the same object: same
/// 132×42 capsule, same bar geometry, same travelling-wave maths, same accent.
///
/// It is a <b>layered window</b> rather than an ordinary form. WinForms can only
/// give a borderless form square corners and a hard edge; UpdateLayeredWindow
/// takes a 32-bit ARGB bitmap and composites it per pixel, which is what makes
/// the capsule's corners and its soft shadow read as cleanly as the Mac's.
///
/// <c>WS_EX_NOACTIVATE</c> keeps it from ever taking focus — critical, or the
/// paste would land in the overlay instead of the field being dictated into —
/// and <c>WS_EX_TRANSPARENT</c> makes it click-through, matching the Mac panel's
/// <c>ignoresMouseEvents</c>.
/// </summary>
internal sealed class DictationOverlay : Form
{
    public enum Mode { Recording, Processing }

    // The capsule, and the margin around it that the shadow is painted into.
    private const int CapsuleWidth = 132;
    private const int CapsuleHeight = 42;
    private const int ShadowPad = 12;
    private const int TopGap = 8;

    // Waveform geometry, matching the Mac bubble.
    private const float InsetX = 15f;
    private const float InsetY = 11f;
    private const float BarWidth = 3f;
    private const float BarGap = 4f;

    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 16 };

    private Mode _mode = Mode.Recording;
    private float[] _heights = Array.Empty<float>();
    private double _phase;
    private float _rawLevel;
    private float _displayLevel;

    // Fade + slide, driven by the same tick as the waveform.
    private double _opacity;
    private double _targetOpacity;
    private bool _hiding;

    public DictationOverlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        ShowActivated = false;
        TopMost = true;
        Size = new Size(CapsuleWidth + ShadowPad * 2, CapsuleHeight + ShadowPad * 2);
        _timer.Tick += (s, e) => Tick();
    }

    // MARK: - Public surface

    /// <summary>Brings the bubble up in the given mode.</summary>
    public void Show(Mode mode)
    {
        _mode = mode;
        _hiding = false;
        _targetOpacity = 1;
        PositionTopCenter();
        if (!Visible)
        {
            _opacity = 0;
            _phase = 0;
            _displayLevel = 0;
            _rawLevel = 0;
            ResetBars();
            base.Show();
        }
        _timer.Start();
        Render();
    }

    public void UpdateMode(Mode mode) => _mode = mode;

    /// <summary>Feeds the latest mic level (0–1) to the waveform.</summary>
    public void UpdateLevel(float level) => _rawLevel = Math.Clamp(level, 0f, 1f);

    public void HideOverlay()
    {
        if (!Visible) return;
        _hiding = true;
        _targetOpacity = 0;
        _timer.Start();
    }

    // MARK: - Animation

    private void ResetBars()
    {
        float waveWidth = CapsuleWidth - InsetX * 2;
        int count = Math.Max(3, (int)((waveWidth + BarGap) / (BarWidth + BarGap)));
        if (_heights.Length != count) _heights = new float[count];
        for (int i = 0; i < _heights.Length; i++) _heights[i] = BarWidth;
    }

    private void Tick()
    {
        // Fade towards the target. The bubble is on screen for seconds at a time,
        // so the entrance is short enough not to be in the way and long enough to
        // read as an arrival rather than a flash.
        _opacity += (_targetOpacity - _opacity) * 0.28;
        if (_hiding && _opacity < 0.02)
        {
            _timer.Stop();
            _opacity = 0;
            Hide();
            return;
        }

        _phase += 0.15;
        _displayLevel += (_rawLevel - _displayLevel) * 0.35f;
        // Let the level decay when the voice goes quiet, so the bars settle
        // instead of holding the last peak.
        _rawLevel *= 0.9f;

        if (_heights.Length == 0) ResetBars();
        float minHeight = BarWidth;
        float maxHeight = CapsuleHeight - InsetY * 2;
        float span = maxHeight - minHeight;
        int n = _heights.Length;

        for (int i = 0; i < n; i++)
        {
            // Centre-weighted envelope: taller in the middle, tapering at the
            // edges, so the waveform reads as a soft bubble rather than a flat row.
            double envInput = n > 1 ? (double)i / (n - 1) : 0.5;
            double envelope = 0.5 + 0.5 * Math.Sin(Math.PI * envInput);

            double amp;
            if (_mode == Mode.Recording)
            {
                double osc = 0.5 + 0.5 * Math.Sin(_phase + i * 0.5);
                amp = Math.Min(1.0, (0.08 + _displayLevel * (0.5 + 0.8 * osc)) * envelope);
            }
            else
            {
                double osc = 0.5 + 0.5 * Math.Sin(_phase * 1.8 + i * 0.5);
                amp = (0.24 + 0.3 * osc) * envelope;
            }

            float target = minHeight + span * (float)amp;
            _heights[i] += (target - _heights[i]) * 0.35f;
        }

        Render();
    }

    private void PositionTopCenter()
    {
        // The screen the user is working on, not always the primary one.
        // FromPoint always answers with a screen, falling back to the primary.
        var area = Screen.FromPoint(MousePosition).WorkingArea;
        Location = new Point(
            area.Left + (area.Width - Width) / 2,
            area.Top + TopGap - ShadowPad);
    }

    // MARK: - Drawing

    private void Render(Graphics g)
    {
        g.Clear(Color.Transparent);
        g.SmoothingMode = SmoothingMode.AntiAlias;

        var capsule = new RectangleF(ShadowPad, ShadowPad, CapsuleWidth, CapsuleHeight);
        float radius = CapsuleHeight / 2f;

        // A soft shadow, approximated by a handful of expanding silhouettes. The
        // Mac gets this from the window server; here it is cheaper to paint it
        // than to ask Windows for a shadow a layered window would not cast.
        for (int step = ShadowPad; step >= 1; step--)
        {
            int alpha = (int)(10 * (1.0 - (double)step / ShadowPad) + 3);
            using var shadow = Glyphs.RoundedPath(
                capsule.X - step, capsule.Y - step + 1.5f,
                capsule.Width + step * 2, capsule.Height + step * 2, radius + step);
            using var brush = new SolidBrush(Color.FromArgb(Math.Min(alpha, 22), 0, 0, 0));
            g.FillPath(brush, shadow);
        }

        using (var path = Glyphs.RoundedPath(capsule.X, capsule.Y, capsule.Width, capsule.Height, radius))
        {
            using var fill = new SolidBrush(Color.FromArgb(250, Theme.Paper));
            g.FillPath(fill, path);
            using var edge = new Pen(Color.FromArgb(120, Theme.RuleStrong));
            g.DrawPath(edge, path);
        }

        if (_heights.Length == 0) return;

        int n = _heights.Length;
        float total = n * BarWidth + (n - 1) * BarGap;
        float startX = capsule.X + InsetX + (capsule.Width - InsetX * 2 - total) / 2f;
        float midY = capsule.Y + capsule.Height / 2f;

        using var bar = new SolidBrush(Theme.Accent);
        for (int i = 0; i < n; i++)
        {
            float h = Math.Max(BarWidth, _heights[i]);
            float x = startX + i * (BarWidth + BarGap);
            using var shape = Glyphs.RoundedPath(x, midY - h / 2f, BarWidth, h, BarWidth / 2f);
            g.FillPath(bar, shape);
        }
    }

    /// <summary>Composites the bubble onto the screen, per pixel.</summary>
    private void Render()
    {
        if (!IsHandleCreated || IsDisposed) return;

        using var bitmap = new Bitmap(Width, Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap)) Render(g);

        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memoryDc = CreateCompatibleDC(screenDc);
        IntPtr hBitmap = IntPtr.Zero;
        IntPtr oldBitmap = IntPtr.Zero;
        try
        {
            // A zero background keeps the alpha channel GDI+ produced.
            hBitmap = bitmap.GetHbitmap(Color.FromArgb(0));
            oldBitmap = SelectObject(memoryDc, hBitmap);

            var size = new SIZE { cx = bitmap.Width, cy = bitmap.Height };
            var source = new POINT { x = 0, y = 0 };
            var destination = new POINT { x = Left, y = Top };
            var blend = new BLENDFUNCTION
            {
                BlendOp = AC_SRC_OVER,
                BlendFlags = 0,
                SourceConstantAlpha = (byte)Math.Clamp((int)Math.Round(_opacity * 255), 0, 255),
                AlphaFormat = AC_SRC_ALPHA,
            };
            UpdateLayeredWindow(Handle, screenDc, ref destination, ref size,
                                memoryDc, ref source, 0, ref blend, ULW_ALPHA);
        }
        finally
        {
            ReleaseDC(IntPtr.Zero, screenDc);
            if (hBitmap != IntPtr.Zero)
            {
                SelectObject(memoryDc, oldBitmap);
                DeleteObject(hBitmap);
            }
            DeleteDC(memoryDc);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _timer.Dispose();
        base.Dispose(disposing);
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            // LAYERED: per-pixel alpha, so the capsule has real rounded corners.
            // NOACTIVATE: never take focus from the field being dictated into.
            // TRANSPARENT: clicks pass straight through to whatever is underneath.
            // TOOLWINDOW: keep it out of Alt-Tab.
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW;
            return cp;
        }
    }

    // MARK: - Win32

    private const int WS_EX_LAYERED = 0x00080000;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TRANSPARENT = 0x00000020;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int ULW_ALPHA = 0x00000002;
    private const byte AC_SRC_OVER = 0x00;
    private const byte AC_SRC_ALPHA = 0x01;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct SIZE { public int cx; public int cy; }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct BLENDFUNCTION
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateLayeredWindow(
        IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
        IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr hDC);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr hdc, IntPtr hObject);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(IntPtr hObject);
}
