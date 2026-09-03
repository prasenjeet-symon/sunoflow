using System;
using System.Collections.Generic;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace SunoFlow;

/// <summary>
/// Keeps dictation from dragging a Bluetooth headset into its call-quality
/// mode — the Windows counterpart of <c>BluetoothAudioGuard.swift</c>.
///
/// A Bluetooth headset exposes two things: a high-quality A2DP output, and a
/// Hands-Free mic. Opening that mic makes Windows negotiate HFP for the whole
/// link, and the headset's <b>output</b> collapses to call quality for every app
/// on the machine until the mic is released. That is why music goes muffled
/// around a dictation app — the recording itself is not the problem, engaging
/// HFP is.
///
/// <b>Where this differs from the Mac, deliberately.</b> macOS lets an app move
/// the system's default input device, so the Mac guard watches that property and
/// steers it back to the built-in mic. Windows has <i>no public API</i> to change
/// the default audio device — the only route is an undocumented COM interface
/// that Microsoft does not support and that breaks between builds. So this does
/// the honest, in-scope thing instead: it never touches the user's system
/// settings, and only chooses a different microphone <b>for SunoFlow's own
/// capture</b>, so a dictation never engages HFP. Anything else on the machine
/// keeps whatever the user chose.
///
/// It deliberately does not fight the user: an explicitly chosen microphone in
/// Settings is respected even when it is the headset. This only redirects the
/// "system default" case, which is where Windows picks the headset on its own.
/// </summary>
internal static class BluetoothAudioGuard
{
    /// <summary>
    /// The capture device SunoFlow should record from, given what the user asked
    /// for. Returns <paramref name="requested"/> unchanged in every case except
    /// the one this exists for.
    /// </summary>
    /// <param name="requested">
    /// The WinMM capture index the preferences resolved to, or -1 for the system
    /// default.
    /// </param>
    public static int PreferNonBluetooth(int requested)
    {
        if (!Preferences.Instance.ProtectBluetoothAudio) return requested;

        // An explicit choice is a choice. Only the default is redirected —
        // that is the case where Windows, not the user, picked the headset.
        if (requested >= 0) return requested;

        try
        {
            var bluetooth = BluetoothCaptureNames();
            if (bluetooth.Count == 0) return requested;

            // Which WinMM device is the system default? WinMM does not say, so
            // ask WASAPI and match on the name. WinMM truncates product names to
            // 31 characters, so compare on a prefix rather than for equality.
            string? defaultName = DefaultCaptureName();
            if (defaultName == null || !IsBluetoothName(bluetooth, defaultName)) return requested;

            // The default really is a Bluetooth mic. Find the first capture
            // device that is not.
            for (int i = 0; i < WaveInEvent.DeviceCount; i++)
            {
                var name = WaveInEvent.GetCapabilities(i).ProductName;
                if (IsBluetoothName(bluetooth, name)) continue;
                AppLog.Log($"BluetoothAudioGuard: the default microphone is '{defaultName}', " +
                           "and recording from a Bluetooth headset drops its output to call " +
                           $"quality for every app — dictating from '{name}' instead");
                return i;
            }

            // Nothing else to record from. Dictation matters more than audio
            // quality, so use the headset and say why.
            AppLog.Log("BluetoothAudioGuard: the Bluetooth headset is the only microphone — " +
                       "using it, so its output will be call quality while dictating");
            return requested;
        }
        catch (Exception ex)
        {
            // Best-effort: a machine that will not answer these questions still
            // gets to dictate.
            AppLog.Log($"BluetoothAudioGuard: could not inspect audio endpoints ({ex.Message})");
            return requested;
        }
    }

    /// <summary>True when any capture endpoint on this machine is Bluetooth.
    /// Used by Settings to decide whether the toggle is worth explaining.</summary>
    public static bool HasBluetoothInput()
    {
        try { return BluetoothCaptureNames().Count > 0; }
        catch { return false; }
    }

    /// <summary>Friendly names of the Bluetooth capture endpoints.</summary>
    private static List<string> BluetoothCaptureNames()
    {
        var names = new List<string>();
        using var enumerator = new MMDeviceEnumerator();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        {
            try
            {
                if (IsBluetooth(device)) names.Add(device.FriendlyName);
            }
            catch { /* a device that will not describe itself is treated as wired */ }
            finally { device.Dispose(); }
        }
        return names;
    }

    private static string? DefaultCaptureName()
    {
        using var enumerator = new MMDeviceEnumerator();
        if (!enumerator.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Console)) return null;
        using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        return device.FriendlyName;
    }

    /// <summary>
    /// Whether an endpoint arrived over Bluetooth, from its device instance id —
    /// "BTHENUM\..." for a Bluetooth device and "BTHHFENUM\..." for the
    /// hands-free audio function specifically. The endpoint form factor is not
    /// enough on its own: a wired headset reports the same Headset form factor
    /// and has none of this problem.
    /// </summary>
    private static bool IsBluetooth(MMDevice device)
    {
        var id = device.Properties.Contains(PropertyKeys.PKEY_Device_InstanceId)
            ? device.Properties[PropertyKeys.PKEY_Device_InstanceId].Value as string
            : null;
        if (!string.IsNullOrEmpty(id) &&
            (id!.StartsWith("BTHENUM", StringComparison.OrdinalIgnoreCase) ||
             id.StartsWith("BTHHFENUM", StringComparison.OrdinalIgnoreCase) ||
             id.StartsWith("BTHLE", StringComparison.OrdinalIgnoreCase)))
            return true;

        // Fallback for endpoints that do not publish an instance id: Windows
        // names the hands-free endpoint "Headset (…)" or "Hands-Free (…)".
        var name = device.FriendlyName ?? "";
        return name.Contains("Hands-Free", StringComparison.OrdinalIgnoreCase)
            || name.Contains("Bluetooth", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Whether a WinMM product name refers to one of the Bluetooth endpoints.
    /// WinMM truncates to 31 characters, so neither side can be assumed to be
    /// the longer one — compare on the shorter shared prefix.
    /// </summary>
    private static bool IsBluetoothName(List<string> bluetooth, string candidate)
    {
        foreach (var bt in bluetooth)
        {
            int n = Math.Min(bt.Length, candidate.Length);
            if (n == 0) continue;
            if (string.Compare(bt, 0, candidate, 0, n, StringComparison.OrdinalIgnoreCase) == 0)
                return true;
        }
        return false;
    }
}
