using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// The SunoFlow dashboard — the Windows counterpart of the macOS
/// <c>SettingsView.swift</c>, and deliberately the same design rather than a
/// WinForms-flavoured approximation of it.
///
/// One flat sheet of paper with a navigation column down the left. No cards, no
/// group boxes, no tab strip: structure comes from hairline rules, generous
/// vertical rhythm, and rows that run the full width of the column. The palette,
/// the type scale and the row anatomy all live in <see cref="Theme"/> and are the
/// same values the Mac app and the website use.
///
/// The pages match the Mac's one-for-one — Overview, Account, General,
/// Microphone, Speech Model, Dictionary, About — so a person who has used one
/// platform already knows where everything is on the other. What differs is only
/// what genuinely differs between the systems: Windows has no Accessibility gate
/// for pasting, and its auto-start is a registry entry rather than a LaunchAgent.
/// </summary>
internal sealed class SettingsForm : Form
{
    private enum Page { Overview, Account, General, Microphone, Model, Corrections, About }

    private readonly Preferences _prefs = Preferences.Instance;

    private readonly Panel _sidebar = new();
    private readonly Panel _host = new();
    private readonly Dictionary<Page, NavButton> _nav = new();
    private readonly EngineStatusStrip _engineStrip = new();

    private Stack _content = new();
    private Page _page = Page.Overview;

    private readonly System.Windows.Forms.Timer _healthTimer = new();
    private readonly System.Windows.Forms.Timer _modelTimer = new();
    private readonly WheelRouter _wheel;

    // Live state, polled or read once when the window opens.
    private bool _sidecarOnline;
    private bool _gatewayOk;
    private bool _micAvailable;
    private string[] _micDevices = Array.Empty<string>();
    private TranscriptionClient.ModelStatus? _modelStatus;
    private TranscriptionClient.Correction[] _corrections = Array.Empty<TranscriptionClient.Correction>();
    private bool _launchAtLogin;
    private bool _startingEngine;
    private bool _downloadStarting;

    // Page titles and the sentence under each of them.
    private static readonly Dictionary<Page, (string Title, string Subtitle, Glyph Icon)> PageInfo = new()
    {
        [Page.Overview] = ("Overview", "System health and quick actions", Glyph.Grid),
        [Page.Account] = ("Account", "Your subscription and this PC", Glyph.Person),
        [Page.General] = ("General", "Launch, hotkey, and recording behaviour", Glyph.Gear),
        [Page.Microphone] = ("Microphone", "Choose which input SunoFlow listens to", Glyph.Mic),
        [Page.Model] = ("Speech Model", "The speech-to-text model", Glyph.Waveform),
        [Page.Corrections] = ("Dictionary", "Spellings it has learned, and shorthand you add", Glyph.TextCheck),
        [Page.About] = ("About", "Version and resources", Glyph.Info),
    };

    public SettingsForm()
    {
        Text = "SunoFlow";
        Icon = TrayApp.AppIcon;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Theme.Paper;
        ClientSize = new Size(980, 700);
        MinimumSize = new Size(880 + (Width - ClientSize.Width), 620 + (Height - ClientSize.Height));
        DoubleBuffered = true;
        KeyPreview = true;

        BuildHost();
        BuildSidebar();
        _wheel = new WheelRouter(_host);

        _healthTimer.Interval = 3000;
        _healthTimer.Tick += (s, e) => _ = PollHealth();

        _modelTimer.Interval = 1000;
        _modelTimer.Tick += (s, e) => _ = PollModel();

        AccountManager.Shared.Changed += OnAccountChanged;

        _launchAtLogin = AutoStart.IsEnabled();
        _micDevices = SafeDeviceNames();
        _micAvailable = _micDevices.Length > 0;

        ShowPage(Page.Overview);
    }

    // MARK: - Shell

    private void BuildHost()
    {
        _host.Dock = DockStyle.Fill;
        _host.AutoScroll = true;
        _host.BackColor = Theme.Paper;
        _host.SizeChanged += (s, e) => Relayout();
        Controls.Add(_host);
    }

    private void BuildSidebar()
    {
        _sidebar.Dock = DockStyle.Left;
        _sidebar.Width = Theme.SidebarWidth;
        _sidebar.BackColor = Theme.Shell;

        var brand = new BrandHeader { Location = new Point(0, 20), Width = Theme.SidebarWidth, Height = 34 };
        _sidebar.Controls.Add(brand);

        int y = brand.Bottom + 20;
        foreach (var page in Enum.GetValues<Page>())
        {
            var info = PageInfo[page];
            var button = new NavButton(info.Title, info.Icon)
            {
                Location = new Point(0, y),
                Width = Theme.SidebarWidth,
            };
            var captured = page;
            button.Click += (s, e) => ShowPage(captured);
            _sidebar.Controls.Add(button);
            _nav[page] = button;
            y += button.Height;
        }

        _engineStrip.Dock = DockStyle.Bottom;
        _sidebar.Controls.Add(_engineStrip);

        // The hairline that separates the navigation column from the sheet.
        var edge = new Panel { Dock = DockStyle.Right, Width = 1, BackColor = Theme.RuleStrong };
        _sidebar.Controls.Add(edge);

        Controls.Add(_sidebar);
    }

    /// <summary>The brand lockup at the top of the navigation column.</summary>
    private sealed class BrandHeader : Control
    {
        private static readonly Font Wordmark = Theme.Semibold(11f);

        public BrandHeader()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                     | ControlStyles.OptimizedDoubleBuffer, true);
            SetStyle(ControlStyles.Selectable, false);
            BackColor = Theme.Shell;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            BrandMark.Draw(e.Graphics, new RectangleF(20, (Height - 18) / 2f, 18, 18), Theme.Accent);
            TextRenderer.DrawText(e.Graphics, "SunoFlow", Wordmark,
                new Rectangle(20 + 18 + 9, 0, Width - 47, Height), Theme.Ink,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter
                | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }
    }

    /// <summary>The "engine online/offline" line that closes the navigation column.</summary>
    private sealed class EngineStatusStrip : Control
    {
        private bool _online;

        public EngineStatusStrip()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                     | ControlStyles.OptimizedDoubleBuffer, true);
            SetStyle(ControlStyles.Selectable, false);
            BackColor = Theme.Shell;
            Height = 44;
        }

        public void SetOnline(bool online)
        {
            if (_online == online) return;
            _online = online;
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(BackColor);
            using (var pen = new Pen(Theme.Rule)) g.DrawLine(pen, 0, 0, Width, 0);
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using (var brush = new SolidBrush(_online ? Theme.Success : Theme.Warning))
                g.FillEllipse(brush, 20, Height / 2f - 3, 6, 6);
            TextRenderer.DrawText(g, _online ? "Engine online" : "Engine offline", Theme.Caption,
                new Rectangle(33, 0, Width - 40, Height), Theme.Faint,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter
                | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }
    }

    // MARK: - Page header

    /// <summary>The page title, its one-line explanation, the overall readiness
    /// word, and the heavy rule that closes the header.</summary>
    private sealed class PageHeader : Control, IReflow
    {
        private string _title = "";
        private string _subtitle = "";
        private string _status = "";
        private Color _statusColor = Theme.Success;

        public PageHeader()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                     | ControlStyles.OptimizedDoubleBuffer, true);
            SetStyle(ControlStyles.Selectable, false);
        }

        public void Set(string title, string subtitle)
        {
            _title = title; _subtitle = subtitle;
            Invalidate();
        }

        public void SetStatus(string status, Color color)
        {
            _status = status; _statusColor = color;
            Invalidate();
        }

        public void Reflow(int width)
        {
            Width = width;
            Height = 32 + Theme.LineHeight(Theme.Display) + 3 + Theme.LineHeight(Theme.Caption) + 22 + 1;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(BackColor);
            int titleHeight = Theme.LineHeight(Theme.Display);
            int captionHeight = Theme.LineHeight(Theme.Caption);

            TextRenderer.DrawText(g, _title, Theme.Display,
                new Rectangle(0, 32, Width, titleHeight), Theme.Ink,
                TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
            TextRenderer.DrawText(g, _subtitle, Theme.Caption,
                new Rectangle(0, 32 + titleHeight + 3, Width, captionHeight), Theme.Faint,
                TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);

            if (_status.Length > 0)
            {
                var size = Theme.MeasureLine(_status, Theme.Value);
                int right = Width;
                int top = 32 + (titleHeight - size.Height) / 2;
                TextRenderer.DrawText(g, _status, Theme.Value,
                    new Rectangle(right - size.Width, top, size.Width, size.Height), _statusColor,
                    TextFormatFlags.Right | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using var dot = new SolidBrush(_statusColor);
                g.FillEllipse(dot, right - size.Width - 12, top + size.Height / 2f - 3, 6, 6);
            }

            using var pen = new Pen(Theme.RuleStrong);
            g.DrawLine(pen, 0, Height - 1, Width, Height - 1);
        }
    }

    private PageHeader _header = new();

    // MARK: - Navigation

    /// <summary>Open straight to Speech Model. The tray app calls this when it
    /// blocks a dictation for a missing model, so the fix is already on screen
    /// rather than a page away.</summary>
    internal void GoToModelPage() => ShowPage(Page.Model);

    private void ShowPage(Page page)
    {
        _page = page;
        foreach (var (key, button) in _nav) button.Selected = key == page;
        BuildPage();
    }

    /// <summary>Tears the sheet down and rebuilds it for the current page. Called
    /// on navigation and whenever a page's *shape* changes (an account that just
    /// connected, a download that just started) — never on a plain poll, which
    /// updates the existing controls in place.</summary>
    private void BuildPage()
    {
        _modelTimer.Stop();
        ForgetPageControls();

        var old = _content;
        _content = new Stack
        {
            BackColor = Theme.Paper,
            Padding = new Padding(Theme.Page, 0, Theme.Page, 56),
            Location = new Point(0, 0),
        };

        _header = new PageHeader();
        var info = PageInfo[_page];
        _header.Set(info.Title, info.Subtitle);
        _content.Controls.Add(_header);

        switch (_page)
        {
            case Page.Overview: BuildOverview(); break;
            case Page.Account: BuildAccount(); break;
            case Page.General: BuildGeneral(); break;
            case Page.Microphone: BuildMicrophone(); break;
            case Page.Model: BuildModel(); break;
            case Page.Corrections: BuildCorrections(); break;
            case Page.About: BuildAbout(); break;
        }

        _host.Controls.Add(_content);
        _host.Controls.Remove(old);
        old.Dispose();
        _host.AutoScrollPosition = new Point(0, 0);
        Relayout();
        RefreshHeaderStatus();

        // The 1s model-status poll only matters on pages that show download
        // progress. Stop it first, then start it for the pages that need it.
        _modelTimer.Stop();
        if (_page == Page.Model || _page == Page.Overview) _modelTimer.Start();
    }

    /// <summary>Empties a container and disposes what it held. Clearing alone
    /// only detaches the children, leaving their window handles alive for as long
    /// as the GC takes to notice.</summary>
    private static void ClearAndDispose(Control host)
    {
        for (int i = host.Controls.Count - 1; i >= 0; i--)
        {
            var child = host.Controls[i];
            host.Controls.RemoveAt(i);
            child.Dispose();
        }
    }

    /// <summary>Drops every reference to the outgoing page's controls. They are
    /// about to be disposed, and an in-flight poll that lands afterwards must find
    /// nulls rather than dead handles.</summary>
    private void ForgetPageControls()
    {
        _ovEngineRow = _ovMicRow = _ovAccountRow = _ovModelRow = null;
        _ovEngineStatus = _ovMicStatus = _ovAccountStatus = _ovModelStatus = null;
        _ovEngineButton = _ovModelButton = null;
        _ovStatusHeader = null;
        _ovLead = _ovLeadDetail = null;
        _ovHotkey = _ovMicValue = _ovAutoStop = _ovScreen = _ovLogin = _ovCorrections = null;
        _gwStatus = null;
        _gwRow = null;
        _modelBody = null;
        _modelProgress = null;
        _modelCounter = null;
        _modelBytes = null;
        _modelStatusRow = null;
        _modelShape = "";
        _dictList = null;
        _search = null;
        _newFrom = _newTo = null;
        _newKind = null;
        _newKindBlurb = null;
        _addBlock = null;
        _addToggle = null;
        _editingKey = null;
    }

    /// <summary>Re-measures the sheet. Two passes, because the first one may make
    /// the scrollbar appear or vanish, which changes the column width.</summary>
    private void Relayout()
    {
        if (_host.ClientSize.Width <= 0) return;
        _content.Reflow(_host.ClientSize.Width);
        if (_content.Width != _host.ClientSize.Width)
            _content.Reflow(_host.ClientSize.Width);
    }

    // MARK: - Lifecycle

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Application.AddMessageFilter(_wheel);
        // First poll after the handle exists: an async continuation that marshals
        // to a window with no handle yet would throw and be swallowed, leaving the
        // page stuck on "Checking…".
        _healthTimer.Start();
        _ = PollHealth();
        _ = PollCorrections();
        _ = PollModel();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        Application.RemoveMessageFilter(_wheel);
        AccountManager.Shared.Changed -= OnAccountChanged;
        _healthTimer.Stop();
        _healthTimer.Dispose();
        _modelTimer.Stop();
        _modelTimer.Dispose();
        base.OnFormClosed(e);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        // Esc closes the dashboard. An armed HotkeyField sees the key first —
        // ProcessCmdKey walks up from the focused control — and consumes it to
        // cancel its capture, so this only fires when nothing is recording.
        if (keyData == Keys.Escape)
        {
            Close();
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    /// <summary>Runs <paramref name="action"/> on the UI thread, and does nothing
    /// at all once the window is on its way out.</summary>
    private void OnUi(Action action)
    {
        if (IsDisposed || Disposing || !IsHandleCreated) return;
        try { BeginInvoke(action); }
        catch (ObjectDisposedException) { /* closed between the check and the post */ }
        catch (InvalidOperationException) { /* handle went away */ }
    }

    private void OnAccountChanged(object? sender, EventArgs e) => OnUi(() =>
    {
        RefreshHeaderStatus();
        // The account page's shape follows its state (a code to approve, a
        // "sign out" row, a failure and its retry), so it is rebuilt rather than
        // patched. The overview only shows a status word, which updates in place.
        if (_page == Page.Account) BuildPage();
        else if (_page == Page.Overview) RefreshOverview();
    });

    // MARK: - Polling

    private async Task PollHealth()
    {
        var sidecar = await TranscriptionClient.HealthAsync();
        var gateway = await TranscriptionClient.CheckCleanupGatewayAsync();
        OnUi(() =>
        {
            _sidecarOnline = sidecar;
            _gatewayOk = gateway;
            _engineStrip.SetOnline(sidecar);
            RefreshHeaderStatus();
            RefreshOverview();
            RefreshGeneral();
        });
    }

    private async Task PollCorrections()
    {
        var corrections = await TranscriptionClient.FetchCorrectionsAsync();
        OnUi(() =>
        {
            _corrections = corrections;
            RefreshOverview();
            if (_page == Page.Corrections) RebuildDictionaryList();
        });
    }

    private async Task PollModel()
    {
        var status = await TranscriptionClient.FetchModelStatusAsync();
        OnUi(() =>
        {
            _modelStatus = status;
            RefreshOverview();
            if (_page == Page.Model) RefreshModel();
        });
    }

    private void RefreshHeaderStatus()
    {
        int healthy = HealthyCount;
        bool ready = healthy == SubsystemCount;
        _header.SetStatus(ready ? "All systems ready" : $"{SubsystemCount - healthy} need attention",
                          ready ? Theme.Success : Theme.Warning);
    }

    private bool AccountConnected => AccountManager.Shared.DeviceKey != null;

    /// <summary>Subsystems the overview tracks. The model is one of them: an app
    /// that calls itself ready while it cannot transcribe a single word is
    /// lying to the user.</summary>
    private const int SubsystemCount = 4;

    /// <summary>The model is only "ready" when it is loaded in memory — present
    /// on disk but unloaded still cannot transcribe.</summary>
    private bool ModelReady => _modelStatus?.ModelLoaded == true;

    private int HealthyCount =>
        (_sidecarOnline ? 1 : 0) + (_micAvailable ? 1 : 0) + (AccountConnected ? 1 : 0)
        + (ModelReady ? 1 : 0);

    private static string[] SafeDeviceNames()
    {
        try { return AudioRecorder.ListDeviceNames(); }
        catch (Exception ex)
        {
            AppLog.Log($"Could not enumerate microphones: {ex.Message}");
            return Array.Empty<string>();
        }
    }

    private string MicDisplayName
    {
        get
        {
            if (string.IsNullOrEmpty(_prefs.MicDeviceId)) return "System default";
            return _micDevices.Contains(_prefs.MicDeviceId)
                ? _prefs.MicDeviceId
                : "Selected device (disconnected)";
        }
    }

    private string HotkeyDisplay => KeyCombo.Display(_prefs.HotkeyCode, _prefs.HotkeyModifiers);

    // MARK: - Overview

    private SunoRow? _ovEngineRow, _ovMicRow, _ovAccountRow, _ovModelRow;
    private StatusText? _ovEngineStatus, _ovMicStatus, _ovAccountStatus, _ovModelStatus;
    private SunoButton? _ovEngineButton, _ovModelButton;
    private SectionHeader? _ovStatusHeader;
    private TextBlock? _ovLead, _ovLeadDetail;
    private ValueText? _ovHotkey, _ovMicValue, _ovAutoStop, _ovScreen, _ovLogin, _ovCorrections;
    // Inline model-download progress, shown on Overview beneath the model row.
    private SunoButton? _ovModelRetry;
    private SunoProgress? _ovModelProgress;
    private TextBlock? _ovModelBytes;
    private SunoRow? _ovModelErrorRow;

    private void BuildOverview()
    {
        _ovLead = new TextBlock("", Theme.Lead, Theme.Ink) { Margin = new Padding(0, 28, 0, 5) };
        _ovLeadDetail = new TextBlock("", Theme.BodyText, Theme.Body);
        _content.Controls.Add(_ovLead);
        _content.Controls.Add(_ovLeadDetail);

        _ovStatusHeader = new SectionHeader("Status", "");
        _content.Controls.Add(_ovStatusHeader);

        _ovEngineStatus = new StatusText("Checking…", Theme.Faint);
        _ovEngineButton = new SunoButton("Start engine", ButtonKind.Primary) { Visible = false };
        _ovEngineButton.Click += (s, e) => StartEngine();
        var engineTrailing = new Row(_ovEngineButton, _ovEngineStatus);
        _ovEngineRow = new SunoRow("Transcription engine", "", Glyph.Cpu, Theme.Faint,
                                   divider: true, trailing: engineTrailing);
        _content.Controls.Add(_ovEngineRow);

        _ovMicStatus = new StatusText("Checking…", Theme.Faint);
        _ovMicRow = new SunoRow("Microphone", "", Glyph.Mic, Theme.Faint,
                                divider: true, trailing: _ovMicStatus);
        _content.Controls.Add(_ovMicRow);

        _ovAccountStatus = new StatusText("Checking…", Theme.Faint);
        _ovAccountRow = new SunoRow("Account", "", Glyph.Person, Theme.Faint,
                                    divider: true, trailing: _ovAccountStatus);
        _content.Controls.Add(_ovAccountRow);

        // The model row carries its own Download button rather than pointing at
        // another page. This is the first thing a new install is missing, and
        // the overview is the page they land on — telling them to go elsewhere
        // was the whole reason nobody found it.
        _ovModelStatus = new StatusText("Checking…", Theme.Faint);
        _ovModelButton = new SunoButton("Download", ButtonKind.Primary) { Visible = false };
        _ovModelButton.Click += (s, e) => StartDownload();
        _ovModelRow = new SunoRow("Speech model", "", Glyph.Waveform, Theme.Faint,
                                  divider: false,
                                  trailing: new Row(_ovModelButton, _ovModelStatus));
        _content.Controls.Add(_ovModelRow);

        // Inline progress beneath the model row — visible only while a download
        // is moving, so the Overview page (where the Download CTA lives) shows
        // the bar, bytes, file count and errors instead of sending the user to
        // the Model tab to see them.
        _ovModelProgress = new SunoProgress { Visible = false, Margin = new Padding(24, 0, 0, 6) };
        _content.Controls.Add(_ovModelProgress);
        _ovModelBytes = new TextBlock("", Theme.Caption, Theme.Faint)
        { Visible = false, Margin = new Padding(24, 0, 0, 8) };
        _content.Controls.Add(_ovModelBytes);
        _ovModelRetry = new SunoButton("Retry", ButtonKind.Primary) { Visible = false };
        _ovModelRetry.Click += (s, e) => StartDownload();
        _ovModelErrorRow = new SunoRow("Download failed", "",
            Glyph.Alert, Theme.Danger, divider: false, trailing: _ovModelRetry)
        { Visible = false, ReserveIconColumn = true };
        _content.Controls.Add(_ovModelErrorRow);

        _content.Controls.Add(new RuleLine(strong: true));

        _content.Controls.Add(new SectionHeader("Current setup"));
        _ovHotkey = AddValueRow("Dictation hotkey", Glyph.Keyboard);
        _ovMicValue = AddValueRow("Microphone", Glyph.Mic);
        _ovAutoStop = AddValueRow("Auto-stop recording", Glyph.Timer);
        _ovScreen = AddValueRow("Screen context", Glyph.Screen);
        _ovLogin = AddValueRow("Start at login", Glyph.Power);
        _ovCorrections = AddValueRow("Dictionary entries", Glyph.TextCheck, divider: false);
        _content.Controls.Add(new RuleLine(strong: true));

        RefreshOverview();
    }

    private ValueText AddValueRow(string label, Glyph glyph, bool divider = true)
    {
        var value = new ValueText("—");
        var row = new SunoRow(label, null, glyph, Theme.Faint, divider, value) { ReserveIconColumn = true };
        _content.Controls.Add(row);
        return value;
    }

    private void RefreshOverview()
    {
        if (_page != Page.Overview || _ovEngineRow == null) return;

        int healthy = HealthyCount;
        bool ready = healthy == SubsystemCount;
        _ovLead!.SetText(ready ? "Everything's ready" : "Almost there");
        _ovLeadDetail!.SetText(ready
            ? $"Press {HotkeyDisplay} anywhere to dictate."
            : healthy == SubsystemCount - 1
                ? "1 item still needs attention before dictation works."
                : $"{SubsystemCount - healthy} items still need attention before dictation works.");
        _ovStatusHeader!.SetTrailing($"{healthy} of {SubsystemCount} ready");

        // Engine.
        _ovEngineRow.SetSubtitle(_sidecarOnline
            ? "Speech is transcribed entirely on this PC."
            : "Start the engine to enable dictation.");
        _ovEngineRow.SetIcon(Glyph.Cpu, _sidecarOnline ? Theme.Success : Theme.Warning);
        _ovEngineStatus!.Set(_sidecarOnline ? "Online" : "Offline",
                             _sidecarOnline ? Theme.Success : Theme.Warning);
        _ovEngineButton!.Visible = !_sidecarOnline && (TrayApp.Shared?.CanStartEngine ?? false);
        _ovEngineButton.SetText(_startingEngine ? "Starting…" : "Start engine");
        _ovEngineButton.Enabled = !_startingEngine;
        (_ovEngineRow.Trailing as Row)?.Refit();

        // Microphone.
        _ovMicRow!.SetSubtitle(_micAvailable
            ? MicDisplayName
            : "No recording device found. Plug one in, or check Settings → Privacy & security → Microphone.");
        _ovMicRow.SetIcon(Glyph.Mic, _micAvailable ? Theme.Success : Theme.Warning);
        _ovMicStatus!.Set(_micAvailable ? "Available" : "Not found",
                          _micAvailable ? Theme.Success : Theme.Warning);

        // Account.
        bool connected = AccountConnected;
        _ovAccountRow!.SetSubtitle(connected
            ? "This PC is linked to your SunoFlow account."
            : "Connect this PC before dictating — every dictation is checked against your subscription.");
        _ovAccountRow.SetIcon(Glyph.Person, connected ? Theme.Success : Theme.Warning);
        _ovAccountStatus!.Set(connected ? "Connected" : "Not connected",
                              connected ? Theme.Success : Theme.Warning);

        // Speech model. Four shapes, and only one of them is an invitation to
        // act — the button appears exactly when downloading is the thing to do.
        var ms = _modelStatus;
        bool modelKnown = _sidecarOnline && ms != null;
        bool downloading = ms is { Active: true };
        bool canDownload = modelKnown && !ModelReady && !downloading;

        _ovModelRow!.SetSubtitle(
            !_sidecarOnline ? "Start the engine to see whether the model is installed."
            : ms == null ? "Checking whether the model is on this PC…"
            : ModelReady ? "Speech is transcribed on this PC, with no internet connection."
            : downloading ? "Downloading now — you can leave this page."
            : "Dictation cannot work until this is downloaded. About 2.5 GB, once.");
        _ovModelRow.SetIcon(Glyph.Waveform, ModelReady ? Theme.Success : Theme.Warning);
        _ovModelStatus!.Set(
            !modelKnown ? "Checking…"
            : ModelReady ? "Ready"
            : downloading ? $"{ms!.OverallDone} of {ms.OverallTotal} files"
            : "Not downloaded",
            !modelKnown ? Theme.Faint : ModelReady ? Theme.Success
            : downloading ? Theme.Accent : Theme.Warning);
        _ovModelButton!.Visible = canDownload;
        _ovModelButton.SetText(_downloadStarting ? "Starting…" : "Download");
        _ovModelButton.Enabled = !_downloadStarting;
        (_ovModelRow.Trailing as Row)?.Refit();

        // Inline download progress beneath the model row: progress bar + byte
        // counter while downloading, error row with Retry on failure.
        bool err = ms is { Phase: "error" } || (ms is { Active: false } && ms != null && !string.IsNullOrEmpty(ms.Error));
        _ovModelProgress!.Visible = downloading && ms is { Phase: not "loading" };
        if (_ovModelProgress.Visible && ms != null && ms.FileTotal > 0)
            _ovModelProgress.SetProgress(ms.Downloaded, ms.FileTotal);
        _ovModelBytes!.Visible = _ovModelProgress.Visible;
        if (_ovModelBytes.Visible && ms != null)
            _ovModelBytes.SetText(ms.FileTotal > 0
                ? $"{FormatBytes(ms.Downloaded)} of {FormatBytes(ms.FileTotal)}  ·  File {ms.OverallDone + 1} of {Math.Max(ms.OverallTotal, 1)}"
                : $"{FormatBytes(ms.Downloaded)}  ·  File {ms.OverallDone + 1} of {Math.Max(ms.OverallTotal, 1)}");

        _ovModelErrorRow!.Visible = err;
        if (err && ms != null)
            _ovModelErrorRow.SetSubtitle(string.IsNullOrEmpty(ms.Error)
                ? "Something went wrong during the download." : ms.Error);
        _ovModelRetry!.Enabled = !_downloadStarting && _sidecarOnline;

        _ovHotkey!.Set(HotkeyDisplay);
        _ovMicValue!.Set(MicDisplayName);
        _ovAutoStop!.Set($"{_prefs.MaxRecordingSeconds} seconds");
        _ovScreen!.Set(_prefs.ScreenContextEnabled ? "On" : "Off",
                       _prefs.ScreenContextEnabled ? Theme.Success : Theme.Faint);
        _ovLogin!.Set(_launchAtLogin ? "Enabled" : "Disabled",
                      _launchAtLogin ? Theme.Success : Theme.Faint);
        _ovCorrections!.Set(_corrections.Length.ToString());

        // Run the 1s model poll while we don't yet know the model status or a
        // download is in flight on this page; stop it once the model is loaded,
        // missing, or in a terminal error so we don't hammer the sidecar forever.
        bool active = _modelStatus is { Active: true };
        bool unknown = _modelStatus == null && _sidecarOnline;
        if (active || unknown) _modelTimer.Start();
        else _modelTimer.Stop();

        Relayout();
    }

    private void StartEngine()
    {
        if (_startingEngine) return;
        _startingEngine = true;
        RefreshOverview();
        TrayApp.Shared?.StartEngine();
        // Give the sidecar a moment to bind its port before the button comes back.
        var settle = new System.Windows.Forms.Timer { Interval = 4000 };
        settle.Tick += (s, e) =>
        {
            settle.Stop();
            settle.Dispose();
            _startingEngine = false;
            RefreshOverview();
        };
        settle.Start();
    }

    // MARK: - Account

    private void BuildAccount()
    {
        var account = AccountManager.Shared;
        _content.Controls.Add(new SectionHeader("This PC"));

        switch (account.State)
        {
            case AccountState.Connected:
            {
                _content.Controls.Add(new SunoRow(
                    "Connected",
                    "This PC is linked to your account and can dictate.",
                    Glyph.CheckCircle, Theme.Success,
                    trailing: new StatusText("Linked", Theme.Success)));

                var signOut = new SunoButton("Disconnect", ButtonKind.Secondary);
                signOut.Click += (s, e) => ConfirmDisconnect();
                _content.Controls.Add(new SunoRow(
                    "Disconnect this PC",
                    "Removes the key stored here. To stop it working everywhere, disconnect the device from your account page instead.",
                    Glyph.XCircle, divider: false, trailing: signOut));
                break;
            }

            case AccountState.Waiting:
            {
                _content.Controls.Add(new SunoRow(
                    "Waiting for you to approve",
                    "Check your browser shows this same code, then choose Connect.",
                    Glyph.Hourglass, Theme.Warning,
                    trailing: new ValueText(account.UserCode, Theme.MonoStrong, Theme.Accent)));

                var cancel = new SunoButton("Cancel", ButtonKind.Ghost);
                cancel.Click += (s, e) => account.CancelPairing();
                var open = new SunoButton("Open browser", ButtonKind.Secondary);
                open.Click += (s, e) => account.OpenAccountPage();
                _content.Controls.Add(new SunoRow("Didn't the browser open?", null, Glyph.Globe,
                    divider: false, trailing: new Row(cancel, open)));
                break;
            }

            case AccountState.Failed:
            {
                var retry = new SunoButton("Try again", ButtonKind.Primary);
                retry.Click += (s, e) => _ = account.ConnectAsync();
                _content.Controls.Add(new SunoRow("Couldn't connect", account.FailureMessage,
                    Glyph.Alert, Theme.Warning, divider: false, trailing: retry));
                break;
            }

            default:
            {
                var connect = new SunoButton("Connect this PC", ButtonKind.Primary);
                connect.Click += (s, e) =>
                {
                    account.ClearEntitlementNotice();
                    _ = account.ConnectAsync();
                };
                _content.Controls.Add(new SunoRow(
                    "Not connected",
                    "Connect this PC to your SunoFlow account to dictate. We'll open your browser to confirm it's you — there's nothing to type.",
                    Glyph.Link, divider: false, trailing: connect));
                break;
            }
        }
        _content.Controls.Add(new RuleLine(strong: true));

        if (account.EntitlementNotice is { Length: > 0 } notice)
        {
            _content.Controls.Add(new SectionHeader("Subscription"));
            var openAccount = new SunoButton("Open account", ButtonKind.Primary);
            openAccount.Click += (s, e) => account.OpenAccountPage();
            _content.Controls.Add(new SunoRow("Dictation is paused", notice, Glyph.Card, Theme.Warning,
                divider: false, trailing: openAccount));
            _content.Controls.Add(new RuleLine(strong: true));
        }

        _content.Controls.Add(new SectionHeader("Your account"));
        var page = new SunoButton("Open account page", ButtonKind.Secondary);
        page.Click += (s, e) => account.OpenAccountPage();
        _content.Controls.Add(new SunoRow(
            "Subscription and devices",
            "Your plan, billing and every connected device live on your account page.",
            Glyph.Globe, divider: false, trailing: page));
        _content.Controls.Add(new RuleLine(strong: true));

        _content.Controls.Add(new SectionHeader("Where the key lives"));
        _content.Controls.Add(new SunoRow(
            "Encrypted for your Windows user",
            "The device key is stored with DPAPI under your account, so another user on this PC cannot read it and copying the file to another machine won't work.",
            Glyph.Lock, divider: false));
        _content.Controls.Add(new RuleLine(strong: true));

        foreach (Control child in _content.Controls)
            if (child is SunoRow row) row.ReserveIconColumn = true;
    }

    private void ConfirmDisconnect()
    {
        var answer = MessageBox.Show(this,
            "Remove the connection from this PC?\n\n" +
            "You won't be able to dictate here until you connect again. " +
            "This doesn't cancel your subscription, and it doesn't sign you out anywhere else.",
            "Disconnect this PC", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
        if (answer == DialogResult.OK) AccountManager.Shared.SignOutThisPc();
    }

    // MARK: - General

    private ValueText? _gwStatus;
    private SunoRow? _gwRow;

    private void BuildGeneral()
    {
        // Startup.
        _content.Controls.Add(new SectionHeader("Startup"));
        var startup = new SunoToggle(_launchAtLogin);
        startup.Toggled += (s, e) =>
        {
            if (startup.Checked) AutoStart.Enable(); else AutoStart.Disable();
            // The registry is the single source of truth, so read it back rather
            // than trusting the toggle: if the write failed, the switch must snap
            // back instead of quietly lying about what Windows will do at boot.
            _launchAtLogin = AutoStart.IsEnabled();
            startup.SetSilently(_launchAtLogin);
        };
        _content.Controls.Add(new SunoRow(
            "Start SunoFlow when I sign in",
            "SunoFlow starts automatically and waits in the notification area.",
            divider: false, trailing: startup));
        _content.Controls.Add(new RuleLine(strong: true));

        // Hotkey.
        _content.Controls.Add(new SectionHeader("Dictation hotkey"));
        var field = new HotkeyField(_prefs.HotkeyCode, _prefs.HotkeyModifiers);
        field.Captured += (s, e) =>
        {
            _prefs.HotkeyCode = field.KeyCode;
            _prefs.HotkeyModifiers = field.Modifiers;
        };
        var reset = new SunoButton("Reset", ButtonKind.Ghost);
        reset.Click += (s, e) =>
        {
            _prefs.ResetHotkeyToDefault();
            field.Set(_prefs.HotkeyCode, _prefs.HotkeyModifiers);
        };
        _content.Controls.Add(new SunoRow(
            "Shortcut",
            "Press this combination anywhere to start and stop dictation. Function keys work on their own; anything else needs a modifier.",
            divider: false, trailing: new Row(reset, field)));
        _content.Controls.Add(new RuleLine(strong: true));

        // Recording.
        _content.Controls.Add(new SectionHeader("Recording"));
        var stepper = new SunoStepper(_prefs.MaxRecordingSeconds, 10, 600, 5, "s");
        stepper.ValueChanged += (s, e) =>
        {
            _prefs.MaxRecordingSeconds = stepper.Value;
            _prefs.Save();
        };
        _content.Controls.Add(new SunoRow(
            "Stop automatically after",
            "Ends a recording you forgot about, so it can't run all day.",
            divider: false, trailing: stepper));
        _content.Controls.Add(new RuleLine(strong: true));

        // Transcript cleanup. The Mac keeps this server-owned and invisible; on
        // Windows the gateway's reachability is worth surfacing, because a PC
        // behind a corporate proxy is the one case where dictation still works
        // but comes back unpolished.
        _content.Controls.Add(new SectionHeader("Transcript cleanup"));
        var cleanup = new SunoToggle(_prefs.CleanupEnabled);
        cleanup.Toggled += (s, e) =>
        {
            _prefs.CleanupEnabled = cleanup.Checked;
            _prefs.Save();
            RefreshOverview();
        };
        _content.Controls.Add(new SunoRow(
            "Polish what I dictate",
            "Punctuation, capitals and paragraphing are tidied by the hosted cleanup service before the text is pasted. Turn this off to paste exactly what was heard.",
            trailing: cleanup));

        _gwStatus = new ValueText("Checking…", Theme.Value, Theme.Faint);
        _gwRow = new SunoRow("Cleanup service", TranscriptionClient.GatewayUrl,
                             divider: false, trailing: _gwStatus);
        _content.Controls.Add(_gwRow);
        _content.Controls.Add(new RuleLine(strong: true));

        // Screen context.
        _content.Controls.Add(new SectionHeader("Screen context"));
        var screen = new SunoToggle(_prefs.ScreenContextEnabled);
        var screenNotice = new SunoNotice(
            "Needs an OCR language pack: Settings → Time & language → Language & region → your language → Language options → Optional language features.",
            Glyph.Info, Theme.Faint)
        { Margin = new Padding(0, 14, 0, 14), Visible = _prefs.ScreenContextEnabled };
        screen.Toggled += (s, e) =>
        {
            _prefs.ScreenContextEnabled = screen.Checked;
            _prefs.Save();
            screenNotice.Visible = screen.Checked;
            Relayout();
            RefreshOverview();
        };
        _content.Controls.Add(new SunoRow(
            "Read what's on screen",
            "When dictation stops, SunoFlow reads the words visible on screen so it can match names, terminology and phrasing. Nothing is stored, and only the vocabulary is used. Off by default.",
            divider: false, trailing: screen));
        _content.Controls.Add(screenNotice);
        _content.Controls.Add(new RuleLine(strong: true));

        RefreshGeneral();
    }

    private void RefreshGeneral()
    {
        if (_page != Page.General || _gwStatus == null) return;
        _gwStatus.Set(_gatewayOk ? "Reachable" : "Offline", _gatewayOk ? Theme.Success : Theme.Danger);
        _gwRow?.SetSubtitle(_gatewayOk
            ? TranscriptionClient.GatewayUrl
            : $"{TranscriptionClient.GatewayUrl} — unreachable. Dictation still works; transcripts arrive unpolished.");
        Relayout();
    }

    // MARK: - Microphone

    private void BuildMicrophone()
    {
        _content.Controls.Add(new SectionHeader("Input device"));

        var combo = MakeCombo(260);
        combo.Items.Add("System default");
        foreach (var name in _micDevices) combo.Items.Add(name);

        // A device that has since been unplugged still deserves an entry, so the
        // list shows what is actually saved instead of silently reading back as
        // "System default" while the preference says otherwise.
        bool saved = !string.IsNullOrEmpty(_prefs.MicDeviceId);
        bool present = saved && _micDevices.Contains(_prefs.MicDeviceId);
        if (saved && !present) combo.Items.Add($"{_prefs.MicDeviceId} (disconnected)");
        combo.SelectedIndex = !saved ? 0
            : present ? combo.Items.IndexOf(_prefs.MicDeviceId)
            : combo.Items.Count - 1;

        combo.SelectedIndexChanged += (s, e) =>
        {
            if (combo.SelectedIndex <= 0) _prefs.MicDeviceId = "";
            else if (combo.SelectedIndex <= _micDevices.Length) _prefs.MicDeviceId = _micDevices[combo.SelectedIndex - 1];
            // The trailing "(disconnected)" entry keeps the saved id as it is.
            _prefs.Save();
            RefreshOverview();
        };

        _content.Controls.Add(new SunoRow(
            "Microphone", "Which input SunoFlow records from.",
            divider: false, trailing: combo));
        _content.Controls.Add(new RuleLine(strong: true));

        _content.Controls.Add(new SectionHeader("Devices out of date?"));
        var rescan = new SunoButton("Rescan", ButtonKind.Secondary);
        rescan.Click += (s, e) =>
        {
            _micDevices = SafeDeviceNames();
            _micAvailable = _micDevices.Length > 0;
            BuildPage();
        };
        _content.Controls.Add(new SunoRow(
            "Rescan inputs",
            "SunoFlow reads the input list when this page opens. Rescan if you have just plugged something in.",
            Glyph.Refresh, divider: false, trailing: rescan));
        _content.Controls.Add(new RuleLine(strong: true));

        _content.Controls.Add(new SectionHeader("Getting a clean recording"));
        _content.Controls.Add(new SunoRow(
            "The built-in microphone is usually best",
            "It stays in high-quality mode while you dictate, and it is what the speech model hears most often.",
            Glyph.CheckCircle));
        _content.Controls.Add(new SunoRow(
            "Wired beats wireless",
            "A Bluetooth headset switches to low-quality call mode the moment anything records from it, which degrades audio in every app while you dictate.",
            Glyph.Link));
        _content.Controls.Add(new SunoRow(
            "Windows asks once",
            "The first recording triggers the system microphone prompt. If you declined it, re-enable SunoFlow under Settings → Privacy & security → Microphone.",
            Glyph.Lock, divider: false));
        _content.Controls.Add(new RuleLine(strong: true));

        foreach (Control child in _content.Controls)
            if (child is SunoRow row) row.ReserveIconColumn = true;
    }

    // MARK: - Speech model

    private Stack? _modelBody;
    private string _modelShape = "";
    private SunoProgress? _modelProgress;
    private ValueText? _modelCounter;
    private TextBlock? _modelBytes;
    private SunoRow? _modelStatusRow;

    private void BuildModel()
    {
        if (!_sidecarOnline)
        {
            _content.Controls.Add(new SunoNotice(
                "The engine is offline — start it from Overview before downloading the model.")
            { Margin = new Padding(0, 26, 0, 0) });
        }

        _content.Controls.Add(new SectionHeader("On-device model"));
        _content.Controls.Add(new SunoRow(
            "SunoFlow speech model v1",
            "Roughly 2.5 GB. The download takes a few minutes on a typical connection, and only happens once.",
            Glyph.Waveform) { ReserveIconColumn = true });

        _modelBody = new Stack { BackColor = Theme.Paper };
        _content.Controls.Add(_modelBody);
        _content.Controls.Add(new RuleLine(strong: true));

        _content.Controls.Add(new SectionHeader("Where it runs"));
        _content.Controls.Add(new SunoRow(
            "On this PC",
            "Speech is turned into text by your own machine, on the GPU via DirectML. The recording is never uploaded.",
            Glyph.Desktop) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow(
            "Downloaded once",
            @"Stored in %LOCALAPPDATA%\SunoFlow\model and reused. After the first download it works with no internet connection.",
            Glyph.Download, divider: false) { ReserveIconColumn = true });
        _content.Controls.Add(new RuleLine(strong: true));

        _modelShape = "";
        RefreshModel();
    }

    private void RefreshModel()
    {
        if (_page != Page.Model || _modelBody == null) return;
        var st = _modelStatus;

        string shape = st == null ? (_sidecarOnline ? "checking" : "unavailable")
            : st.ModelLoaded ? "loaded"
            : st.Active && st.Phase == "loading" ? "loading"
            : st.Active ? "downloading"
            : st.Phase == "error" || !string.IsNullOrEmpty(st.Error) ? "error"
            : st.ModelPresent ? "present"
            : "missing";

        if (shape != _modelShape)
        {
            _modelShape = shape;
            RebuildModelBody(shape, st);
        }

        // Numbers move every second; the shape does not, so only these are patched.
        if (shape == "downloading" && st != null)
        {
            _modelCounter?.Set($"{st.OverallDone}/{st.OverallTotal}");
            _modelStatusRow?.SetSubtitle($"File {st.OverallDone + 1} of {Math.Max(st.OverallTotal, 1)}");
            _modelProgress?.SetProgress(st.Downloaded, Math.Max(st.FileTotal, 1));
            _modelBytes?.SetText(st.FileTotal > 0
                ? $"{FormatBytes(st.Downloaded)} of {FormatBytes(st.FileTotal)}"
                : FormatBytes(st.Downloaded));
        }

        // Stop the one-second poll once there is nothing left moving.
        if (shape is "loaded" or "missing" or "error" or "present" or "unavailable") _modelTimer.Stop();
        else _modelTimer.Start();

        Relayout();
    }

    private void RebuildModelBody(string shape, TranscriptionClient.ModelStatus? st)
    {
        var body = _modelBody!;
        ClearAndDispose(body);
        _modelProgress = null;
        _modelCounter = null;
        _modelBytes = null;
        _modelStatusRow = null;

        switch (shape)
        {
            case "loaded":
                body.Controls.Add(new SunoRow("Model ready", "Dictation is available.",
                    divider: false, trailing: new StatusText("Ready", Theme.Success)));
                break;

            case "loading":
                body.Controls.Add(new SunoRow("Loading model into memory…", null,
                    divider: false, trailing: new StatusText("Working", Theme.Accent)));
                break;

            case "downloading":
                _modelCounter = new ValueText("0/0", Theme.Value, Theme.Body);
                _modelStatusRow = new SunoRow("Downloading model…", "", divider: false, trailing: _modelCounter);
                body.Controls.Add(_modelStatusRow);
                _modelProgress = new SunoProgress { Margin = new Padding(0, 0, 0, 7) };
                body.Controls.Add(_modelProgress);
                _modelBytes = new TextBlock("", Theme.Caption, Theme.Faint) { Margin = new Padding(0, 0, 0, 16) };
                body.Controls.Add(_modelBytes);
                break;

            case "present":
            {
                var start = new SunoButton("Start engine", ButtonKind.Primary);
                start.Click += (s, e) => StartEngine();
                start.Enabled = TrayApp.Shared?.CanStartEngine ?? false;
                body.Controls.Add(new SunoRow("Downloaded, but not loaded",
                    "Restart the engine to activate the model.", divider: false, trailing: start));
                break;
            }

            case "error":
            {
                var retry = new SunoButton("Retry", ButtonKind.Primary);
                retry.Click += (s, e) => StartDownload();
                body.Controls.Add(new SunoRow("Download failed",
                    string.IsNullOrEmpty(st?.Error) ? "Something went wrong during the download." : st!.Error,
                    Glyph.Alert, Theme.Danger, divider: false, trailing: retry));
                break;
            }

            case "checking":
                body.Controls.Add(new SunoRow("Checking model status…", null, divider: false));
                break;

            case "unavailable":
                body.Controls.Add(new SunoRow("Status unavailable",
                    "Start the engine to see whether the model is installed.", divider: false));
                break;

            default:
            {
                var download = new SunoButton(_downloadStarting ? "Starting…" : "Download model", ButtonKind.Primary);
                download.Enabled = !_downloadStarting && _sidecarOnline;
                download.Click += (s, e) => StartDownload();
                body.Controls.Add(new SunoRow("Not downloaded yet",
                    "Dictation stays unavailable until the model is on this PC.",
                    divider: false, trailing: download));
                break;
            }
        }
    }

    private async void StartDownload()
    {
        if (_downloadStarting) return;
        _downloadStarting = true;
        _modelShape = "";           // force the body to redraw with "Starting…"
        RefreshModel();
        RefreshOverview();          // the overview has its own button now
        var started = await TranscriptionClient.StartModelDownloadAsync();
        _downloadStarting = false;
        if (!started) AppLog.Log("Model download did not start");
        _modelShape = "";
        RefreshOverview();
        await PollModel();
    }

    private static string FormatBytes(long bytes)
    {
        if (bytes >= 1_000_000_000) return $"{bytes / 1_000_000_000.0:0.0} GB";
        if (bytes >= 1_000_000) return $"{bytes / 1_000_000.0:0} MB";
        if (bytes >= 1_000) return $"{bytes / 1_000.0:0} KB";
        return $"{bytes} B";
    }

    // MARK: - Dictionary

    private Stack? _dictList;
    private SunoField? _search;
    private SunoField? _newFrom, _newTo;
    private ComboBox? _newKind;
    private TextBlock? _newKindBlurb;
    private Stack? _addBlock;
    private SunoButton? _addToggle;
    private string? _editingKey;

    /// <summary>What the sidecar's classifier does when the user does not say.</summary>
    private const string AutoDetectBlurb =
        "Paste a link or handle and it becomes a shorthand; a respelling stays a spelling.";

    private void BuildCorrections()
    {
        _content.Controls.Add(new SectionHeader("Your dictionary", "Spellings it learns, and shorthand you add"));

        if (!_sidecarOnline)
        {
            _content.Controls.Add(new SunoNotice(
                "The engine is offline — start it from Overview to manage your dictionary.")
            { Margin = new Padding(0, 16, 0, 16) });
            _content.Controls.Add(new RuleLine(strong: true));
            AddDictionaryExplainer();
            return;
        }

        _search = new SunoField("Search your dictionary…", 260);
        _search.Box.TextChanged += (s, e) => RebuildDictionaryList();
        _addToggle = new SunoButton("Add entry", ButtonKind.Secondary);
        _addToggle.Click += (s, e) =>
        {
            _addBlock!.Visible = !_addBlock.Visible;
            _addToggle.SetText(_addBlock.Visible ? "Cancel" : "Add entry");
            Relayout();
        };
        _content.Controls.Add(new Row(_search, _addToggle) { Margin = new Padding(0, 14, 0, 14) });
        _content.Controls.Add(BuildAddBlock());

        _content.Controls.Add(new RuleLine());
        _dictList = new Stack { BackColor = Theme.Paper };
        _content.Controls.Add(_dictList);
        _content.Controls.Add(new RuleLine(strong: true));

        AddDictionaryExplainer();
        RebuildDictionaryList();
        _ = PollCorrections();
    }

    /// <summary>The "add an entry by hand" form: the pair, then which half of the
    /// dictionary it belongs to and what that means.</summary>
    private Control BuildAddBlock()
    {
        _newFrom = new SunoField("What you say", 210);
        _newTo = new SunoField("What should be written instead", 210);
        var add = new SunoButton("Add", ButtonKind.Primary);
        add.Click += (s, e) => AddCorrection();

        _newKind = MakeCombo(200);
        _newKind.Items.Add("Detect automatically");
        foreach (var kind in TranscriptionClient.CorrectionKinds.All)
            _newKind.Items.Add(TranscriptionClient.CorrectionKinds.Label(kind));
        _newKind.SelectedIndex = 0;

        _newKindBlurb = new TextBlock(AutoDetectBlurb, Theme.Caption, Theme.Faint);
        _newKind.SelectedIndexChanged += (s, e) =>
        {
            var kind = SelectedNewKind;
            _newFrom!.Box.PlaceholderText = kind.HasValue
                ? TranscriptionClient.CorrectionKinds.FromPlaceholder(kind.Value) : "What you say";
            _newTo!.Box.PlaceholderText = kind.HasValue
                ? TranscriptionClient.CorrectionKinds.ToPlaceholder(kind.Value)
                : "What should be written instead";
            _newKindBlurb!.SetText(kind.HasValue
                ? TranscriptionClient.CorrectionKinds.Blurb(kind.Value) : AutoDetectBlurb);
            Relayout();
        };

        _addBlock = new Stack { BackColor = Theme.Paper, Visible = false, Margin = new Padding(0, 0, 0, 14) };
        _addBlock.Controls.Add(new Row(_newFrom, _newTo, add));
        _addBlock.Controls.Add(new Row(_newKind) { Margin = new Padding(0, 8, 0, 6) });
        _addBlock.Controls.Add(_newKindBlurb);
        return _addBlock;
    }

    /// <summary>The chosen kind, or null for "let the sidecar decide" — which is
    /// the default, so the rule that classifies an entry lives in one place
    /// instead of being guessed at again here.</summary>
    private TranscriptionClient.CorrectionKind? SelectedNewKind =>
        _newKind == null || _newKind.SelectedIndex <= 0
            ? null
            : TranscriptionClient.CorrectionKinds.All[_newKind.SelectedIndex - 1];

    private static ComboBox MakeCombo(int width) => new()
    {
        DropDownStyle = ComboBoxStyle.DropDownList,
        Font = Theme.BodyText,
        Width = width,
        FlatStyle = FlatStyle.Flat,
        BackColor = Theme.Wash,
        ForeColor = Theme.Ink,
    };

    private void AddDictionaryExplainer()
    {
        _content.Controls.Add(new SectionHeader("How this works"));
        _content.Controls.Add(new SunoRow(
            "Spellings are learned for you",
            "After SunoFlow pastes, it notices small edits you make — a name respelled, an acronym capitalised — and remembers them. Rephrasing a whole sentence is you changing your mind, not a mistake, so only short, name-like fixes are picked up.",
            Glyph.Eye) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow(
            "Spellings always win",
            "They are applied as the last step of every dictation, so they override whatever the model heard.",
            Glyph.CheckCircle) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow(
            "Shorthand saves you spelling things out",
            "Save your Instagram or LinkedIn link once, then just say “here's my Instagram” and the link is written instead. Add these by hand — SunoFlow never invents one.",
            Glyph.Link) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow(
            "Shorthand reads the sentence first",
            "The value is only substituted where you were actually giving it out. Say “I don't have an Instagram” and the words stay exactly as you said them.",
            Glyph.Search) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow(
            "The list stays on this PC",
            "It lives in a local file next to the engine. Only the few entries that match what you just said travel with a dictation, so cleanup can apply them. Remove any entry above, or clear the lot.",
            Glyph.Lock, divider: false) { ReserveIconColumn = true });
        _content.Controls.Add(new RuleLine(strong: true));
    }

    private void RebuildDictionaryList()
    {
        if (_dictList == null) return;
        ClearAndDispose(_dictList);

        var query = _search?.Box.Text.Trim() ?? "";
        var shown = query.Length == 0
            ? _corrections
            : _corrections.Where(c =>
                  c.From.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                  c.To.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                  TranscriptionClient.CorrectionKinds.Label(c.ResolvedKind)
                      .Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();

        if (_corrections.Length == 0)
        {
            _dictList.Controls.Add(new SunoRow(
                "Nothing saved yet",
                "Edit the text SunoFlow pastes and it remembers the fix — or add a spelling or a shorthand by hand.",
                divider: false) { Margin = new Padding(0, 7, 0, 7) });
            Relayout();
            return;
        }

        if (shown.Length == 0)
        {
            _dictList.Controls.Add(new SunoRow(
                "No matches", $"Nothing in your dictionary matches “{query}”.", divider: false));
            Relayout();
            return;
        }

        foreach (var correction in shown)
        {
            if (correction.Key == _editingKey)
                _dictList.Controls.Add(BuildEditBlock(correction));
            else
                _dictList.Controls.Add(new EntryRow(correction, BeginEdit, DeleteCorrection));
        }

        var clear = new SunoButton("Clear all", ButtonKind.Ghost, Theme.Danger);
        clear.Click += (s, e) => ClearCorrections();
        _dictList.Controls.Add(new RuleLine(strong: true));
        _dictList.Controls.Add(new SunoRow(DictionarySummary(), null, divider: false, trailing: clear));
        Relayout();
    }

    /// <summary>"3 spellings · 1 shorthand entry", dropping whichever half is empty.</summary>
    private string DictionarySummary()
    {
        int spellings = _corrections.Count(c =>
            c.ResolvedKind == TranscriptionClient.CorrectionKind.Correction);
        int shorthand = _corrections.Length - spellings;
        var parts = new List<string>();
        if (spellings > 0) parts.Add($"{spellings} spelling{(spellings == 1 ? "" : "s")}");
        if (shorthand > 0) parts.Add($"{shorthand} shorthand entr{(shorthand == 1 ? "y" : "ies")}");
        return parts.Count == 0 ? "Nothing saved yet" : string.Join(" · ", parts);
    }

    private void BeginEdit(TranscriptionClient.Correction correction)
    {
        _editingKey = correction.Key;
        RebuildDictionaryListLater();
    }

    /// <summary>Rebuilds the list once the current click has finished unwinding.
    /// The buttons that ask for a rebuild live inside the rows the rebuild
    /// disposes, and destroying a control's handle from inside its own Click
    /// handler is how an ObjectDisposedException falls out of the message loop.</summary>
    private void RebuildDictionaryListLater() => OnUi(RebuildDictionaryList);

    /// <summary>Swaps one row for its editable form: the pair, its kind, and the
    /// two ways out. The kind is prefilled from the entry and never re-inferred —
    /// fixing a typo in a URL must not silently reclassify it.</summary>
    private Control BuildEditBlock(TranscriptionClient.Correction correction)
    {
        var kinds = TranscriptionClient.CorrectionKinds.All;
        var current = correction.ResolvedKind;

        var from = new SunoField(TranscriptionClient.CorrectionKinds.FromPlaceholder(current), 210)
        { Value = correction.From };
        var to = new SunoField(TranscriptionClient.CorrectionKinds.ToPlaceholder(current), 210)
        { Value = correction.To };
        var save = new SunoButton("Save", ButtonKind.Primary);
        var cancel = new SunoButton("Cancel", ButtonKind.Ghost);

        var kindCombo = MakeCombo(150);
        foreach (var kind in kinds) kindCombo.Items.Add(TranscriptionClient.CorrectionKinds.Label(kind));
        kindCombo.SelectedIndex = Math.Max(0, Array.IndexOf(kinds, current));
        var blurb = new TextBlock(TranscriptionClient.CorrectionKinds.Blurb(current), Theme.Caption, Theme.Faint);

        kindCombo.SelectedIndexChanged += (s, e) =>
        {
            var kind = kinds[Math.Max(0, kindCombo.SelectedIndex)];
            from.Box.PlaceholderText = TranscriptionClient.CorrectionKinds.FromPlaceholder(kind);
            to.Box.PlaceholderText = TranscriptionClient.CorrectionKinds.ToPlaceholder(kind);
            blurb.SetText(TranscriptionClient.CorrectionKinds.Blurb(kind));
            Relayout();
        };

        save.Click += async (s, e) =>
        {
            if (from.Value.Length == 0 || to.Value.Length == 0)
            {
                _editingKey = null;
                RebuildDictionaryListLater();
                return;
            }
            _corrections = await TranscriptionClient.UpdateCorrectionAsync(
                correction.Key, from.Value, to.Value, kinds[Math.Max(0, kindCombo.SelectedIndex)]);
            _editingKey = null;
            RebuildDictionaryListLater();
        };
        cancel.Click += (s, e) => { _editingKey = null; RebuildDictionaryListLater(); };

        var block = new Stack { BackColor = Theme.Paper, Margin = new Padding(0, 6, 0, 6) };
        block.Controls.Add(new Row(from, to, save, cancel));
        block.Controls.Add(new Row(kindCombo) { Margin = new Padding(0, 8, 0, 6) });
        block.Controls.Add(blurb);
        return block;
    }

    /// <summary>
    /// A small pill naming which half of the dictionary an entry belongs to.
    ///
    /// Worth the pixels because the two behave differently at dictation time: a
    /// spelling is swapped in on every dictation, while a shorthand value only
    /// lands where the model judges you were actually giving it. Without the badge
    /// that difference is invisible until it surprises someone.
    /// </summary>
    private sealed class KindBadge : Control
    {
        private static readonly Font BadgeFont = Theme.Semibold(7.5f);
        private readonly TranscriptionClient.CorrectionKind _kind;

        public KindBadge(TranscriptionClient.CorrectionKind kind)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                     | ControlStyles.OptimizedDoubleBuffer, true);
            SetStyle(ControlStyles.Selectable, false);
            _kind = kind;
            Text = TranscriptionClient.CorrectionKinds.Label(kind);
            var size = Theme.MeasureLine(Text, BadgeFont);
            Size = new Size(size.Width + 12, size.Height + 5);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(BackColor);
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            bool shorthand = _kind == TranscriptionClient.CorrectionKind.Expansion;
            using (var path = Glyphs.RoundedPath(0, 0, Width, Height, 4f))
            using (var brush = new SolidBrush(shorthand ? Theme.AccentSoft : Theme.Wash))
                g.FillPath(brush, path);
            TextRenderer.DrawText(g, Text, BadgeFont, ClientRectangle,
                shorthand ? Theme.Accent : Theme.Faint,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter
                | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }
    }

    /// <summary>One dictionary entry: what is heard, what gets written, which half
    /// it belongs to, and the edit and delete actions that appear on hover.</summary>
    private sealed class EntryRow : Control, IReflow
    {
        private readonly TranscriptionClient.Correction _correction;
        private readonly KindBadge _badge;
        private readonly SunoButton _edit;
        private readonly SunoButton _delete;
        private bool _hovering;

        public EntryRow(TranscriptionClient.Correction correction,
                        Action<TranscriptionClient.Correction> onEdit, Action<string> onDelete)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                     | ControlStyles.OptimizedDoubleBuffer, true);
            SetStyle(ControlStyles.Selectable, false);
            _correction = correction;

            _badge = new KindBadge(correction.ResolvedKind);
            Controls.Add(_badge);

            // Both actions only ever show while the row is hovered, so they carry
            // the hovered fill — otherwise each would clear a paper square over it.
            _edit = new SunoButton(Glyph.Pencil, Theme.Accent, "Edit")
            { Visible = false, BackColor = Theme.Wash };
            _edit.Click += (s, e) => onEdit(correction);
            _delete = new SunoButton(Glyph.Trash, Theme.Danger, "Delete")
            { Visible = false, BackColor = Theme.Wash };
            _delete.Click += (s, e) => onDelete(correction.Key);
            foreach (var button in new[] { _edit, _delete })
            {
                button.MouseEnter += (s, e) => Hover(true);
                button.MouseLeave += (s, e) => Hover(false);
                Controls.Add(button);
            }
            Height = 40;
        }

        private void Hover(bool on)
        {
            if (_hovering == on) return;
            _hovering = on;
            _edit.Visible = on;
            _delete.Visible = on;
            _badge.BackColor = on ? Theme.Wash : Theme.Paper;
            Invalidate();
        }

        protected override void OnMouseEnter(EventArgs e) { Hover(true); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e)
        {
            // Leaving into one of the buttons is not leaving the row.
            if (!ClientRectangle.Contains(PointToClient(MousePosition))) Hover(false);
            base.OnMouseLeave(e);
        }

        public void Reflow(int width)
        {
            Width = width;
            Height = 40;
            int band = Height - 1;
            int top = (band - _delete.Height) / 2;
            _delete.Location = new Point(width - _delete.Width, top);
            _edit.Location = new Point(width - _delete.Width - _edit.Width - 2, top);
            _badge.Location = new Point(BadgeLeft, (band - _badge.Height) / 2);
        }

        /// <summary>Room for the spoken side. Capped at a third of the row so a
        /// wordy shorthand trigger ("connect with me on LinkedIn") cannot squeeze
        /// out the value it stands for.</summary>
        private int FromWidth => Math.Min(
            Theme.MeasureLine(_correction.From, Theme.Mono).Width,
            Math.Max(60, Width / 3));

        /// <summary>Room for the written side. A shorthand value is a URL, several
        /// times longer than any respelling, so without a ceiling it runs under the
        /// badge and the hover buttons instead of ellipsising.</summary>
        private int ToWidth
        {
            get
            {
                int reserved = _badge.Width + 10 + _edit.Width + _delete.Width + 16;
                if (_correction.Count > 1)
                    reserved += Theme.MeasureLine($"seen {_correction.Count}×", Theme.Caption).Width + 10;
                int room = Width - (FromWidth + 10 + 21) - 12 - reserved;
                return Math.Max(60, Math.Min(
                    Theme.MeasureLine(_correction.To, Theme.MonoStrong).Width, room));
            }
        }

        /// <summary>Where the pair ends and the badge begins.</summary>
        private int BadgeLeft => FromWidth + 10 + 21 + ToWidth + 12;

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(_hovering ? Theme.Wash : BackColor);

            int band = Height - 1;
            var fromSize = Theme.MeasureLine(_correction.From, Theme.Mono);
            int x = 0;

            TextRenderer.DrawText(g, _correction.From, Theme.Mono,
                new Rectangle(x, (band - fromSize.Height) / 2, FromWidth, fromSize.Height),
                Theme.Faint, TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix
                    | TextFormatFlags.EndEllipsis);
            x += FromWidth + 10;

            Glyphs.Draw(g, Glyph.ArrowRight, new RectangleF(x, (band - 11) / 2f, 11, 11),
                        Theme.Blend(Theme.Faint, Theme.Paper, 0.3));
            x += 21;

            var toSize = Theme.MeasureLine(_correction.To, Theme.MonoStrong);
            TextRenderer.DrawText(g, _correction.To, Theme.MonoStrong,
                new Rectangle(x, (band - toSize.Height) / 2, ToWidth, toSize.Height), Theme.Ink,
                TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix
                    | TextFormatFlags.EndEllipsis);

            if (_correction.Count > 1)
            {
                var seen = $"seen {_correction.Count}×";
                var seenSize = Theme.MeasureLine(seen, Theme.Caption);
                int seenX = _badge.Right + 10;
                TextRenderer.DrawText(g, seen, Theme.Caption,
                    new Rectangle(seenX, (band - seenSize.Height) / 2, seenSize.Width, seenSize.Height),
                    Theme.Faint, TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
            }

            using var pen = new Pen(Theme.Rule);
            g.DrawLine(pen, 0, Height - 1, Width, Height - 1);
        }
    }

    private async void AddCorrection()
    {
        var from = _newFrom?.Value ?? "";
        var to = _newTo?.Value ?? "";
        if (from.Length == 0 || to.Length == 0) return;
        _corrections = await TranscriptionClient.AddCorrectionAsync(from, to, SelectedNewKind);
        if (_newFrom != null) _newFrom.Value = "";
        if (_newTo != null) _newTo.Value = "";
        if (_newKind != null) _newKind.SelectedIndex = 0;
        if (_addBlock != null) _addBlock.Visible = false;
        _addToggle?.SetText("Add entry");
        RebuildDictionaryList();
        RefreshOverview();
    }

    private async void DeleteCorrection(string key)
    {
        await TranscriptionClient.DeleteCorrectionAsync(key);
        await PollCorrections();
    }

    private async void ClearCorrections()
    {
        await TranscriptionClient.ClearCorrectionsAsync();
        await PollCorrections();
    }

    // MARK: - About

    private void BuildAbout()
    {
        _content.Controls.Add(new AboutLockup { Margin = new Padding(0, 28, 0, 4) });

        _content.Controls.Add(new SectionHeader("Version"));
        _content.Controls.Add(new SunoRow("Version", null, divider: true,
            trailing: new ValueText(Application.ProductVersion, Theme.Mono)));
        _content.Controls.Add(new SunoRow("Platform", null, divider: false,
            trailing: new ValueText($"Windows {Environment.OSVersion.Version}", Theme.Mono)));
        _content.Controls.Add(new RuleLine(strong: true));

        _content.Controls.Add(new SectionHeader("How it works"));
        _content.Controls.Add(new SunoRow(
            "Speech stays on this PC",
            "The speech model runs locally on your GPU through ONNX Runtime and DirectML. Audio is never uploaded.",
            Glyph.Desktop) { ReserveIconColumn = true });
        _content.Controls.Add(new SunoRow(
            "Cleanup runs on the hosted service",
            $"Transcript polishing is done by {TranscriptionClient.GatewayUrl}, which is also where your subscription is checked.",
            Glyph.Globe, divider: false) { ReserveIconColumn = true });
        _content.Controls.Add(new RuleLine(strong: true));

        _content.Controls.Add(new SectionHeader("Resources"));
        var logs = new SunoButton("Show log", ButtonKind.Secondary);
        logs.Click += (s, e) => RevealLogs();
        _content.Controls.Add(new SunoRow(
            "Diagnostic log",
            @"Records state changes and errors, never transcript contents. %LOCALAPPDATA%\SunoFlow\app-debug.log",
            divider: false, trailing: logs));
        _content.Controls.Add(new RuleLine(strong: true));
    }

    /// <summary>The mark and the product line that open the About page.</summary>
    private sealed class AboutLockup : Control, IReflow
    {
        public AboutLockup()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                     | ControlStyles.OptimizedDoubleBuffer, true);
            SetStyle(ControlStyles.Selectable, false);
            Height = 46;
        }

        public void Reflow(int width) { Width = width; Height = 46; }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(BackColor);
            BrandMark.Draw(g, new RectangleF(0, (Height - 34) / 2f, 34, 34), Theme.Accent);
            int titleHeight = Theme.LineHeight(Theme.Lead);
            int captionHeight = Theme.LineHeight(Theme.Caption);
            int top = (Height - titleHeight - 3 - captionHeight) / 2;
            TextRenderer.DrawText(g, "SunoFlow", Theme.Lead,
                new Rectangle(48, top, Width - 48, titleHeight), Theme.Ink,
                TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
            TextRenderer.DrawText(g, "On-device dictation for Windows", Theme.Caption,
                new Rectangle(48, top + titleHeight + 3, Width - 48, captionHeight), Theme.Faint,
                TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }
    }

    private static void RevealLogs()
    {
        try
        {
            var path = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "SunoFlow", "app-debug.log");
            if (!System.IO.File.Exists(path))
            {
                MessageBox.Show("No log has been written yet.", "SunoFlow",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe",
                $"/select,\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            AppLog.Log($"Could not reveal the log: {ex.Message}");
        }
    }
}

/// <summary>
/// A horizontal run of controls, right-aligned, used for the trailing side of a
/// row (a button beside a status word, a reset beside the hotkey field). Sizes
/// itself to its children so <see cref="SunoRow"/> can place it.
/// </summary>
internal sealed class Row : Panel, IReflow
{
    private readonly int _gap;

    public Row(params Control[] children) : this(12, children) { }

    public Row(int gap, params Control[] children)
    {
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
        _gap = gap;
        Controls.AddRange(children);
        Refit();
    }

    /// <summary>A run of buttons keeps its natural width; the column does not
    /// stretch it the way it stretches a row.</summary>
    public void Reflow(int width) => Refit();

    /// <summary>Re-measures after a child is shown, hidden or relabelled.</summary>
    public void Refit()
    {
        int x = 0, height = 0;
        foreach (Control child in Controls)
        {
            if (!child.Visible) continue;
            if (x > 0) x += _gap;
            child.Location = new Point(x, 0);
            x += child.Width;
            height = Math.Max(height, child.Height);
        }
        foreach (Control child in Controls)
        {
            if (!child.Visible) continue;
            child.Top = (height - child.Height) / 2;
        }
        Size = new Size(Math.Max(1, x), Math.Max(1, height));
    }
}

/// <summary>
/// Sends the mouse wheel to the sheet under the pointer.
///
/// Every control on these pages is non-selectable — the design has no focus rings
/// in it — so nothing inside a scrolling host ever holds focus, and Windows
/// delivers <c>WM_MOUSEWHEEL</c> to the focused control rather than the one being
/// pointed at. Without this neither the dashboard nor first-run setup would
/// scroll at all.
/// </summary>
internal sealed class WheelRouter : IMessageFilter
{
    private const int WM_MOUSEWHEEL = 0x020A;
    private readonly Panel _target;

    public WheelRouter(Panel target) => _target = target;

    public bool PreFilterMessage(ref Message m)
    {
        if (m.Msg != WM_MOUSEWHEEL) return false;
        if (_target.IsDisposed || !_target.IsHandleCreated || !_target.Visible) return false;
        if (!_target.RectangleToScreen(_target.ClientRectangle).Contains(Control.MousePosition)) return false;

        int delta = (short)(m.WParam.ToInt64() >> 16);
        var offset = _target.AutoScrollPosition;   // reported negative, assigned positive
        _target.AutoScrollPosition = new Point(-offset.X, -offset.Y - delta);
        return true;
    }
}
