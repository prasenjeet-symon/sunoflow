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
///   (not <c>from</c>) — the Swift client sends <c>from</c> and silently 422s.</item>
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
    public const string GatewayUrl = "https://cleanup.mirrorli.art";

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

    public sealed class Correction
    {
        [JsonPropertyName("key")] public string Key { get; set; } = "";
        [JsonPropertyName("from")] public string From { get; set; } = "";
        [JsonPropertyName("to")] public string To { get; set; } = "";
        [JsonPropertyName("count")] public int Count { get; set; }
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
        [JsonPropertyName("error")] public string Error { get; set; } = "";
        [JsonPropertyName("model_dir")] public string ModelDir { get; set; } = "";
        [JsonPropertyName("model_id")] public string ModelId { get; set; } = "";
    }

    // --- Health -------------------------------------------------------------------

    /// <summary>Lightweight liveness probe (GET /health). Polled every 3s.</summary>
    public static async Task<bool> HealthAsync()
    {
        try
        {
            using var cts = new System.Threading.CancellationTokenSource(TimeSpan.FromSeconds(2));
            using var resp = await Http.GetAsync($"{BaseUrl}/health", cts.Token);
            return resp.IsSuccessStatusCode;
        }
        catch { return false; }
    }

    // --- Transcribe (multipart) ---------------------------------------------------

    /// <summary>
    /// POST /transcribe. Uploads the WAV as multipart/form-data with the
    /// optional <c>context</c> and <c>screen</c> fields, plus the <c>cleanup</c>
    /// query param. Returns null on any transport error (the caller beeps).
    /// </summary>
    public static async Task<TranscriptionResult?> TranscribeAsync(
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
            using var resp = await Http.PostAsync(url, form);
            if (!resp.IsSuccessStatusCode)
            {
                AppLog.Log($"Transcribe returned HTTP {resp.StatusCode}");
                return null;
            }
            var json = await resp.Content.ReadAsStringAsync();
            return JsonSerializer.Deserialize<TranscriptionResult>(json, JsonOpts);
        }
        catch (Exception ex)
        {
            AppLog.Log($"Transcribe request failed: {ex.Message}");
            return null;
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
    public static async Task<Correction[]> AddCorrectionAsync(string from, string to)
    {
        var fields = new Dictionary<string, string> { ["frm"] = from, ["to"] = to };
        var data = await PostFormAsync("corrections/add", fields);
        return DecodeCorrections(data);
    }

    /// <summary>Edit an existing correction. Sends <c>frm</c> + <c>key</c>.</summary>
    public static async Task<Correction[]> UpdateCorrectionAsync(string key, string from, string to)
    {
        var fields = new Dictionary<string, string> { ["key"] = key, ["frm"] = from, ["to"] = to };
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