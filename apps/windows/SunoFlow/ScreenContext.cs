using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Linq;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Tasks;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace SunoFlow;

/// <summary>
/// Screen-context OCR for the Windows tray app — the counterpart of the macOS
/// <c>ScreenContext.swift</c>. When dictation stops, captures the primary
/// display, runs on-device OCR via <c>Windows.Media.Ocr</c> (WinRT, in-box — no
/// native dep), and returns the recognized words joined by spaces. Those words
/// go to the cleanup gateway as the <c>screen</c> field so the cleanup LLM knows
/// what app/field the user is typing into → better terminology/phrasing.
///
/// <b>Accuracy is NOT the goal</b> — only the on-screen vocabulary is extracted.
/// Only the joined words leave the machine.
///
/// <b>Best-effort:</b> every failure path returns <c>""</c>. A broken OCR must
/// never break dictation. This is the hard contract, identical to the macOS
/// version's soft-fail posture.
///
/// <b>No permission layer</b> — unlike macOS (where <c>CGDisplayCreateImage</c>
/// returns a black image without the Screen Recording TCC grant), a Windows
/// foreground process can copy the screen pixels via GDI with no prompt. So the
/// <c>hasPermission</c>/<c>openSystemSettings</c> layer from the Swift version
/// is intentionally not ported. The one Windows-specific soft-fail cause is
/// "no OCR language pack installed" (<c>OcrEngine</c> is null → return <c>""</c>).
/// </summary>
internal static class ScreenContext
{
    /// Max edge (px) we downscale the capture to before OCR. Matches the macOS
    /// <c>maxCaptureEdge</c>.
    ///
    /// This was 1600, picked to keep the OCR pass cheap when it ran between the
    /// user's last word and their pasted text. It no longer runs there — the
    /// capture starts with the recording (see TrayApp.StartScreenCapture) — so
    /// the reason to keep the image small is gone, and 1600px was costing real
    /// accuracy: on a 3420x2214 macOS capture, shrinking that far left UI text
    /// too small to read and only 49% of its 4+ letter words were real words,
    /// against 76-79% at 2400.
    ///
    /// That measurement is Apple's Vision engine, not Windows.Media.Ocr, so
    /// treat the size of the win here as unverified — but the cause (text
    /// rendered too small to recognise) is not engine-specific, and the extra
    /// pixels are free now that nobody is waiting on them.
    private const int MaxCaptureEdge = 2400;

    /// <summary>
    /// Captures the primary display, runs on-device OCR, and returns the
    /// recognized words joined by spaces. Best-effort: returns <c>""</c> on any
    /// failure (capture failed, no OCR language pack, OCR threw, no text). Runs
    /// on a background thread — caller must NOT invoke on the UI thread.
    /// </summary>
    public static async Task<string> CaptureAndRecognizeAsync()
    {
        try
        {
            // 1. Capture the primary display via GDI — no permission preflight
            //    needed on Windows (direct analogue of CGDisplayCreateImage).
            // PrimaryScreen is nullable (a session with no attached display), and
            // this whole path is best-effort, so bow out rather than throw.
            var bounds = Screen.PrimaryScreen?.Bounds ?? Rectangle.Empty;
            if (bounds.Width <= 0 || bounds.Height <= 0) return "";
            using var bmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
                g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);

            // 2. Downscale to MaxCaptureEdge on the longest edge, preserving
            //    aspect ratio. Skipped if already smaller (mirrors the macOS
            //    downscale step).
            Bitmap ocrBmp = bmp;
            bool ownsOcrBmp = false;
            try
            {
                int longest = Math.Max(bmp.Width, bmp.Height);
                if (longest > MaxCaptureEdge)
                {
                    double scale = (double)MaxCaptureEdge / longest;
                    int newW = (int)Math.Round(bmp.Width * scale);
                    int newH = (int)Math.Round(bmp.Height * scale);
                    var scaled = new Bitmap(newW, newH, PixelFormat.Format32bppArgb);
                    using (var g = Graphics.FromImage(scaled))
                    {
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.DrawImage(bmp, 0, 0, newW, newH);
                    }
                    ocrBmp = scaled;
                    ownsOcrBmp = true;
                }

                // 3. Bitmap → SoftwareBitmap via a direct BGRA buffer copy.
                //    System.Drawing's Format32bppArgb stores B-G-R-A in memory,
                //    which matches WinRT's BitmapPixelFormat.Bgra8. Stride may
                //    exceed width*4 (GDI row padding); copy row-by-row if so.
                var data = ocrBmp.LockBits(
                    new Rectangle(0, 0, ocrBmp.Width, ocrBmp.Height),
                    ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                byte[] pixels;
                try
                {
                    int rowBytes = data.Width * 4;
                    if (data.Stride == rowBytes)
                    {
                        pixels = new byte[rowBytes * data.Height];
                        Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
                    }
                    else
                    {
                        pixels = new byte[rowBytes * data.Height];
                        for (int y = 0; y < data.Height; y++)
                        {
                            Marshal.Copy(
                                data.Scan0 + y * data.Stride,
                                pixels, y * rowBytes, rowBytes);
                        }
                    }
                }
                finally
                {
                    ocrBmp.UnlockBits(data);
                }

                // BGRA8 + premultiplied alpha matches GDI's 32bppArgb layout.
                using var softwareBitmap = SoftwareBitmap.CreateCopyFromBuffer(
                    pixels.AsBuffer(), BitmapPixelFormat.Bgra8,
                    ocrBmp.Width, ocrBmp.Height, BitmapAlphaMode.Premultiplied);

                // 4. OCR — prefer the user's profile language, fall back to the
                //    first installed recognizer language. Null engine (no OCR
                //    language pack) → soft-fail to "".
                OcrEngine? engine = OcrEngine.TryCreateFromUserProfileLanguages();
                if (engine is null && OcrEngine.AvailableRecognizerLanguages.Count > 0)
                    engine = OcrEngine.TryCreateFromLanguage(OcrEngine.AvailableRecognizerLanguages[0]);
                if (engine is null)
                {
                    AppLog.Log("Screen OCR skipped — no OCR language pack installed");
                    return "";
                }

                var result = await engine.RecognizeAsync(softwareBitmap);

                // 5. Flatten lines → words → joined string (matches the macOS
                //    observations.compactMap{}.joined(" ")).
                if (result is null || result.Lines is null || result.Lines.Count == 0)
                    return "";
                var words = result.Lines
                    .SelectMany(l => l.Words)
                    .Where(w => !string.IsNullOrWhiteSpace(w.Text))
                    .Select(w => w.Text.Trim());
                var joined = string.Join(" ", words);
                return string.IsNullOrWhiteSpace(joined) ? "" : joined;
            }
            finally
            {
                if (ownsOcrBmp) ocrBmp.Dispose();
            }
        }
        catch (Exception ex)
        {
            AppLog.Log($"Screen OCR failed: {ex.Message}");
            return "";
        }
    }
}