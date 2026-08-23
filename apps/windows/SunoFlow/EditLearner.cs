using System;
using System.Threading;
using System.Threading.Tasks;

namespace SunoFlow;

/// <summary>
/// Watches what the user changes after a dictation is pasted, and feeds the
/// (pasted, edited) pair to the sidecar so it can learn recurring spellings.
/// Windows counterpart of <c>EditLearner.swift</c>.
///
/// Reading the field is <see cref="FocusedField"/>'s job — the same reader the
/// cleanup context uses, which is also where password fields are refused. This
/// is a best-effort learner: if the field cannot be read we simply don't learn,
/// the same graceful degradation as the macOS version without Accessibility.
/// </summary>
internal sealed class EditLearner
{
    private sealed class Pending
    {
        public IntPtr Handle { get; init; }
        public string Snapshot { get; init; } = "";
    }

    private Pending? _pending;
    private Timer? _fallbackTimer;

    private const int MaxSnapshotChars = 4000;
    private const int FallbackDelayMs = 30_000;

    /// <summary>Call right after we paste text into the focused field.</summary>
    public void NoteInsertion()
    {
        // Read slightly later so the simulated Ctrl+V has actually landed.
        // Matches the macOS 0.5s delay.
        Task.Delay(500).ContinueWith(_ =>
        {
            var hwnd = FocusedField.Handle();
            if (hwnd == IntPtr.Zero) return;
            var text = FocusedField.Text(hwnd);
            if (text == null) return;
            _pending = new Pending { Handle = hwnd, Snapshot = Clamp(text) };
            _fallbackTimer?.Dispose();
            _fallbackTimer = new Timer(_ => CaptureIfNeeded(), null, FallbackDelayMs, Timeout.Infinite);
        }, TaskScheduler.Default);
    }

    /// <summary>Compare the snapshot against the field's current text and learn
    /// the diff. Safe to call anytime; a no-op if there's nothing pending.</summary>
    public void CaptureIfNeeded()
    {
        _fallbackTimer?.Dispose();
        _fallbackTimer = null;
        var pending = Interlocked.Exchange(ref _pending, null);
        if (pending == null) return;

        var current = FocusedField.Text(pending.Handle);
        if (current == null) return;
        var edited = Clamp(current);
        if (string.IsNullOrEmpty(edited) || edited == pending.Snapshot) return;

        _ = TranscriptionClient.LearnAsync(pending.Snapshot, edited).ContinueWith(t =>
        {
            if (t.IsCompletedSuccessfully && t.Result > 0)
                AppLog.Log($"Learned {t.Result} spelling(s) from your edits");
        });
    }

    private static string Clamp(string text) =>
        text.Length > MaxSnapshotChars ? text[^MaxSnapshotChars..] : text;
}
