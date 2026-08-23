using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace SunoFlow;

/// <summary>Where this PC stands with a SunoFlow account.</summary>
internal enum AccountState
{
    NotConnected,
    Waiting,
    Connected,
    Failed,
}

/// <summary>
/// Links this PC to a SunoFlow account and holds the device key. The Windows
/// counterpart of <c>AccountManager.swift</c>, following the same device-
/// authorisation flow the website implements: ask for a code, send the user to
/// the browser to approve it, then poll until the key comes back. Nothing is
/// typed by the user and the app never handles a password — the browser does
/// the signing in.
///
/// The key is this PC's credential for the cleanup service, which is where a
/// dictation is checked against the user's trial or subscription. Without it
/// nothing authenticates and the app refuses to record, exactly as the macOS
/// app does.
///
/// It is stored DPAPI-encrypted under the current user account rather than as
/// plain text, so it is not readable by another user on the same machine and
/// does not survive being copied to a different one. That is the closest
/// Windows equivalent of the macOS Keychain available without dragging in a
/// credential-manager dependency.
/// </summary>
internal sealed class AccountManager
{
    public static readonly AccountManager Shared = new();

    private const string FunctionsBase = "https://asia-south1-sunoflow-app.cloudfunctions.net";
    private const string AccountUrl = "https://sunoflow-app.web.app/dashboard.html";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNameCaseInsensitive = true };

    private readonly object _gate = new();
    private CancellationTokenSource? _pairing;

    // The key is read on every dictation, so it is cached rather than decrypted
    // from disk each time.
    private string? _cachedKey;
    private bool _cacheLoaded;

    private AccountManager()
    {
        State = DeviceKey == null ? AccountState.NotConnected : AccountState.Connected;
    }

    /// <summary>Raised whenever <see cref="State"/> or the notice changes, so the
    /// settings window can redraw. Handlers must marshal to the UI thread.</summary>
    public event EventHandler? Changed;

    public AccountState State { get; private set; }

    /// <summary>The short code the user approves in the browser, while waiting.</summary>
    public string UserCode { get; private set; } = "";

    /// <summary>Why the last pairing attempt failed, when <see cref="State"/> is Failed.</summary>
    public string FailureMessage { get; private set; } = "";

    /// <summary>Set when the gateway last refused us for a subscription reason,
    /// so the settings window can say why instead of failing silently.</summary>
    public string? EntitlementNotice { get; private set; }

    public bool IsConnected => State == AccountState.Connected;

    /// <summary>This PC's device key, or null if it has never been connected.
    /// Read by the transcription client so the sidecar can authenticate to the
    /// cleanup gateway.</summary>
    public string? DeviceKey
    {
        get
        {
            lock (_gate)
            {
                if (!_cacheLoaded)
                {
                    _cachedKey = ReadKey();
                    _cacheLoaded = true;
                }
                return _cachedKey;
            }
        }
    }

    // --- Pairing ------------------------------------------------------------------

    /// <summary>Starts a pairing: fetches a code, opens the browser, then polls
    /// until the user approves it or it expires.</summary>
    public async Task ConnectAsync()
    {
        CancelPairing();
        var cts = new CancellationTokenSource();
        // Taken once. A CancellationToken stays usable after its source is
        // disposed, but registering a callback on one (which Task.Delay does)
        // does not — so this method, not CancelPairing, owns the disposal.
        var ct = cts.Token;
        lock (_gate) { _pairing = cts; }

        EntitlementNotice = null;
        SetState(AccountState.Waiting, code: "…");

        try
        {
            var pairing = await RequestPairingAsync(ct);
            ct.ThrowIfCancellationRequested();
            SetState(AccountState.Waiting, code: pairing.UserCode);

            // Hand off to the browser, where the user signs in.
            OpenInBrowser(pairing.VerificationUri);

            var key = await AwaitApprovalAsync(pairing, ct);
            ct.ThrowIfCancellationRequested();

            StoreKey(key);
            SetState(AccountState.Connected);
            AppLog.Log("account: device connected");
        }
        catch (OperationCanceledException)
        {
            // CancelPairing already set the state.
        }
        catch (PairingException ex)
        {
            SetState(AccountState.Failed, failure: ex.Message);
            AppLog.Log($"account: pairing failed — {ex.Message}");
        }
        catch (Exception ex)
        {
            SetState(AccountState.Failed, failure: "Couldn't connect. Check your internet and try again.");
            AppLog.Log($"account: pairing failed — {ex.Message}");
        }
        finally
        {
            lock (_gate)
            {
                if (ReferenceEquals(_pairing, cts)) _pairing = null;
            }
            cts.Dispose();
        }
    }

    public void CancelPairing()
    {
        CancellationTokenSource? cts;
        lock (_gate) { cts = _pairing; _pairing = null; }
        if (cts == null) return;
        // Cancel only. ConnectAsync disposes it in its finally, once it is
        // certain nothing is still waiting on the token.
        try { cts.Cancel(); } catch (ObjectDisposedException) { /* already finished */ }
        SetState(DeviceKey == null ? AccountState.NotConnected : AccountState.Connected);
    }

    /// <summary>Forgets the key on this PC. It does not revoke it on the server —
    /// only the account owner can do that, from the dashboard — so the wording in
    /// the UI has to be careful not to promise more than this does.</summary>
    public void SignOutThisPc()
    {
        CancelPairing();
        ClearKey();
        EntitlementNotice = null;
        SetState(AccountState.NotConnected);
        AppLog.Log("account: device key removed from this PC");
    }

    public void OpenAccountPage() => OpenInBrowser(AccountUrl);

    /// <summary>Called when the sidecar reports the gateway refused a dictation.</summary>
    public void NoteEntitlementProblem(string message)
    {
        EntitlementNotice = message;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void ClearEntitlementNotice()
    {
        EntitlementNotice = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void SetState(AccountState state, string code = "", string failure = "")
    {
        State = state;
        UserCode = code;
        FailureMessage = failure;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    // --- Network ------------------------------------------------------------------

    private sealed class PairingException : Exception
    {
        public PairingException(string message) : base(message) { }
    }

    private sealed class Pairing
    {
        public string DeviceCode { get; init; } = "";
        public string UserCode { get; init; } = "";
        public string VerificationUri { get; init; } = "";
        public TimeSpan Interval { get; init; } = TimeSpan.FromSeconds(3);
        public DateTime ExpiresAt { get; init; }
    }

    private sealed class PairResponse
    {
        [JsonPropertyName("device_code")] public string DeviceCode { get; set; } = "";
        [JsonPropertyName("user_code")] public string UserCode { get; set; } = "";
        [JsonPropertyName("verification_uri")] public string VerificationUri { get; set; } = "";
        [JsonPropertyName("interval")] public double Interval { get; set; } = 3;
        [JsonPropertyName("expires_in")] public double ExpiresIn { get; set; } = 600;
    }

    private sealed class PollResponse
    {
        [JsonPropertyName("api_key")] public string ApiKey { get; set; } = "";
    }

    private static async Task<Pairing> RequestPairingAsync(CancellationToken ct)
    {
        var body = JsonSerializer.Serialize(new
        {
            name = Environment.MachineName,
            platform = "Windows " + Environment.OSVersion.Version,
            appVersion = typeof(AccountManager).Assembly.GetName().Version?.ToString() ?? "",
        });

        using var content = new StringContent(body, Encoding.UTF8, "application/json");
        using var resp = await Http.PostAsync($"{FunctionsBase}/pairDevice", content, ct);
        if (!resp.IsSuccessStatusCode)
            throw new PairingException("Couldn't start the connection. Check your internet and try again.");

        var json = await resp.Content.ReadAsStringAsync(ct);
        var parsed = JsonSerializer.Deserialize<PairResponse>(json, JsonOpts);
        if (parsed == null || string.IsNullOrEmpty(parsed.DeviceCode) || string.IsNullOrEmpty(parsed.UserCode))
            throw new PairingException("Couldn't start the connection. Check your internet and try again.");

        return new Pairing
        {
            DeviceCode = parsed.DeviceCode,
            UserCode = parsed.UserCode,
            VerificationUri = parsed.VerificationUri,
            Interval = TimeSpan.FromSeconds(Math.Max(1, parsed.Interval)),
            ExpiresAt = DateTime.UtcNow.AddSeconds(parsed.ExpiresIn),
        };
    }

    /// <summary>Polls until the user approves, the pairing expires, or we are cancelled.</summary>
    private static async Task<string> AwaitApprovalAsync(Pairing pairing, CancellationToken ct)
    {
        var body = JsonSerializer.Serialize(new { device_code = pairing.DeviceCode });

        while (DateTime.UtcNow < pairing.ExpiresAt)
        {
            ct.ThrowIfCancellationRequested();
            await Task.Delay(pairing.Interval, ct);
            ct.ThrowIfCancellationRequested();

            HttpResponseMessage resp;
            try
            {
                using var content = new StringContent(body, Encoding.UTF8, "application/json");
                resp = await Http.PostAsync($"{FunctionsBase}/pollDevice", content, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch
            {
                continue;   // transient network trouble: keep waiting
            }

            using (resp)
            {
                if ((int)resp.StatusCode == 428) continue;  // still waiting for approval
                if (!resp.IsSuccessStatusCode)
                    throw new PairingException("That connection expired. Start again to get a fresh code.");

                var json = await resp.Content.ReadAsStringAsync(ct);
                var parsed = JsonSerializer.Deserialize<PollResponse>(json, JsonOpts);
                if (parsed == null || string.IsNullOrEmpty(parsed.ApiKey))
                    throw new PairingException("The connection came back empty. Try again.");
                return parsed.ApiKey;
            }
        }
        throw new PairingException("The code expired before it was approved. Try again.");
    }

    private static void OpenInBrowser(string url)
    {
        if (string.IsNullOrEmpty(url)) return;
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            AppLog.Log($"account: couldn't open the browser — {ex.Message}");
        }
    }

    // --- Key storage (DPAPI) ------------------------------------------------------

    private static string KeyPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SunoFlow", "device.key");

    private static string? ReadKey()
    {
        try
        {
            if (!File.Exists(KeyPath)) return null;
            var plain = ProtectedData.Unprotect(
                File.ReadAllBytes(KeyPath), null, DataProtectionScope.CurrentUser);
            var value = Encoding.UTF8.GetString(plain);
            return string.IsNullOrWhiteSpace(value) ? null : value;
        }
        catch (Exception ex)
        {
            // A key encrypted by a different Windows user (or a corrupt file)
            // cannot be decrypted here. Treat it as absent so the app asks the
            // user to connect again rather than failing every dictation.
            AppLog.Log($"account: stored device key unreadable — {ex.Message}");
            return null;
        }
    }

    private void StoreKey(string key)
    {
        lock (_gate)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(KeyPath)!);
                var blob = ProtectedData.Protect(
                    Encoding.UTF8.GetBytes(key), null, DataProtectionScope.CurrentUser);
                File.WriteAllBytes(KeyPath, blob);
                _cachedKey = key;
                _cacheLoaded = true;
            }
            catch (Exception ex)
            {
                AppLog.Log($"account: could not store the device key — {ex.Message}");
                throw new PairingException("Couldn't save the connection on this PC. Try again.");
            }
        }
    }

    private void ClearKey()
    {
        lock (_gate)
        {
            try { File.Delete(KeyPath); } catch { /* best-effort */ }
            _cachedKey = null;
            _cacheLoaded = true;
        }
    }
}
