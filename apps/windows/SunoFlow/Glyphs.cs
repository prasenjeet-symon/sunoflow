using System;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace SunoFlow;

/// <summary>The line glyphs used by the dashboard's rows and navigation.</summary>
internal enum Glyph
{
    None,
    // Navigation.
    Grid, Person, Gear, Mic, Waveform, TextCheck, Info,
    // Rows.
    Cpu, Keyboard, Timer, Screen, Power, CheckCircle, XCircle, Alert,
    Lock, Eye, Refresh, Globe, Link, Download, Card, Hourglass, Desktop,
    Trash, Pencil, Plus, Search, ArrowRight, Chevron,
}

/// <summary>
/// Vector line icons drawn with GDI+, the Windows stand-in for the SF Symbols the
/// macOS dashboard uses. They are deliberately hand-drawn rather than taken from
/// a symbol font: a missing font codepoint renders as a tofu box on the machines
/// that lack it, whereas these draw identically on every Windows 10 and 11 install.
///
/// Every glyph is described in the same 24x24 box the brand mark uses, stroked at
/// 1.7 with round caps and joins, so an icon sits at the same visual weight as
/// <see cref="BrandMark"/> beside it.
/// </summary>
internal static class Glyphs
{
    private const float Box = 24f;
    private const float Stroke = 1.7f;

    /// <summary>Draws <paramref name="glyph"/> centred in <paramref name="rect"/>,
    /// scaled to the shorter side.</summary>
    public static void Draw(Graphics g, Glyph glyph, RectangleF rect, Color color)
    {
        if (glyph == Glyph.None) return;
        float scale = Math.Min(rect.Width, rect.Height) / Box;
        if (scale <= 0) return;

        var saved = g.Save();
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TranslateTransform(rect.X + (rect.Width - Box * scale) / 2f,
                             rect.Y + (rect.Height - Box * scale) / 2f);
        g.ScaleTransform(scale, scale);

        using var pen = new Pen(color, Stroke)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
            LineJoin = LineJoin.Round,
        };
        using var brush = new SolidBrush(color);
        Paint(g, pen, brush, glyph);

        g.Restore(saved);
    }

    private static void Paint(Graphics g, Pen p, Brush b, Glyph glyph)
    {
        switch (glyph)
        {
            case Glyph.Grid:
                foreach (var (x, y) in new[] { (3.5f, 3.5f), (13f, 3.5f), (3.5f, 13f), (13f, 13f) })
                    Rounded(g, p, x, y, 7.5f, 7.5f, 2f);
                break;

            case Glyph.Person:
                g.DrawEllipse(p, 8.4f, 3.6f, 7.2f, 7.2f);
                g.DrawArc(p, 4.5f, 12.5f, 15f, 15f, 190, 160);
                break;

            case Glyph.Gear:
                g.DrawEllipse(p, 8.6f, 8.6f, 6.8f, 6.8f);
                for (int i = 0; i < 8; i++)
                {
                    double a = i * Math.PI / 4;
                    g.DrawLine(p,
                        (float)(12 + 5.4 * Math.Cos(a)), (float)(12 + 5.4 * Math.Sin(a)),
                        (float)(12 + 8.4 * Math.Cos(a)), (float)(12 + 8.4 * Math.Sin(a)));
                }
                break;

            case Glyph.Mic:
                Rounded(g, p, 9f, 2.6f, 6f, 11f, 3f);
                g.DrawArc(p, 5.5f, 8.5f, 13f, 11f, 0, 180);
                g.DrawLine(p, 12f, 19.8f, 12f, 21.6f);
                break;

            case Glyph.Waveform:
                foreach (var (x, h) in new[] { (4f, 5f), (8f, 11f), (12f, 16f), (16f, 9f), (20f, 4f) })
                    g.DrawLine(p, x, 12 - h / 2, x, 12 + h / 2);
                break;

            case Glyph.TextCheck:
                g.DrawLine(p, 4f, 6.5f, 16f, 6.5f);
                g.DrawLine(p, 4f, 11.5f, 12.5f, 11.5f);
                g.DrawLine(p, 4f, 16.5f, 10f, 16.5f);
                Check(g, p, 13.5f, 15.5f, 16f, 18f, 21f, 12.5f);
                break;

            case Glyph.Info:
                g.DrawEllipse(p, 3.2f, 3.2f, 17.6f, 17.6f);
                g.FillEllipse(b, 11.1f, 6.6f, 1.8f, 1.8f);
                g.DrawLine(p, 12f, 11f, 12f, 17f);
                break;

            case Glyph.Cpu:
                Rounded(g, p, 7f, 7f, 10f, 10f, 2f);
                for (int i = 0; i < 3; i++)
                {
                    float o = 9.5f + i * 2.5f;
                    g.DrawLine(p, o, 3.5f, o, 7f);      // top pins
                    g.DrawLine(p, o, 17f, o, 20.5f);    // bottom pins
                    g.DrawLine(p, 3.5f, o, 7f, o);      // left pins
                    g.DrawLine(p, 17f, o, 20.5f, o);    // right pins
                }
                break;

            case Glyph.Keyboard:
                Rounded(g, p, 2.5f, 6.5f, 19f, 11f, 2.5f);
                foreach (var x in new[] { 6f, 9.4f, 12.8f, 16.2f })
                    g.DrawLine(p, x, 10.3f, x + 1.8f, 10.3f);   // top key row
                g.DrawLine(p, 8f, 14.2f, 16f, 14.2f);           // space bar
                break;

            case Glyph.Timer:
                g.DrawEllipse(p, 4.5f, 6f, 15f, 15f);
                g.DrawLine(p, 12f, 13.5f, 12f, 9.5f);
                g.DrawLine(p, 9.5f, 3f, 14.5f, 3f);
                g.DrawLine(p, 12f, 3f, 12f, 6f);
                break;

            case Glyph.Screen:
                Rounded(g, p, 2.5f, 4.5f, 13f, 10f, 2f);
                Rounded(g, p, 8.5f, 9.5f, 13f, 10f, 2f);
                break;

            case Glyph.Power:
                g.DrawArc(p, 4.5f, 5.5f, 15f, 15f, -55, 290);
                g.DrawLine(p, 12f, 2.8f, 12f, 10.5f);
                break;

            case Glyph.CheckCircle:
                g.DrawEllipse(p, 3.2f, 3.2f, 17.6f, 17.6f);
                Check(g, p, 7.6f, 12.2f, 10.8f, 15.4f, 16.4f, 9f);
                break;

            case Glyph.XCircle:
                g.DrawEllipse(p, 3.2f, 3.2f, 17.6f, 17.6f);
                g.DrawLine(p, 8.8f, 8.8f, 15.2f, 15.2f);
                g.DrawLine(p, 15.2f, 8.8f, 8.8f, 15.2f);
                break;

            case Glyph.Alert:
                using (var path = new GraphicsPath())
                {
                    path.AddLine(12f, 3.4f, 21.4f, 19.6f);
                    path.AddLine(21.4f, 19.6f, 2.6f, 19.6f);
                    path.CloseFigure();
                    g.DrawPath(p, path);
                }
                g.DrawLine(p, 12f, 10f, 12f, 14.4f);
                g.FillEllipse(b, 11.2f, 16.1f, 1.6f, 1.6f);
                break;

            case Glyph.Lock:
                Rounded(g, p, 4.5f, 10.5f, 15f, 10f, 2.5f);
                g.DrawArc(p, 8f, 4f, 8f, 9f, 180, 180);
                break;

            case Glyph.Eye:
                g.DrawArc(p, 1.5f, 5.5f, 21f, 13f, 200, 140);
                g.DrawArc(p, 1.5f, 5.5f, 21f, 13f, 20, 140);
                g.DrawEllipse(p, 9.5f, 9.5f, 5f, 5f);
                break;

            case Glyph.Refresh:
                g.DrawArc(p, 4f, 4f, 16f, 16f, 60, 285);
                g.DrawLine(p, 20f, 5.2f, 20f, 10.4f);
                g.DrawLine(p, 20f, 10.4f, 14.8f, 10.4f);
                break;

            case Glyph.Globe:
                g.DrawEllipse(p, 3.2f, 3.2f, 17.6f, 17.6f);
                g.DrawEllipse(p, 8f, 3.2f, 8f, 17.6f);
                g.DrawLine(p, 3.6f, 9f, 20.4f, 9f);
                g.DrawLine(p, 3.6f, 15f, 20.4f, 15f);
                break;

            case Glyph.Link:
                g.DrawArc(p, 2.5f, 8.5f, 11f, 7f, 90, 180);
                g.DrawArc(p, 10.5f, 8.5f, 11f, 7f, 270, 180);
                g.DrawLine(p, 8f, 12f, 16f, 12f);
                break;

            case Glyph.Download:
                g.DrawLine(p, 12f, 3f, 12f, 15f);
                g.DrawLine(p, 7f, 10f, 12f, 15f);
                g.DrawLine(p, 17f, 10f, 12f, 15f);
                g.DrawLine(p, 4f, 20f, 20f, 20f);
                break;

            case Glyph.Card:
                Rounded(g, p, 2.5f, 5.5f, 19f, 13f, 2.5f);
                g.DrawLine(p, 2.5f, 10f, 21.5f, 10f);
                break;

            case Glyph.Hourglass:
                g.DrawLine(p, 6f, 3.5f, 18f, 3.5f);
                g.DrawLine(p, 6f, 20.5f, 18f, 20.5f);
                g.DrawLine(p, 7f, 3.5f, 12f, 12f);
                g.DrawLine(p, 17f, 3.5f, 12f, 12f);
                g.DrawLine(p, 7f, 20.5f, 12f, 12f);
                g.DrawLine(p, 17f, 20.5f, 12f, 12f);
                break;

            case Glyph.Desktop:
                Rounded(g, p, 2.5f, 4f, 19f, 13f, 2f);
                g.DrawLine(p, 12f, 17f, 12f, 20.5f);
                g.DrawLine(p, 8f, 20.5f, 16f, 20.5f);
                break;

            case Glyph.Trash:
                g.DrawLine(p, 4f, 6.5f, 20f, 6.5f);
                g.DrawLine(p, 9.5f, 6.5f, 9.5f, 3.5f);
                g.DrawLine(p, 14.5f, 6.5f, 14.5f, 3.5f);
                g.DrawLine(p, 9.5f, 3.5f, 14.5f, 3.5f);
                g.DrawLine(p, 6f, 6.5f, 7f, 20.5f);
                g.DrawLine(p, 18f, 6.5f, 17f, 20.5f);
                g.DrawLine(p, 7f, 20.5f, 17f, 20.5f);
                break;

            case Glyph.Pencil:
                g.DrawLine(p, 15.5f, 4f, 20f, 8.5f);
                g.DrawLine(p, 15.5f, 4f, 4.5f, 15f);
                g.DrawLine(p, 20f, 8.5f, 9f, 19.5f);
                g.DrawLine(p, 4.5f, 15f, 3.2f, 20.8f);
                g.DrawLine(p, 3.2f, 20.8f, 9f, 19.5f);
                break;

            case Glyph.Plus:
                g.DrawLine(p, 12f, 5f, 12f, 19f);
                g.DrawLine(p, 5f, 12f, 19f, 12f);
                break;

            case Glyph.Search:
                g.DrawEllipse(p, 3.5f, 3.5f, 13f, 13f);
                g.DrawLine(p, 15.6f, 15.6f, 20.5f, 20.5f);
                break;

            case Glyph.ArrowRight:
                g.DrawLine(p, 4f, 12f, 19f, 12f);
                g.DrawLine(p, 13.5f, 6.5f, 19f, 12f);
                g.DrawLine(p, 13.5f, 17.5f, 19f, 12f);
                break;

            case Glyph.Chevron:
                g.DrawLine(p, 9.5f, 5.5f, 16f, 12f);
                g.DrawLine(p, 9.5f, 18.5f, 16f, 12f);
                break;
        }
    }

    private static void Rounded(Graphics g, Pen p, float x, float y, float w, float h, float r)
    {
        using var path = RoundedPath(x, y, w, h, r);
        g.DrawPath(p, path);
    }

    private static void Check(Graphics g, Pen p, float x1, float y1, float x2, float y2, float x3, float y3)
    {
        g.DrawLine(p, x1, y1, x2, y2);
        g.DrawLine(p, x2, y2, x3, y3);
    }

    /// <summary>A rounded rectangle as a closed path. Shared with the theme's
    /// capsules and cards so every corner in the app is drawn the same way.</summary>
    public static GraphicsPath RoundedPath(float x, float y, float w, float h, float r)
    {
        r = Math.Max(0, Math.Min(r, Math.Min(w, h) / 2f));
        var path = new GraphicsPath();
        if (r <= 0)
        {
            path.AddRectangle(new RectangleF(x, y, w, h));
            return path;
        }
        float d = r * 2;
        path.AddArc(x, y, d, d, 180, 90);
        path.AddArc(x + w - d, y, d, d, 270, 90);
        path.AddArc(x + w - d, y + h - d, d, d, 0, 90);
        path.AddArc(x, y + h - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
