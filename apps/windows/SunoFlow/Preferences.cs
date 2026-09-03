using System;
using System.ComponentModel;
using System.Text.Json;

namespace SunoFlow;

/// <summary>
/// App-wide user settings persisted as JSON in
/// <c>%LOCALAPPDATA%/SunoFlow/preferences.json</c>. Mirrors the macOS
/// <c>Preferences.swift</c> (which uses <c>UserDefaults</c>) — same fields,
/// same defaults, same "cleanup is server-hosted" stance. The hotkey here is a
/// (virtual-key code, modifier flags) pair, matching how Windows global
/// hotkeys work (see <see cref="HotkeyManager"/>).
/// </summary>
internal sealed class Preferences : INotifyPropertyChanged
{
    public static Preferences Instance { get; } = Load();

    private const int DefaultHotkeyCode = 0x20; // VK_SPACE
    private const int DefaultHotkeyMods = ModAlt;

    // Tone cycle: Alt+Shift+Space, the Windows analogue of the Mac's ⌥⇧Space.
    private const int DefaultToneHotkeyCode = 0x20; // VK_SPACE
    private const int DefaultToneHotkeyMods = ModAlt | ModShift;
    // Used when the default collides with a customised dictation shortcut:
    // Ctrl+Shift+Space, matching the Mac's ⌘⇧Space fallback.
    public const int FallbackToneHotkeyCode = 0x20;
    public const int FallbackToneHotkeyMods = ModControl | ModShift;

    // Win32 modifier flags for RegisterHotKey.
    public const int ModNone = 0x0000;
    public const int ModAlt = 0x0001;
    public const int ModControl = 0x0002;
    public const int ModShift = 0x0004;
    public const int ModWin = 0x0008;

    public string MicDeviceId { get; set; } = "";
    public int MaxRecordingSeconds { get; set; } = 60;
    public bool CleanupEnabled { get; set; } = true;
    public bool ScreenContextEnabled { get; set; } = false;

    /// <summary>When a dictation finishes and no text field has focus, offer the
    /// transcript instead of pasting it into nothing. On by default — the
    /// alternative is losing what the user just said.</summary>
    public bool OfferCopyWhenUnfocused { get; set; } = true;

    /// <summary>Steer capture away from a Bluetooth headset's call-quality mode.
    /// On by default, and only ever acts when the selected input really is a
    /// Bluetooth device.</summary>
    public bool ProtectBluetoothAudio { get; set; } = true;

    /// <summary>The writing voice, stored as the gateway's raw id rather than an
    /// index: an index would silently mean a different voice the moment the list
    /// gains or loses an entry. Serialized as a string so the JSON stays
    /// readable and matches what goes over the wire.</summary>
    public string ToneId { get; set; } = "";

    /// <summary>The chosen voice. Not serialized — <see cref="ToneId"/> is.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public Tone Tone
    {
        get => Tone.From(ToneId);
        set { ToneId = value.Id; Save(); OnPropertyChanged(nameof(Tone)); }
    }

    /// <summary>Advance to the next voice and hand back what it landed on, so the
    /// caller can announce it. One place for the cycle, whether it was driven
    /// from the key or from the tray menu.</summary>
    public Tone CycleTone()
    {
        Tone = Tone.Next();
        return Tone;
    }

    /// <summary>False until first-run setup has been completed (or explicitly
    /// skipped). Stored rather than inferred from "is everything configured",
    /// so someone who deletes their model later gets the model page, not the
    /// whole wizard again.</summary>
    public bool OnboardingCompleted { get; set; } = false;

    // The hotkey pair raises PropertyChanged so the TrayApp can re-register the
    // system-wide shortcut the moment the user picks a new combo in Settings.
    private int _hotkeyCode = DefaultHotkeyCode;
    private int _hotkeyModifiers = DefaultHotkeyMods;
    public int HotkeyCode
    {
        get => _hotkeyCode;
        set { _hotkeyCode = value; Save(); OnPropertyChanged(nameof(HotkeyCode)); }
    }
    public int HotkeyModifiers
    {
        get => _hotkeyModifiers;
        set { _hotkeyModifiers = value; Save(); OnPropertyChanged(nameof(HotkeyModifiers)); }
    }

    // The tone-cycle hotkey. Off by default: the dictation hotkey already does
    // something with every press, and a second system-wide shortcut should be
    // something the user opts into. Raises PropertyChanged for the same reason
    // as the pair above — TrayApp re-registers on the change.
    private bool _toneHotkeyEnabled;
    private int _toneHotkeyCode = DefaultToneHotkeyCode;
    private int _toneHotkeyModifiers = DefaultToneHotkeyMods;

    public bool ToneHotkeyEnabled
    {
        get => _toneHotkeyEnabled;
        set { _toneHotkeyEnabled = value; Save(); OnPropertyChanged(nameof(ToneHotkeyEnabled)); }
    }
    public int ToneHotkeyCode
    {
        get => _toneHotkeyCode;
        set { _toneHotkeyCode = value; Save(); OnPropertyChanged(nameof(ToneHotkeyCode)); }
    }
    public int ToneHotkeyModifiers
    {
        get => _toneHotkeyModifiers;
        set { _toneHotkeyModifiers = value; Save(); OnPropertyChanged(nameof(ToneHotkeyModifiers)); }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged(string name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    /// <summary>Restore the built-in Alt+Space shortcut.</summary>
    public void ResetHotkeyToDefault()
    {
        HotkeyCode = DefaultHotkeyCode;
        HotkeyModifiers = DefaultHotkeyMods;
        // The setters already save + raise PropertyChanged for both fields.
    }

    /// <summary>Restore the built-in Alt+Shift+Space tone shortcut.</summary>
    public void ResetToneHotkeyToDefault()
    {
        ToneHotkeyCode = DefaultToneHotkeyCode;
        ToneHotkeyModifiers = DefaultToneHotkeyMods;
    }

    /// <summary>Set while <see cref="Load"/> is populating a fresh instance. The
    /// hotkey setters persist on write, and during a load that would serialize the
    /// half-populated object straight back over the file being read — whatever had
    /// not been assigned yet would silently revert to its default.</summary>
    private static bool _loading;

    public void Save()
    {
        if (_loading) return;
        try
        {
            var dir = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SunoFlow");
            System.IO.Directory.CreateDirectory(dir);
            var path = System.IO.Path.Combine(dir, "preferences.json");
            var json = JsonSerializer.Serialize(this, JsonOpts);

            // Write beside the real file and swap it in, so a crash or a full disk
            // mid-write leaves the previous settings intact rather than a truncated
            // file the next launch cannot parse.
            var temp = path + ".tmp";
            System.IO.File.WriteAllText(temp, json);
            System.IO.File.Move(temp, path, overwrite: true);
        }
        catch (Exception ex)
        {
            AppLog.Log($"Failed to save preferences: {ex.Message}");
        }
    }

    private static Preferences Load()
    {
        try
        {
            var path = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "SunoFlow", "preferences.json");
            if (System.IO.File.Exists(path))
            {
                var json = System.IO.File.ReadAllText(path);
                _loading = true;
                try
                {
                    var p = JsonSerializer.Deserialize<Preferences>(json, JsonOpts);
                    if (p != null) return p;
                }
                finally { _loading = false; }
            }
        }
        catch (Exception ex)
        {
            AppLog.Log($"Failed to load preferences, using defaults: {ex.Message}");
        }
        return new Preferences();
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        // We write camelCase but the C# props are PascalCase, so the loader must
        // match case-insensitively or saved settings would be silently dropped.
        PropertyNameCaseInsensitive = true,
    };
}