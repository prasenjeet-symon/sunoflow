using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace SunoFlow;

// MARK: - Design tokens

/// <summary>
/// The dashboard's design system — the C# port of the macOS <c>Theme.swift</c>.
///
/// The dashboard is one flat sheet of paper. There are no cards, no boxes, no
/// nested panels and no drop shadows: structure comes from hairline rules,
/// generous vertical rhythm, and rows that run the full width of the column so
/// nothing is left floating in dead space.
///
/// Colour is rationed. Ink for text, one accent for selection and the single
/// primary action per screen, and three semantic colours for status. Everything
/// else is paper. The palette below is the same hex the Mac app and the website
/// use, so all three read as one product.
/// </summary>
internal static class Theme
{
    // MARK: Surfaces

    /// <summary>The content sheet.</summary>
    public static readonly Color Paper = Color.FromArgb(255, 255, 255);
    /// <summary>The navigation column — a half-step warmer so the eye can tell
    /// them apart without needing a border between them.</summary>
    public static readonly Color Shell = Color.FromArgb(248, 247, 244);   // #F8F7F4
    /// <summary>A barely-there fill for inputs and pressed states.</summary>
    public static readonly Color Wash = Color.FromArgb(246, 245, 242);    // #F6F5F2

    /// <summary>The hairline between rows.</summary>
    public static readonly Color Rule = Color.FromArgb(236, 234, 230);    // #ECEAE6
    /// <summary>The heavier hairline that closes a section or the page header.</summary>
    public static readonly Color RuleStrong = Color.FromArgb(226, 223, 218); // #E2DFDA

    // MARK: Ink

    public static readonly Color Ink = Color.FromArgb(23, 23, 27);        // #17171B
    public static readonly Color Body = Color.FromArgb(90, 90, 101);      // #5A5A65
    public static readonly Color Faint = Color.FromArgb(140, 140, 150);   // #8C8C96

    // MARK: Accent

    public static readonly Color Accent = Color.FromArgb(79, 73, 181);    // #4F49B5
    public static readonly Color AccentSoft = Color.FromArgb(241, 240, 250); // #F1F0FA

    // MARK: Semantic status

    public static readonly Color Success = Color.FromArgb(22, 122, 84);   // #167A54
    public static readonly Color Warning = Color.FromArgb(156, 100, 16);  // #9C6410
    public static readonly Color Danger = Color.FromArgb(168, 58, 48);    // #A83A30

    public static Color Status(bool ok) => ok ? Success : Danger;

    // MARK: Metrics

    /// <summary>Left and right margin of the content column.</summary>
    public const int Page = 40;
    /// <summary>Space above a section's label.</summary>
    public const int Section = 34;
    /// <summary>Vertical padding inside a single row.</summary>
    public const int Row = 15;
    public const int SidebarWidth = 210;
    /// <summary>Width of the row icon column, plus the gap to the title.</summary>
    public const int IconColumn = 17;
    public const int IconGap = 13;

    // MARK: Type scale

    // Segoe UI is specified in points and the macOS system font in the design's
    // pixel-like points, so every size below is the macOS one times 0.75.
    private const string Sans = "Segoe UI";
    private static readonly bool HasSemibold = FamilyExists("Segoe UI Semibold");
    private static readonly string SemiboldFamily = HasSemibold ? "Segoe UI Semibold" : Sans;
    private static readonly FontStyle SemiboldStyle = HasSemibold ? FontStyle.Regular : FontStyle.Bold;
    private static readonly string MonoFamily =
        FamilyExists("Cascadia Mono") ? "Cascadia Mono" :
        FamilyExists("Consolas") ? "Consolas" : FontFamily.GenericMonospace.Name;

    public static Font Regular(float size) => new(Sans, size, FontStyle.Regular, GraphicsUnit.Point);
    public static Font Semibold(float size) => new(SemiboldFamily, size, SemiboldStyle, GraphicsUnit.Point);
    public static Font Monospace(float size, bool semibold = false) =>
        new(MonoFamily, size, semibold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Point);

    /// <summary>The page title. Large, tight, and the only display size in the app.</summary>
    public static readonly Font Display = Semibold(20f);
    /// <summary>A statement line — the one sentence that answers "am I set up?".</summary>
    public static readonly Font Lead = Semibold(14f);
    public static readonly Font RowTitle = Semibold(9.75f);
    public static readonly Font Value = Regular(9.75f);
    public static readonly Font BodyText = Regular(9.75f);
    public static readonly Font Caption = Regular(9f);
    /// <summary>The small capitalised label that opens a group of rows.</summary>
    public static readonly Font Kicker = Semibold(8f);
    public static readonly Font Mono = Monospace(9f);
    public static readonly Font MonoStrong = Monospace(9f, semibold: true);
    public static readonly Font ControlText = Regular(9.5f);
    public static readonly Font ControlTextStrong = Semibold(9.5f);

    private static bool FamilyExists(string name)
    {
        try
        {
            foreach (var family in FontFamily.Families)
                if (string.Equals(family.Name, name, StringComparison.OrdinalIgnoreCase)) return true;
        }
        catch { /* an unreadable font collection is not worth crashing over */ }
        return false;
    }

    // MARK: Helpers

    /// <summary>Mixes <paramref name="from"/> towards <paramref name="to"/>. Used
    /// instead of alpha compositing, because the flat sheet is always opaque and a
    /// solid colour renders crisper than a blended one.</summary>
    public static Color Blend(Color from, Color to, double amount)
    {
        amount = Math.Min(1, Math.Max(0, amount));
        return Color.FromArgb(
            (int)Math.Round(from.R + (to.R - from.R) * amount),
            (int)Math.Round(from.G + (to.G - from.G) * amount),
            (int)Math.Round(from.B + (to.B - from.B) * amount));
    }

    /// <summary>Measures wrapped text the same way <see cref="DrawText"/> draws it.
    /// Both must pass identical flags or the measured height is a lie.</summary>
    public const TextFormatFlags WrapFlags =
        TextFormatFlags.WordBreak | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix;

    public static int MeasureWrapped(string text, Font font, int width)
    {
        if (string.IsNullOrEmpty(text) || width <= 0) return 0;
        return TextRenderer.MeasureText(text, font, new Size(width, int.MaxValue), WrapFlags).Height;
    }

    public static Size MeasureLine(string text, Font font)
    {
        if (string.IsNullOrEmpty(text)) return Size.Empty;
        return TextRenderer.MeasureText(text, font, new Size(int.MaxValue, int.MaxValue),
                                        TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
    }

    public static int LineHeight(Font font) => TextRenderer.MeasureText("Hg", font,
        new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding).Height;
}

// MARK: - Layout

/// <summary>A child of <see cref="Stack"/>: something that knows its own height
/// once it is told how wide it may be.</summary>
internal interface IReflow
{
    void Reflow(int width);
}

/// <summary>
/// Lays its children out top-to-bottom at the full column width. This is the one
/// layout primitive the dashboard needs — the whole design is a single column of
/// full-width rows — and it replaces the <c>FlowLayoutPanel</c>s the old settings
/// window used, which could not stretch a row or wrap a paragraph.
/// </summary>
internal class Stack : Panel, IReflow
{
    public Stack()
    {
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
        AutoScroll = false;
    }

    /// <summary>Total height of the laid-out children, including padding.</summary>
    public int ContentHeight { get; private set; }

    private bool _laying;

    protected override void OnLayout(LayoutEventArgs e)
    {
        base.OnLayout(e);
        // Sizing a child asks its parent to lay out again, which would re-enter
        // this loop halfway through. One pass is always enough, so refuse the
        // nested one rather than paying for a cascade on every resize.
        if (_laying) return;
        int available = ClientSize.Width - Padding.Horizontal;
        if (available <= 0) return;
        _laying = true;
        try
        {
            int y = Padding.Top;
            foreach (Control child in Controls)
            {
                if (!child.Visible) continue;
                int width = Math.Max(1, available - child.Margin.Horizontal);
                if (child is IReflow reflow) reflow.Reflow(width);
                else if (child.AutoSize && child is Label label) label.MaximumSize = new Size(width, 0);
                else child.Width = width;

                y += child.Margin.Top;
                child.Location = new Point(Padding.Left + child.Margin.Left, y);
                y += child.Height + child.Margin.Bottom;
            }
            ContentHeight = y + Padding.Bottom;
        }
        finally { _laying = false; }
    }

    public virtual void Reflow(int width)
    {
        if (Width != width) Width = width;
        PerformLayout();
        if (Height != ContentHeight) Height = ContentHeight;
    }

    /// <summary>Adds children in reading order and returns the stack, so a page
    /// can be written as one expression.</summary>
    public Stack With(params Control[] children)
    {
        Controls.AddRange(children);
        return this;
    }
}

/// <summary>Vertical breathing room between groups.</summary>
internal sealed class Spacer : Control, IReflow
{
    public Spacer(int height)
    {
        SetStyle(ControlStyles.Selectable, false);
        Height = height;
    }

    public void Reflow(int width) => Width = width;
}

/// <summary>The hairline that does all the structural work in this design.</summary>
internal sealed class RuleLine : Control, IReflow
{
    public RuleLine(bool strong = false)
    {
        SetStyle(ControlStyles.Selectable, false);
        Height = 1;
        BackColor = strong ? Theme.RuleStrong : Theme.Rule;
    }

    public void Reflow(int width)
    {
        Width = width;
        Height = 1;
    }
}

// MARK: - Section label

/// <summary>
/// The small capitalised label that opens a group of rows, and the heavier rule
/// that closes the header. It replaces what would otherwise be a card header —
/// same job, none of the chrome.
/// </summary>
internal sealed class SectionHeader : Control, IReflow
{
    private readonly string _title;
    private string? _trailing;

    public SectionHeader(string title, string? trailing = null)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        _title = title.ToUpperInvariant();
        _trailing = trailing;
    }

    /// <summary>The right-hand count ("2 of 3 ready"). Null hides it.</summary>
    public void SetTrailing(string? text)
    {
        if (_trailing == text) return;
        _trailing = text;
        Invalidate();
    }

    public void Reflow(int width)
    {
        Width = width;
        Height = Theme.Section + Theme.LineHeight(Theme.Kicker) + 9 + 1;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        int lineHeight = Theme.LineHeight(Theme.Kicker);
        var band = new Rectangle(0, Theme.Section, Width, lineHeight);

        TextRenderer.DrawText(g, _title, Theme.Kicker, band, Theme.Faint,
            TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        if (!string.IsNullOrEmpty(_trailing))
        {
            TextRenderer.DrawText(g, _trailing, Theme.Caption, band, Theme.Faint,
                TextFormatFlags.Right | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }

        using var pen = new Pen(Theme.RuleStrong);
        g.DrawLine(pen, 0, Height - 1, Width, Height - 1);
    }
}

// MARK: - Text

/// <summary>A paragraph that wraps to the column and reports its own height.</summary>
internal sealed class TextBlock : Control, IReflow
{
    public TextBlock(string text, Font? font = null, Color? color = null)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        Font = font ?? Theme.BodyText;
        ForeColor = color ?? Theme.Body;
        Text = text;
    }

    public void SetText(string text)
    {
        if (Text == text) return;
        Text = text;
        if (Width > 0) Reflow(Width);
        Invalidate();
    }

    public void Reflow(int width)
    {
        Width = width;
        Height = Math.Max(0, Theme.MeasureWrapped(Text, Font, width));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(BackColor);
        TextRenderer.DrawText(e.Graphics, Text, Font, new Rectangle(0, 0, Width, Height),
                              ForeColor, Theme.WrapFlags);
    }
}

// MARK: - Status

/// <summary>A status word with a dot. No capsule, no border — on a flat sheet the
/// colour and the dot are enough.</summary>
internal sealed class StatusText : Control
{
    private const int Dot = 6;
    private const int Gap = 6;

    public StatusText(string text, Color color)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        Font = Theme.Value;
        Set(text, color);
    }

    public void Set(string text, Color color)
    {
        Text = text;
        ForeColor = color;
        var size = Theme.MeasureLine(text, Font);
        Size = new Size(Dot + Gap + size.Width, Math.Max(Dot, size.Height));
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var brush = new SolidBrush(ForeColor))
            g.FillEllipse(brush, 0, (Height - Dot) / 2f, Dot, Dot);
        TextRenderer.DrawText(g, Text, Font,
            new Rectangle(Dot + Gap, 0, Width - Dot - Gap, Height), ForeColor,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter
            | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
    }
}

/// <summary>An inline advisory line. Tinted glyph and text, sitting directly on
/// the page rather than inside a coloured box.</summary>
internal sealed class SunoNotice : Control, IReflow
{
    private readonly Glyph _glyph;
    private readonly Color _tint;

    public SunoNotice(string text, Glyph glyph = Glyph.Alert, Color? tint = null)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        _glyph = glyph;
        _tint = tint ?? Theme.Warning;
        Font = Theme.Caption;
        ForeColor = Theme.Body;
        Text = text;
    }

    public void SetText(string text)
    {
        if (Text == text) return;
        Text = text;
        if (Width > 0) Reflow(Width);
        Invalidate();
    }

    private const int GlyphSize = 14;
    private const int Gap = 9;

    public void Reflow(int width)
    {
        Width = width;
        int textWidth = Math.Max(1, width - GlyphSize - Gap);
        Height = Math.Max(GlyphSize, Theme.MeasureWrapped(Text, Font, textWidth));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        Glyphs.Draw(g, _glyph, new RectangleF(0, 0.5f, GlyphSize, GlyphSize), _tint);
        TextRenderer.DrawText(g, Text, Font,
            new Rectangle(GlyphSize + Gap, 0, Width - GlyphSize - Gap, Height),
            ForeColor, Theme.WrapFlags);
    }
}

/// <summary>A flat progress track for the model download.</summary>
internal sealed class SunoProgress : Control, IReflow
{
    private double _fraction;

    public SunoProgress()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        Height = 4;
    }

    public void SetProgress(double value, double total)
    {
        double fraction = total > 0 ? Math.Min(1, Math.Max(0, value / total)) : 0;
        if (Math.Abs(fraction - _fraction) < 0.0005) return;
        _fraction = fraction;
        Invalidate();
    }

    public void Reflow(int width)
    {
        Width = width;
        Height = 4;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var track = Glyphs.RoundedPath(0, 0, Width, Height, Height / 2f))
        using (var brush = new SolidBrush(Theme.RuleStrong))
            g.FillPath(brush, track);

        float filled = (float)Math.Max(Height, Width * _fraction);
        if (filled <= 0) return;
        using (var bar = Glyphs.RoundedPath(0, 0, filled, Height, Height / 2f))
        using (var brush = new SolidBrush(Theme.Accent))
            g.FillPath(brush, bar);
    }
}

// MARK: - Rows

/// <summary>
/// The workhorse. A full-width line: an optional glyph, a title with an optional
/// explanation beneath it, and whatever control belongs on the right.
///
/// Rows draw their own bottom hairline so a run of them reads as one table; set
/// <see cref="Divider"/> to false on the last row of a group.
/// </summary>
internal sealed class SunoRow : Panel, IReflow
{
    private string _title;
    private string? _subtitle;

    public SunoRow(string title, string? subtitle = null, Glyph glyph = Glyph.None,
                   Color? glyphColor = null, bool divider = true, Control? trailing = null)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer, true);
        _title = title;
        _subtitle = subtitle;
        Icon = glyph;
        IconColor = glyphColor ?? Theme.Faint;
        Divider = divider;
        if (trailing != null)
        {
            Trailing = trailing;
            Controls.Add(trailing);
        }
    }

    public Glyph Icon { get; set; }
    public Color IconColor { get; set; }
    public bool Divider { get; set; }
    public Control? Trailing { get; private set; }

    /// <summary>Reserve the glyph column even without a glyph, so every title in a
    /// group shares a left edge instead of stepping in and out.</summary>
    public bool ReserveIconColumn { get; set; }

    public void SetTitle(string title) { _title = title; Invalidate(); }
    public void SetSubtitle(string? subtitle) { _subtitle = subtitle; if (Width > 0) Reflow(Width); Invalidate(); }
    public void SetIcon(Glyph glyph, Color color) { Icon = glyph; IconColor = color; Invalidate(); }

    private int TextLeft => Icon != Glyph.None || ReserveIconColumn ? Theme.IconColumn + Theme.IconGap : 0;

    public void Reflow(int width)
    {
        Width = width;
        int trailingWidth = Trailing is { Visible: true } ? Trailing.Width + 16 : 0;
        int textWidth = Math.Max(1, width - TextLeft - trailingWidth);

        int titleHeight = Theme.MeasureWrapped(_title, Theme.RowTitle, textWidth);
        int subtitleHeight = string.IsNullOrEmpty(_subtitle)
            ? 0 : 2 + Theme.MeasureWrapped(_subtitle, Theme.Caption, textWidth);
        int content = Math.Max(titleHeight + subtitleHeight,
                               Trailing is { Visible: true } ? Trailing.Height : 0);

        Height = Theme.Row * 2 + content + (Divider ? 1 : 0);
        if (Trailing is { Visible: true })
        {
            Trailing.Location = new Point(
                width - Trailing.Width,
                (Height - (Divider ? 1 : 0) - Trailing.Height) / 2);
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);

        int trailingWidth = Trailing is { Visible: true } ? Trailing.Width + 16 : 0;
        int textWidth = Math.Max(1, Width - TextLeft - trailingWidth);
        int titleHeight = Theme.MeasureWrapped(_title, Theme.RowTitle, textWidth);
        int subtitleHeight = string.IsNullOrEmpty(_subtitle)
            ? 0 : 2 + Theme.MeasureWrapped(_subtitle, Theme.Caption, textWidth);
        int band = Height - (Divider ? 1 : 0);
        int top = (band - titleHeight - subtitleHeight) / 2;

        if (Icon != Glyph.None)
        {
            Glyphs.Draw(g, Icon,
                new RectangleF(0, (band - Theme.IconColumn) / 2f, Theme.IconColumn, Theme.IconColumn),
                IconColor);
        }

        TextRenderer.DrawText(g, _title, Theme.RowTitle,
            new Rectangle(TextLeft, top, textWidth, titleHeight), Theme.Ink, Theme.WrapFlags);
        if (subtitleHeight > 0)
        {
            TextRenderer.DrawText(g, _subtitle, Theme.Caption,
                new Rectangle(TextLeft, top + titleHeight + 2, textWidth, subtitleHeight - 2),
                Theme.Faint, Theme.WrapFlags);
        }

        if (Divider)
        {
            using var pen = new Pen(Theme.Rule);
            g.DrawLine(pen, 0, Height - 1, Width, Height - 1);
        }
    }
}

/// <summary>A label on the left, a value hard right. Used for read-only summaries.</summary>
internal sealed class ValueText : Control
{
    public ValueText(string text, Font? font = null, Color? color = null)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        Font = font ?? Theme.Value;
        ForeColor = color ?? Theme.Ink;
        Set(text);
    }

    public void Set(string text, Color? color = null)
    {
        Text = text;
        if (color.HasValue) ForeColor = color.Value;
        var size = Theme.MeasureLine(text, Font);
        Size = new Size(Math.Max(1, size.Width), Math.Max(1, size.Height));
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(BackColor);
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, ForeColor,
            TextFormatFlags.Right | TextFormatFlags.VerticalCenter
            | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
    }
}

// MARK: - Buttons

internal enum ButtonKind
{
    /// <summary>The one filled action per screen: solid ink, like the website.</summary>
    Primary,
    /// <summary>The neutral action: a soft fill, no border.</summary>
    Secondary,
    /// <summary>A text action for tertiary things ("Reset", "Clear all").</summary>
    Ghost,
    /// <summary>A compact glyph button for row-level actions.</summary>
    Icon,
}

/// <summary>A capsule button in the dashboard's three weights, plus a glyph-only
/// variant for row actions. Owner-drawn, because a themed WinForms
/// <see cref="Button"/> cannot be made to sit flat on the sheet.</summary>
internal sealed class SunoButton : Control
{
    private readonly ButtonKind _kind;
    private readonly Glyph _glyph;
    private bool _hovering;
    private bool _pressed;
    private Color _tint;
    private ToolTip? _tip;

    public SunoButton(string text, ButtonKind kind = ButtonKind.Secondary, Color? tint = null)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        _kind = kind;
        _glyph = Glyph.None;
        _tint = tint ?? (kind == ButtonKind.Ghost ? Theme.Accent : Theme.Ink);
        Font = kind == ButtonKind.Primary ? Theme.ControlTextStrong : Theme.ControlText;
        Cursor = Cursors.Hand;
        SetText(text);
    }

    public SunoButton(Glyph glyph, Color tint, string tooltip = "")
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        _kind = ButtonKind.Icon;
        _glyph = glyph;
        _tint = tint;
        Cursor = Cursors.Hand;
        Size = new Size(24, 24);
        if (tooltip.Length > 0)
        {
            // Held in a field: a ToolTip nobody references is collectable, and
            // the hint silently stops appearing once the GC gets to it.
            _tip = new ToolTip();
            _tip.SetToolTip(this, tooltip);
        }
    }

    /// <summary>Sets the label and resizes to fit it. Buttons in this design are
    /// sized by their text, never by a fixed grid.</summary>
    public void SetText(string text)
    {
        Text = text;
        if (_kind == ButtonKind.Icon) return;
        var size = Theme.MeasureLine(text, Font);
        int padX = _kind switch
        {
            ButtonKind.Primary => 15,
            ButtonKind.Secondary => 14,
            _ => 0,
        };
        int padY = _kind == ButtonKind.Ghost ? 2 : 7;
        Size = new Size(size.Width + padX * 2, size.Height + padY * 2);
        Invalidate();
    }

    public void SetTint(Color tint) { _tint = tint; Invalidate(); }

    protected override void OnMouseEnter(EventArgs e) { _hovering = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hovering = false; _pressed = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { _pressed = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _pressed = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;

        if (_kind == ButtonKind.Icon)
        {
            var color = Enabled
                ? (_hovering ? _tint : Theme.Blend(Theme.Faint, BackColor, 0.25))
                : Theme.Blend(Theme.Faint, BackColor, 0.6);
            Glyphs.Draw(g, _glyph, new RectangleF(5, 5, Width - 10, Height - 10), color);
            return;
        }

        if (_kind == ButtonKind.Ghost)
        {
            var color = Enabled
                ? (_hovering ? Theme.Blend(_tint, BackColor, 0.3) : _tint)
                : Theme.Blend(_tint, BackColor, 0.65);
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, color,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter
                | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
            return;
        }

        Color fill, ink;
        if (_kind == ButtonKind.Primary)
        {
            fill = _hovering ? Theme.Blend(_tint, Color.White, 0.12) : _tint;
            if (_pressed) fill = Theme.Blend(fill, Color.Black, 0.1);
            ink = Color.White;
            if (!Enabled) { fill = Theme.Blend(_tint, BackColor, 0.68); ink = Theme.Blend(Color.White, fill, 0.15); }
        }
        else
        {
            fill = _hovering ? Theme.RuleStrong : Theme.Wash;
            if (_pressed) fill = Theme.Blend(fill, Theme.Ink, 0.06);
            ink = Theme.Ink;
            if (!Enabled) { fill = Theme.Wash; ink = Theme.Blend(Theme.Ink, fill, 0.65); }
        }

        using (var path = Glyphs.RoundedPath(0, 0, Width, Height, Height / 2f))
        using (var brush = new SolidBrush(fill))
            g.FillPath(brush, path);

        TextRenderer.DrawText(g, Text, Font, ClientRectangle, ink,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter
            | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
    }
}

// MARK: - Switch

/// <summary>The brand toggle: an accent-filled pill. Mirrors the small tinted
/// <c>Toggle(.switch)</c> the Mac dashboard uses for every on/off setting.</summary>
internal sealed class SunoToggle : Control
{
    private bool _on;
    private bool _hovering;

    public event EventHandler? Toggled;

    public SunoToggle(bool on)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        _on = on;
        Size = new Size(38, 22);
        Cursor = Cursors.Hand;
    }

    public bool Checked
    {
        get => _on;
        set { if (_on == value) return; _on = value; Invalidate(); }
    }

    /// <summary>Sets the state without raising <see cref="Toggled"/>, for when the
    /// UI is catching up with a value that changed elsewhere.</summary>
    public void SetSilently(bool on) => Checked = on;

    protected override void OnMouseEnter(EventArgs e) { _hovering = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hovering = false; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnClick(EventArgs e)
    {
        if (!Enabled) return;
        _on = !_on;
        Invalidate();
        base.OnClick(e);
        Toggled?.Invoke(this, EventArgs.Empty);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;

        var track = _on ? Theme.Accent : Theme.RuleStrong;
        if (!Enabled) track = Theme.Blend(track, BackColor, 0.6);
        else if (_hovering) track = Theme.Blend(track, Theme.Ink, 0.08);

        using (var path = Glyphs.RoundedPath(0, 0, Width, Height, Height / 2f))
        using (var brush = new SolidBrush(track))
            g.FillPath(brush, path);

        float knob = Height - 6;
        float x = _on ? Width - knob - 3 : 3;
        using var knobBrush = new SolidBrush(Color.White);
        g.FillEllipse(knobBrush, x, 3, knob, knob);
    }
}

// MARK: - Stepper

/// <summary>A compact value stepper — the Windows stand-in for the Mac
/// <c>Stepper</c>. A wash capsule holding the value and two chevrons.</summary>
internal sealed class SunoStepper : Control
{
    private readonly int _min, _max, _step;
    private readonly string _suffix;
    private int _value;
    private int _hotHalf = -1;   // 0 = up, 1 = down, -1 = neither

    public event EventHandler? ValueChanged;

    public SunoStepper(int value, int min, int max, int step, string suffix = "")
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        _min = min; _max = max; _step = step; _suffix = suffix;
        _value = Math.Min(max, Math.Max(min, value));
        Size = new Size(104, 30);
    }

    public int Value
    {
        get => _value;
        set
        {
            int clamped = Math.Min(_max, Math.Max(_min, value));
            if (clamped == _value) return;
            _value = clamped;
            Invalidate();
            ValueChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private const int ButtonWidth = 26;

    protected override void OnMouseMove(MouseEventArgs e)
    {
        int half = e.X < Width - ButtonWidth ? -1 : (e.Y < Height / 2 ? 0 : 1);
        if (half != _hotHalf) { _hotHalf = half; Invalidate(); }
        base.OnMouseMove(e);
    }

    protected override void OnMouseLeave(EventArgs e) { _hotHalf = -1; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (Enabled && e.X >= Width - ButtonWidth)
            Value += e.Y < Height / 2 ? _step : -_step;
        base.OnMouseDown(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;

        using (var path = Glyphs.RoundedPath(0, 0, Width, Height, 7f))
        using (var brush = new SolidBrush(Theme.Wash))
            g.FillPath(brush, path);

        var label = _suffix.Length > 0 ? $"{_value} {_suffix}" : _value.ToString();
        TextRenderer.DrawText(g, label, Theme.Value,
            new Rectangle(11, 0, Width - ButtonWidth - 14, Height), Theme.Ink,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter
            | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);

        using var pen = new Pen(Theme.Faint, 1.4f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        float cx = Width - ButtonWidth / 2f;
        DrawChevron(g, pen, cx, Height * 0.32f, up: true, hot: _hotHalf == 0);
        DrawChevron(g, pen, cx, Height * 0.68f, up: false, hot: _hotHalf == 1);
    }

    private static void DrawChevron(Graphics g, Pen pen, float cx, float cy, bool up, bool hot)
    {
        var saved = pen.Color;
        pen.Color = hot ? Theme.Ink : Theme.Faint;
        float dy = up ? 2f : -2f;
        g.DrawLine(pen, cx - 3.5f, cy + dy, cx, cy - dy);
        g.DrawLine(pen, cx + 3.5f, cy + dy, cx, cy - dy);
        pen.Color = saved;
    }
}

// MARK: - Text field

/// <summary>Text fields on a flat sheet: a soft well, no border, no focus-ring
/// fight. Hosts a real <see cref="TextBox"/> so editing, selection and IME all
/// behave, and paints the well behind it.</summary>
internal sealed class SunoField : Control
{
    public readonly TextBox Box = new();

    public SunoField(string placeholder, int width = 180)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        Box.BorderStyle = BorderStyle.None;
        Box.BackColor = Theme.Wash;
        Box.ForeColor = Theme.Ink;
        Box.Font = Theme.BodyText;
        Box.PlaceholderText = placeholder;
        Controls.Add(Box);
        Size = new Size(width, Theme.LineHeight(Theme.BodyText) + 14);
    }

    public string Value
    {
        get => Box.Text.Trim();
        set => Box.Text = value;
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        Box.SetBounds(11, (Height - Box.PreferredHeight) / 2, Math.Max(1, Width - 22), Box.PreferredHeight);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Glyphs.RoundedPath(0, 0, Width, Height, 7f);
        using var brush = new SolidBrush(Theme.Wash);
        g.FillPath(brush, path);
    }
}

// MARK: - Hotkey recorder

/// <summary>
/// A click-to-record shortcut field, the Windows counterpart of the macOS
/// <c>HotkeyRecorderNSView</c>. Clicking arms it; the next combination becomes the
/// new hotkey. Esc cancels, and a bare key with no modifier is rejected so the
/// shortcut cannot hijack ordinary typing.
/// </summary>
internal sealed class HotkeyField : Control
{
    private bool _armed;
    private bool _hovering;

    public int KeyCode { get; private set; }
    public int Modifiers { get; private set; }

    /// <summary>Raised when a new combination has been captured.</summary>
    public event EventHandler? Captured;

    public HotkeyField(int keyCode, int modifiers)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, true);
        TabStop = true;
        KeyCode = keyCode;
        Modifiers = modifiers;
        Size = new Size(160, 32);
        Cursor = Cursors.Hand;
    }

    public void Set(int keyCode, int modifiers)
    {
        KeyCode = keyCode;
        Modifiers = modifiers;
        Invalidate();
    }

    protected override void OnMouseEnter(EventArgs e) { _hovering = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hovering = false; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (_armed) Disarm();
        else { _armed = true; Focus(); Invalidate(); }
    }

    protected override void OnLostFocus(EventArgs e) { Disarm(); base.OnLostFocus(e); }

    private void Disarm()
    {
        if (!_armed) return;
        _armed = false;
        Invalidate();
    }

    // WM_KEYDOWN / WM_SYSKEYDOWN. Intercepting here rather than in OnKeyDown is
    // what lets the field capture Tab, Esc, the arrows and Alt-combinations —
    // keys the form would otherwise consume as navigation before we ever see them.
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (!_armed || (msg.Msg != WM_KEYDOWN && msg.Msg != WM_SYSKEYDOWN))
            return base.ProcessCmdKey(ref msg, keyData);

        var key = keyData & Keys.KeyCode;
        if (key == Keys.Escape) { Disarm(); return true; }

        // Pure modifier presses are not a shortcut on their own.
        if (key is Keys.ControlKey or Keys.Menu or Keys.ShiftKey or Keys.LWin or Keys.RWin
                or Keys.LControlKey or Keys.RControlKey or Keys.LShiftKey or Keys.RShiftKey)
            return true;

        int mods = Preferences.ModNone;
        if ((keyData & Keys.Control) != 0) mods |= Preferences.ModControl;
        if ((keyData & Keys.Alt) != 0) mods |= Preferences.ModAlt;
        if ((keyData & Keys.Shift) != 0) mods |= Preferences.ModShift;
        // The Windows key never reaches an app as a modifier flag — the shell
        // swallows it — so a Win-based shortcut cannot be recorded here. Nothing
        // to read, and nothing worth pretending about.

        // A function key stands alone; anything else needs a modifier, or the
        // shortcut would fire in the middle of ordinary typing.
        bool standalone = key >= Keys.F1 && key <= Keys.F24;
        if (mods == Preferences.ModNone && !standalone)
        {
            System.Media.SystemSounds.Beep.Play();
            return true;
        }

        KeyCode = (int)key;
        Modifiers = mods;
        Disarm();
        Captured?.Invoke(this, EventArgs.Empty);
        return true;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;

        using var path = Glyphs.RoundedPath(0.5f, 0.5f, Width - 1, Height - 1, 9f);
        var fill = _armed ? Theme.AccentSoft : _hovering ? Theme.RuleStrong : Theme.Wash;
        using (var brush = new SolidBrush(fill)) g.FillPath(brush, path);
        using (var pen = new Pen(_armed ? Theme.Accent : Theme.RuleStrong, _armed ? 1.8f : 1f))
            g.DrawPath(pen, path);

        var text = _armed ? "Type shortcut…" : KeyCombo.Display(KeyCode, Modifiers);
        TextRenderer.DrawText(g, text, Theme.ControlTextStrong, ClientRectangle,
            _armed ? Theme.Accent : Theme.Ink,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter
            | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
    }
}

// MARK: - Sidebar navigation

/// <summary>One row of the dashboard's navigation column.</summary>
internal sealed class NavButton : Control, IReflow
{
    private readonly Glyph _glyph;
    private bool _selected;
    private bool _hovering;

    public NavButton(string title, Glyph glyph)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                 | ControlStyles.OptimizedDoubleBuffer, true);
        SetStyle(ControlStyles.Selectable, false);
        _glyph = glyph;
        Text = title;
        Height = Theme.LineHeight(Theme.Value) + 16;
        Cursor = Cursors.Hand;
        BackColor = Theme.Shell;
    }

    public bool Selected
    {
        get => _selected;
        set { if (_selected == value) return; _selected = value; Invalidate(); }
    }

    public void Reflow(int width) => Width = width;

    protected override void OnMouseEnter(EventArgs e) { _hovering = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hovering = false; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var background = _selected ? Theme.AccentSoft
            : _hovering ? Theme.Blend(Theme.Shell, Theme.Rule, 0.55) : Theme.Shell;
        g.Clear(background);

        if (_selected)
        {
            using var bar = new SolidBrush(Theme.Accent);
            g.FillRectangle(bar, 0, 0, 2, Height);
        }

        Glyphs.Draw(g, _glyph, new RectangleF(20, (Height - 16) / 2f, 16, 16),
                    _selected ? Theme.Accent : Theme.Faint);
        TextRenderer.DrawText(g, Text, _selected ? Theme.ControlTextStrong : Theme.Value,
            new Rectangle(20 + 16 + 11, 0, Width - 47, Height),
            _selected ? Theme.Ink : Theme.Body,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter
            | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
    }
}
