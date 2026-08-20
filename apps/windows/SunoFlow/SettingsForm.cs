using System;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace SunoFlow;

/// <summary>
/// The settings window, a tabbed WinForms dialog. Mirrors the macOS
/// <c>SettingsView.swift</c> tabs: Overview, General, Mic, Corrections, AI
/// Cleanup, Model, About. Each tab is a panel built programmatically to match
/// the macOS layout (label + description on the left, control on the right).
/// </summary>
internal sealed class SettingsForm : Form
{
    private readonly TabControl _tabs = new();
    private readonly Preferences _prefs = Preferences.Instance;

    // General tab controls.
    private Label _hotkeyLabel = new();
    private NumericUpDown _maxSeconds = new();
    private CheckBox _cleanupCheck = new();
    private CheckBox _screenCheck = new();
    private CheckBox _autoStartCheck = new();

    // Mic tab.
    private ComboBox _micCombo = new();
    private Label _micWarning = new();

    // AI Cleanup tab.
    private Label _gatewayLabel = new();
    private readonly System.Windows.Forms.Timer _statusTimer = new();

    // Model tab.
    private Label _modelPhase = new();
    private ProgressBar _modelProgress = new();
    private Button _downloadBtn = new();
    private Label _modelId = new();
    private readonly System.Windows.Forms.Timer _modelTimer = new();

    public SettingsForm()
    {
        Text = "SunoFlow Settings";
        StartPosition = FormStartPosition.CenterScreen;
        Width = 620;
        Height = 520;
        MinimumSize = new Size(560, 480);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;

        _tabs.Dock = DockStyle.Fill;
        Controls.Add(_tabs);

        BuildOverviewTab();
        BuildGeneralTab();
        BuildMicTab();
        BuildCorrectionsTab();
        BuildCleanupTab();
        BuildModelTab();
        BuildAboutTab();

        _statusTimer.Interval = 3000;
        _statusTimer.Tick += (s, e) => _ = RefreshGatewayStatus();
        _statusTimer.Start();
        _ = RefreshGatewayStatus();

        _modelTimer.Interval = 1000;
        _modelTimer.Tick += (s, e) => _ = RefreshModelStatus();
    }

    // --- Overview ----------------------------------------------------------------

    private void BuildOverviewTab()
    {
        var p = new TabPage("Overview");
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(16),
        };

        panel.Controls.Add(MakeLabel("SunoFlow", 16, FontStyle.Bold, Color.Black));
        panel.Controls.Add(MakeLabel("On-device voice dictation for Windows.", 9));
        panel.Controls.Add(MakeSpacer(10));

        // Status card: sidecar health.
        var sidecarCard = MakeStatusCard("STT sidecar", "Checking…", Color.Gray);
        panel.Controls.Add(sidecarCard);

        // Cleanup gateway card.
        var cleanupCard = MakeStatusCard("Cleanup service", "Checking…", Color.Gray);
        panel.Controls.Add(cleanupCard);

        // Poll health for both cards.
        var pollTimer = new System.Windows.Forms.Timer { Interval = 3000 };
        pollTimer.Tick += (s, e) =>
        {
            _ = Task.Run(async () =>
            {
                var sidecarOk = await TranscriptionClient.HealthAsync();
                var cleanupOk = await TranscriptionClient.CheckCleanupGatewayAsync();
                BeginInvoke(() =>
                {
                    UpdateStatusCard(sidecarCard, sidecarOk ? "Running" : "Offline",
                        sidecarOk ? Color.Green : Color.Red);
                    UpdateStatusCard(cleanupCard, cleanupOk ? "Reachable" : "Offline",
                        cleanupOk ? Color.Green : Color.Red);
                });
            });
        };
        pollTimer.Start();
        pollTimer.Tick += (s, e) => { }; // trigger first poll
        // Fire immediately.
        _ = Task.Run(async () =>
        {
            var sidecarOk = await TranscriptionClient.HealthAsync();
            var cleanupOk = await TranscriptionClient.CheckCleanupGatewayAsync();
            BeginInvoke(() =>
            {
                UpdateStatusCard(sidecarCard, sidecarOk ? "Running" : "Offline",
                    sidecarOk ? Color.Green : Color.Red);
                UpdateStatusCard(cleanupCard, cleanupOk ? "Reachable" : "Offline",
                    cleanupOk ? Color.Green : Color.Red);
            });
        });

        _tabs.TabPages.Add(p);
    }

    // --- General -----------------------------------------------------------------

    private void BuildGeneralTab()
    {
        var p = new TabPage("General");
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(16),
        };

        // Hotkey.
        panel.Controls.Add(MakeSectionLabel("Dictation hotkey"));
        _hotkeyLabel = MakeLabel(KeyCombo.Display(_prefs.HotkeyCode, _prefs.HotkeyModifiers), 10);
        panel.Controls.Add(_hotkeyLabel);
        var recordBtn = new Button { Text = "Record new shortcut…", AutoSize = true };
        recordBtn.Click += (s, e) => RecordNewHotkey();
        panel.Controls.Add(recordBtn);
        var resetBtn = new Button { Text = "Restore default (Alt+Space)", AutoSize = true };
        resetBtn.Click += (s, e) =>
        {
            _prefs.ResetHotkeyToDefault();
            _hotkeyLabel.Text = KeyCombo.Display(_prefs.HotkeyCode, _prefs.HotkeyModifiers);
        };
        panel.Controls.Add(resetBtn);
        panel.Controls.Add(MakeSpacer(12));

        // Max recording duration.
        panel.Controls.Add(MakeSectionLabel("Max recording duration (seconds)"));
        _maxSeconds = new NumericUpDown
        {
            Minimum = 10, Maximum = 300, Value = _prefs.MaxRecordingSeconds, Width = 80,
        };
        _maxSeconds.ValueChanged += (s, e) => { _prefs.MaxRecordingSeconds = (int)_maxSeconds.Value; _prefs.Save(); };
        panel.Controls.Add(_maxSeconds);
        panel.Controls.Add(MakeSpacer(12));

        panel.Controls.Add(MakeSectionLabel("AI cleanup"));
        _cleanupCheck = new CheckBox { Text = "Polish transcripts with the cleanup service",
            Checked = _prefs.CleanupEnabled, AutoSize = true };
        _cleanupCheck.CheckedChanged += (s, e) => { _prefs.CleanupEnabled = _cleanupCheck.Checked; _prefs.Save(); };
        panel.Controls.Add(_cleanupCheck);

        panel.Controls.Add(MakeSpacer(12));
        panel.Controls.Add(MakeSectionLabel("Screen context (beta)"));
        _screenCheck = new CheckBox
        {
            Text = "Capture on-screen text as cleanup context",
            Checked = _prefs.ScreenContextEnabled, AutoSize = true,
        };
        _screenCheck.CheckedChanged += (s, e) => { _prefs.ScreenContextEnabled = _screenCheck.Checked; _prefs.Save(); };
        panel.Controls.Add(_screenCheck);
        panel.Controls.Add(MakeLabel("Requires the Screen Recording permission. Off by default.", 8, FontStyle.Italic, Color.DimGray));

        panel.Controls.Add(MakeSpacer(12));
        panel.Controls.Add(MakeSectionLabel("Startup"));
        _autoStartCheck = new CheckBox
        {
            Text = "Start SunoFlow automatically when I log in",
            Checked = AutoStart.IsEnabled(),
            AutoSize = true,
        };
        _autoStartCheck.CheckedChanged += (s, e) =>
        {
            if (_autoStartCheck.Checked) AutoStart.Enable();
            else AutoStart.Disable();
        };
        panel.Controls.Add(_autoStartCheck);

        p.Controls.Add(panel);
        _tabs.TabPages.Add(p);
    }

    // --- Mic ---------------------------------------------------------------------

    private void BuildMicTab()
    {
        var p = new TabPage("Mic");
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(16),
        };

        panel.Controls.Add(MakeSectionLabel("Input device"));
        _micCombo = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            Width = 320,
        };
        _micCombo.Items.Add("System default");
        foreach (var name in AudioRecorder.ListDeviceNames())
            _micCombo.Items.Add(name);
        _micCombo.SelectedIndex = string.IsNullOrEmpty(_prefs.MicDeviceId) ? 0 : Math.Max(0, _micCombo.Items.IndexOf(_prefs.MicDeviceId));
        _micCombo.SelectedIndexChanged += (s, e) =>
        {
            _prefs.MicDeviceId = _micCombo.SelectedIndex == 0 ? "" : (string)_micCombo.SelectedItem!;
            _prefs.Save();
            RefreshMicWarning();
        };
        panel.Controls.Add(_micCombo);
        panel.Controls.Add(MakeSpacer(8));
        _micWarning = MakeLabel("", 8, FontStyle.Italic, Color.DimGray);
        panel.Controls.Add(_micWarning);
        RefreshMicWarning();

        p.Controls.Add(panel);
        _tabs.TabPages.Add(p);
    }

    private void RefreshMicWarning()
    {
        if (string.IsNullOrEmpty(_prefs.MicDeviceId))
            _micWarning.Text = "Using the system default input device.";
        else
            _micWarning.Text = $"Selected: {_prefs.MicDeviceId}";
    }

    // --- Corrections -------------------------------------------------------------

    private void BuildCorrectionsTab()
    {
        var p = new TabPage("Corrections");
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3,
            Padding = new Padding(16),
        };
        panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));

        var header = MakeSectionLabel("Learned Corrections (edit pasted text to teach it)");
        panel.Controls.Add(header, 0, 0);

        var list = new ListView
        {
            Dock = DockStyle.Fill,
            View = View.Details,
            FullRowSelect = true,
            GridLines = true,
        };
        list.Columns.Add("From", 160);
        list.Columns.Add("To", 200);
        list.Columns.Add("Count", 60);
        list.ContextMenuStrip = new ContextMenuStrip();
        var deleteItem = list.ContextMenuStrip.Items.Add("Delete");
        deleteItem.Click += (s, e) =>
        {
            if (list.SelectedItems.Count == 0) return;
            var key = (string)list.SelectedItems[0].Tag!;
            _ = TranscriptionClient.DeleteCorrectionAsync(key).ContinueWith(_ => BeginInvoke(() => LoadCorrections(list)));
        };
        panel.Controls.Add(list, 0, 1);

        var addPanel = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = false };
        var fromBox = new TextBox { Width = 120, PlaceholderText = "from" };
        var toBox = new TextBox { Width = 120, PlaceholderText = "to" };
        var addBtn = new Button { Text = "Add", AutoSize = true };
        addBtn.Click += async (s, e) =>
        {
            var from = fromBox.Text.Trim();
            var to = toBox.Text.Trim();
            if (from.Length == 0 || to.Length == 0) return;
            await TranscriptionClient.AddCorrectionAsync(from, to);
            fromBox.Clear(); toBox.Clear();
            LoadCorrections(list);
        };
        var clearBtn = new Button { Text = "Clear All", AutoSize = true };
        clearBtn.Click += async (s, e) =>
        {
            await TranscriptionClient.ClearCorrectionsAsync();
            LoadCorrections(list);
        };
        addPanel.Controls.AddRange(new Control[] { fromBox, toBox, addBtn, clearBtn });
        panel.Controls.Add(addPanel, 0, 2);

        p.Controls.Add(panel);
        _tabs.TabPages.Add(p);

        LoadCorrections(list);
        // Refresh when the tab is shown.
        _tabs.SelectedIndexChanged += (s, e) =>
        {
            if (_tabs.SelectedTab == p) LoadCorrections(list);
        };
    }

    private async void LoadCorrections(ListView list)
    {
        var corrections = await TranscriptionClient.FetchCorrectionsAsync();
        // After an await on a UI-thread call, we resume on the UI thread (no
        // ConfigureAwait(false)), so marshalling isn't strictly required — but
        // guard against a threadpool resume just in case.
        if (InvokeRequired)
            BeginInvoke(() => PopulateCorrections(list, corrections));
        else
            PopulateCorrections(list, corrections);
    }

    private static void PopulateCorrections(ListView list, TranscriptionClient.Correction[] corrections)
    {
        list.Items.Clear();
        foreach (var c in corrections)
        {
            var item = new ListViewItem(c.From) { Tag = c.Key };
            item.SubItems.Add(c.To);
            item.SubItems.Add(c.Count.ToString());
            list.Items.Add(item);
        }
    }

    // --- AI Cleanup --------------------------------------------------------------

    private void BuildCleanupTab()
    {
        var p = new TabPage("AI Cleanup");
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(16),
        };

        panel.Controls.Add(MakeSectionLabel("Cleanup service"));
        _gatewayLabel = MakeLabel("Checking…", 10);
        panel.Controls.Add(_gatewayLabel);
        panel.Controls.Add(MakeSpacer(8));
        panel.Controls.Add(MakeLabel($"Endpoint: {TranscriptionClient.GatewayUrl}", 8, FontStyle.Italic, Color.DimGray));
        panel.Controls.Add(MakeSpacer(12));
        panel.Controls.Add(MakeLabel(
            "The cleanup step runs on a hosted server, not on your machine. " +
            "When enabled, transcripts are sent to the cleanup service for " +
            "polishing (punctuation, formatting) before being pasted.", 9));

        p.Controls.Add(panel);
        _tabs.TabPages.Add(p);
    }

    private async Task RefreshGatewayStatus()
    {
        var ok = await TranscriptionClient.CheckCleanupGatewayAsync();
        BeginInvoke(() =>
        {
            _gatewayLabel.Text = ok ? "● Reachable" : "● Offline";
            _gatewayLabel.ForeColor = ok ? Color.Green : Color.Red;
        });
    }

    // --- Model -------------------------------------------------------------------

    private void BuildModelTab()
    {
        var p = new TabPage("Model");
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(16),
        };

        panel.Controls.Add(MakeSectionLabel("Speech recognition model"));
        _modelId = MakeLabel("", 8, FontStyle.Italic, Color.DimGray);
        panel.Controls.Add(_modelId);
        panel.Controls.Add(MakeSpacer(8));
        _modelPhase = MakeLabel("Checking…", 10);
        panel.Controls.Add(_modelPhase);
        panel.Controls.Add(MakeSpacer(8));
        _modelProgress = new ProgressBar { Width = 400, Height = 20, Minimum = 0, Maximum = 100 };
        panel.Controls.Add(_modelProgress);
        panel.Controls.Add(MakeSpacer(12));
        _downloadBtn = new Button { Text = "Download model", AutoSize = true };
        _downloadBtn.Click += async (s, e) =>
        {
            _downloadBtn.Enabled = false;
            await TranscriptionClient.StartModelDownloadAsync();
            _modelTimer.Start();
        };
        panel.Controls.Add(_downloadBtn);
        panel.Controls.Add(MakeSpacer(12));
        panel.Controls.Add(MakeLabel(
            "The model is downloaded once (about 2.5 GB) and stored in " +
            "%LOCALAPPDATA%\\SunoFlow\\model. After download it loads automatically — " +
            "no restart needed.", 9));

        p.Controls.Add(panel);
        _tabs.TabPages.Add(p);
        _ = RefreshModelStatus();
    }

    private async Task RefreshModelStatus()
    {
        var st = await TranscriptionClient.FetchModelStatusAsync();
        BeginInvoke(() =>
        {
            if (st == null)
            {
                _modelPhase.Text = "Cannot reach sidecar.";
                _modelId.Text = "";
                _downloadBtn.Enabled = false;
                _modelTimer.Stop();
                return;
            }
            _modelId.Text = $"{st.ModelId}";
            if (st.ModelLoaded)
            {
                _modelPhase.Text = "● Loaded — ready to dictate.";
                _modelPhase.ForeColor = Color.Green;
                _modelProgress.Value = 100;
                _downloadBtn.Enabled = false;
                _downloadBtn.Text = "Model ready";
                _modelTimer.Stop();
            }
            else if (st.Active || st.Phase == "downloading" || st.Phase == "loading")
            {
                _modelPhase.Text = st.Phase == "loading"
                    ? "Loading model…"
                    : $"Downloading: {st.CurrentFile} ({st.OverallDone}/{st.OverallTotal})";
                _modelPhase.ForeColor = Color.Blue;
                if (st.OverallTotal > 0)
                    _modelProgress.Value = (int)(100.0 * st.OverallDone / st.OverallTotal);
                _downloadBtn.Enabled = false;
                _downloadBtn.Text = "Downloading…";
                _modelTimer.Start();
            }
            else if (st.ModelPresent)
            {
                _modelPhase.Text = "Model present but not loaded.";
                _modelPhase.ForeColor = Color.Orange;
                _downloadBtn.Enabled = false;
            }
            else if (!string.IsNullOrEmpty(st.Error))
            {
                _modelPhase.Text = $"Error: {st.Error}";
                _modelPhase.ForeColor = Color.Red;
                _downloadBtn.Enabled = true;
                _downloadBtn.Text = "Retry download";
            }
            else
            {
                _modelPhase.Text = "Not downloaded yet.";
                _modelPhase.ForeColor = Color.DimGray;
                _downloadBtn.Enabled = true;
                _downloadBtn.Text = "Download model";
            }
        });
    }

    // --- About -------------------------------------------------------------------

    private void BuildAboutTab()
    {
        var p = new TabPage("About");
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(16),
        };

        panel.Controls.Add(MakeLabel("SunoFlow for Windows", 16, FontStyle.Bold, Color.Black));
        panel.Controls.Add(MakeLabel("On-device voice dictation.", 9));
        panel.Controls.Add(MakeSpacer(12));
        panel.Controls.Add(MakeLabel("The speech-to-text model (Parakeet TDT 0.6B v3) " +
            "runs entirely on your machine via ONNX Runtime + DirectML. " +
            "Transcript polishing runs on the hosted cleanup service.", 9));
        panel.Controls.Add(MakeSpacer(12));
        panel.Controls.Add(MakeLabel($"Version {Application.ProductVersion}", 8, FontStyle.Italic, Color.DimGray));
        panel.Controls.Add(MakeLabel($"Cleanup service: {TranscriptionClient.GatewayUrl}", 8, FontStyle.Italic, Color.DimGray));
        panel.Controls.Add(MakeLabel($"Log file: %LOCALAPPDATA%\\SunoFlow\\app-debug.log", 8, FontStyle.Italic, Color.DimGray));

        p.Controls.Add(panel);
        _tabs.TabPages.Add(p);
    }

    // --- Hotkey recording --------------------------------------------------------

    private void RecordNewHotkey()
    {
        using var dlg = new HotkeyCaptureForm();
        if (dlg.ShowDialog(this) == DialogResult.OK)
        {
            _prefs.HotkeyCode = dlg.KeyCode;
            _prefs.HotkeyModifiers = dlg.Modifiers;
            _prefs.Save();
            _hotkeyLabel.Text = KeyCombo.Display(_prefs.HotkeyCode, _prefs.HotkeyModifiers);
        }
    }

    // --- Helpers -----------------------------------------------------------------

    private static Label MakeLabel(string text, float size = 9, FontStyle style = FontStyle.Regular, Color? color = null)
    {
        var l = new Label
        {
            Text = text,
            AutoSize = true,
            Font = new Font("Segoe UI", size, style),
            ForeColor = color ?? Color.Black,
        };
        return l;
    }

    private static Label MakeSectionLabel(string text)
    {
        var l = MakeLabel(text, 10, FontStyle.Bold);
        l.Margin = new Padding(0, 8, 0, 4);
        return l;
    }

    private static Control MakeSpacer(int height) => new Panel { Size = new Size(1, height), Margin = new Padding(0) };

    private static Panel MakeStatusCard(string title, string status, Color color)
    {
        var card = new Panel
        {
            Width = 540,
            Height = 60,
            BackColor = Color.FromArgb(245, 245, 247),
            Padding = new Padding(12),
        };
        var titleLbl = new Label { Text = title, Font = new Font("Segoe UI", 10, FontStyle.Bold), Location = new Point(12, 8), AutoSize = true };
        var statusLbl = new Label { Text = status, ForeColor = color, Font = new Font("Segoe UI", 10), Location = new Point(12, 30), AutoSize = true };
        // A small dot before the status text.
        var dot = new Label { Text = "●", ForeColor = color, Font = new Font("Segoe UI", 10), Location = new Point(card.Width - 30, 22), AutoSize = true };
        card.Controls.AddRange(new Control[] { titleLbl, statusLbl, dot });
        return card;
    }

    private static void UpdateStatusCard(Panel card, string status, Color color)
    {
        foreach (Control c in card.Controls)
        {
            if (c.Text == "●") { c.ForeColor = color; }
            else if (c.Font.Bold && c.Text != card.Controls[0].Text) { }
            else if (!c.Text.Contains("●")) { c.Text = status; c.ForeColor = color; }
        }
    }
}