using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;

namespace SunoFlow;

/// <summary>
/// HTTP client for the SunoFlow sidecar (<c>127.0.0.1:8765</c>). This is the C#
/// counterpart of <c>TranscriptionClient.swift</c> and consumes the exact same
/// HTTP contract documented in <c>docs/CONTRACT.md</c>. Two notable fixes over
/// the Swift client, called out in the contract:
/// <list type="bullet">
/// <item><c>/corrections/add</c> + <c>/corrections/update</c> send <c>frm</c>
///   (not <c>from</c>) — <c>from</c> is a Python keyword, so the endpoint names
///   its parameter <c>frm</c> and anything else silently 422s.</item>
/// <item><c>/learn</c> decodes <c>learned</c> as a lighter struct with a
///   <c>count</c> field (the Swift client decodes into a struct requiring
///   <c>key</c> the server never sends, so the learned count always reads 0).</item>
/// </list>
/// </summary>
internal static class TranscriptionClient
{
    public const string BaseUrl = "http://127.0.0.1:8765";

    /// <summary>Hosted cleanup gateway (transcript polishing). The app only
    /// probes its unauthenticated <c>/ready</c> for the settings status card.</summary>
    public const string GatewayUrl = "http://162.19.81.108:40009";

    private static readonly HttpClient Http = new()
    {
        Timeout = TimeSpan.FromSeconds(30),
    };

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    // --- Response DTOs -------------------------------------------------------------

    public sealed class TranscriptionResult
    {
        [JsonPropertyName("raw")] public string Raw { get; set; } = "";
        [JsonPropertyName("cleaned")] public string Cleaned { get; set; } = "";
    }

    /// <summary>Which half of the dictionary an entry belongs to.
    ///
    /// The two behave very differently at dictation time — a spelling is swapped
    /// in mechanically, a shorthand value is only substituted where the model
    /// judges the speaker was actually giving it — so the UI names the
    /// difference rather than showing one undifferentiated list. See
    /// <c>docs/CONTRACT.md</c> §corrections.</summary>
    public enum CorrectionKind { Correction, Expansion }

    /// <summary>User-facing wording for a <see cref="CorrectionKind"/>, kept
    /// beside the enum so the two platforms stay worded the same.</summary>
    public static class CorrectionKinds
    {
        public static readonly CorrectionKind[] All =
            { CorrectionKind.Correction, CorrectionKind.Expansion };

        /// <summary>Anything unrecognised — including the field being absent,
        /// which is how a sidecar predating the two-kind dictionary answers —
        /// reads as a spelling. Those installs only ever held spellings.</summary>
        public static CorrectionKind Parse(string? wire) =>
            string.Equals(wire, "expansion", StringComparison.OrdinalIgnoreCase)
                ? CorrectionKind.Expansion
                : CorrectionKind.Correction;

        public static string Wire(CorrectionKind kind) =>
            kind == CorrectionKind.Expansion ? "expansion" : "correction";

        public static string Label(CorrectionKind kind) =>
            kind == CorrectionKind.Expansion ? "Shorthand" : "Spelling";

        public static string Blurb(CorrectionKind kind) => kind == CorrectionKind.Expansion
            ? "Something you say out loud, and the value it stands for."
            : "A word dictation mishears, and how you write it.";

        public static string FromPlaceholder(CorrectionKind kind) =>
            kind == CorrectionKind.Expansion ? "What you say" : "What it mishears";

        public static string ToPlaceholder(CorrectionKind kind) =>
            kind == CorrectionKind.Expansion ? "The value to write instead" : "What it should write";
    }

    public sealed class Correction
    {
        [JsonPropertyName("key")] public string Key { get; set; } = "";
        [JsonPropertyName("from")] public string From { get; set; } = "";
        [JsonPropertyName("to")] public string To { get; set; } = "";
        [JsonPropertyName("count")] public int Count { get; set; }
        /// <summary>Kept as the raw wire string so an unknown value can never
        /// break deserialization of the whole list; read it via
        /// <see cref="ResolvedKind"/>.</summary>
        [JsonPropertyName("kind")] public string Kind { get; set; } = "";

        [JsonIgnore] public CorrectionKind ResolvedKind => CorrectionKinds.Parse(Kind);
    }

    private sealed class CorrectionsResponse
    {
        [JsonPropertyName("corrections")] public Correction[] Corrections { get; set; } = Array.Empty<Correction>();
    }

    private sealed class LearnResponse
    {
        // Decoded as a lighter struct — see class doc.
        public sealed class LearnedItem
        {
            [JsonPropertyName("from")] public string From { get; set; } = "";
            [JsonPropertyName("to")] public string To { get; set; } = "";
            [JsonPropertyName("count")] public int Count { get; set; }
        }
        [JsonPropertyName("learned")] public LearnedItem[] Learned { get; set; } = Array.Empty<LearnedItem>();
        [JsonPropertyName("total")] public int Total { get; set; }
    }

    private sealed class ReadyResponse
    {
        [JsonPropertyName("backend_ok")] public bool BackendOk { get; set; }
    }

    /// <summary>The sidecar's 402 body when this device may not dictate.</summary>
    private sealed class RefusalResponse
    {
        [JsonPropertyName("error")] public string Error { get; set; } = "";
        [JsonPropertyName("message")] public string Message { get; set; } = "";
    }

    /// <summary>
    /// What came back from <c>/transcribe</c>. Three outcomes, and the caller
    /// has to tell them apart: a transcript, a refusal (the account's trial has
    /// ended, its subscription lapsed, or this PC is not connected), or a plain
    /// failure. A refusal must not be treated as a failure — the user needs to
    /// be told why nothing was typed, and pointed at the fix.
    /// </summary>
    public sealed class TranscribeOutcome
    {
        public TranscriptionResult? Result { get; init; }

        /// <summary>Non-null when the device was refused; carries the wording the
        /// gateway chose, so every surface shows one consistent explanation.</summary>
        public string? NotEntitled { get; init; }

        /// <summary>Why it was refused: <c>not_entitled</c> (trial over,
        /// subscription lapsed, device disconnected — fixed on the account
        /// page) or <c>unreachable</c> (we could not check — fixed by
        /// reconnecting). Both stop the dictation; they are not the same news
        /// and must not read the same in the tray.</summary>
        public string NotEntitledCode { get; init; } = "not_entitled";

        public static TranscribeOutcome Ok(TranscriptionResult r) => new() { Result = r };
        public static TranscribeOutcome Refused(string message, string code) =>
            new() { NotEntitled = message, NotEntitledCode = code };
        public static TranscribeOutcome Failed() => new();
    }

    public sealed class Health
    {
        [JsonPropertyName("status")] public string Status { get; set; } = "";
        [JsonPropertyName("model_loaded")] public bool ModelLoaded { get; set; }
        [JsonPropertyName("model_present")] public bool ModelPresent { get; set; }

        /// <summary>Why the model would not start, empty when it started or was
        /// never downloaded. Carried on the liveness probe so the tray — which
        /// polls nothing else — can stop telling someone to download a model
        /// that is already on their disk.</summary>
        [JsonPropertyName("load_error")] public string LoadError { get; set; } = "";
    }

    public sealed class ModelStatus
    {
        [JsonPropertyName("model_present")] public bool ModelPresent { get; set; }
        [JsonPropertyName("model_loaded")] public bool ModelLoaded { get; set; }
        [JsonPropertyName("active")] public bool Active { get; set; }
        [JsonPropertyName("phase")] public string Phase { get; set; } = "idle";
        [JsonPropertyName("current_file")] public string CurrentFile { get; set; } = "";
        [JsonPropertyName("downloaded")] public long Downloaded { get; set; }
        [JsonPropertyName("file_total")] public long FileTotal { get; set; }
        [JsonPropertyName("overall_done")] public int OverallDone { get; set; }
        [JsonPropertyName("overall_total")] public int OverallTotal { get; set; }
        /// <summary>Last <b>download</b> error. Its remedy is to download again.</summary>
        [JsonPropertyName("error")] public string Error { get; set; } = "";
        [JsonPropertyName("model_dir")] public string ModelDir { get; set; } = "";
        [JsonPropertyName("model_id")] public string ModelId { get; set; } = "";

        /// <summary>Last <b>load</b> error — a distinct failure from
        /// <see cref="Error"/>, and one that re-downloading cannot fix: by the
        /// time it happens the whole model is already on disk and intact enough
        /// to open.
        /// Empty when the model loaded, or was never downloaded.</summary>
        [JsonPropertyName("load_error")] public string LoadError { get; set; } = "";

        /// <summary>What inference was actually verified on — "GPU (DirectML)"
        /// or "CPU". The sidecar falls back to CPU on a box with no DX12 GPU,
        /// so the dashboard reads this rather than claiming the GPU.</summary>
        [JsonPropertyName("runtime")] public string Runtime { get; set; } = "";

        /// <summary>Which build of the model this PC runs — "fp32" or "int8".
        /// The sidecar picks it from the hardware it finds; it is not a setting,
        /// and there is no user choice to offer. Empty on a platform that ships
        /// only one build.</summary>
        [JsonPropertyName("variant")] public string Variant { get; set; } = "";

        /// <summary><see cref="Variant"/> in words, for display: "full precision"
        /// or "int8".</summary>
        [JsonPropertyName("variant_label")] public string VariantLabel { get; set; } = "";

        /// <summary>Why the sidecar chose that build, in a sentence a user can
        /// read. Worth showing: somebody told they are on the smaller model is
        /// owed the reason, and "your GPU has 2 GB" is a better answer than
        /// silence.</summary>
        [JsonPropertyName("variant_reason")] public string VariantReason { get; set; } = "";

        /// <summary>What this PC's variant weighs. Full precision is ~2.5 GB and
        /// int8 about a quarter of that, so no screen may quote a fixed size —
        /// read it from here via <see cref="DownloadSizeText"/>.</summary>
        [JsonPropertyName("download_bytes")] public long DownloadBytes { get; set; }

        /// <summary>The download size as a short phrase for prose. Falls back to
        /// a size-free wording before the sidecar has said which variant this PC
        /// gets, which is better than naming a number that may be four times
        /// too big.</summary>
        [JsonIgnore]
        public string DownloadSizeText =>
            DownloadBytes >= 1_000_000_000 ? $"about {DownloadBytes / 1_000_000_000.0:0.0} GB"
            : DownloadBytes >= 1_000_000 ? $"about {DownloadBytes / 1_000_000.0:0} MB"
            : "a one-time download";

        /// <summary>True when the model is downloaded but will not start. The
        /// one state the dashboard used to have no words for: it looked like
        /// "not downloaded" and was offered a fix aimed at something else.</summary>
        [JsonIgnore] public bool LoadFailed => !ModelLoaded && !string.IsNullOrWhiteSpace(LoadError);
    }

    // --- Health -------------------------------------------------------------------

    /// <summary>GET /health. Liveness plus the model flags, because "the engine
    /// answers" and "dictation can produce words" are different questions — a
    /// sidecar with no model downloaded is healthy and returns empty
    /// transcripts forever.</summary>
    public static async Task<Health?> HealthDetailAsync()
    {
        try
        {
            using var cts = new System.Threading.CancellationTokenSource(TimeSpan.FromSeconds(2));
            using var resp = await Http.GetAsync($"{BaseUrl}/health", cts.Token);
            if (!resp.IsSuccessStatusCode) return null;
            var json = await resp.Content.ReadAsStringAsync(cts.Token);
            return JsonSerializer.Deserialize<Health>(json, JsonOpts);
        }
        catch { return null; }
    }

    /// <summary>Lightweight liveness probe (GET /health). Polled every 3s.</summary>
    public static async Task<bool> HealthAsync() => await HealthDetailAsync() != null;

    // --- Transcribe (multipart) ---------------------------------------------------

    /// <summary>
    /// POST /transcribe. Uploads the WAV as multipart/form-data with the
    /// optional <c>context</c> and <c>screen</c> fields, plus the <c>cleanup</c>
    /// query param.
    ///
    /// This PC's device key travels with the request so the sidecar can
    /// authenticate to the cleanup gateway, which is where the account's trial
    /// and subscription are actually checked. Sending it per call rather than
    /// baking it into the sidecar's environment means re-pairing takes effect
    /// immediately, with no restart, and the key is never written to disk
    /// outside its DPAPI-protected store.
    /// </summary>
    public static async Task<TranscribeOutcome> TranscribeAsync(
        string wavPath, string context, string screenContext, bool cleanup)
    {
        try
        {
            using var form = new MultipartFormDataContent();
            var fileBytes = await File.ReadAllBytesAsync(wavPath);
            var fileContent = new ByteArrayContent(fileBytes);
            fileContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
            form.Add(fileContent, "file", "audio.wav");
            form.Add(new StringContent(context, Encoding.UTF8), "context");
            form.Add(new StringContent(screenContext, Encoding.UTF8), "screen");

            var url = $"{BaseUrl}/transcribe?cleanup={(cleanup ? "true" : "false")}";
            using var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = form };
            var deviceKey = AccountManager.Shared.DeviceKey;
            if (!string.IsNullOrEmpty(deviceKey))
                request.Headers.TryAddWithoutValidation("X-SunoFlow-Device-Key", $"Bearer {deviceKey}");

            using var resp = await Http.SendAsync(request);

            // 402 means this device may not dictate: the trial ended, the
            // subscription lapsed, or the account disconnected this PC. This is
            // deliberately not a soft failure — nothing is pasted and the user
            // is told why.
            if ((int)resp.StatusCode == 402)
            {
                var body = await resp.Content.ReadAsStringAsync();
                string message = "Your SunoFlow subscription isn't active.";
                string code = "not_entitled";
                try
                {
                    var parsed = JsonSerializer.Deserialize<RefusalResponse>(body, JsonOpts);
                    if (!string.IsNullOrWhiteSpace(parsed?.Message)) message = parsed!.Message;
                    if (!string.IsNullOrWhiteSpace(parsed?.Error)) code = parsed!.Error;
                }
                catch { /* keep the default wording */ }
                AppLog.Log($"Dictation refused — {code}");
                return TranscribeOutcome.Refused(message, code);
            }

            if (!resp.IsSuccessStatusCode)
            {
                AppLog.Log($"Transcribe returned HTTP {resp.StatusCode}");
                return TranscribeOutcome.Failed();
            }
            var json = await resp.Content.ReadAsStringAsync();
            var result = JsonSerializer.Deserialize<TranscriptionResult>(json, JsonOpts);
            return result == null ? TranscribeOutcome.Failed() : TranscribeOutcome.Ok(result);
        }
        catch (Exception ex)
        {
            AppLog.Log($"Transcribe request failed: {ex.Message}");
            return TranscribeOutcome.Failed();
        }
    }

    // --- Learning -----------------------------------------------------------------

    /// <summary>Send a (pasted, edited) pair so the sidecar can learn corrections.</summary>
    public static async Task<int> LearnAsync(string original, string edited)
    {
        var fields = new Dictionary<string, string> { ["original"] = original, ["edited"] = edited };
        var data = await PostFormAsync("learn", fields);
        if (data == null) return 0;
        try
        {
            var resp = JsonSerializer.Deserialize<LearnResponse>(data, JsonOpts);
            return resp?.Learned.Length ?? 0;
        }
        catch { return 0; }
    }

    public static async Task<Correction[]> FetchCorrectionsAsync()
    {
        try
        {
            using var cts = new System.Threading.CancellationTokenSource(TimeSpan.FromSeconds(3));
            var resp = await Http.GetAsync($"{BaseUrl}/corrections", cts.Token);
            if (!resp.IsSuccessStatusCode) return Array.Empty<Correction>();
            var json = await resp.Content.ReadAsStringAsync();
            return JsonSerializer.Deserialize<CorrectionsResponse>(json, JsonOpts)?.Corrections
                   ?? Array.Empty<Correction>();
        }
        catch { return Array.Empty<Correction>(); }
    }

    public static async Task DeleteCorrectionAsync(string key)
        => await PostFormAsync("corrections/delete", new Dictionary<string, string> { ["key"] = key });

    public static async Task ClearCorrectionsAsync()
        => await PostFormAsync("corrections/clear", new Dictionary<string, string>());

    /// <summary>
    /// Manually add a correction. Sends <c>frm</c> on the wire (not
    /// <c>from</c>) — see the contract note. Returns the updated list.
    /// </summary>
    /// <param name="kind">Null sends no <c>kind</c> field, leaving the sidecar to
    /// infer it from the shape of the pair. That is the default: the classifier
    /// lives in one place rather than being second-guessed here, and the list
    /// refreshes straight after with the badge showing what it decided.</param>
    public static async Task<Correction[]> AddCorrectionAsync(string from, string to,
                                                              CorrectionKind? kind = null)
    {
        var fields = new Dictionary<string, string> { ["frm"] = from, ["to"] = to };
        if (kind.HasValue) fields["kind"] = CorrectionKinds.Wire(kind.Value);
        var data = await PostFormAsync("corrections/add", fields);
        return DecodeCorrections(data);
    }

    /// <summary>Edit an existing correction. Sends <c>frm</c> + <c>key</c>.</summary>
    /// <param name="kind">Always worth sending on an edit: fixing a typo in a URL
    /// should not silently reclassify the entry.</param>
    public static async Task<Correction[]> UpdateCorrectionAsync(string key, string from, string to,
                                                                 CorrectionKind? kind = null)
    {
        var fields = new Dictionary<string, string> { ["key"] = key, ["frm"] = from, ["to"] = to };
        if (kind.HasValue) fields["kind"] = CorrectionKinds.Wire(kind.Value);
        var data = await PostFormAsync("corrections/update", fields);
        return DecodeCorrections(data);
    }

    private static Correction[] DecodeCorrections(string? data)
    {
        if (data == null) return Array.Empty<Correction>();
        try
        {
            return JsonSerializer.Deserialize<CorrectionsResponse>(data, JsonOpts)?.Corrections
                   ?? Array.Empty<Correction>();
        }
        catch { return Array.Empty<Correction>(); }
    }

    // --- Cleanup gateway reachability --------------------------------------------

    /// <summary>Reachability of the hosted cleanup service (GET /ready, no auth).</summary>
    public static async Task<bool> CheckCleanupGatewayAsync()
    {
        try
        {
            using var cts = new System.Threading.CancellationTokenSource(TimeSpan.FromSeconds(4));
            var resp = await Http.GetAsync($"{GatewayUrl}/ready", cts.Token);
            if (!resp.IsSuccessStatusCode) return false;
            var json = await resp.Content.ReadAsStringAsync();
            return JsonSerializer.Deserialize<ReadyResponse>(json, JsonOpts)?.BackendOk ?? false;
        }
        catch { return false; }
    }

    // --- Model download -----------------------------------------------------------

    public static async Task<ModelStatus?> FetchModelStatusAsync()
    {
        try
        {
            using var cts = new System.Threading.CancellationTokenSource(TimeSpan.FromSeconds(4));
            var resp = await Http.GetAsync($"{BaseUrl}/model/status", cts.Token);
            if (!resp.IsSuccessStatusCode) return null;
            var json = await resp.Content.ReadAsStringAsync();
            return JsonSerializer.Deserialize<ModelStatus>(json, JsonOpts);
        }
        catch { return null; }
    }

    public static async Task<bool> StartModelDownloadAsync()
    {
        try
        {
            using var resp = await Http.PostAsync($"{BaseUrl}/model/download", new StringContent(""));
            if (!resp.IsSuccessStatusCode) return false;
            var json = await resp.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.TryGetProperty("started", out var s) && s.GetBoolean();
        }
        catch { return false; }
    }

    // --- Internal helper ---------------------------------------------------------

    private static async Task<string?> PostFormAsync(string path, Dictionary<string, string> fields)
    {
        try
        {
            using var cts = new System.Threading.CancellationTokenSource(TimeSpan.FromSeconds(5));
            var content = new FormUrlEncodedContent(fields);
            var resp = await Http.PostAsync($"{BaseUrl}/{path}", content, cts.Token);
            return await resp.Content.ReadAsStringAsync();
        }
        catch (Exception ex)
        {
            AppLog.Log($"POST /{path} failed: {ex.Message}");
            return null;
        }
    }
}