using System;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace SunoFlow;

/// <summary>
/// Enforces single-instance behaviour and carries the cross-process "open
/// settings" ping, mirroring the macOS <c>DistributedNotificationCenter</c>
/// mechanism (a second launch sends <c>com.sunoapp.sunoflow.openSettings</c> to
/// the running copy).
///
/// A named <see cref="Mutex"/> holds the lock and a named pipe carries the ping.
/// Both are scoped to the current logon session and user, because a Windows
/// machine is genuinely multi-user: two people signed in at once must each get
/// their own tray app, and neither should be able to reach into the other's.
///
/// <para>
/// This replaces a loopback TCP listener on a fixed port. That had two problems
/// worth naming, because they are the reasons for every choice below: the port
/// is machine-wide, so whoever signed in second silently lost the ping (and any
/// unrelated program holding 51831 broke it outright); and <em>any</em> local
/// process could connect and pop the window. The pipe is per-user by name and,
/// via <see cref="PipeOptions.CurrentUserOnly"/>, by ACL as well — the client
/// checks the server's owner too, so neither end can be impersonated.
/// </para>
/// </summary>
internal static class SingleInstance
{
    /// <summary>What a real second launch writes after connecting. Not a security
    /// boundary — <see cref="PipeOptions.CurrentUserOnly"/> already is one — just
    /// enough that something merely probing the pipe cannot open a window.</summary>
    private static readonly byte[] Handshake = { 0x53, 0x55, 0x4E, 0x4F };   // "SUNO"

    private static Mutex? _mutex;
    private static bool _ownsMutex;
    private static CancellationTokenSource? _listening;

    /// <summary>Fired on the first instance when a later launch pings us. Raised
    /// on a thread-pool thread — handlers must marshal to the UI themselves.</summary>
    public static event EventHandler? OpenSettingsRequested;

    /// <summary>
    /// Takes the single-instance lock. Returns <see langword="true"/> when another
    /// copy already holds it, in which case the caller should ping that copy and
    /// exit.
    /// </summary>
    public static bool AnotherInstanceIsRunning(string mutexName)
    {
        // Local\ rather than Global\: the lock is per logon session, so two
        // signed-in users each get a tray app instead of one of them starting up
        // and immediately exiting because the other user already "has" it.
        _mutex = new Mutex(initiallyOwned: true, name: $@"Local\{mutexName}", out bool createdNew);
        _ownsMutex = createdNew;
        return !createdNew;
    }

    // --- Listening ----------------------------------------------------------------

    /// <summary>Start answering pings from later launches (first instance only).</summary>
    public static void StartServer()
    {
        _listening = new CancellationTokenSource();
        _ = ListenAsync(_listening.Token);
    }

    private static async Task ListenAsync(CancellationToken cancel)
    {
        while (!cancel.IsCancellationRequested)
        {
            try
            {
                // One connection at a time, recreated per ping: a second launch
                // connects, says its four bytes and exits, so there is nothing to
                // keep open between them.
                using var server = new NamedPipeServerStream(
                    PipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

                await server.WaitForConnectionAsync(cancel);

                // There is one server instance, so a client that connects and then
                // says nothing would hold the door shut against every later launch.
                // Give it a few seconds and move on.
                using var greetingWindow = CancellationTokenSource.CreateLinkedTokenSource(cancel);
                greetingWindow.CancelAfter(TimeSpan.FromSeconds(5));

                var greeting = new byte[Handshake.Length];
                await server.ReadExactlyAsync(greeting, greetingWindow.Token);
                if (greeting.AsSpan().SequenceEqual(Handshake))
                    OpenSettingsRequested?.Invoke(null, EventArgs.Empty);
            }
            catch (OperationCanceledException)
            {
                // Shutting down is the end of the loop; a client that timed out
                // mid-handshake is not.
                if (cancel.IsCancellationRequested) return;
            }
            catch (ObjectDisposedException) { return; }
            catch (EndOfStreamException)
            {
                // Connected and closed without saying anything. Go round again.
            }
            catch (IOException)
            {
                // The client vanished mid-handshake. Same treatment.
            }
            catch (Exception ex)
            {
                // An unusable pipe — the name is taken by something we cannot
                // displace, or the runtime refuses CurrentUserOnly — is not worth
                // a crash. The app simply stops answering second launches.
                AppLog.Log($"SingleInstance: stopped listening — {ex.Message}");
                return;
            }
        }
    }

    /// <summary>Ping the running instance to show its dashboard.</summary>
    public static void NotifyRunningInstance()
    {
        try
        {
            using var client = new NamedPipeClientStream(
                ".", PipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            // Short and bounded: the running instance either answers at once or is
            // still starting up and not listening yet. A second launch must never
            // sit there hanging on either outcome.
            client.Connect(2000);
            client.Write(Handshake, 0, Handshake.Length);
            client.Flush();
        }
        catch (Exception ex)
        {
            AppLog.Log($"SingleInstance: could not reach the running instance — {ex.Message}");
        }
    }

    /// <summary>Stop listening and give the lock back. Windows would do both at
    /// process exit; doing it here keeps a clean shutdown clean, and releases the
    /// pipe name promptly for a relaunch.</summary>
    public static void Stop()
    {
        try { _listening?.Cancel(); }
        catch (ObjectDisposedException) { /* already stopped */ }
        _listening?.Dispose();
        _listening = null;

        if (_mutex == null) return;
        try { if (_ownsMutex) _mutex.ReleaseMutex(); }
        catch (ApplicationException) { /* we were never the owner */ }
        _mutex.Dispose();
        _mutex = null;
        _ownsMutex = false;
    }

    // --- Naming --------------------------------------------------------------------

    /// <summary>Pipe names are machine-global, so both the session and the user go
    /// into this one. Scoped to match the Local\ mutex above, so the same person
    /// signed in twice (fast user switching) gets two independent tray apps and
    /// each one's second launch reaches its own.</summary>
    private static readonly string PipeName =
        $"SunoFlow.OpenSettings.{SessionId()}.{UserFingerprint()}";

    private static int SessionId()
    {
        try
        {
            using var self = System.Diagnostics.Process.GetCurrentProcess();
            return self.SessionId;
        }
        catch { return 0; }
    }

    /// <summary>A short, stable stand-in for the account name. Hashed rather than
    /// used directly because a pipe name may not contain a backslash, and a domain
    /// account name always does.</summary>
    private static string UserFingerprint()
    {
        try
        {
            var who = $@"{Environment.UserDomainName}\{Environment.UserName}";
            var digest = SHA256.HashData(Encoding.UTF8.GetBytes(who));
            return Convert.ToHexString(digest, 0, 8);
        }
        catch { return "default"; }
    }
}
