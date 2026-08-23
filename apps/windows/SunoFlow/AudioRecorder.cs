using System;
using System.IO;
using NAudio.Wave;

namespace SunoFlow;

/// <summary>
/// Captures microphone audio and writes it to a temp WAV file as 16 kHz mono
/// 16-bit PCM — the format the Parakeet STT engine expects. Mirrors the macOS
/// <c>AudioRecorder.swift</c> (which uses <c>AVAudioEngine</c>). Uses NAudio's
/// <c>WaveInEvent</c> (WinMM, event-driven) and requests the 16 kHz format
/// directly; the WinMM driver resamples to the nearest supported format if the
/// device can't do 16 kHz natively. (WASAPI shared mode would ignore the
/// requested format and need a resampler; WaveInEvent honors it.)
/// </summary>
internal sealed class AudioRecorder
{
    private WaveInEvent? _waveIn;
    private WaveFileWriter? _writer;
    private string? _currentFile;
    private readonly string _deviceId;
    // Signalled once the writer is finalized (header patched) on RecordingStopped.
    // StopRecording() waits on this so the WAV is complete before transcription reads it.
    private ManualResetEventSlim? _stopped;

    /// <summary>Current level (0–1) for the overlay waveform, updated from the
    /// capture thread. Read from the UI thread to animate the bubble.</summary>
    public float CurrentLevel { get; private set; }

    public bool IsRecording => _waveIn != null;

    /// <summary>The temp WAV path of the recording in progress, once started.</summary>
    public string? CurrentFile => _currentFile;

    /// <param name="deviceId">NAudio device index, or -1 for the system default.</param>
    public AudioRecorder(string deviceId = "")
    {
        _deviceId = deviceId;
    }

    /// <summary>Start recording. Returns the temp WAV path. Throws on failure.</summary>
    public string StartRecording()
    {
        var tempPath = Path.Combine(Path.GetTempPath(), $"sunoflow-{Guid.NewGuid():N}.wav");
        _currentFile = tempPath;
        _stopped?.Dispose();
        _stopped = new ManualResetEventSlim(false);

        // Capture at 16 kHz mono 16-bit directly — no resampling needed if the
        // mic supports it. NAudio picks the closest supported format otherwise.
        var format = new WaveFormat(16000, 16, 1);
        _waveIn = new WaveInEvent
        {
            DeviceNumber = ResolveDeviceIndex(_deviceId),
            WaveFormat = format,
            BufferMilliseconds = 100,
        };

        _writer = new WaveFileWriter(tempPath, format);
        _waveIn.DataAvailable += OnDataAvailable;
        _waveIn.RecordingStopped += OnRecordingStopped;
        _waveIn.StartRecording();
        AppLog.Log($"Recording started → {tempPath}");
        return tempPath;
    }

    /// <summary>Stop recording and block until the WAV header is finalized so
    /// the file is a valid, complete WAV before transcription reads it.
    /// (WaveFileWriter patches the RIFF/data chunk sizes only on Dispose, and
    /// RecordingStopped fires asynchronously on the capture thread.)</summary>
    public void StopRecording()
    {
        if (_waveIn == null) return;
        try
        {
            _waveIn.StopRecording();
            // Wait for OnRecordingStopped to finalize the writer. Cap the wait so
            // a wedged capture thread can't hang the UI forever.
            _stopped?.Wait(TimeSpan.FromSeconds(3));
        }
        catch (Exception ex)
        {
            AppLog.Log($"StopRecording error: {ex.Message}");
        }
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (_writer == null) return;
        try
        {
            _writer.Write(e.Buffer, 0, e.BytesRecorded);
            CurrentLevel = ComputeLevel(e.Buffer, e.BytesRecorded);
        }
        catch (Exception ex)
        {
            AppLog.Log($"Audio write error: {ex.Message}");
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        try { _writer?.Flush(); _writer?.Dispose(); }
        catch { /* best-effort */ }
        _writer = null;

        // Close the capture device. WaveInEvent owns an unmanaged WinMM handle and
        // a callback thread; dropping the reference without disposing leaks both,
        // and after enough dictations the driver runs out of handles and the next
        // StartRecording throws — with the mic-in-use indicator stuck on the whole
        // time. A new recorder is built per utterance, so this runs every time.
        var device = _waveIn;
        _waveIn = null;
        if (device != null)
        {
            device.DataAvailable -= OnDataAvailable;
            device.RecordingStopped -= OnRecordingStopped;
            try { device.Dispose(); }
            catch (Exception ex) { AppLog.Log($"Closing the capture device failed: {ex.Message}"); }
        }

        _stopped?.Set();
        if (e.Exception != null)
            AppLog.Log($"Recording stopped with error: {e.Exception.Message}");
    }

    /// <summary>Peak amplitude from the 16-bit PCM buffer, normalized to 0–1.</summary>
    private static float ComputeLevel(byte[] buffer, int bytes)
    {
        float peak = 0;
        for (int i = 0; i + 1 < bytes; i += 2)
        {
            short sample = (short)(buffer[i] | (buffer[i + 1] << 8));
            float abs = Math.Abs(sample) / 32768f;
            if (abs > peak) peak = abs;
        }
        return peak;
    }

    /// <summary>Resolve a preferences device id to an NAudio capture index.
    /// Empty string → -1 (system default). Returns -1 if not found.</summary>
    private static int ResolveDeviceIndex(string deviceId)
    {
        if (string.IsNullOrEmpty(deviceId)) return -1;
        for (int i = 0; i < WaveInEvent.DeviceCount; i++)
        {
            var caps = WaveInEvent.GetCapabilities(i);
            if (caps.ProductName == deviceId) return i;
        }
        AppLog.Log($"Mic device '{deviceId}' not found; using default");
        return -1;
    }

    /// <summary>List available capture device product names (for the settings dropdown).</summary>
    public static string[] ListDeviceNames()
    {
        var names = new string[WaveInEvent.DeviceCount];
        for (int i = 0; i < WaveInEvent.DeviceCount; i++)
            names[i] = WaveInEvent.GetCapabilities(i).ProductName;
        return names;
    }
}