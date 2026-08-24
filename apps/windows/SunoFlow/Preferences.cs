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