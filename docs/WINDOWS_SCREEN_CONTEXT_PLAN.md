# Windows Screen-Context OCR — Implementation Plan

**Status:** Planned (not yet built)
**Date:** 2026-08-20
**Scope:** `apps/windows/SunoFlow/` — add on-screen OCR context to the Windows tray app, mirroring the macOS `ScreenContext.swift` feature.

---

## 1. Goal

When dictation stops, the Windows tray app captures the primary display, runs
on-device OCR, and feeds the extracted words to the cleanup gateway as
`screen` context — exactly as the macOS app does. This gives the cleanup LLM
heuristic vocabulary about the app/field the user is typing into (window
titles, menu items, nearby labels) so it picks better terminology/phrasing.

**Accuracy is NOT the goal** — only the on-screen vocabulary is extracted.
Only the joined words leave the machine, alongside the transcript, to the
cleanup endpoint.

---

## 2. Why this is simpler than macOS

The macOS implementation (`SunoFlowApp/Sources/SunoFlow/ScreenContext.swift`)
carries a whole permission layer: `CGPreflightScreenCaptureAccess`,
`CGRequestScreenCaptureAccess`, `openSystemSettings()`, and a TCC gate —
because `CGDisplayCreateImage` returns a **black image** (not nil) without the
Screen Recording permission.

**Windows has no equivalent consent wall for desktop capture.** A foreground
process can copy the screen pixels directly via GDI with no prompt and no
system setting to toggle. So the entire `hasPermission` /
`requestPermissionIfNeeded` / `openSystemSettings` layer from the macOS version
is **not ported**. There is no permission card in Settings, no preflight, no
"open System Settings" button.

The one Windows-specific soft-fail cause is **no OCR language pack installed**
(`OcrEngine.AvailableRecognizerLanguages` empty → engine is null → return `""`).
This is the Windows analogue of the macOS "permission missing" soft-fail, just
a different root cause.

---

## 3. Technology choice — Windows.Media.Ocr (WinRT)

| Option | Verdict |
|---|---|
| **Windows.Media.Ocr (WinRT)** | ✅ Chosen — built into the OS, no native dep, no GPU contention with the DirectML STT sidecar, <200ms on a downscaled capture. |
| Tesseract | ❌ Ships a ~15MB native lib + trained data, extra packaging burden. |
| PaddleOCR via ONNX | ❌ Adds a second ONNX session competing with the STT sidecar for GPU. |
| Azure Cloud OCR | ❌ Cloud round-trip + sends screen pixels off-device (privacy regression). |

**Cost of using WinRT OCR:** a `TargetFramework` bump in the `.csproj` (see
§6). The WinRT projection is built into the .NET 8 SDK when the TFM carries a
Windows 10 SDK contract version — **no NuGet package required**.

---

## 4. The flow (1:1 with macOS)

```
TrayApp.StopAndTranscribe()
  ├─ stop recorder, set State = Processing
  ├─ if (cleanupEnabled && screenContextEnabled):
  │     Task.Run(() => ScreenContext.CaptureAndRecognize())   // background thread
  │        ├─ Graphics.CopyFromScreen → Bitmap                 // primary monitor, NO permission check
  │        ├─ downscale to 1600px max edge (preserve aspect)
  │        ├─ Bitmap → SoftwareBitmap (direct BGRA buffer copy)
  │        ├─ OcrEngine.TryCreateFromUserProfileLanguages() ?? first AvailableRecognizerLanguages
  │        │     (null → soft-fail → return "")
  │        ├─ await engine.RecognizeAsync(softwareBitmap)
  │        └─ flatten result.Lines → Words → joined string
  │     then _ui.Post → SendForTranscription(wavPath, context:"", screen: <words or "">)
  └─ else:
        SendForTranscription(wavPath, context:"", screenContext: "")
```

Gated by `cleanupEnabled && screenContextEnabled` — identical to the macOS
`AppDelegate.swift` gate (lines 307–326). The existing Windows
`Preferences.ScreenContextEnabled` field (already present, default `false`) is
the gate; no new preference is needed.

---

## 5. File-by-file change list

### 5a. NEW FILE — `apps/windows/SunoFlow/ScreenContext.cs`

The Windows counterpart of `ScreenContext.swift`. One static class, best-effort,
soft-fails to `""` on any error.

**Public API (mirrors the macOS `captureAndRecognize(completion:)`):**

```csharp
internal static class ScreenContext
{
    /// Max edge (px) we downscale the capture to before OCR. Matches the macOS
    /// maxCaptureEdge (1600) — a full HiDPI screenshot is ~3-4K px; OCR on that
    /// is slow, and we only need legible words, so shrink to 1600px which keeps
    /// text crisp while cutting pixel count ~10x.
    private const int MaxCaptureEdge = 1600;

    /// Captures the primary display, runs on-device OCR, returns the recognized
    /// words joined by spaces. Best-effort: returns "" on any failure (capture
    /// failed, no OCR language pack, OCR threw, no text). Runs on a background
    /// thread — caller must NOT invoke on the UI thread.
    public static async Task<string> CaptureAndRecognizeAsync();
}
```

**Internal steps:**

1. **Capture** — `Screen.PrimaryScreen.Bounds` + `Graphics.CopyFromScreen` into
   a `Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb)`. No
   permission preflight (not needed on Windows). `Screen.PrimaryScreen` is the
   WinForms primary-monitor handle, already in scope (`UseWindowsForms` is on).
   This is the direct analogue of `CGDisplayCreateImage(CGMainDisplayID())`.

   ```csharp
   var bounds = Screen.PrimaryScreen.Bounds;
   using var bmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
   using (var g = Graphics.FromImage(bmp))
       g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
   ```

2. **Downscale** — if the longest edge > 1600, create a scaled `Bitmap` via
   `Graphics.DrawImage` with `InterpolationMode.HighQualityBicubic`, preserving
   aspect ratio. If already smaller, skip. Mirrors `downscale(_:maxEdge:)`.

3. **Bitmap → SoftwareBitmap** — direct BGRA buffer copy (no PNG re-encode):
   - `LockBits` the (downscaled) 32bppArgb bitmap read-only.
   - `System.Drawing`'s `Format32bppArgb` stores **B-G-R-A** in memory, which
     matches WinRT's `BitmapPixelFormat.Bgra8`.
   - **Stride caveat:** `BitmapData.Stride` may exceed `width * 4` (GDI pads
     rows to 4-byte boundaries — already 4-byte aligned here, but be safe). If
     `stride == width * 4`, copy the buffer in one shot; otherwise copy
     row-by-row into a tightly-packed `byte[]`.
   - `SoftwareBitmap.CreateCopyFromBuffer(pixels.AsBuffer(), Bgra8, w, h,
     Premultiplied)`.

   Chosen over the encode-to-PNG-then-decode path because it's synchronous,
   avoids a re-encode round-trip, and the capture is already downscaled so the
   buffer is small. `pixels.AsBuffer()` is a WinRT projection extension
   available automatically with the Windows TFM.

4. **OCR** —
   ```csharp
   var engine = OcrEngine.TryCreateFromUserProfileLanguages();
   if (engine is null && OcrEngine.AvailableRecognizerLanguages.Count > 0)
       engine = OcrEngine.TryCreateFromLanguage(OcrEngine.AvailableRecognizerLanguages[0]);
   if (engine is null) return "";   // no OCR language pack — soft-fail
   var result = await engine.RecognizeAsync(softwareBitmap);
   ```

5. **Flatten** — join `result.Lines.SelectMany(l => l.Words).Select(w => w.Text)`
   with spaces. Return `""` if empty. Matches the macOS
   `observations.compactMap { … }.joined(separator: " ")`.

6. **Soft-fail** — the entire method is wrapped in try/catch; any exception →
   `AppLog.Log("Screen OCR failed: {ex.Message}")` → return `""`. Identical
   posture to the macOS `recognizeText` catch + nil return.

**Threading:** the method is async and will be called inside `Task.Run` from
`StopAndTranscribe`. `RecognizeAsync` is a WinRT `IAsyncOperation` — `await`
works from any thread; no `SynchronizationContext` is captured on a
`Task.Run` thread (good — we don't want it marshalling to the UI pump mid-OCR).
The `Bitmap` is created and disposed on the same background thread.

### 5b. EDIT — `apps/windows/SunoFlow/TrayApp.cs` (`StopAndTranscribe`)

Replace the current placeholder (lines 263–284) which sends an empty `screen`:

```csharp
private async void StopAndTranscribe()
{
    _maxRecTimer?.Stop();  _maxRecTimer = null;
    _levelTimer?.Stop();   _levelTimer = null;

    var fileURL = _recorder.CurrentFile;
    if (fileURL == null) { _overlay.HideOverlay(); State = State.Idle; return; }
    _recorder.StopRecording();
    State = State.Processing;
    _overlay.UpdateMode(DictationOverlay.Mode.Processing);

    var prefs = Preferences.Instance;
    string screenContext = "";
    if (prefs.CleanupEnabled && prefs.ScreenContextEnabled)
    {
        try
        {
            screenContext = await ScreenContext.CaptureAndRecognizeAsync();
            if (!string.IsNullOrEmpty(screenContext))
                AppLog.Log($"Captured {screenContext.Length} chars of screen OCR context");
        }
        catch (Exception ex)
        {
            AppLog.Log($"Screen context capture failed: {ex.Message}");
        }
    }
    SendForTranscription(fileURL, context: "", screenContext);
}
```

> **Note on `async void`:** `StopAndTranscribe` is called from `ToggleRecording`
> (a hotkey event handler, fire-and-forget). Making it `async void` is the
> standard pattern for a WinForms event handler. The existing macOS equivalent
> is a completion-callback; the Windows version awaits inline, which is cleaner.
> The `SendForTranscription` call already marshals its HTTP work to `Task.Run`
> internally, so the UI thread is not blocked during the upload — only the
> capture+OCR (a few hundred ms) runs before the await returns. If that proves
> too long on the hotkey path, a follow-up can shift the whole block into
> `Task.Run` and `_ui.Post` the `SendForTranscription` call, but the inline
> await matches the macOS sequencing (capture completes *then* transcription
> starts) and keeps the code simple for v1.

`SendForTranscription` (lines 286–312) is **unchanged** — it already accepts a
`screenContext` string and passes it to
`TranscriptionClient.TranscribeAsync`, which already sends the `screen` multipart
field. No change to the wire protocol; the sidecar `/transcribe` endpoint
already accepts `screen: str = Form("")` and the cleanup gateway already
receives it.

### 5c. EDIT — `apps/windows/SunoFlow/SunoFlow.csproj` (TargetFramework bump)

The only way to access `Windows.Media.Ocr` (and `Windows.Graphics.Imaging`)
from .NET 8 is to carry a Windows 10 SDK contract version in the TFM. The
WinRT projection is then supplied in-box by the SDK — **no NuGet package**.

```xml
<TargetFramework>net8.0-windows10.0.19041.0</TargetFramework>
<SupportedOSPlatformVersion>10.0.19041.0</SupportedOSPlatformVersion>
```

- **`10.0.19041.0`** = Windows 10 version 2004 (build 19041), the baseline SDK
  that ships with the .NET 8 Windows workload and contains the WinRT metadata
  for `Windows.Media.Ocr` + `Windows.Graphics.Imaging` + `Windows.Foundation`.
  This is the commonly-recommended floor for .NET 8 WinRT projections.
- **`SupportedOSPlatformVersion`** must match or the compiler emits
  `CA1416` platform-compatibility warnings for every WinRT call. Setting it to
  the same value declares "this app requires Windows 10 2004+".
- The app already targets Windows 10/11 with a DX12 GPU (DirectML STT), so
  raising the floor to 19041 is a no-op for the supported audience.
- `<UseWindowsForms>true</UseWindowsForms>` stays — WinForms and WinRT
  projections coexist fine on this TFM.
- `<UseWPF>` stays false (still pure WinForms).

**Risk:** any build that worked on `net8.0-windows` but fails on
`net8.0-windows10.0.19041.0` would surface at the first Windows `dotnet build`
(which we can't run on macOS anyway — see §8). The change is additive: it only
adds WinRT projections; it removes nothing.

### 5d. EDIT — `apps/windows/SunoFlow/SettingsForm.cs` (`BuildGeneralTab` helper text)

The current screen-context checkbox (lines 178–186) has a helper label copied
from macOS:

> *"Requires the Screen Recording permission. Off by default."*

This is **wrong for Windows** — there is no Screen Recording permission for
desktop capture. Replace with the Windows-accurate caveat:

> *"Captures the screen on each dictation to give the cleanup AI on-screen
> vocabulary as context. Requires an OCR language pack (Windows Settings →
> Time & Language → Language → Optional features). Off by default."*

The checkbox itself and its `ScreenContextEnabled` binding are already correct
and need no change. No permission card / "Open System Settings" button is
added (none exists on Windows).

### 5e. EDIT — `apps/windows/README.md`

Two updates:
1. **Architecture diagram** — add a `Screen-context OCR (Windows.Media.Ocr)`
   bullet to the tray-app box, mirroring how the macOS architecture references
   Vision OCR.
2. **File table** — add a row: `ScreenContext.cs` → Screen capture + on-device
   OCR for cleanup context (`ScreenContext.swift`).
3. **Permissions section** — add a bullet: "Screen context (optional) — uses
   `Windows.Media.Ocr`; no capture permission needed, but an OCR language pack
   must be installed (Settings → Time & Language → Optional features)."
4. **Status section** — note that screen-context OCR is implemented but, like
   the rest of the Windows app, awaits the first Windows `dotnet build` to
   confirm end-to-end.

### 5f. NO CHANGE — `Preferences.cs`, `TranscriptionClient.cs`, sidecar

- `Preferences.ScreenContextEnabled` already exists (default `false`).
- `TranscriptionClient.TranscribeAsync` already sends the `screen` multipart
  field (line 131).
- The sidecar `/transcribe` endpoint already accepts `screen: str = Form("")`
  and forwards it to the cleanup gateway. The gateway's `build_cleanup_prompt`
  already includes a `[SCREEN — reference only]` section when `screen` is
  non-empty.

No protocol, sidecar, or gateway change is needed. This is a client-only feature.

---

## 6. The TargetFramework decision in detail

| TFM | WinRT OCR available? | Notes |
|---|---|---|
| `net8.0-windows` (current) | ❌ | No SDK contract version → no WinRT projection assemblies. |
| `net8.0-windows10.0.19041.0` (proposed) | ✅ | Baseline Win10 2004 SDK; in-box projection; no NuGet. |
| `net8.0-windows10.0.22621.0` | ✅ | Win11 22H2 SDK; newer APIs but higher OS floor — unnecessary for OCR. |

**Why not a NuGet package?** `Microsoft.Windows.SDK.Contracts` was the
.NET Core 3.1 / .NET 5 approach. With .NET 8 and a versioned Windows TFM, the
projection is auto-referenced by the SDK (`Microsoft.Windows.SDK.NET.Ref`). No
extra dependency, no version drift.

**`System.Drawing` + WinRT interop:** the bridge is
`System.IO.WindowsRuntimeStreamExtensions.AsRandomAccessStream()` (for the
encode/decode path) and `WindowsRuntimeBufferExtensions.AsBuffer()` (for the
direct copy path). Both are available automatically with the versioned TFM.
No `System.Drawing.Common` NuGet is needed — it's in-box for Windows TFMs
(no need for the runtime config switch that desktop-Linux users hit).

---

## 7. Edge cases & soft-fail behaviour

| Situation | Behaviour |
|---|---|
| `screenContextEnabled == false` | Skip capture entirely; send `screen: ""`. (Same as macOS.) |
| `cleanupEnabled == false` | Skip capture (no point — cleanup is off, screen words go nowhere). (Same as macOS gate.) |
| No OCR language pack installed | `OcrEngine` is null → return `""` → send `screen: ""`. Dictation proceeds normally; log a warning. (Windows analogue of macOS "permission missing".) |
| Capture throws (e.g. headless / locked screen) | try/catch → log → `""`. |
| OCR throws | try/catch → log → `""`. |
| No text recognized | `""`. |
| Multi-monitor | `Screen.PrimaryScreen` only — matches macOS `CGMainDisplayID()`. If we ever want all monitors, swap to `SystemInformation.VirtualScreen`; not for v1. |
| HiDPI / DPI scaling | `Screen.PrimaryScreen.Bounds` is logical, but `CopyFromScreen` captures the physical pixels of the whole primary display. Downscale handles it. |
| OCR language differs from user's text | `TryCreateFromUserProfileLanguages` picks the user's profile language; falls back to the first available pack. English is the common case. |

**Every failure path returns `""` and dictation continues** — screen context
is purely a best-effort enrichment. This is the hard contract: a broken OCR
must never break dictation.

---

## 8. Build & validation (cannot run on macOS)

The Windows tray app cannot be compiled on macOS (no `net8.0-windows` SDK).
This plan is **reviewed-only** until the first Windows `dotnet build`. The
validation sequence, to run on a Windows box:

1. **Build:** `cd apps\windows\SunoFlow && dotnet build -c Release`
   - Confirms the TFM bump compiles and the WinRT projections resolve.
   - Confirms `ScreenContext.cs` has no C# errors.
   - Confirms `TrayApp.StopAndTranscribe` still compiles with the async change.

2. **Smoke test (no OCR language pack):** with screen-context ON but no pack
   installed, dictate a phrase. Expect: transcript pastes normally, log shows
   `"Screen OCR failed"` or empty screen context, cleanup still runs with
   `screen: ""`. **Dictation must not break.**

3. **Smoke test (with OCR language pack):** install an English OCR pack
   (Settings → Time & Language → Optional features), open a window with
   distinctive words visible (e.g. a browser title + page text), dictate
   "email john about the project". Expect: log shows
   `Captured N chars of screen OCR context`, and the cleanup result should
   reflect on-screen vocabulary where relevant.

4. **Latency check:** time `CaptureAndRecognizeAsync` on a 1080p and a 4K
   primary display. Target <300ms end-to-end (capture + downscale + OCR). The
   macOS Vision `.fast` path is ~200ms; WinRT OCR on a 1600px capture should
   be comparable. If it's much slower, revisit the downscale target or move
   the whole capture block off the hotkey path (see the note in §5b).

5. **Full `dotnet test`** (when Windows unit tests exist) — there are currently
   no C# tests for the tray app; this is unchanged by the feature.

---

## 9. What is explicitly NOT in scope

- **No multi-monitor capture** (primary only — matches macOS v1).
- **No new preference** (`ScreenContextEnabled` already exists).
- **No sidecar / gateway / protocol change** (the `screen` field already exists
  end-to-end).
- **No permission UI** (Windows has no Screen Recording consent for desktop
  capture).
- **No GPU acceleration of OCR** (WinRT OCR is CPU-side; deliberately avoids
  competing with the DirectML STT session for GPU).
- **No macOS changes** — the macOS `ScreenContext.swift` is untouched.

---

## 10. Summary of edits

| File | Change | LOC (est.) |
|---|---|---|
| `apps/windows/SunoFlow/ScreenContext.cs` | **NEW** — capture + downscale + WinRT OCR + join words | ~90 |
| `apps/windows/SunoFlow/TrayApp.cs` | `StopAndTranscribe` — gate + await `CaptureAndRecognizeAsync` | ~15 changed |
| `apps/windows/SunoFlow/SunoFlow.csproj` | TFM → `net8.0-windows10.0.19041.0` + `SupportedOSPlatformVersion` | 2 lines |
| `apps/windows/SunoFlow/SettingsForm.cs` | Fix the wrong "Screen Recording permission" helper text | 1 line |
| `apps/windows/README.md` | Diagram + file table + permissions + status | ~10 lines |

**Total: ~1 new file + 4 small edits.** No protocol change, no sidecar change,
no new dependency, no new preference.