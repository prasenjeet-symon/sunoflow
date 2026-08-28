using System;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Media;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// First-run setup: a short wizard that takes a fresh install from "nothing
/// configured" to "you just dictated a sentence and watched it appear".
///
/// It exists because the dashboard was a poor first experience. Everything a
/// new install needs — an account, a microphone, a working shortcut, the speech
/// model — lived on separate pages the user had to know to visit, and nothing
/// on the page they landed on told them so. The wizard turns that into one
/// ordered path with a single next step at any moment.
///
/// Two things it deliberately does NOT do:
///
///   * It does not wait for the model before letting the user get on with the
///     rest. The download is ~2.5 GB and can take an hour on a bad connection,
///     so it starts the moment an account is connected and streams in the
///     background while the microphone and shortcut steps happen. Only the
///     final live test needs it, and that step can be left for later.
///   * It does not pretend the download is small. The wording avoids jargon —
///     nobody needs to hear "Parakeet TDT" — but the size and the one-time
///     nature are always on screen, because those are the facts that actually
///     affect someone on a metered connection or a small disk.
///
/// The last step runs the real pipeline rather than a mock: the user's own
/// shortcut, their microphone, the sidecar, the entitlement check, the cleanup
/// gateway and the clipboard paste, landing in a text box on this window. If
/// that box fills in, the product works on this machine.
/// </summary>
internal sealed class OnboardingForm : Form
{
    private enum Step { Welcome, Account, Microphone, Shortcut, Setup, TryIt, Done }

    // Welcome is scene-setting and Done is a farewell; the numbered steps in
    // between are the ones the user is actually asked to do.
    private static readonly Step[] Numbered =
        { Step.Account, Step.Microphone, Step.Shortcut, Step.Setup, Step.TryIt };

    private readonly Panel _host = new();
    private readonly Stack _content = new() { BackColor = Theme.Paper };
    private readonly WheelRouter _wheel;
    private readonly Preferences _prefs = Preferences.Instance;

    private Step _step = Step.Welcome;

    // Polling. Health is the slow heartbeat (is the engine up, is the model
    // loaded); the model timer only runs while a download is moving.
    private readonly System.Windows.Forms.Timer _healthTimer = new() { Interval = 3000 };
    private readonly System.Windows.Forms.Timer _modelTimer = new() { Interval = 1000 };
    private readonly System.Windows.Forms.Timer _levelTimer = new() { Interval = 80 };

    private bool _sidecarOnline;
    private bool _modelLoaded;
    /// <summary>Why the model would not start, or null. Setup used to have no
    /// state for this: the download reported nothing wrong, nothing was loaded,
    /// and the wizard sat on "Starting the download…" indefinitely.</summary>
    private string? _modelLoadError;
    private SunoButton? _retryModel;
    private TranscriptionClient.ModelStatus? _modelStatus;
    private bool _downloadRequested;

    // Live controls for the current step, patched by the timers rather than
    // rebuilt, so a progress number does not make the page flicker.
    private SunoButton? _primary, _secondary;
    private TextBlock? _stepNote;
    private SunoProgress? _progress;
    private ValueText? _progressValue;
    private StatusText? _stepStatus;
    private AudioRecorder? _micProbe;
    private SunoProgress? _levelMeter;
    private TextBox? _tryBox;
    private bool _trySucceeded;
    private bool _hotkeyProved;

    public OnboardingForm()
    {
        Text = "Set up SunoFlow";
        Icon = TrayApp.AppIcon;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Theme.Paper;
        ClientSize = new Size(720, 620);
        MinimumSize = new Size(660 + (Width - ClientSize.Width), 560 + (Height - ClientSize.Height));
        MaximizeBox = false;
        DoubleBuffered = true;

        _host.Dock = DockStyle.Fill;
        _host.AutoScroll = true;
        _host.BackColor = Theme.Paper;
        _host.SizeChanged += (s, e) => Relayout();
        Controls.Add(_host);
        _host.Controls.Add(_content);
        _content.Padding = new Padding(44, 0, 44, 32);
        _wheel = new WheelRouter(_host);

        _healthTimer.Tick += (s, e) => _ = PollHealth();
        _modelTimer.Tick += (s, e) => _ = PollModel();
        _levelTimer.Tick += (s, e) => UpdateLevelMeter();

        AccountManager.Shared.Changed += OnAccountChanged;

        ShowStep(Step.Welcome);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Application.AddMessageFilter(_wheel);

        // Lay the page out again now that the window actually exists.
        //
        // The first pass runs from the constructor, where there is no handle and
        // no monitor yet, so every height in the page was measured against the
        // wrong DPI — or, if the host had no usable width at that moment, never
        // measured at all. Nothing else would fix it afterwards: the only other
        // trigger is _host.SizeChanged, and a lone Fill-docked host inside a
        // fixed-size window never changes size again, so the page would stay
        // exactly as mismeasured as it was built. That is the blank first-run
        // window: controls present, all of them zero-height.
        //
        // Cheap and idempotent, so it costs nothing when the constructor pass
        // happened to get it right.
        Relayout();

        _healthTimer.Start();
        _ = PollHealth();
        _ = PollModel();
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        // Dragged to a monitor at a different scale. WinForms rescales child
        // bounds proportionally, but these heights are not proportional — they
        // come from TextRenderer measuring wrapped text at a specific font size.
        // Measuring again is the only way to get them right.
        Relayout();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        Application.RemoveMessageFilter(_wheel);
        AccountManager.Shared.Changed -= OnAccountChanged;
        // Whatever happens, the shortcut goes back to dictating and the probe
        // microphone is released. Leaving either behind would break the app for
        // someone who closes the wizard with the X.
        ReleaseHotkey();
        StopMicProbe();
        _healthTimer.Dispose();
        _modelTimer.Dispose();
        _levelTimer.Dispose();
        base.OnFormClosed(e);
    }

    // MARK: - Shell

    private void Relayout()
    {
        if (_host.ClientSize.Width <= 0) return;
        _content.Reflow(_host.ClientSize.Width);
        if (_content.Width != _host.ClientSize.Width)
            _content.Reflow(_host.ClientSize.Width);
    }

    private static void ClearAndDispose(Control host)
    {
        for (int i = host.Controls.Count - 1; i >= 0; i--)
        {
            var child = host.Controls[i];
            host.Controls.RemoveAt(i);
            child.Dispose();
        }
    }

    private void ShowStep(Step step)
    {
        // Leaving a step must undo whatever it borrowed, or the shortcut stays
        // swallowed and the microphone stays open on the next page.
        ReleaseHotkey();
        StopMicProbe();

        _step = step;
        _primary = _secondary = null;
        _stepNote = null;
        _progress = null;
        _progressValue = null;
        _stepStatus = null;
        _levelMeter = null;
        _tryBox = null;
        _retryModel = null;
        ClearAndDispose(_content);

        BuildChrome(step);
        switch (step)
        {
            case Step.Welcome: BuildWelcome(); break;
            case Step.Account: BuildAccount(); break;
            case Step.Microphone: BuildMicrophone(); break;
            case Step.Shortcut: BuildShortcut(); break;
            case Step.Setup: BuildSetup(); break;
            case Step.TryIt: BuildTryIt(); break;
            case Step.Done: BuildDone(); break;
        }
        Relayout();
    }

    /// <summary>Title, subtitle and the "step 2 of 5" rail every page shares.</summary>
    private void BuildChrome(Step step)
    {
        int index = Array.IndexOf(Numbered, step);
        if (index >= 0)
        {
            var kicker = new TextBlock($"STEP {index + 1} OF {Numbered.Length}", Theme.Kicker, Theme.Faint)
            { Margin = new Padding(0, 34, 0, 6) };
            _content.Controls.Add(kicker);
        }
        else
        {
            _content.Controls.Add(new Spacer(34));
        }

        var (title, subtitle) = step switch
        {
            Step.Welcome => ("Welcome to SunoFlow",
                "Talk, and it types. Four short steps and you'll be dictating into any app on this PC."),
            Step.Account => ("Connect this PC",
                "Your subscription lives on your account, so this PC needs to be linked to it before it can dictate."),
            Step.Microphone => ("Choose your microphone",
                "Pick the input you'll talk into, and check that SunoFlow can hear it."),
            Step.Shortcut => ("Your dictation shortcut",
                "One key combination starts and stops dictation, anywhere in Windows."),
            Step.Setup => ("Setting up speech recognition",
                "SunoFlow turns speech into text on this PC rather than sending your voice anywhere. That needs a one-time download."),
            Step.TryIt => ("Try it out",
                "Last step. Read the line below out loud and watch it appear."),
            Step.Done => ("You're all set",
                "SunoFlow lives in your system tray from here on."),
            _ => ("", ""),
        };

        _content.Controls.Add(new TextBlock(title, Theme.Display, Theme.Ink) { Margin = new Padding(0, 0, 0, 8) });
        _content.Controls.Add(new TextBlock(subtitle, Theme.BodyText, Theme.Body) { Margin = new Padding(0, 0, 0, 22) });
        _content.Controls.Add(new RuleLine(strong: true));
    }

    /// <summary>The button run at the bottom of every step.</summary>
    private void AddFooter(string primaryText, Action primaryAction,
                           string? secondaryText = null, Action? secondaryAction = null,
                           bool primaryEnabled = true)
    {
        _primary = new SunoButton(primaryText, ButtonKind.Primary) { Enabled = primaryEnabled };
        _primary.Click += (s, e) => primaryAction();

        Control run;
        if (secondaryText != null && secondaryAction != null)
        {
            _secondary = new SunoButton(secondaryText);
            _secondary.Click += (s, e) => secondaryAction();
            run = new Row(_primary, _secondary);
        }
        else
        {
            run = new Row(_primary);
        }
        run.Margin = new Padding(0, 24, 0, 0);
        _content.Controls.Add(run);
    }

    // MARK: - Steps

    private void BuildWelcome()
    {
        _content.Controls.Add(new SectionHeader("What happens next"));
        _content.Controls.Add(new SunoRow("Connect this PC to your account",
            "A code you approve in the browser. Nothing is typed in here.",
            Glyph.Person) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow("Pick a microphone",
            "And check SunoFlow can hear you.", Glyph.Mic) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow("Confirm your shortcut",
            "The key combination that starts dictation.", Glyph.Keyboard) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow("Set up speech recognition",
            "A one-time download of about 2.5 GB, which runs in the background while you finish the steps above.",
            Glyph.Download) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow("Say something",
            "A quick end-to-end check that it all works on this PC.",
            Glyph.CheckCircle, divider: false) { ReserveIconColumn = true });
        _content.Controls.Add(new RuleLine(strong: true));

        AddFooter("Get started", () => ShowStep(Step.Account),
                  "Skip setup", SkipSetup);
    }

    private void BuildAccount()
    {
        var state = AccountManager.Shared.State;

        if (state == AccountState.Connected)
        {
            _content.Controls.Add(new SunoRow("This PC is connected",
                "You're signed in and ready to dictate.", Glyph.CheckCircle, Theme.Success,
                divider: false, trailing: new StatusText("Connected", Theme.Success))
            { ReserveIconColumn = true });
            _content.Controls.Add(new RuleLine(strong: true));
            // Connecting is what unlocks the download, so ask for it here rather
            // than making the user wait for the dedicated step to come round.
            StartModelDownloadOnce();
            AddFooter("Continue", () => ShowStep(Step.Microphone));
            return;
        }

        if (state == AccountState.Waiting)
        {
            var code = new TextBlock(AccountManager.Shared.UserCode, Theme.MonoStrong, Theme.Ink)
            { Margin = new Padding(0, 18, 0, 6) };
            _content.Controls.Add(code);
            _content.Controls.Add(new TextBlock(
                "Enter this code in the browser window that just opened, then come back here. "
                + "This page updates by itself once you approve it.",
                Theme.BodyText, Theme.Body));
            _stepStatus = new StatusText("Waiting for approval…", Theme.Accent);
            _content.Controls.Add(new SunoRow("Waiting", null, Glyph.Hourglass, Theme.Accent,
                divider: false, trailing: _stepStatus) { ReserveIconColumn = true });
            _content.Controls.Add(new RuleLine(strong: true));
            AddFooter("Cancel", () =>
            {
                AccountManager.Shared.CancelPairing();
                ShowStep(Step.Account);
            });
            return;
        }

        if (state == AccountState.Failed)
        {
            _content.Controls.Add(new SunoNotice(
                string.IsNullOrEmpty(AccountManager.Shared.FailureMessage)
                    ? "That didn't go through. Try connecting again."
                    : AccountManager.Shared.FailureMessage,
                Glyph.Alert, Theme.Danger)
            { Margin = new Padding(0, 18, 0, 0) });
        }

        _content.Controls.Add(new SunoRow("How this works",
            "SunoFlow opens your browser, you approve this PC there, and the key it returns is stored "
            + "encrypted under your Windows account. Your password is never typed into this app.",
            Glyph.Lock, divider: false) { ReserveIconColumn = true });
        _content.Controls.Add(new RuleLine(strong: true));

        AddFooter("Connect this PC", async () =>
        {
            _primary!.Enabled = false;
            _primary.SetText("Opening browser…");
            await AccountManager.Shared.ConnectAsync();
        }, "Back", () => ShowStep(Step.Welcome));
    }

    private void BuildMicrophone()
    {
        var devices = SafeDeviceNames();
        if (devices.Length == 0)
        {
            _content.Controls.Add(new SunoNotice(
                "No microphone found. Plug one in, then choose Refresh.", Glyph.Alert, Theme.Warning)
            { Margin = new Padding(0, 18, 0, 0) });
            _content.Controls.Add(new RuleLine(strong: true));
            AddFooter("Refresh", () => ShowStep(Step.Microphone), "Skip", () => ShowStep(Step.Shortcut));
            return;
        }

        var combo = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            Font = Theme.BodyText,
            Width = 260,
            FlatStyle = FlatStyle.Flat,
            BackColor = Theme.Wash,
            ForeColor = Theme.Ink,
        };
        combo.Items.Add("System default");
        foreach (var name in devices) combo.Items.Add(name);
        bool saved = !string.IsNullOrEmpty(_prefs.MicDeviceId);
        combo.SelectedIndex = saved && devices.Contains(_prefs.MicDeviceId)
            ? Array.IndexOf(devices, _prefs.MicDeviceId) + 1
            : 0;
        combo.SelectedIndexChanged += (s, e) =>
        {
            _prefs.MicDeviceId = combo.SelectedIndex <= 0 ? "" : devices[combo.SelectedIndex - 1];
            _prefs.Save();
            // Listen through the newly chosen device rather than the old one.
            StartMicProbe();
        };
        _content.Controls.Add(new SunoRow("Microphone", "Which input SunoFlow records from.",
            Glyph.Mic, divider: true, trailing: combo) { ReserveIconColumn = true });

        _levelMeter = new SunoProgress { Margin = new Padding(0, 14, 0, 6) };
        _content.Controls.Add(new SunoRow("Say something",
            "The bar below should move while you talk. Windows may ask for permission the first time.",
            Glyph.Waveform, divider: false) { ReserveIconColumn = true });
        _content.Controls.Add(_levelMeter);
        _stepNote = new TextBlock("Listening…", Theme.Caption, Theme.Faint)
        { Margin = new Padding(0, 0, 0, 12) };
        _content.Controls.Add(_stepNote);
        _content.Controls.Add(new RuleLine(strong: true));

        AddFooter("Continue", () => ShowStep(Step.Shortcut), "Back", () => ShowStep(Step.Account));
        StartMicProbe();
    }

    private void BuildShortcut()
    {
        var app = TrayApp.Shared;
        bool registered = app?.HotkeyRegistered ?? false;
        string combo = KeyCombo.Display(_prefs.HotkeyCode, _prefs.HotkeyModifiers);

        if (!registered)
        {
            // A shortcut another app already owns is the failure with no
            // symptom: the key simply does nothing, forever, with no error.
            _content.Controls.Add(new SunoNotice(
                $"Windows would not give SunoFlow {combo} — another app already uses it. "
                + "Pick a different combination below.", Glyph.Alert, Theme.Warning)
            { Margin = new Padding(0, 18, 0, 0) });
        }

        var field = new HotkeyField(_prefs.HotkeyCode, _prefs.HotkeyModifiers);
        field.Captured += (s, e) =>
        {
            bool ok = TrayApp.Shared?.RebindHotkey(field.KeyCode, field.Modifiers) ?? false;
            _hotkeyProved = false;
            if (_stepStatus != null)
                _stepStatus.Set(ok ? "Press it to check" : "Still taken — try another",
                                ok ? Theme.Faint : Theme.Warning);
            if (_primary != null) _primary.Enabled = ok;
        };
        _content.Controls.Add(new SunoRow("Dictation shortcut",
            "Click the field and press the combination you want.",
            Glyph.Keyboard, divider: true, trailing: field) { ReserveIconColumn = true });

        _stepStatus = new StatusText(registered ? "Press it to check" : "Pick another combination",
                                     registered ? Theme.Faint : Theme.Warning);
        _content.Controls.Add(new SunoRow("Try it now",
            "Press your shortcut. Nothing will be recorded — this only proves Windows is passing the key to SunoFlow.",
            Glyph.CheckCircle, divider: false, trailing: _stepStatus) { ReserveIconColumn = true });
        _content.Controls.Add(new RuleLine(strong: true));

        AddFooter("Continue", () => ShowStep(Step.Setup),
                  "Back", () => ShowStep(Step.Microphone),
                  primaryEnabled: registered);

        // Borrow the shortcut for the duration of this step.
        if (app != null)
        {
            app.HotkeyInterceptor = () =>
            {
                BeginInvoke(new Action(OnHotkeyProved));
                return true;
            };
        }
    }

    private void OnHotkeyProved()
    {
        if (_step != Step.Shortcut || _hotkeyProved) return;
        _hotkeyProved = true;
        SystemSounds.Asterisk.Play();
        _stepStatus?.Set("Works", Theme.Success);
        if (_primary != null)
        {
            _primary.Enabled = true;
            _primary.SetText("Continue");
        }
    }

    private void BuildSetup()
    {
        StartModelDownloadOnce();

        _content.Controls.Add(new SunoRow("Runs on this PC",
            "Your voice is turned into text by this machine. Recordings are never uploaded.",
            Glyph.Desktop) { ReserveIconColumn = true });

        _progressValue = new ValueText("—", Theme.Value, Theme.Body);
        _content.Controls.Add(new SunoRow("One-time download",
            "About 2.5 GB. It only happens once, and it keeps working afterwards with no internet connection.",
            Glyph.Download, divider: false, trailing: _progressValue) { ReserveIconColumn = true });

        _progress = new SunoProgress { Margin = new Padding(0, 14, 0, 6) };
        _content.Controls.Add(_progress);
        _stepNote = new TextBlock("Checking…", Theme.Caption, Theme.Faint)
        { Margin = new Padding(0, 0, 0, 12) };
        _content.Controls.Add(_stepNote);

        // Its own button rather than relabelling Continue. The footer binds its
        // action once at build time, so the old "Try again" label sat on a
        // button that still advanced the wizard — the one thing the user was
        // not asking for at the moment something had just failed.
        _retryModel = new SunoButton("Try again", ButtonKind.Primary) { Visible = false };
        _retryModel.Click += (s, e) => RetryModel();
        _content.Controls.Add(_retryModel);
        _content.Controls.Add(new RuleLine(strong: true));

        AddFooter("Continue", () => ShowStep(Step.TryIt),
                  "Finish later", FinishLater,
                  primaryEnabled: _modelLoaded);
        RefreshSetup();
        _modelTimer.Start();
    }

    private void BuildTryIt()
    {
        if (!_modelLoaded)
        {
            _content.Controls.Add(new SunoNotice(
                "Speech recognition is still being set up. This step needs it finished.",
                Glyph.Hourglass, Theme.Accent)
            { Margin = new Padding(0, 18, 0, 0) });
            _content.Controls.Add(new RuleLine(strong: true));
            AddFooter("Back to setup", () => ShowStep(Step.Setup), "Finish later", FinishLater);
            return;
        }

        string combo = KeyCombo.Display(_prefs.HotkeyCode, _prefs.HotkeyModifiers);
        _content.Controls.Add(new SunoRow("Read this out loud",
            "“Hi, this is my first sentence with SunoFlow, and it seems to be working.”",
            Glyph.Waveform) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow($"Press {combo} to start, then press it again when you're done",
            "The text will appear in the box below, exactly as it would in any other app.",
            Glyph.Keyboard, divider: false) { ReserveIconColumn = true });

        _tryBox = new TextBox
        {
            Multiline = true,
            Height = 96,
            Font = Theme.BodyText,
            BackColor = Theme.Wash,
            ForeColor = Theme.Ink,
            BorderStyle = BorderStyle.FixedSingle,
            Margin = new Padding(0, 14, 0, 6),
        };
        _tryBox.TextChanged += (s, e) =>
        {
            if (_trySucceeded || string.IsNullOrWhiteSpace(_tryBox!.Text)) return;
            _trySucceeded = true;
            _stepStatus?.Set("It works", Theme.Success);
            if (_primary != null) _primary.Enabled = true;
        };
        _content.Controls.Add(_tryBox);

        _stepStatus = new StatusText("Waiting for you to speak…", Theme.Faint);
        _content.Controls.Add(new SunoRow("Result", null, Glyph.CheckCircle,
            divider: false, trailing: _stepStatus) { ReserveIconColumn = true });
        _content.Controls.Add(new RuleLine(strong: true));

        // Enabled either way: someone whose microphone is genuinely broken must
        // still be able to leave the wizard rather than being trapped in it.
        AddFooter("Finish", () => ShowStep(Step.Done), "Skip this check", () => ShowStep(Step.Done));

        // The box must have focus for the paste to land in it.
        BeginInvoke(new Action(() => _tryBox?.Focus()));
    }

    private void BuildDone()
    {
        _prefs.OnboardingCompleted = true;
        _prefs.Save();

        string combo = KeyCombo.Display(_prefs.HotkeyCode, _prefs.HotkeyModifiers);
        _content.Controls.Add(new SunoRow($"Press {combo} anywhere",
            "In any app, any text field. Press once to start, once more to stop.",
            Glyph.Keyboard) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow("SunoFlow is in your system tray",
            "Right-click the tray icon for settings, your dictionary and the shortcut.",
            Glyph.Grid) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow("It learns your words",
            "Correct a word after it's typed and SunoFlow remembers the spelling for next time.",
            Glyph.TextCheck, divider: false) { ReserveIconColumn = true });
        _content.Controls.Add(new RuleLine(strong: true));

        AddFooter("Start dictating", Close, "Open settings", () =>
        {
            Close();
            TrayApp.Shared?.OpenSettings();
        });
    }

    // MARK: - Actions

    /// <summary>Leaves setup for later without nagging on every launch. The
    /// dashboard still shows what is missing, so nothing is lost.</summary>
    private void SkipSetup()
    {
        _prefs.OnboardingCompleted = true;
        _prefs.Save();
        AppLog.Log("Setup skipped by the user");
        Close();
    }

    private void FinishLater()
    {
        _prefs.OnboardingCompleted = true;
        _prefs.Save();
        AppLog.Log("Setup left to finish later — model download continues in the background");
        Close();
    }

    /// <summary>Shows or hides the retry button, and relayouts when it changed.</summary>
    private void ShowRetry(bool visible)
    {
        if (_retryModel == null || _retryModel.Visible == visible) return;
        _retryModel.Visible = visible;
        Relayout();
    }

    /// <summary>Re-runs the download, which for files already on disk is just a
    /// re-run of the load — the retry a "won't start" model actually needs.</summary>
    private void RetryModel()
    {
        _downloadRequested = false;
        _modelLoadError = null;
        ShowRetry(false);
        _progressValue?.Set("Starting…", Theme.Body);
        _stepNote?.SetText("Trying again…");
        StartModelDownloadOnce();
        _modelTimer.Start();
    }

    /// <summary>Kick the download off as early as we are allowed to, which is
    /// as soon as there is an account. Idempotent: the sidecar refuses a second
    /// start, and this guards against asking on every page build anyway.</summary>
    private async void StartModelDownloadOnce()
    {
        if (_downloadRequested || _modelLoaded || !_sidecarOnline) return;
        if (!AccountManager.Shared.IsConnected) return;
        _downloadRequested = true;
        AppLog.Log("Setup: starting the speech model download");
        var started = await TranscriptionClient.StartModelDownloadAsync();
        if (!started) AppLog.Log("Setup: download did not start (already running, or already present)");
        await PollModel();
    }

    // MARK: - Microphone probe

    private void StartMicProbe()
    {
        StopMicProbe();
        try
        {
            _micProbe = new AudioRecorder(_prefs.MicDeviceId);
            _micProbe.StartRecording();
            _levelTimer.Start();
            _stepNote?.SetText("Listening…");
        }
        catch (Exception ex)
        {
            // The usual cause is Windows privacy settings blocking microphone
            // access for desktop apps, which no amount of retrying will fix.
            AppLog.Log($"Setup: microphone probe failed — {ex.Message}");
            _stepNote?.SetText("Windows is not letting SunoFlow use the microphone. "
                + "Open Settings → Privacy & security → Microphone and allow desktop apps.");
        }
    }

    private void StopMicProbe()
    {
        _levelTimer.Stop();
        var probe = _micProbe;
        _micProbe = null;
        if (probe == null) return;
        try
        {
            probe.StopRecording();
            // The probe only ever existed to move a meter; its audio is not
            // wanted and would otherwise pile up in the temp directory.
            var file = probe.CurrentFile;
            if (!string.IsNullOrEmpty(file) && File.Exists(file)) File.Delete(file);
        }
        catch (Exception ex)
        {
            AppLog.Log($"Setup: stopping the microphone probe failed — {ex.Message}");
        }
    }

    private void UpdateLevelMeter()
    {
        if (_micProbe == null || _levelMeter == null) return;
        float level = _micProbe.CurrentLevel;
        _levelMeter.SetProgress(level, 1.0);
        if (level > 0.04f) _stepNote?.SetText("Heard that.");
    }

    // MARK: - Hotkey borrowing

    private void ReleaseHotkey()
    {
        if (TrayApp.Shared != null) TrayApp.Shared.HotkeyInterceptor = null;
    }

    // MARK: - Polling

    private async Task PollHealth()
    {
        var health = await TranscriptionClient.HealthDetailAsync();
        OnUi(() =>
        {
            _sidecarOnline = health != null;
            _modelLoaded = health?.ModelLoaded ?? false;
            _modelLoadError = string.IsNullOrWhiteSpace(health?.LoadError) ? null : health!.LoadError;
            if (_step == Step.Setup) RefreshSetup();
            // An account connected on another step should still start the
            // download the moment the engine comes up.
            StartModelDownloadOnce();
        });
    }

    private async Task PollModel()
    {
        var status = await TranscriptionClient.FetchModelStatusAsync();
        OnUi(() =>
        {
            _modelStatus = status;
            if (_step == Step.Setup) RefreshSetup();
        });
    }

    private void RefreshSetup()
    {
        if (_step != Step.Setup || _progress == null) return;
        var st = _modelStatus;

        if (_modelLoaded)
        {
            _progress.SetProgress(1, 1);
            _progressValue?.Set("Ready", Theme.Success);
            _stepNote?.SetText("Speech recognition is ready on this PC.");
            if (_primary != null) _primary.Enabled = true;
            ShowRetry(false);
            _modelTimer.Stop();
            return;
        }

        if (!_sidecarOnline)
        {
            _progressValue?.Set("Waiting", Theme.Warning);
            _stepNote?.SetText("Waiting for the speech engine to start…");
            ShowRetry(false);
            return;
        }

        if (st is { Active: true })
        {
            ShowRetry(false);
            _progress.SetProgress(st.Downloaded, Math.Max(st.FileTotal, 1));
            _progressValue?.Set($"{st.OverallDone} of {st.OverallTotal}", Theme.Accent);
            _stepNote?.SetText(st.Phase == "loading"
                ? "Almost there — getting it ready to use…"
                : $"Downloading… {FormatBytes(st.Downloaded)} of {FormatBytes(st.FileTotal)}. "
                  + "You can leave this running and finish later.");
            _modelTimer.Start();
            return;
        }

        // A model that arrived intact and then refused to start. Checked before
        // the download error, because the download did not fail — and before the
        // fall-through below, which would otherwise sit on "Starting the
        // download…" forever over a download that finished long ago.
        string? loadError = _modelLoadError ?? (st is { LoadFailed: true } ? st.LoadError : null);
        if (loadError != null)
        {
            _progressValue?.Set("Won't start", Theme.Danger);
            _stepNote?.SetText($"The model downloaded, but the engine could not start it. {loadError} "
                               + "Try again, or finish setup and sort this out from the dashboard.");
            ShowRetry(true);
            _modelTimer.Stop();
            return;
        }

        if (st != null && (st.Phase == "error" || !string.IsNullOrEmpty(st.Error)))
        {
            _progressValue?.Set("Failed", Theme.Danger);
            _stepNote?.SetText(string.IsNullOrEmpty(st.Error)
                ? "The download failed. Check your connection and try again."
                : st.Error);
            ShowRetry(true);
            _modelTimer.Stop();
            return;
        }

        ShowRetry(false);
        _progressValue?.Set("Starting…", Theme.Body);
        _stepNote?.SetText("Starting the download…");
        _modelTimer.Start();
    }

    private void OnAccountChanged(object? sender, EventArgs e) => OnUi(() =>
    {
        if (_step != Step.Account) return;
        // The account page's shape follows its state — a code to approve, a
        // success, a failure — so it is rebuilt rather than patched.
        ShowStep(Step.Account);
        if (AccountManager.Shared.IsConnected)
        {
            // Straight on to the next step: standing on a "connected" page the
            // user cannot act on any further is just a click for its own sake.
            StartModelDownloadOnce();
            ShowStep(Step.Microphone);
        }
    });

    // MARK: - Helpers

    private void OnUi(Action action)
    {
        if (IsDisposed || Disposing || !IsHandleCreated) return;
        try { BeginInvoke(action); }
        catch (ObjectDisposedException) { /* closed between the check and the post */ }
        catch (InvalidOperationException) { /* handle went away */ }
    }

    private static string[] SafeDeviceNames()
    {
        try { return AudioRecorder.ListDeviceNames(); }
        catch (Exception ex)
        {
            AppLog.Log($"Setup: listing microphones failed — {ex.Message}");
            return Array.Empty<string>();
        }
    }

    private static string FormatBytes(long bytes)
    {
        if (bytes >= 1_000_000_000) return $"{bytes / 1_000_000_000.0:0.0} GB";
        if (bytes >= 1_000_000) return $"{bytes / 1_000_000.0:0} MB";
        if (bytes >= 1_000) return $"{bytes / 1_000.0:0} KB";
        return $"{bytes} B";
    }
}
