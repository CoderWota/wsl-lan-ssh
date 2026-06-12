$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Initialize-Utf8Output {
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  try {
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
  } catch {
    Write-Verbose "Console UTF-8 initialization was skipped. $($_.Exception.Message)"
  }
  Set-Variable -Scope Script -Name OutputEncoding -Value $utf8
  if (-not (Get-Variable -Scope Script -Name PSDefaultParameterValues -ErrorAction SilentlyContinue)) {
    Set-Variable -Scope Script -Name PSDefaultParameterValues -Value @{}
  }
  $script:PSDefaultParameterValues["Out-File:Encoding"] = "utf8"
  $script:PSDefaultParameterValues["Set-Content:Encoding"] = "utf8"
  $script:PSDefaultParameterValues["Add-Content:Encoding"] = "utf8"
}

Initialize-Utf8Output

Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class WslSshRelay
{
    private const int PollDelayMs = 1000;
    private const int ListenBacklog = 32;
    private const int ProcessExitWaitMs = 5000;
    private readonly string _distroName;
    private readonly int _port;
    private readonly int _idleShutdownSeconds;
    private readonly string _preferredListenAddress;
    private readonly string _preferredListenInterfaceAlias;
    private readonly string _logPath;
    private readonly TcpListener _listener;
    private readonly object _logLock = new object();
    private readonly object _keeperLock = new object();
    private readonly SemaphoreSlim _backendLock = new SemaphoreSlim(1, 1);
    private volatile string _backendAddress;
    private Process _instanceKeeperProcess;
    private int _activeConnections;
    private long _lastActivityUtcTicks = DateTime.UtcNow.Ticks;
    private readonly string _wslExe = @"C:\Windows\System32\wsl.exe";

    public WslSshRelay(string distroName, int port, int idleShutdownSeconds, string preferredListenAddress, string preferredListenInterfaceAlias, string logPath)
    {
        _distroName = distroName;
        _port = port;
        _idleShutdownSeconds = idleShutdownSeconds;
        _preferredListenAddress = preferredListenAddress;
        _preferredListenInterfaceAlias = preferredListenInterfaceAlias;
        _logPath = logPath;
        _listener = new TcpListener(IPAddress.Any, _port);
    }

    public void Run()
    {
        EnsureLogDirectory();
        Log("WSL SSH relay starting on TCP port " + _port + ".");
        if (!string.IsNullOrWhiteSpace(_preferredListenAddress))
        {
            Log("Preferred LAN address: " + _preferredListenAddress + (string.IsNullOrWhiteSpace(_preferredListenInterfaceAlias) ? "" : " (" + _preferredListenInterfaceAlias + ")"));
        }

        _listener.Start(ListenBacklog);

        var idleThread = new Thread(IdleMonitorLoop)
        {
            IsBackground = true,
            Name = "WslSshRelayIdleMonitor"
        };
        idleThread.Start();

        while (true)
        {
            TcpClient client = null;
            try
            {
                client = _listener.AcceptTcpClient();
                client.NoDelay = true;
                var localClient = client;
                Task.Run(() => HandleClient(localClient));
            }
            catch (Exception ex)
            {
                if (client != null)
                {
                    try { client.Close(); } catch { }
                }

                Log("Listener error: " + ex.Message);
                Thread.Sleep(1000);
            }
        }
    }

    private void HandleClient(TcpClient client)
    {
        Interlocked.Increment(ref _activeConnections);
        UpdateLastActivityUtc();

        try
        {
            var backendAddress = EnsureBackendReady();
            using (var backend = new TcpClient())
            {
                backend.NoDelay = true;
                if (!TryConnect(backend, backendAddress, _port, 1500))
                {
                    throw new InvalidOperationException("Unable to connect to WSL backend at " + backendAddress + ":" + _port + ".");
                }

                using (var clientStream = client.GetStream())
                using (var backendStream = backend.GetStream())
                {
                    var clientToBackend = Task.Run(() => Pump(clientStream, backendStream));
                    var backendToClient = Task.Run(() => Pump(backendStream, clientStream));
                    Task.WaitAny(clientToBackend, backendToClient);
                }
            }
        }
        catch (Exception ex)
        {
            Log("Client handling failed: " + ex.Message);
        }
        finally
        {
            try { client.Close(); } catch { }
            Interlocked.Decrement(ref _activeConnections);
            UpdateLastActivityUtc();
        }
    }

    private string EnsureBackendReady()
    {
        var cachedAddress = _backendAddress;
        if (!string.IsNullOrWhiteSpace(cachedAddress) && TryConnectToBackend(cachedAddress, 1000))
        {
            EnsureInstanceKeeperRunning();
            return cachedAddress;
        }

        _backendLock.Wait();
        try
        {
            cachedAddress = _backendAddress;
            if (!string.IsNullOrWhiteSpace(cachedAddress) && TryConnectToBackend(cachedAddress, 1000))
            {
                EnsureInstanceKeeperRunning();
                return cachedAddress;
            }

            try
            {
                StartDistroAndSshService();

                for (var attempt = 1; attempt <= 60; attempt++)
                {
                    var address = GetBackendAddress();
                    if (!string.IsNullOrWhiteSpace(address) && TryConnectToBackend(address, 1000))
                    {
                        _backendAddress = address;
                        Log("WSL backend is ready at " + address + ":" + _port + ".");
                        return address;
                    }

                    Thread.Sleep(PollDelayMs);
                }

                throw new InvalidOperationException("WSL did not become ready in time.");
            }
            catch
            {
                _backendAddress = null;
                StopInstanceKeeper();
                throw;
            }
        }
        finally
        {
            _backendLock.Release();
        }
    }

    private void StartDistroAndSshService()
    {
        RunProcess("Starting WSL distro", _wslExe, "-d", _distroName, "--exec", "/bin/true");
        EnsureInstanceKeeperRunning();

        TryRunProcess("Enable ssh.service", _wslExe, "-d", _distroName, "-u", "root", "--exec", "/usr/bin/systemctl", "enable", "ssh.service");
        TryRunProcess("Disable ssh.socket", _wslExe, "-d", _distroName, "-u", "root", "--exec", "/usr/bin/systemctl", "disable", "ssh.socket");

        if (!TryRunProcess("Start ssh.service", _wslExe, "-d", _distroName, "-u", "root", "--exec", "/usr/bin/systemctl", "start", "ssh.service"))
        {
            if (!TryRunProcess("Start ssh via service", _wslExe, "-d", _distroName, "-u", "root", "--exec", "/usr/sbin/service", "ssh", "start"))
            {
                throw new InvalidOperationException("Unable to start ssh.service inside WSL.");
            }
        }
    }

    private void EnsureInstanceKeeperRunning()
    {
        lock (_keeperLock)
        {
            if (_instanceKeeperProcess != null)
            {
                if (!_instanceKeeperProcess.HasExited)
                {
                    return;
                }

                try
                {
                    Log("WSL instance keeper exited with code " + _instanceKeeperProcess.ExitCode + ".");
                }
                catch
                {
                }

                _instanceKeeperProcess.Dispose();
                _instanceKeeperProcess = null;
            }

            _instanceKeeperProcess = StartBackgroundProcess(
                "Start WSL instance keeper",
                _wslExe,
                "-d",
                _distroName,
                "-u",
                "root",
                "--exec",
                "/bin/sh",
                "-lc",
                "trap 'exit 0' TERM INT; while :; do /bin/sleep 3600; done");
            Log("WSL instance keeper started.");
        }
    }

    private void StopInstanceKeeper()
    {
        Process keeperToStop = null;
        lock (_keeperLock)
        {
            keeperToStop = _instanceKeeperProcess;
            _instanceKeeperProcess = null;
        }

        if (keeperToStop == null)
        {
            return;
        }

        try
        {
            if (!keeperToStop.HasExited)
            {
                try
                {
                    keeperToStop.Kill();
                }
                catch (InvalidOperationException)
                {
                }
                catch (System.ComponentModel.Win32Exception)
                {
                }

                TryWaitForExit(keeperToStop, ProcessExitWaitMs);
            }
        }
        finally
        {
            keeperToStop.Dispose();
        }
    }

    private string GetBackendAddress()
    {
        var output = RunProcess("Read WSL IPv4 address", _wslExe, "-d", _distroName, "--exec", "/bin/hostname", "-I");
        var tokens = output.Split(new[] { ' ', '\r', '\n', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        foreach (var token in tokens)
        {
            IPAddress address;
            if (IPAddress.TryParse(token, out address) && address.AddressFamily == AddressFamily.InterNetwork)
            {
                return token;
            }
        }

        return null;
    }

    private bool TryConnectToBackend(string address, int timeoutMs)
    {
        using (var probe = new TcpClient())
        {
            return TryConnect(probe, address, _port, timeoutMs);
        }
    }

    private static bool TryConnect(TcpClient client, string address, int port, int timeoutMs)
    {
        try
        {
            var connectTask = client.ConnectAsync(address, port);
            if (!connectTask.Wait(timeoutMs))
            {
                return false;
            }

            return client.Connected;
        }
        catch
        {
            return false;
        }
    }

    private static void Pump(NetworkStream source, NetworkStream destination)
    {
        var buffer = new byte[8192];
        int read;
        while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
        {
            destination.Write(buffer, 0, read);
            destination.Flush();
        }
    }

    private void IdleMonitorLoop()
    {
        while (true)
        {
            Thread.Sleep(5000);

            if (Interlocked.CompareExchange(ref _activeConnections, 0, 0) > 0)
            {
                continue;
            }

            var backendAddress = _backendAddress;
            if (string.IsNullOrWhiteSpace(backendAddress))
            {
                continue;
            }

            var idleSeconds = (DateTime.UtcNow - GetLastActivityUtc()).TotalSeconds;
            if (idleSeconds < _idleShutdownSeconds)
            {
                continue;
            }

            if (_backendLock.Wait(0))
            {
                try
                {
                    if (Interlocked.CompareExchange(ref _activeConnections, 0, 0) > 0)
                    {
                        continue;
                    }

                    if ((DateTime.UtcNow - GetLastActivityUtc()).TotalSeconds < _idleShutdownSeconds)
                    {
                        continue;
                    }

                    Log("Idle timeout reached. Terminating WSL distro " + _distroName + ".");
                    if (!TryRunProcess("Terminate WSL distro", _wslExe, "--terminate", _distroName))
                    {
                        Log("WSL terminate returned a non-zero exit code.");
                    }

                    StopInstanceKeeper();
                    _backendAddress = null;
                    UpdateLastActivityUtc();
                }
                finally
                {
                    _backendLock.Release();
                }
            }
        }
    }

    private bool TryRunProcess(string description, string fileName, params string[] args)
    {
        try
        {
            RunProcess(description, fileName, args);
            return true;
        }
        catch (Exception ex)
        {
            Log(description + " failed: " + ex.Message);
            return false;
        }
    }

    private Process StartBackgroundProcess(string description, string fileName, params string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = BuildArguments(args),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        var process = Process.Start(psi);
        if (process == null)
        {
            throw new InvalidOperationException(description + " failed to start.");
        }

        Task.Run(() => DrainReader(process.StandardOutput));
        Task.Run(() => DrainReader(process.StandardError));
        return process;
    }

    private string RunProcess(string description, string fileName, params string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = BuildArguments(args),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        using (var process = Process.Start(psi))
        {
            var stdout = process.StandardOutput.ReadToEnd();
            var stderr = process.StandardError.ReadToEnd();
            process.WaitForExit();

            if (process.ExitCode != 0)
            {
                var message = string.IsNullOrWhiteSpace(stderr) ? stdout : stderr;
                var combined = string.IsNullOrWhiteSpace(message) ? ("exit code " + process.ExitCode) : message.Trim();
                throw new InvalidOperationException(description + " failed with exit code " + process.ExitCode + ". " + combined);
            }

            return stdout;
        }
    }

    private static void DrainReader(StreamReader reader)
    {
        try
        {
            reader.ReadToEnd();
        }
        catch
        {
        }
        finally
        {
            reader.Dispose();
        }
    }

    private static void TryWaitForExit(Process process, int timeoutMs)
    {
        try
        {
            process.WaitForExit(timeoutMs);
        }
        catch
        {
        }
    }

    private static string BuildArguments(string[] args)
    {
        var builder = new StringBuilder();
        for (var index = 0; index < args.Length; index++)
        {
            if (index > 0)
            {
                builder.Append(' ');
            }

            builder.Append(QuoteArgument(args[index]));
        }

        return builder.ToString();
    }

    private static string QuoteArgument(string arg)
    {
        if (string.IsNullOrEmpty(arg))
        {
            return "\"\"";
        }

        var needsQuotes = false;
        for (var i = 0; i < arg.Length; i++)
        {
            var c = arg[i];
            if (char.IsWhiteSpace(c) || c == '\"')
            {
                needsQuotes = true;
                break;
            }
        }

        if (!needsQuotes)
        {
            return arg;
        }

        return "\"" + arg.Replace("\"", "\\\"") + "\"";
    }

    private void EnsureLogDirectory()
    {
        var directory = Path.GetDirectoryName(_logPath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
    }

    private void UpdateLastActivityUtc()
    {
        Interlocked.Exchange(ref _lastActivityUtcTicks, DateTime.UtcNow.Ticks);
    }

    private DateTime GetLastActivityUtc()
    {
        return new DateTime(Interlocked.Read(ref _lastActivityUtcTicks), DateTimeKind.Utc);
    }

    private void Log(string message)
    {
        var line = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss") + " " + message;
        lock (_logLock)
        {
            File.AppendAllText(_logPath, line + Environment.NewLine, new UTF8Encoding(false));
        }

        try
        {
            Console.WriteLine(message);
        }
        catch
        {
        }
    }
}

"@

$distroName = "Ubuntu"
$port = "2222"
$idleTimeout = "300"
$preferredAddress = "192.168.0.251"
$preferredAlias = "イーサネット"
$logPath = "c:\\Users\\Wota\\Documents\\WSL\\state\\WslSshRelay.runtime.log"

$relay = [WslSshRelay]::new($distroName, $port, $idleTimeout, $preferredAddress, $preferredAlias, $logPath)
$relay.Run()
