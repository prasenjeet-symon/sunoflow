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
///   exe has no console when launched by the tray app.</item>
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
    private readonly string? _exePath;
    private readonly string _logPath;
    private DateTime _lastSpawn = DateTime.MinValue;

    // Minimum gap between spawn attempts so a sidecar that dies on startup
    // doesn't get relaunched in a tight loop.
    private static readonly TimeSpan RespawnCooldown = TimeSpan.FromSeconds(10);

    private readonly object _logLock = new();

    public SidecarSupervisor()
    {
        var baseDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalAppData), "SunoFlow");
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
            _process = Process.Start(psi);
            _lastSpawn = DateTime.UtcNow;
            AppLog.Log($"Sidecar spawned (pid={_process?.Id}) from {_exePath}");
            // Tee the sidecar's output into its own log so a frozen-bundle startup
            // failure is diagnosable (the exe has no console when launched here).
            _ = PipeAsync(_process!.StandardOutput, "OUT");
            _ = PipeAsync(_process!.StandardError, "ERR");
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
            {
                lock (_logLock)
                {
                    File.AppendAllText(_logPath, $"[{tag}] {line}{Environment.NewLine}");
                }
            }
        }
        catch { /* logging is best-effort */ }
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
        // Intentionally left running — the sidecar is an independent service.
        // Killing it on tray-app quit would force a slow model reload on the
        // next launch. The health loop restarts it if it ever dies.
    }
}