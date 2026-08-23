using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace SunoFlow;

/// <summary>
/// The SunoFlow brand mark — an ear receiving sound.
///
/// The path strings below are copied verbatim from the website's wordmark
/// (<c>site/assets/favicon.svg</c>), so the tray, the dashboard, the app icon and
/// the web app cannot drift apart. They are SVG path data in a 24x24 box, stroked
/// at width 2 with round caps and joins. This is the C# counterpart of
/// <c>SunoFlowApp/Sources/SunoFlow/BrandMark.swift</c> and of the rasteriser in
/// <c>tools/make-icons.js</c> — three renderers, one geometry.
///
/// Unlike Quartz, GDI+ already grows y downwards, so no flip is needed here.
/// </summary>
internal static class BrandMark
{
    /// <summary>The outer ear. A closed subpath, so it can also be filled as a silhouette.</summary>
    public const string EarPath =
        "M8.9 4.3c2.8 0 4.7 2 4.7 4.8 0 2.5-1.8 3.7-2.9 5.1-.7.9-.9 1.8-.9 2.9 0 1.5-1.2 2.6-2.6 2.6s-2.6-1.2-2.6-2.6c0-1.2.4-2 .4-3.1 0-1.6-1-2.8-1-4.9 0-2.8 2.1-4.8 4.9-4.8z";

    /// <summary>The inner curl of the ear.</summary>
    public const string CurlPath =
        "M8.9 7.4c1.4 0 2.2 1 2.2 2.1 0 1.3-1.1 1.9-1.7 2.8-.4.6-.5 1.2-.5 1.9";

    /// <summary>The two arcs of sound arriving at the ear.</summary>
    public static readonly string[] WavePaths =
    {
        "M16.6 10.2a3.6 3.6 0 0 0 0 5.2",
        "M19.9 8.2a6.8 6.8 0 0 0 0 9.2",
    };

    /// <summary>The design box the paths live in, and the weight they are drawn at.</summary>
    public const float Box = 24f;
    public const float Stroke = 2f;

    /// <summary>
    /// How much of the mark to draw. The ear is always the mark; what changes is
    /// whether sound is arriving (<see cref="Idle"/>), being taken in
    /// (<see cref="Recording"/> — a filled silhouette), or not being listened for
    /// at all (<see cref="Processing"/> is busy, <see cref="Offline"/> is struck
    /// through).
    /// </summary>
    public enum Variant { Idle, Recording, Processing, Offline }

    /// <summary>
    /// Draws the mark centred in <paramref name="rect"/>, scaled to the shorter side.
    /// </summary>
    /// <param name="knockout">
    /// The colour to punch the offline slash's gap in. GDI+ has no "clear" blend
    /// mode when drawing into a control, so the gap is painted rather than erased;
    /// pass the surface colour behind the mark. Ignored for every other variant.
    /// </param>
    public static void Draw(Graphics g, RectangleF rect, Color color,
                            Variant variant = Variant.Idle, Color? knockout = null)
    {
        float scale = Math.Min(rect.Width, rect.Height) / Box;
        if (scale <= 0) return;

        using var transform = new Matrix();
        transform.Translate(rect.X + (rect.Width - Box * scale) / 2f,
                            rect.Y + (rect.Height - Box * scale) / 2f);
        transform.Scale(scale, scale);

        var savedSmoothing = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var pen = new Pen(color, Stroke * scale)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
            LineJoin = LineJoin.Round,
        };
        using var brush = new SolidBrush(color);

        using (var ear = Placed(EarPath, transform))
        {
            if (variant == Variant.Recording)
            {
                // Fill *and* stroke, so the silhouette keeps the same outer edge as
                // the outlined variants and the mark doesn't jump size on record.
                g.FillPath(brush, ear);
                g.DrawPath(pen, ear);
            }
            else
            {
                g.DrawPath(pen, ear);
                using var curl = Placed(CurlPath, transform);
                g.DrawPath(pen, curl);
            }
        }

        if (variant == Variant.Idle || variant == Variant.Recording)
        {
            foreach (var wave in WavePaths)
            {
                using var path = Placed(wave, transform);
                g.DrawPath(pen, path);
            }
        }

        if (variant == Variant.Offline)
        {
            var ends = new[] { new PointF(4.2f, 19.8f), new PointF(19.8f, 4.2f) };
            transform.TransformPoints(ends);
            if (knockout is Color gap)
            {
                // Knock a gap out from under the slash first, so it reads as one
                // stroke crossing the mark rather than a line tangled up in it.
                using var eraser = new Pen(gap, Stroke * scale * 2.4f)
                {
                    StartCap = LineCap.Round,
                    EndCap = LineCap.Round,
                };
                g.DrawLine(eraser, ends[0], ends[1]);
            }
            g.DrawLine(pen, ends[0], ends[1]);
        }

        g.SmoothingMode = savedSmoothing;
    }

    // MARK: - SVG path reading

    /// <summary>Parsed once; the mark is fixed at build time.</summary>
    private static readonly Dictionary<string, GraphicsPath> Cache = new();

    private static GraphicsPath Placed(string d, Matrix transform)
    {
        GraphicsPath? cached;
        lock (Cache)
        {
            if (!Cache.TryGetValue(d, out cached))
            {
                cached = Parse(d);
                Cache[d] = cached;
            }
        }
        var copy = (GraphicsPath)cached.Clone();
        copy.Transform(transform);
        return copy;
    }

    /// <summary>
    /// A deliberately small SVG path reader: it understands exactly the commands
    /// the mark uses (M, L, C, S, A, Z, and their relative forms). The alternative
    /// is hand-porting the curves into C#, where they would quietly drift away
    /// from the ones the website ships.
    /// </summary>
    private static GraphicsPath Parse(string d)
    {
        var path = new GraphicsPath();
        int i = 0;
        PointF cur = PointF.Empty, start = PointF.Empty;
        PointF? lastControl = null;
        char command = 'M';

        while (true)
        {
            SkipSeparators(d, ref i);
            if (i >= d.Length) break;
            if (char.IsLetter(d[i])) command = d[i++];
            bool relative = char.IsLower(command);

            switch (char.ToLowerInvariant(command))
            {
                case 'm':
                {
                    var p = Resolve(cur, relative, Number(d, ref i), Number(d, ref i));
                    path.StartFigure();
                    cur = p; start = p; lastControl = null;
                    // Extra coordinate pairs after a moveto are implicit linetos.
                    command = relative ? 'l' : 'L';
                    break;
                }
                case 'l':
                {
                    var p = Resolve(cur, relative, Number(d, ref i), Number(d, ref i));
                    path.AddLine(cur, p);
                    cur = p; lastControl = null;
                    break;
                }
                case 'c':
                {
                    var c1 = Resolve(cur, relative, Number(d, ref i), Number(d, ref i));
                    var c2 = Resolve(cur, relative, Number(d, ref i), Number(d, ref i));
                    var end = Resolve(cur, relative, Number(d, ref i), Number(d, ref i));
                    path.AddBezier(cur, c1, c2, end);
                    cur = end; lastControl = c2;
                    break;
                }
                case 's':
                {
                    // Smooth curve: the first control point mirrors the previous one.
                    var previous = lastControl ?? cur;
                    var c1 = new PointF(2 * cur.X - previous.X, 2 * cur.Y - previous.Y);
                    var c2 = Resolve(cur, relative, Number(d, ref i), Number(d, ref i));
                    var end = Resolve(cur, relative, Number(d, ref i), Number(d, ref i));
                    path.AddBezier(cur, c1, c2, end);
                    cur = end; lastControl = c2;
                    break;
                }
                case 'a':
                {
                    float rx = Number(d, ref i), ry = Number(d, ref i);
                    float rotation = Number(d, ref i);
                    bool largeArc = Number(d, ref i) != 0, sweep = Number(d, ref i) != 0;
                    var end = Resolve(cur, relative, Number(d, ref i), Number(d, ref i));
                    AddArc(path, cur, end, rx, ry, rotation, largeArc, sweep);
                    cur = end; lastControl = null;
                    break;
                }
                case 'z':
                {
                    path.CloseFigure();
                    cur = start; lastControl = null;
                    break;
                }
                default:
                    return path;   // An unsupported command: stop rather than guess.
            }
        }
        return path;
    }

    private static PointF Resolve(PointF cur, bool relative, float x, float y) =>
        relative ? new PointF(cur.X + x, cur.Y + y) : new PointF(x, y);

    private static bool IsSeparator(char c) =>
        c == ' ' || c == ',' || c == '\n' || c == '\t' || c == '\r';

    private static void SkipSeparators(string d, ref int i)
    {
        while (i < d.Length && IsSeparator(d[i])) i++;
    }

    /// <summary>Reads one number. SVG lets them run together without separators
    /// (<c>.4-3.1</c> is <c>0.4</c> then <c>-3.1</c>), so this stops at the first
    /// character that cannot continue the current number.</summary>
    private static float Number(string d, ref int i)
    {
        SkipSeparators(d, ref i);
        int begin = i;
        if (i < d.Length && (d[i] == '-' || d[i] == '+')) i++;
        bool seenDot = false;
        while (i < d.Length)
        {
            char c = d[i];
            if (c >= '0' && c <= '9') i++;
            else if (c == '.' && !seenDot) { seenDot = true; i++; }
            else break;
        }
        var text = d.Substring(begin, i - begin);
        return float.TryParse(text, System.Globalization.NumberStyles.Float,
                              System.Globalization.CultureInfo.InvariantCulture, out var value)
            ? value : 0f;
    }

    /// <summary>Endpoint-parameterised elliptical arc to cubic Béziers (SVG spec F.6.5).</summary>
    private static void AddArc(GraphicsPath path, PointF p0, PointF p1,
                               float rxIn, float ryIn, float degrees, bool largeArc, bool sweep)
    {
        if (p0 == p1) return;
        double rx = Math.Abs(rxIn), ry = Math.Abs(ryIn);
        if (rx == 0 || ry == 0) { path.AddLine(p0, p1); return; }

        double phi = degrees * Math.PI / 180.0;
        double cosPhi = Math.Cos(phi), sinPhi = Math.Sin(phi);
        double dx = (p0.X - p1.X) / 2.0, dy = (p0.Y - p1.Y) / 2.0;
        double x1 = cosPhi * dx + sinPhi * dy;
        double y1 = -sinPhi * dx + cosPhi * dy;

        // Grow the radii if they're too small to span the chord (spec F.6.6).
        double lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lambda > 1) { double s = Math.Sqrt(lambda); rx *= s; ry *= s; }

        double sign = largeArc != sweep ? 1 : -1;
        double numerator = Math.Max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1);
        double denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        double coefficient = denominator == 0 ? 0 : sign * Math.Sqrt(numerator / denominator);
        double cx1 = coefficient * rx * y1 / ry;
        double cy1 = -coefficient * ry * x1 / rx;
        double cx = cosPhi * cx1 - sinPhi * cy1 + (p0.X + p1.X) / 2.0;
        double cy = sinPhi * cx1 + cosPhi * cy1 + (p0.Y + p1.Y) / 2.0;

        static double Angle(double ux, double uy, double vx, double vy)
        {
            double length = Math.Sqrt(ux * ux + uy * uy) * Math.Sqrt(vx * vx + vy * vy);
            if (length <= 0) return 0;
            double a = Math.Acos(Math.Min(1, Math.Max(-1, (ux * vx + uy * vy) / length)));
            if (ux * vy - uy * vx < 0) a = -a;
            return a;
        }

        double ux = (x1 - cx1) / rx, uy = (y1 - cy1) / ry;
        double vx = (-x1 - cx1) / rx, vy = (-y1 - cy1) / ry;
        double theta = Angle(1, 0, ux, uy);
        double sweepAngle = Angle(ux, uy, vx, vy);
        if (!sweep && sweepAngle > 0) sweepAngle -= 2 * Math.PI;
        if (sweep && sweepAngle < 0) sweepAngle += 2 * Math.PI;

        // A cubic approximates at most a quarter turn well; split beyond that.
        int segments = Math.Max(1, (int)Math.Ceiling(Math.Abs(sweepAngle) / (Math.PI / 2)));
        double step = sweepAngle / segments;
        double k = 4.0 / 3.0 * Math.Tan(step / 4);
        PointF from = p0;

        for (int s = 0; s < segments; s++)
        {
            double next = theta + step;
            PointF On(double t) => new(
                (float)(cx + rx * cosPhi * Math.Cos(t) - ry * sinPhi * Math.Sin(t)),
                (float)(cy + rx * sinPhi * Math.Cos(t) + ry * cosPhi * Math.Sin(t)));
            PointF Tangent(double t) => new(
                (float)(-rx * cosPhi * Math.Sin(t) - ry * sinPhi * Math.Cos(t)),
                (float)(-rx * sinPhi * Math.Sin(t) + ry * cosPhi * Math.Cos(t)));

            PointF end = On(next), d0 = Tangent(theta), d1 = Tangent(next);
            path.AddBezier(
                from,
                new PointF((float)(from.X + k * d0.X), (float)(from.Y + k * d0.Y)),
                new PointF((float)(end.X - k * d1.X), (float)(end.Y - k * d1.Y)),
                end);
            from = end; theta = next;
        }
    }
}
