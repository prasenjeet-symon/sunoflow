using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;

namespace SunoFlow;

/// <summary>
/// Enforces single-instance behaviour and cross-process "open settings" pings,
/// mirroring the macOS <c>DistributedNotificationCenter</c> mechanism (a second
/// launch sends <c>com.sunoapp.sunoflow.openSettings</c> to the running copy).
///
/// On Windows we use a named <c>Mutex</c> for the single-instance lock and a
/// loopback TCP listener for the "show me" ping. The first instance becomes the
/// server; a second instance sends a byte and exits. This avoids named-pipe
/// complexity and matches the simple, robust nature of the macOS notification.
/// </summary>
internal static class SingleInstance
{
    private const int SignalPort = 51831; // arbitrary, stable across runs
    private static Mutex? _mutex;
    private static TcpListener? _listener;

    /// <summary>Try to acquire the single-instance lock. Returns false if
    /// another instance already holds it (i.e. we're the second launch).</summary>
    public static bool TryAcquire(string mutexName, out bool firstInstance)
    {
        _mutex = new Mutex(initiallyOwned: true, name: mutexName, out firstInstance);
        return !firstInstance; // true means "we're the second instance, exit"
    }

    /// <summary>Fired on the first instance when a second launch pings us.</summary>
    public static event EventHandler? OpenSettingsRequested;

    /// <summary>Start listening for pings from later launches (first instance only).</summary>
    public static void StartServer()
    {
        _listener = new TcpListener(IPAddress.Loopback, SignalPort);
        try { _listener.Start(); }
        catch (SocketException)
        {
            AppLog.Log("SingleInstance: signal port busy; second-launch pings will be ignored");
            return;
        }
        ThreadPool.QueueUserWorkItem(_ =>
        {
            while (true)
            {
                try
                {
                    using var client = _listener.AcceptTcpClient();
                    // Just reading the connection is enough — no payload needed.
                    OpenSettingsRequested?.Invoke(null, EventArgs.Empty);
                }
                catch { break; }
            }
        });
    }

    /// <summary>Ping the running instance to show its Settings window.</summary>
    public static void NotifyRunningInstance()
    {
        try
        {
            using var client = new TcpClient();
            client.Connect(IPAddress.Loopback, SignalPort);
        }
        catch { /* if the server isn't there, nothing to do */ }
    }
}