using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;

namespace SunoFlow;

/// <summary>
/// Owns the sidecar process lifecycle: locates the frozen sidecar exe and
/// (re)spawns it when the health probe fails. This is the Windows counterpart
/// of the macOS sidecar <c>LaunchAgent</c> (launchd <c>KeepAlive</c>) — on
/// Windows there is no launchd equivalent wired up, so the tray app itself
/// supervises the sidecar and keeps it alive.
/// <para>
/// Behaviour:
/// <list type="bullet">
/// <item><b>Dev mode</b> (no frozen exe at the install path): a no-op. The
///   user runs the sidecar manually, exactly as documented in the README.</item>
/// <item><b>Installed mode</b>: when <c>/health</c> fails, the supervisor
///   spawns <c>SunoFlowSidecar.exe</c> if it isn't already running. A 10-second
///   cooldown prevents a crashing sidecar from spinning a respawn loop.</item>
/// <item>The sidecar's stdout/stderr are teed into <c>sidecar.log</c> so a
///   frozen-bundle startup failure (e.g. a missing DLL) is diagnosable — the
///   exe has no console when launched by the tray app. The log keeps one
///   generation so it cannot grow without bound.</item>
/// <item>On tray-app quit the sidecar is intentionally <b>left running</b>.
///   It is an independent service; restarting the tray app should not force a
///   model reload. If the user wants it stopped, they reboot or kill it.</item>
/// </list>
/// </summary>
internal sealed class SidecarSupervisor : IDisposable
{
    // We only track a process we spawned ourselves. If the user launched the
    // sidecar manually (dev), we never touch it.
    private Process? _process;

    /// <summary>Completes once the current process's stdout and stderr have both
    /// hit EOF — that is, once it has exited and everything it said has reached
    /// the log. Its handle is only released after this.</summary>
    private Task _drained = Task.CompletedTask;

    private readonly string? _exePath;
    private readonly string _logPath;
    private DateTime _lastSpawn = DateTime.MinValue;

    // Minimum gap between spawn attempts so a sidecar that dies on startup
    // doesn't get relaunched in a tight loop.
    private static readonly TimeSpan RespawnCooldown = TimeSpan.FromSeconds(10);

    // One generation of roughly this size. The sidecar is chatty during a model
    // download, and an unbounded log under %LOCALAPPDATA% is a slow leak on a
    // machine nobody thinks to clean out.
    private const long MaxLogBytes = 1_000_000;

    private readonly object _logLock = new();

    public SidecarSupervisor()
    {
        var baseDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SunoFlow");
        _exePath = ResolveExePath(baseDir);
        _logPath = Path.Combine(baseDir, "sidecar.log");
    }

    /// <summary><see langword="true"/> when a frozen sidecar exe was found at
    /// the expected install path. When <see langword="false"/> the supervisor
    /// is a no-op (dev mode — the user runs the sidecar manually).</summary>
    public bool IsAvailable => _exePath != null;

    /// <summary>(Re)spawn the sidecar if we own a dead process or none yet.
    /// Called from the health-poll loop when <c>/health</c> fails. No-op in dev
    /// mode or within the respawn cooldown.</summary>
    public void EnsureRunning()
    {
        if (_exePath == null) return;
        if (_process != null && !_process.HasExited) return;
        if (DateTime.UtcNow - _lastSpawn < RespawnCooldown) return;
        Spawn();
    }

    private void Spawn()
    {
        // Stamped before the attempt, not after a successful start: a sidecar
        // that cannot be launched at all (missing DLL, blocked by policy) would
        // otherwise skip the cooldown entirely and be retried on every 3-second
        // health tick, forever.
        _lastSpawn = DateTime.UtcNow;

        var previous = _process;
        var previousDrained = _drained;
        _process = null;
        _drained = Task.CompletedTask;

        // Hand the old handle back once its output has finished draining.
        // Releasing it any earlier would cut off a crashed sidecar's last words,
        // which are exactly the ones worth having. Process.Dispose only closes
        // our handle on the child; it never terminates it.
        if (previous != null)
        {
            _ = previousDrained.ContinueWith(_ =>
            {
                try { previous.Dispose(); }
                catch (Exception ex)
                {
                    AppLog.Log($"Releasing the previous sidecar handle failed: {ex.Message}");
                }
            }, TaskScheduler.Default);
        }

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = _exePath!,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = Path.GetDirectoryName(_exePath!)!,
            };
            var process = Process.Start(psi);
            if (process == null)
            {
                AppLog.Log("Sidecar spawn returned no process");
                return;
            }

            _process = process;
            AppLog.Log($"Sidecar spawned (pid={process.Id}) from {_exePath}");
            // Tee the sidecar's output into its own log so a frozen-bundle startup
            // failure is diagnosable (the exe has no console when launched here).
            _drained = Task.WhenAll(
                PipeAsync(process.StandardOutput, "OUT"),
                PipeAsync(process.StandardError, "ERR"));
        }
        catch (Exception ex)
        {
            AppLog.Log($"Failed to spawn sidecar: {ex.Message}");
        }
    }

    private async Task PipeAsync(StreamReader reader, string tag)
    {
        try
        {
            string? line;
            while ((line = await reader.ReadLineAsync()) != null)
                AppendLog($"[{tag}] {line}{Environment.NewLine}");
        }
        catch { /* logging is best-effort */ }
    }

    private void AppendLog(string line)
    {
        lock (_logLock)
        {
            try
            {
                var info = new FileInfo(_logPath);
                if (info.Exists && info.Length > MaxLogBytes)
                {
                    // Keep exactly one previous generation, so the last crash is
                    // still readable after the current run has filled the file.
                    var rolled = _logPath + ".1";
                    File.Delete(rolled);
                    File.Move(_logPath, rolled);
                }
                File.AppendAllText(_logPath, line);
            }
            catch { /* logging is best-effort */ }
        }
    }

    private static string? ResolveExePath(string baseDir)
    {
        // Installed/frozen layout (see sidecars/windows/PACKAGING.md):
        //   %LOCALAPPDATA%\SunoFlow\sidecar\SunoFlowSidecar\SunoFlowSidecar.exe
        var frozen = Path.Combine(baseDir, "sidecar", "SunoFlowSidecar", "SunoFlowSidecar.exe");
        return File.Exists(frozen) ? frozen : null;
    }

    public void Dispose()
    {
        // The sidecar is intentionally left running — it is an independent
        // service, and killing it on tray-app quit would force a slow model
        // reload on the next launch. All that is given up here is our handle on
        // it, which would otherwise outlive the supervisor.
        var process = _process;
        _process = null;
        try { process?.Dispose(); }
        catch { /* shutting down */ }
    }
}
