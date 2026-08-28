using System;
using System.Diagnostics;
using System.Reflection;
using Microsoft.Win32;

namespace SunoFlow;

/// <summary>
/// Whether this PC will actually let SunoFlow record — as opposed to whether it
/// has a microphone plugged in.
/// <para>
/// Counting devices is not the same question. Windows enumerates every input
/// device regardless of the privacy setting, so a machine with microphone access
/// switched off for desktop apps reports a full device list and then throws the
/// moment capture starts. The dashboard used to read the device count alone and
/// call that "Available", which is the one answer that is wrong in exactly the
/// case the user needs telling about.
/// </para>
/// <para>
/// Two independent signals, because neither is sufficient alone:
/// <list type="bullet">
/// <item><b>The consent store</b> — the registry keys the Windows privacy page
///   writes. Read-only, cheap, and can be checked without touching the mic (so
///   no recording indicator lights up just to draw a status row).</item>
/// <item><b>What actually happened</b> — a latch set when a real capture attempt
///   throws and cleared when one succeeds. This is the ground truth, and it
///   catches the causes the consent store knows nothing about: a device grabbed
///   in exclusive mode by another app, a driver that has fallen over.</item>
/// </list>
/// </para>
/// <para>
/// Deliberately conservative: a consent key that is missing or unreadable means
/// <i>unknown</i>, not denied. Windows only writes these once something has
/// asked, so a clean install has no entry at all — reading absence as "blocked"
/// would put a red row in front of every new user whose microphone is fine.
/// </para>
/// </summary>
internal static class MicrophoneAccess
{
    // Where the Windows privacy page records microphone consent. The global
    // gate lives on the key itself; unpackaged desktop apps like this one get a
    // per-executable entry under NonPackaged.
    private const string ConsentPath =
        @"SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    /// <summary>Why the last real capture attempt failed, or null if the last
    /// one worked (or none has been made). Ground truth, and the only signal
    /// that can see past what the privacy settings claim.</summary>
    public static string? LastCaptureFailure { get; private set; }

    /// <summary>Record that opening the microphone threw. Called from
    /// <see cref="AudioRecorder.StartRecording"/> so every caller — the tray's
    /// dictation, the onboarding level meter — feeds the same latch.</summary>
    public static void NoteCaptureFailed(string reason)
    {
        LastCaptureFailure = string.IsNullOrWhiteSpace(reason) ? "Recording could not start." : reason;
    }

    /// <summary>Record that the microphone opened. Clears the latch so a fixed
    /// problem stops being reported as a current one.</summary>
    public static void NoteCaptureSucceeded() => LastCaptureFailure = null;

    // Three registry opens, and the dashboard asks on every repaint, several
    // times per health tick. Cached briefly — a privacy setting the user has
    // just changed still shows up within a second or two, which is as fast as
    // anyone can switch windows back.
    private const long ConsentCacheMs = 1500;
    private static bool _deniedCached;
    // Not long.MinValue: TickCount64 starts near zero at boot, and the
    // subtraction below would overflow into a negative gap that reads as a
    // fresh cache — pinning the answer to its uninitialised value for good.
    private static long _deniedCheckedAt = -ConsentCacheMs - 1;

    /// <summary>True only when a consent key positively says <c>Deny</c>.
    /// Absent or unreadable keys are treated as "no objection" — see the class
    /// note on why absence must not read as denial.</summary>
    public static bool DeniedByPrivacySettings
    {
        get
        {
            long now = Environment.TickCount64;
            if (now - _deniedCheckedAt < ConsentCacheMs) return _deniedCached;
            _deniedCheckedAt = now;
            _deniedCached = ReadConsentDenied();
            return _deniedCached;
        }
    }

    private static bool ReadConsentDenied()
    {
        // Machine-wide first: an administrator turning microphone access off
        // for the whole PC overrides anything set per user.
        if (IsDeny(Registry.LocalMachine, ConsentPath)) return true;
        if (IsDeny(Registry.CurrentUser, ConsentPath)) return true;
        // "Let desktop apps access your microphone", which is the switch
        // that catches an unpackaged app like this one.
        return IsDeny(Registry.CurrentUser, ConsentPath + @"\NonPackaged\" + ConsentKeyName());
    }

    /// <summary>A one-line explanation of the current block, or null when
    /// nothing is blocking. Ordered by what the user can act on: a privacy
    /// setting has a specific place to go, a capture failure does not.</summary>
    public static string? BlockReason
    {
        get
        {
            if (DeniedByPrivacySettings)
                return "Windows is blocking microphone access. Allow it under "
                       + "Settings → Privacy & security → Microphone.";
            return LastCaptureFailure == null
                ? null
                : $"The microphone could not be opened — {LastCaptureFailure}";
        }
    }

    /// <summary>Opens the Windows microphone privacy page.</summary>
    public static void OpenPrivacySettings()
    {
        try
        {
            Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone")
            { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            AppLog.Log($"Could not open the microphone privacy settings: {ex.Message}");
        }
    }

    /// <summary>The consent store names each unpackaged app by its full
    /// executable path with the separators swapped for <c>#</c>.</summary>
    private static string ConsentKeyName() =>
        _consentKeyName ??= (Environment.ProcessPath
                             ?? Assembly.GetExecutingAssembly().Location).Replace('\\', '#');

    private static string? _consentKeyName;

    private static bool IsDeny(RegistryKey root, string path)
    {
        try
        {
            using var key = root.OpenSubKey(path);
            var value = key?.GetValue("Value") as string;
            return value != null && value.Equals("Deny", StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex)
        {
            // An unreadable consent store is not evidence of denial.
            AppLog.Log($"Could not read the microphone consent store: {ex.Message}");
            return false;
        }
    }
}
