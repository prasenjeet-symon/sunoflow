using System;
using System.Drawing;
using System.IO;
using System.Media;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// The tray application. Owns the <c>NotifyIcon</c> + context menu, the global
/// hotkey, the recording state machine, and the transcription flow. This is the
/// Windows counterpart of the macOS <c>AppDelegate</c> — same state machine
/// (<c>sidecarOffline → idle → recording → processing → idle</c>), same soft-
/// fail behaviour, same paste-then-learn flow.
/// </summary>
internal sealed class TrayApp : IDisposable
{
    private enum State { SidecarOffline, Idle, Recording, Processing }

    private readonly NotifyIcon _tray = new();
    private readonly HotkeyManager _hotkey = new();
    private AudioRecorder _recorder = new(Preferences.Instance.MicDeviceId);
    private readonly DictationOverlay _overlay = new();
    private readonly EditLearner _editLearner = new();
    private readonly SidecarSupervisor _sidecar = new();
    private readonly System.Windows.Forms.Timer _healthTimer = new();
    private System.Windows.Forms.Timer? _maxRecTimer;

    // Captured on the UI thread at construction so async continuations can
    // marshal back to it (TrayApp is not a Control and has no BeginInvoke).
    private readonly SynchronizationContext _ui;

    private State _state = State.SidecarOffline;
    private string? _lastTranscript;

    /// <summary>Current recording/dictation state. Setting it refreshes the
    /// tray icon and status menu text, mirroring the macOS <c>didSet</c>.</summary>
    private State State
    {
        get => _state;
        set { _state = value; UpdateIcon(); UpdateStatusText(); }
    }

    // Status menu items kept as fields so we can update their text.
    private ToolStripMenuItem _statusItem = new("(disabled)") { Enabled = false };
    private ToolStripMenuItem _lastItem = new("Last: (nothing yet)") { Enabled = false };
    private ToolStripMenuItem _correctionsItem = new("Learned Corrections");
    private readonly ToolStripDropDown _correctionsMenu = new ToolStripDropDownMenu();

    public TrayApp()
    {
        _ui = SynchronizationContext.Current ?? throw new InvalidOperationException(
            "TrayApp must be constructed on the UI thread.");
        BuildMenu();
        UpdateIcon();
        UpdateStatusText();

        _hotkey.HotkeyPressed += (s, e) => ToggleRecording();
        var prefs = Preferences.Instance;
        _hotkey.Register(prefs.HotkeyCode, prefs.HotkeyModifiers);

        // In installed mode (frozen sidecar present), spawn it now so the user
        // doesn't have to launch it separately. In dev mode this is a no-op and
        // the user runs the sidecar manually, exactly as documented.
        if (_sidecar.IsAvailable)
        {
            AppLog.Log("Frozen sidecar found — starting it now");
            _sidecar.EnsureRunning();
        }
        else
        {
            AppLog.Log("No frozen sidecar at install path — assuming dev mode (run sidecar manually)");
        }

        // Re-register when the hotkey changes in Settings.
        prefs.PropertyChanged += (s, e) =>
        {
            if (e.PropertyName == nameof(Preferences.HotkeyCode) ||
                e.PropertyName == nameof(Preferences.HotkeyModifiers))
            {
                var p = Preferences.Instance;
                _hotkey.Reregister(p.HotkeyCode, p.HotkeyModifiers);
                AppLog.Log($"Hotkey re-registered: {KeyCombo.Display(p.HotkeyCode, p.HotkeyModifiers)}");
            }
        };

        _healthTimer.Interval = 3000;
        _healthTimer.Tick += (s, e) => _ = CheckHealth();
        _healthTimer.Start();
        _ = CheckHealth();
    }

    // --- Tray menu ----------------------------------------------------------------

    private void BuildMenu()
    {
        var menu = new ContextMenuStrip();

        var titleItem = new ToolStripMenuItem("SunoFlow") { Enabled = false };
        menu.Items.Add(titleItem);
        menu.Items.Add(_statusItem);
        menu.Items.Add(_lastItem);
        menu.Items.Add(new ToolStripSeparator());

        var toggleItem = new ToolStripMenuItem("Toggle Dictation (Alt+Space)");
        toggleItem.Click += (s, e) => ToggleRecording();
        menu.Items.Add(toggleItem);

        menu.Items.Add(new ToolStripSeparator());
        _correctionsItem.DropDown = _correctionsMenu;
        _correctionsItem.DropDown.Opening += (s, e) => _ = RefreshCorrectionsMenu();
        menu.Items.Add(_correctionsItem);

        var settingsItem = new ToolStripMenuItem("Settings…");
        settingsItem.Click += (s, e) => OpenSettings();
        menu.Items.Add(settingsItem);

        menu.Items.Add(new ToolStripSeparator());
        var quitItem = new ToolStripMenuItem("Quit SunoFlow");
        quitItem.Click += (s, e) => Application.Exit();
        menu.Items.Add(quitItem);

        _tray.Icon = LoadIcon("mic-idle.ico");
        _tray.Text = "SunoFlow";
        _tray.ContextMenuStrip = menu;
        _tray.Visible = true;
        _tray.DoubleClick += (s, e) => ToggleRecording();
    }

    private async Task RefreshCorrectionsMenu()
    {
        var corrections = await TranscriptionClient.FetchCorrectionsAsync();
        _correctionsMenu.Items.Clear();
        _correctionsItem.Text = corrections.Length == 0
            ? "Learned Corrections"
            : $"Learned Corrections ({corrections.Length})";

        if (corrections.Length == 0)
        {
            var none = new ToolStripMenuItem("None yet — edit pasted text to teach it") { Enabled = false };
            _correctionsMenu.Items.Add(none);
            return;
        }

        var header = new ToolStripMenuItem("Click an item to remove it:") { Enabled = false };
        _correctionsMenu.Items.Add(header);

        foreach (var c in corrections)
        {
            var suffix = c.Count > 1 ? $"  (×{c.Count})" : "";
            var item = new ToolStripMenuItem($"“{c.From}” → “{c.To}”{suffix}") { Tag = c.Key };
            item.Click += async (s, e) =>
            {
                var key = (string)((ToolStripMenuItem)s!).Tag!;
                await TranscriptionClient.DeleteCorrectionAsync(key);
                await RefreshCorrectionsMenu();
            };
            _correctionsMenu.Items.Add(item);
        }

        _correctionsMenu.Items.Add(new ToolStripSeparator());
        var clear = new ToolStripMenuItem("Clear All");
        clear.Click += async (s, e) =>
        {
            await TranscriptionClient.ClearCorrectionsAsync();
            await RefreshCorrectionsMenu();
        };
        _correctionsMenu.Items.Add(clear);
    }

    // --- Health polling ------------------------------------------------------------

    private async Task CheckHealth()
    {
        var ok = await TranscriptionClient.HealthAsync();
        _ui.Post(_ =>
        {
            if (State is State.Recording or State.Processing) return;
            if (ok)
            {
                State = State.Idle;
            }
            else
            {
                State = State.SidecarOffline;
                // In installed mode the tray app keeps the sidecar alive (the
                // Windows counterpart of the macOS LaunchAgent KeepAlive). In
                // dev mode this is a no-op.
                _sidecar.EnsureRunning();
            }
        }, null);
    }

    // --- Recording flow -----------------------------------------------------------

    private System.Windows.Forms.Timer? _levelTimer;

    private void ToggleRecording()
    {
        AppLog.Log($"ToggleRecording called, state={_state}");
        switch (_state)
        {
            case State.SidecarOffline:
                SystemSounds.Beep.Play();
                break;
            case State.Processing:
                // Never leave the user stuck: a press while processing cancels to idle.
                AppLog.Log("Press during processing — cancelling back to idle");
                _overlay.HideOverlay();
                State = State.Idle;
                break;
            case State.Idle:
                StartRecording();
                break;
            case State.Recording:
                StopAndTranscribe();
                break;
        }
    }

    private void StartRecording()
    {
        // Before recording the next utterance, learn from any edits the user
        // made to the previously pasted text.
        _editLearner.CaptureIfNeeded();
        try
        {
            _recorder = new AudioRecorder(Preferences.Instance.MicDeviceId);
            _ = _recorder.StartRecording();
            State = State.Recording;
            _overlay.Show(DictationOverlay.Mode.Recording);
            _maxRecTimer?.Dispose();
            _maxRecTimer = new System.Windows.Forms.Timer { Interval = Preferences.Instance.MaxRecordingSeconds * 1000 };
            _maxRecTimer.Tick += (s, e) =>
            {
                if (State == State.Recording)
                {
                    AppLog.Log("Max recording duration reached — auto-stopping");
                    StopAndTranscribe();
                }
            };
            _maxRecTimer.Start();

            // Animate the overlay from the capture thread's level updates.
            _levelTimer?.Dispose();
            _levelTimer = new System.Windows.Forms.Timer { Interval = 80 };
            _levelTimer.Tick += (s, e) =>
            {
                if (State == State.Recording) _overlay.UpdateLevel(_recorder.CurrentLevel);
            };
            _levelTimer.Start();
        }
        catch (Exception ex)
        {
            SystemSounds.Beep.Play();
            AppLog.Log($"Failed to start recording: {ex.Message}");
        }
    }

    private void StopAndTranscribe()
    {
        _maxRecTimer?.Stop();
        _maxRecTimer = null;
        _levelTimer?.Stop();
        _levelTimer = null;

        var fileURL = _recorder.CurrentFile;
        if (fileURL == null)
        {
            _overlay.HideOverlay();
            State = State.Idle;
            return;
        }
        _recorder.StopRecording();
        State = State.Processing;
        _overlay.UpdateMode(DictationOverlay.Mode.Processing);

        // Screen-context OCR is deferred to a later Windows-specific implementation;
        // the sidecar already handles empty `screen` gracefully. Send empty for now.
        SendForTranscription(fileURL, context: "", screenContext: "");
    }

    private void SendForTranscription(string wavPath, string context, string screenContext)
    {
        var prefs = Preferences.Instance;
        Task.Run(async () =>
        {
            var result = await TranscriptionClient.TranscribeAsync(wavPath, context, screenContext, prefs.CleanupEnabled);
            _ui.Post(_ =>
            {
                // If the user cancelled while we were transcribing, drop the result.
                if (State != State.Processing)
                {
                    TryDelete(wavPath);
                    return;
                }
                _overlay.HideOverlay();
                State = State.Idle;
                if (result != null)
                    HandleTranscript(result);
                else
                {
                    SystemSounds.Beep.Play();
                    AppLog.Log("Transcription request failed");
                }
                TryDelete(wavPath);
            }, null);
        });
    }

    private void HandleTranscript(TranscriptionClient.TranscriptionResult transcription)
    {
        var cleaned = transcription.Cleaned.Trim();
        AppLog.Log($"Transcript received — raw {transcription.Raw.Length} chars, cleaned {cleaned.Length} chars");

        if (string.IsNullOrEmpty(cleaned))
        {
            AppLog.Log("Transcript is EMPTY — nothing to insert");
            SystemSounds.Beep.Play();
            _lastItem.Text = "Last: (empty — no speech detected)";
            return;
        }

        var preview = cleaned.Length > 60 ? cleaned[..60] + "…" : cleaned;
        _lastTranscript = cleaned;
        _lastItem.Text = $"Last: {preview}";

        // Insert via clipboard + Ctrl+V. We always attempt paste (Windows has no
        // separate "accessibility permission" gate for SendInput the way macOS
        // does for CGEvent); if it fails the user can re-paste from the clipboard,
        // which we leave populated.
        TextInjector.Insert(cleaned);
        AppLog.Log($"Inserted via paste ({cleaned.Length} chars)");
        // Snapshot the field so we can learn from any edits the user makes.
        _editLearner.NoteInsertion();
    }

    // --- UI updates ---------------------------------------------------------------

    private void UpdateStatusText()
    {
        _statusItem.Text = _state switch
        {
            State.SidecarOffline => "Status: sidecar offline (start the sidecar)",
            State.Idle => "Status: idle — press Alt+Space to dictate",
            State.Recording => "Status: recording… press Alt+Space to stop",
            State.Processing => "Status: transcribing…",
            _ => "Status: unknown",
        };
    }

    private void UpdateIcon()
    {
        _tray.Icon = _state switch
        {
            State.SidecarOffline => LoadIcon("mic-offline.ico"),
            State.Idle => LoadIcon("mic-idle.ico"),
            State.Recording => LoadIcon("mic-recording.ico"),
            State.Processing => LoadIcon("mic-processing.ico"),
            _ => LoadIcon("mic-idle.ico"),
        };
    }

    internal void OpenSettings()
    {
        // May be invoked from the SingleInstance listener's threadpool thread.
        _ui.Post(_ =>
        {
            var form = new SettingsForm();
            form.Show();
        }, null);
    }

    // --- Helpers ------------------------------------------------------------------

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { /* best-effort */ }
    }

    /// <summary>Load a tray icon from the embedded resource.</summary>
    private static Icon LoadIcon(string name)
    {
        var asm = Assembly.GetExecutingAssembly();
        var fullName = $"SunoFlow.Assets.{name}";
        using var stream = asm.GetManifestResourceStream(fullName);
        if (stream != null) return new Icon(stream);
        // Fallback to the default system icon if the resource is missing (dev build).
        return SystemIcons.Application;
    }

    public void Dispose()
    {
        _healthTimer.Stop();
        _maxRecTimer?.Dispose();
        _levelTimer?.Dispose();
        _hotkey.Dispose();
        // SidecarSupervisor.Dispose() intentionally leaves the sidecar running.
        _sidecar.Dispose();
        if (_recorder.IsRecording) _recorder.StopRecording();
        _tray.Visible = false;
        _tray.Dispose();
    }
}