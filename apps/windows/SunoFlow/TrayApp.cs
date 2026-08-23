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

    // Read from /health every poll. The engine being up says nothing about
    // whether it can produce words: with no model downloaded it answers every
    // clip with an empty transcript.
    private bool _modelLoaded;

    /// <summary>The running tray app. The dashboard reads it to start the engine
    /// and to ask whether starting it is even possible on this install.</summary>
    internal static TrayApp? Shared { get; private set; }

    /// <summary>Current recording/dictation state. Setting it refreshes the
    /// tray icon and status menu text, mirroring the macOS <c>didSet</c>.</summary>
    private State CurrentState
    {
        get => _state;
        set { _state = value; UpdateIcon(); UpdateStatusText(); }
    }

    // Status menu items kept as fields so we can update their text.
    private ToolStripMenuItem _statusItem = new("(disabled)") { Enabled = false };
    private ToolStripMenuItem _lastItem = new("Last: (nothing yet)") { Enabled = false };
    private ToolStripMenuItem _correctionsItem = new("Dictionary");
    private readonly ToolStripDropDown _correctionsMenu = new ToolStripDropDownMenu();
    private readonly ToolStripMenuItem _toggleItem = new("Toggle Dictation");

    /// <summary>The shortcut as the user has it right now. Everything that names
    /// the hotkey reads this, so rebinding it in Settings updates the tray menu,
    /// the status line and the recording overlay together — rather than leaving
    /// three places claiming Alt+Space long after it stopped being true.</summary>
    private static string HotkeyLabel =>
        KeyCombo.Display(Preferences.Instance.HotkeyCode, Preferences.Instance.HotkeyModifiers);

    public TrayApp()
    {
        _ui = SynchronizationContext.Current ?? throw new InvalidOperationException(
            "TrayApp must be constructed on the UI thread.");
        Shared = this;
        BuildMenu();
        UpdateIcon();
        UpdateStatusText();
        UpdateHotkeyLabels();

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
                UpdateHotkeyLabels();
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

        _toggleItem.Click += (s, e) => ToggleRecording();
        menu.Items.Add(_toggleItem);

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

        _tray.Icon = LoadIcon("tray-idle.ico");
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
            ? "Dictionary"
            : $"Dictionary ({corrections.Length})";

        if (corrections.Length == 0)
        {
            var none = new ToolStripMenuItem("Empty — edit pasted text to teach it a spelling") { Enabled = false };
            _correctionsMenu.Items.Add(none);
            return;
        }

        var header = new ToolStripMenuItem("Click an item to remove it:") { Enabled = false };
        _correctionsMenu.Items.Add(header);

        foreach (var c in corrections)
        {
            // Only shorthand is tagged. Spellings are the default and the bulk of
            // the list, so labelling them too would be noise in a menu this size.
            var kindTag = c.ResolvedKind == TranscriptionClient.CorrectionKind.Expansion
                ? "  · Shorthand" : "";
            var suffix = c.Count > 1 ? $"  (×{c.Count})" : "";
            var item = new ToolStripMenuItem($"“{c.From}” → “{c.To}”{suffix}{kindTag}") { Tag = c.Key };
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
        var health = await TranscriptionClient.HealthDetailAsync();
        _ui.Post(_ =>
        {
            // Tracked even mid-dictation: a download that finishes while the
            // user is talking should unblock the next press, not the one after.
            _modelLoaded = health?.ModelLoaded ?? false;
            if (CurrentState is State.Recording or State.Processing) return;
            if (health != null)
            {
                CurrentState = State.Idle;
            }
            else
            {
                CurrentState = State.SidecarOffline;
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
                CurrentState = State.Idle;
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
        // SunoFlow is a subscription product: without a connected account there
        // is no device key, nothing would authenticate to the cleanup service,
        // and the sidecar would refuse the dictation anyway. Say so up front
        // rather than recording something we cannot finish.
        if (AccountManager.Shared.DeviceKey == null)
        {
            SystemSounds.Beep.Play();
            AppLog.Log("Dictation blocked — no account connected on this PC");
            _lastItem.Text = "Connect your account to dictate";
            OpenSettings();
            return;
        }

        // The model is what turns speech into words. Without it the sidecar
        // answers every clip with an empty transcript, so a press would record,
        // upload and then paste nothing at all — a failure with no symptom.
        // Say so, and open the page that fixes it.
        if (!_modelLoaded)
        {
            SystemSounds.Beep.Play();
            AppLog.Log("Dictation blocked — speech model not downloaded");
            _lastItem.Text = "Download the speech model to dictate";
            OpenSettings(onModelPage: true);
            return;
        }

        // Before recording the next utterance, learn from any edits the user
        // made to the previously pasted text.
        _editLearner.CaptureIfNeeded();
        try
        {
            _recorder = new AudioRecorder(Preferences.Instance.MicDeviceId);
            _ = _recorder.StartRecording();
            CurrentState = State.Recording;
            _overlay.Show(DictationOverlay.Mode.Recording);
            _maxRecTimer?.Dispose();
            _maxRecTimer = new System.Windows.Forms.Timer { Interval = Preferences.Instance.MaxRecordingSeconds * 1000 };
            _maxRecTimer.Tick += (s, e) =>
            {
                if (CurrentState == State.Recording)
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
                if (CurrentState == State.Recording) _overlay.UpdateLevel(_recorder.CurrentLevel);
            };
            _levelTimer.Start();
        }
        catch (Exception ex)
        {
            SystemSounds.Beep.Play();
            AppLog.Log($"Failed to start recording: {ex.Message}");
        }
    }

    private async void StopAndTranscribe()
    {
        _maxRecTimer?.Stop();
        _maxRecTimer?.Dispose();
        _maxRecTimer = null;
        _levelTimer?.Stop();
        _levelTimer?.Dispose();
        _levelTimer = null;

        var fileURL = _recorder.CurrentFile;
        if (fileURL == null)
        {
            _overlay.HideOverlay();
            CurrentState = State.Idle;
            return;
        }
        _recorder.StopRecording();
        CurrentState = State.Processing;
        _overlay.UpdateMode(DictationOverlay.Mode.Processing);

        // Read the text just before the cursor while the field is still focused
        // and unmodified, so the cleanup pass has the names, terminology and
        // half-finished sentence already on screen to match. Best-effort: an
        // unreadable field (or any password field) simply yields nothing.
        var context = FocusedField.TextBeforeCursor();
        if (context.Length > 0)
            AppLog.Log($"Captured {context.Length} chars of cursor context");

        // Screen-context OCR — gated identically to the macOS app: only run
        // when cleanup is on (the words go to the cleanup LLM) AND the user
        // opted into screen context. Best-effort: CaptureAndRecognizeAsync
        // returns "" on any failure, so dictation never breaks.
        var prefs = Preferences.Instance;
        string screenContext = "";
        if (prefs.CleanupEnabled && prefs.ScreenContextEnabled)
        {
            try
            {
                // Off the UI thread: the capture, the downscale and the pixel copy
                // are all synchronous, and running them here would freeze the
                // message pump — including the overlay — for the whole capture.
                screenContext = await Task.Run(ScreenContext.CaptureAndRecognizeAsync);
                if (!string.IsNullOrEmpty(screenContext))
                    AppLog.Log($"Captured {screenContext.Length} chars of screen OCR context");
            }
            catch (Exception ex)
            {
                AppLog.Log($"Screen context capture failed: {ex.Message}");
            }
        }
        SendForTranscription(fileURL, context, screenContext);
    }

    private void SendForTranscription(string wavPath, string context, string screenContext)
    {
        var prefs = Preferences.Instance;
        Task.Run(async () =>
        {
            var outcome = await TranscriptionClient.TranscribeAsync(wavPath, context, screenContext, prefs.CleanupEnabled);
            _ui.Post(_ =>
            {
                // If the user cancelled while we were transcribing, drop the result.
                if (CurrentState != State.Processing)
                {
                    TryDelete(wavPath);
                    return;
                }
                _overlay.HideOverlay();
                CurrentState = State.Idle;
                if (outcome.NotEntitled != null)
                {
                    // Nothing is pasted. The account has lapsed, so this is a
                    // stop, not a degraded result — say so and point at the
                    // place it can be fixed.
                    SystemSounds.Beep.Play();
                    AccountManager.Shared.NoteEntitlementProblem(outcome.NotEntitled);
                    ShowDictationBlocked(outcome.NotEntitledCode);
                }
                else if (outcome.Result != null)
                {
                    // Served, so the account is in good standing: clear any
                    // stale lapse notice and re-arm it for a future one.
                    AccountManager.Shared.ClearEntitlementNotice();
                    _shownLapseNotice = false;
                    HandleTranscript(outcome.Result);
                }
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

    /// <summary>Tells the user why nothing was typed.
    ///
    /// Only surfaces the window once per lapse, so repeated hotkey presses do
    /// not keep yanking Settings to the front.</summary>
    private void ShowDictationBlocked(string code)
    {
        // An outage and a lapsed subscription both stop dictation, but they are
        // not the same news and must not read the same in the tray.
        var summary = code == "unreachable"
            ? "Paused — can't reach SunoFlow"
            : "Paused — subscription inactive";
        _lastItem.Text = summary;
        _statusItem.Text = $"Status: {summary.ToLowerInvariant()}";
        // The icon carries the news as well: the tray is where the user is looking
        // when nothing appeared in their document.
        _tray.Icon = LoadIcon("tray-offline.ico");
        _tray.Text = $"SunoFlow — {summary}";
        if (_shownLapseNotice) return;
        _shownLapseNotice = true;
        OpenSettings();
    }

    private bool _shownLapseNotice;

    // --- UI updates ---------------------------------------------------------------

    private void UpdateStatusText()
    {
        _statusItem.Text = _state switch
        {
            State.SidecarOffline => "Status: sidecar offline (start the sidecar)",
            State.Idle when AccountManager.Shared.DeviceKey == null
                => "Status: connect your account to dictate",
            State.Idle when !_modelLoaded
                => "Status: download the speech model to dictate",
            State.Idle => $"Status: idle — press {HotkeyLabel} to dictate",
            State.Recording => $"Status: recording… press {HotkeyLabel} to stop",
            State.Processing => "Status: transcribing…",
            _ => "Status: unknown",
        };
    }

    private void UpdateHotkeyLabels()
    {
        _toggleItem.Text = $"Toggle Dictation ({HotkeyLabel})";
        UpdateStatusText();
    }

    private void UpdateIcon()
    {
        _tray.Icon = _state switch
        {
            State.SidecarOffline => LoadIcon("tray-offline.ico"),
            State.Idle => LoadIcon("tray-idle.ico"),
            State.Recording => LoadIcon("tray-recording.ico"),
            State.Processing => LoadIcon("tray-processing.ico"),
            _ => LoadIcon("tray-idle.ico"),
        };
    }

    private SettingsForm? _settings;

    /// <summary>Bring the dashboard up. <paramref name="onModelPage"/> lands
    /// straight on Speech Model, for the case where a dictation was refused
    /// because the model is missing.</summary>
    internal void OpenSettings(bool onModelPage = false)
    {
        // May be invoked from the SingleInstance listener's threadpool thread.
        _ui.Post(_ =>
        {
            // One dashboard, brought forward. Opening a second copy would leave two
            // windows polling the same endpoints and disagreeing about the answers.
            if (_settings is { IsDisposed: false })
            {
                if (_settings.WindowState == FormWindowState.Minimized)
                    _settings.WindowState = FormWindowState.Normal;
                _settings.Activate();
                if (onModelPage) _settings.GoToModelPage();
                return;
            }
            _settings = new SettingsForm();
            _settings.FormClosed += (s, e) => _settings = null;
            _settings.Show();
            if (onModelPage) _settings.GoToModelPage();
        }, null);
    }

    /// <summary><see langword="true"/> when a bundled sidecar exists for us to
    /// start. In dev mode there is none and the dashboard hides the button rather
    /// than offering an action that would do nothing.</summary>
    internal bool CanStartEngine => _sidecar.IsAvailable;

    /// <summary>Starts the bundled sidecar if it isn't already up.</summary>
    internal void StartEngine()
    {
        AppLog.Log("Engine start requested from Settings");
        _sidecar.EnsureRunning();
        _ = CheckHealth();
    }

    // --- Helpers ------------------------------------------------------------------

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { /* best-effort */ }
    }

    /// <summary>The app icon — the brand mark on the violet chip — for windows.</summary>
    internal static Icon AppIcon => _appIcon ??= LoadIcon("app-icon.ico");
    private static Icon? _appIcon;

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
        Shared = null;
        _healthTimer.Stop();
        _healthTimer.Dispose();
        _maxRecTimer?.Dispose();
        _levelTimer?.Dispose();
        _overlay.Dispose();
        _hotkey.Dispose();
        // SidecarSupervisor.Dispose() intentionally leaves the sidecar running.
        _sidecar.Dispose();
        if (_recorder.IsRecording) _recorder.StopRecording();
        _tray.Visible = false;
        _tray.Dispose();
    }
}