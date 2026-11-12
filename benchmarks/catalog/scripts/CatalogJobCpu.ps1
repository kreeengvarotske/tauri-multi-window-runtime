# Whole-run CPU of scenario M from a Windows Job Object (#36 decisions
# 6691611439 and 6692721269; spike #44).
#
# The runner creates the app suspended, assigns it to a new job and only then
# resumes it, so the app and every process it starts are in the job from the
# first instruction. The job's basic accounting holds the user and kernel time
# of all its processes, running and exited, so a WebView2 child that lives a
# few milliseconds between two samples is still counted. The job:
#   - sets JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE and nothing else: no process may
#     break away (neither BREAKAWAY_OK nor SILENT_BREAKAWAY_OK), and closing the
#     runner's handle ends any process of this job and of no other;
#   - posts its messages to an I/O completion port read by a background thread:
#     JOB_OBJECT_MSG_NEW_PROCESS with the PID of every process added, and the
#     exit messages. Membership of a monitor-tree process is checked against
#     these messages (PID and time of creation), never against a PID list read
#     at some moment, so a process that lives between two reads is not missed.
#     The new-process messages must number exactly the job's total count;
#     otherwise membership is not verified and the run's job CPU is invalid.
#     The end of the run is confirmed by the job's counters (no active
#     process at the last row); exit and active-zero messages are kept as
#     diagnostics, because their delivery to the port is not guaranteed
#     (CompletionRule below; earlier results keep 'exit-messages').
#
# Dot-sourced by Run-CatalogTriplets.ps1 (native part, Windows only),
# Summarize-CatalogRuns.ps1 and the tests (pure functions, any platform).

$script:CatalogJob = [ordered]@{
    # Interval: from the assignment of the suspended app to the empty job (CPU 0
    # by construction) to the end of the idle-after phase (report endedAt).
    SampleIntervalMs      = 250
    # The job value used at a phase boundary is the last row at or before it;
    # that row must be at most this far before the boundary. CPU after the end
    # of the measured interval is never counted.
    MaxBoundaryGapSeconds = 0.5
    # No two consecutive job rows further apart, up to the first row after the
    # end of the interval.
    MaxRowIntervalSeconds = 1.0
    # Wall clock (row and phase timestamps) against the runner's monotonic
    # stopwatch over the run.
    MaxClockDriftSeconds  = 0.1
    # A NEW_PROCESS message for a monitor-tree process must arrive from this much
    # before to MembershipWindowSeconds after its creation time.
    MembershipSlackSeconds = 0.1
    MembershipWindowSeconds = 5.0
    # After the app exits, how long its other processes may take to exit before
    # the runner ends them by terminating its own job (the run is then invalid).
    ExitGraceSeconds      = 30
    # How the end of the run is confirmed (protocol §7). 'accounting': by the
    # job's own counters (no active process at the last row), with every
    # NEW_PROCESS message present; exit and active-zero messages are
    # diagnostics, because the completion port does not guarantee their
    # delivery (#54 6790225378). 'exit-messages': the earlier rule, which also
    # required one exit message per exited process and an active-zero message.
    # Results whose configuration has no CompletionRule keep 'exit-messages'.
    CompletionRule        = 'accounting'
}

$script:CatalogJobCompletionRules = @('accounting', 'exit-messages')

# Job message ids (winnt.h).
$script:CatalogJobMessage = @{ ActiveProcessZero = 4; NewProcess = 6; ExitProcess = 7; AbnormalExitProcess = 8 }

$script:CatalogJobNativeSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class TmwrCatalogJobMessage
{
    public int Message;
    public long ProcessId;
    public long UtcTicks;
}

public sealed class TmwrCatalogJobStart
{
    public int ProcessId;
    public IntPtr Process;
    public int Error;
    public bool TerminatedAfterFailure;
}

public sealed class TmwrCatalogJob : IDisposable
{
    public const uint KillOnJobClose = 0x00002000;
    public const uint BreakawayOk = 0x00000800;
    public const uint SilentBreakawayOk = 0x00001000;
    const uint CREATE_SUSPENDED = 0x00000004;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    const uint INFINITE = 0xFFFFFFFF;
    const uint JOB_OBJECT_QUERY = 0x0004;
    const int BasicAccounting = 1;
    const int BasicProcessIdList = 3;
    const int AssociateCompletionPort = 7;
    const int ExtendedLimit = 9;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

    [StructLayout(LayoutKind.Sequential)]
    struct BASIC_ACCOUNTING
    {
        public long TotalUserTime; public long TotalKernelTime;
        public long ThisPeriodTotalUserTime; public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount; public uint TotalProcesses; public uint ActiveProcesses; public uint TotalTerminatedProcesses;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BASIC_LIMIT
    {
        public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount; public ulong WriteOperationCount; public ulong OtherOperationCount;
        public ulong ReadTransferCount; public ulong WriteTransferCount; public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct EXTENDED_LIMIT
    {
        public BASIC_LIMIT BasicLimitInformation; public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ASSOCIATE_PORT { public IntPtr CompletionKey; public IntPtr CompletionPort; }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, int length);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, int length, out int returned);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateIoCompletionPort(IntPtr fileHandle, IntPtr existingPort, UIntPtr key, uint threads);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetQueuedCompletionStatus(IntPtr port, out uint bytes, out UIntPtr key, out IntPtr overlapped, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint flags, IntPtr environment, string currentDirectory, ref STARTUPINFO startupInfo, out PROCESS_INFORMATION info);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int GetProcessId(IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr source, IntPtr targetProcess, out IntPtr target, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    readonly object gate = new object();
    readonly List<TmwrCatalogJobMessage> messages = new List<TmwrCatalogJobMessage>();
    IntPtr port;
    Thread reader;

    public IntPtr Handle { get; private set; }
    public uint LimitFlags { get; private set; }

    static void Set<T>(IntPtr job, int infoClass, T value)
    {
        int size = Marshal.SizeOf(typeof(T));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(value, buffer, false);
            if (!SetInformationJobObject(job, infoClass, buffer, size)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    static T Query<T>(IntPtr job, int infoClass)
    {
        int size = Marshal.SizeOf(typeof(T));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            int returned;
            if (!QueryInformationJobObject(job, infoClass, buffer, size, out returned)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return (T)Marshal.PtrToStructure(buffer, typeof(T));
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    // A new job: kill on close, no breakaway, messages to a completion port.
    public static TmwrCatalogJob Create()
    {
        TmwrCatalogJob job = new TmwrCatalogJob();
        job.Handle = CreateJobObjectW(IntPtr.Zero, null);
        if (job.Handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            EXTENDED_LIMIT limit = new EXTENDED_LIMIT();
            limit.BasicLimitInformation.LimitFlags = KillOnJobClose;
            Set(job.Handle, ExtendedLimit, limit);
            job.LimitFlags = Query<EXTENDED_LIMIT>(job.Handle, ExtendedLimit).BasicLimitInformation.LimitFlags;
            if ((job.LimitFlags & (BreakawayOk | SilentBreakawayOk)) != 0 || (job.LimitFlags & KillOnJobClose) == 0)
                throw new InvalidOperationException("job limit flags are " + job.LimitFlags.ToString("X"));
            job.port = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, UIntPtr.Zero, 1);
            if (job.port == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            ASSOCIATE_PORT associate = new ASSOCIATE_PORT();
            associate.CompletionKey = new IntPtr(1);
            associate.CompletionPort = job.port;
            Set(job.Handle, AssociateCompletionPort, associate);
            job.reader = new Thread(job.Read);
            job.reader.IsBackground = true;
            job.reader.Start();
            return job;
        }
        catch
        {
            job.Dispose();
            throw;
        }
    }

    void Read()
    {
        while (true)
        {
            uint message; UIntPtr key; IntPtr overlapped;
            // Returns false once the port is closed (Dispose).
            if (!GetQueuedCompletionStatus(port, out message, out key, out overlapped, INFINITE)) return;
            TmwrCatalogJobMessage item = new TmwrCatalogJobMessage();
            item.Message = (int)message;
            item.ProcessId = overlapped.ToInt64();
            item.UtcTicks = DateTime.UtcNow.Ticks;
            lock (gate) { messages.Add(item); }
        }
    }

    public TmwrCatalogJobMessage[] Messages()
    {
        lock (gate) { return messages.ToArray(); }
    }

    // A handle to this job with query access only (tests: an assignment that fails).
    public IntPtr DuplicateQueryOnly()
    {
        IntPtr copy;
        if (!DuplicateHandle(GetCurrentProcess(), Handle, GetCurrentProcess(), out copy, JOB_OBJECT_QUERY, false, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return copy;
    }

    public TmwrCatalogJobStart Start(string commandLine, string currentDirectory, uint extraFlags)
    {
        return StartIn(Handle, commandLine, currentDirectory, extraFlags);
    }

    // Creates commandLine suspended, assigns it to job, then lets it run. If the
    // assignment fails the process is terminated before it ran any instruction
    // and Error holds the Win32 error; nothing is left running.
    public static TmwrCatalogJobStart StartIn(IntPtr job, string commandLine, string currentDirectory, uint extraFlags)
    {
        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | extraFlags, IntPtr.Zero, currentDirectory, ref si, out pi))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        TmwrCatalogJobStart result = new TmwrCatalogJobStart();
        result.ProcessId = pi.dwProcessId;
        if (!AssignProcessToJobObject(job, pi.hProcess))
        {
            result.Error = Marshal.GetLastWin32Error();
            TerminateProcess(pi.hProcess, 1);
            result.TerminatedAfterFailure = WaitForSingleObject(pi.hProcess, 10000) == 0;
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            return result;
        }
        if (ResumeThread(pi.hThread) == -1)
        {
            result.Error = Marshal.GetLastWin32Error();
            TerminateProcess(pi.hProcess, 1);
            result.TerminatedAfterFailure = WaitForSingleObject(pi.hProcess, 10000) == 0;
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            return result;
        }
        CloseHandle(pi.hThread);
        result.Process = pi.hProcess;
        return result;
    }

    // userTicks, kernelTicks, totalProcesses, activeProcesses, terminatedByLimit
    public long[] Accounting()
    {
        BASIC_ACCOUNTING a = Query<BASIC_ACCOUNTING>(Handle, BasicAccounting);
        return new long[] { a.TotalUserTime, a.TotalKernelTime, a.TotalProcesses, a.ActiveProcesses, a.TotalTerminatedProcesses };
    }

    // Diagnostic only: a list read at one moment.
    public int[] ProcessIds()
    {
        int capacity = 256;
        while (true)
        {
            int size = 8 + IntPtr.Size * capacity;
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                int returned;
                bool ok = QueryInformationJobObject(Handle, BasicProcessIdList, buffer, size, out returned);
                int error = Marshal.GetLastWin32Error();
                int assigned = Marshal.ReadInt32(buffer, 0);
                int listed = Marshal.ReadInt32(buffer, 4);
                if (!ok && error != 234) throw new Win32Exception(error);
                if (ok && listed == assigned)
                {
                    int[] ids = new int[listed];
                    for (int i = 0; i < listed; i++) ids[i] = (int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64();
                    return ids;
                }
                capacity = Math.Max(capacity * 2, assigned + 16);
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }

    // Ends every process of this job, and only of this job.
    public void TerminateAll(uint exitCode)
    {
        if (!TerminateJobObject(Handle, exitCode)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public bool Contains(IntPtr process)
    {
        bool result;
        if (!IsProcessInJob(process, Handle, out result)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return result;
    }

    // exited (1/0), creation as UTC DateTime ticks, kernel ticks, user ticks
    public static long[] ProcessTimes(IntPtr process)
    {
        uint wait = WaitForSingleObject(process, 0);
        long creation, exit, kernel, user;
        if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return new long[] { wait == 0 ? 1 : 0, DateTime.FromFileTimeUtc(creation).Ticks, kernel, user };
    }

    public static int ProcessIdOf(IntPtr process)
    {
        int id = GetProcessId(process);
        if (id == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        return id;
    }

    public static long ExitCode(IntPtr process)
    {
        uint code;
        if (!GetExitCodeProcess(process, out code)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return code;
    }

    public static bool WaitExit(IntPtr process, uint milliseconds) { return WaitForSingleObject(process, milliseconds) == 0; }

    public static void Close(IntPtr handle) { if (handle != IntPtr.Zero) CloseHandle(handle); }

    // Closing the job handle ends any process still in it (kill on close).
    public void Dispose()
    {
        if (Handle != IntPtr.Zero) { CloseHandle(Handle); Handle = IntPtr.Zero; }
        if (port != IntPtr.Zero) { CloseHandle(port); port = IntPtr.Zero; }
        if (reader != null) { reader.Join(2000); reader = null; }
    }
}
'@

function Initialize-CatalogJobNative {
    if ($null -eq ('TmwrCatalogJob' -as [type])) {
        Add-Type -TypeDefinition $script:CatalogJobNativeSource -Language CSharp
    }
}

function New-CatalogJob {
    Initialize-CatalogJobNative
    [TmwrCatalogJob]::Create()
}

function Start-CatalogJobProcess {
    # CommandLine goes to CreateProcess as is (quote the executable). Throws if
    # the process could not be assigned to the job; it is then already ended.
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )
    $result = $Job.Start($CommandLine, $WorkingDirectory, [uint32]0)
    if ($result.Error -ne 0) {
        throw ("Could not assign the app to its job (Win32 error {0}); the process (PID {1}) was {2}." -f $result.Error, $result.ProcessId, $(if ($result.TerminatedAfterFailure) { 'ended before it ran' } else { 'NOT confirmed ended' }))
    }
    $result
}

function Read-CatalogJobRow {
    param([Parameter(Mandatory = $true)][object]$Job, [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$Stopwatch)
    $a = $Job.Accounting()
    $elapsed = $Stopwatch.Elapsed.TotalSeconds
    $utc = [DateTime]::UtcNow
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    [pscustomobject][ordered]@{
        Utc                      = $utc.ToString('o', $culture)
        ElapsedSeconds           = $elapsed.ToString('F6', $culture)
        UserTicks                = $a[0]
        KernelTicks              = $a[1]
        CpuSeconds               = (([double]$a[0] + [double]$a[1]) / [TimeSpan]::TicksPerSecond).ToString('F7', $culture)
        TotalProcesses           = $a[2]
        ActiveProcesses          = $a[3]
        LimitTerminatedProcesses = $a[4]
    }
}

function ConvertTo-CatalogJobMessageRows {
    param([object[]]$Messages)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    @($Messages | ForEach-Object {
            [pscustomobject][ordered]@{ Utc = ([DateTime]::new([long]$_.UtcTicks, [DateTimeKind]::Utc)).ToString('o', $culture); UtcTicks = $_.UtcTicks; Message = $_.Message; ProcessId = $_.ProcessId }
        })
}

function ConvertTo-CatalogTimestamp {
    param([object]$Value)
    # PowerShell 7 can deserialize ISO JSON timestamps directly to DateTime.
    # Keep its UTC kind and precision rather than converting through a string.
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) {
        return [DateTimeOffset]$Value
    }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Wait-CatalogMonitorExit {
    param([AllowNull()]$Process)
    if ($null -eq $Process) { return $null }
    $Process.WaitForExit()
    return $Process.ExitCode
}

function Invoke-CatalogJobRun {
    <#
    One run in its own job: the command is created suspended in a new job
    (kill on close, no breakaway) with Environment set for it, resumed, and
    OnStarted is called with its PID (the runner starts the monitor there). The
    job is read every SampleIntervalMs into JobCsv until the app exits, then
    until every process of the job has exited (at most ExitGraceSeconds). On a
    timeout or leftovers the runner terminates this job, and only this job.
    The job's messages go to JobMessagesCsv. Closing the job at the end ends
    anything still in it. Returns the PID, exit code, timeout, leftovers,
    whether the job was terminated, the limit flags, the row count, an error
    (if the run could not be started or followed) and OnStarted's result.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [System.Collections.IDictionary]$Environment = @{},
        [Parameter(Mandatory = $true)][double]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$JobCsv,
        [Parameter(Mandatory = $true)][string]$JobMessagesCsv,
        [scriptblock]$OnStarted,
        # Tests only; the runner uses the protocol value.
        [double]$ExitGraceSeconds = $script:CatalogJob.ExitGraceSeconds
    )
    $result = [ordered]@{ Pid = $null; ExitCode = $null; TimedOut = $false; LeftoverProcesses = 0; Terminated = $false; LimitFlags = $null; Rows = 0; Error = $null; OnStartedResult = $null }
    $rows = New-Object System.Collections.Generic.List[object]
    $interval = [int]$script:CatalogJob.SampleIntervalMs
    $job = New-CatalogJob
    try {
        $result.LimitFlags = '0x{0:X}' -f $job.LimitFlags
        $previous = @{}
        foreach ($name in @($Environment.Keys)) { $previous[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name]) }
        try {
            # Suspended, assigned to the empty job, then resumed: the job's CPU starts at 0.
            $app = Start-CatalogJobProcess -Job $job -CommandLine $CommandLine -WorkingDirectory $WorkingDirectory
        }
        finally {
            foreach ($name in @($previous.Keys)) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        }
        $result.Pid = $app.ProcessId
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $rows.Add((Read-CatalogJobRow -Job $job -Stopwatch $stopwatch))
        if ($null -ne $OnStarted) { $result.OnStartedResult = & $OnStarted $app.ProcessId }
        while (-not [TmwrCatalogJob]::WaitExit($app.Process, [uint32]$interval)) {
            $rows.Add((Read-CatalogJobRow -Job $job -Stopwatch $stopwatch))
            if ($stopwatch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                $result.TimedOut = $true
                Write-Warning "$Label did not exit within $TimeoutSeconds s; terminating its job."
                break
            }
        }
        $rows.Add((Read-CatalogJobRow -Job $job -Stopwatch $stopwatch))
        if (-not $result.TimedOut) {
            # The app has exited; its other processes get ExitGraceSeconds to exit.
            $graceEnd = $stopwatch.Elapsed.TotalSeconds + $ExitGraceSeconds
            while ([int]$rows[$rows.Count - 1].ActiveProcesses -gt 0 -and $stopwatch.Elapsed.TotalSeconds -lt $graceEnd) {
                Start-Sleep -Milliseconds $interval
                $rows.Add((Read-CatalogJobRow -Job $job -Stopwatch $stopwatch))
            }
        }
        $result.LeftoverProcesses = [int]$rows[$rows.Count - 1].ActiveProcesses
        if ($result.TimedOut -or $result.LeftoverProcesses -gt 0) {
            if (-not $result.TimedOut) { Write-Warning "$Label left $($result.LeftoverProcesses) process(es) running $ExitGraceSeconds s after it exited; terminating its job." }
            # Only this run's job: no process is stopped by name or by PID.
            $job.TerminateAll([uint32]1)
            $result.Terminated = $true
            $terminateEnd = $stopwatch.Elapsed.TotalSeconds + 10
            do {
                Start-Sleep -Milliseconds $interval
                $rows.Add((Read-CatalogJobRow -Job $job -Stopwatch $stopwatch))
            } while ([int]$rows[$rows.Count - 1].ActiveProcesses -gt 0 -and $stopwatch.Elapsed.TotalSeconds -lt $terminateEnd)
        }
        [void][TmwrCatalogJob]::WaitExit($app.Process, [uint32]10000)
        $result.ExitCode = [TmwrCatalogJob]::ExitCode($app.Process)
        [TmwrCatalogJob]::Close($app.Process)
        # The last messages (exits, active-zero) arrive just after the last exit.
        Start-Sleep -Milliseconds 200
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-Warning "${Label}: $($result.Error)"
    }
    finally {
        $result.Rows = $rows.Count
        if ($rows.Count -gt 0) { $rows | Export-Csv -LiteralPath $JobCsv -NoTypeInformation -Encoding UTF8 }
        @(ConvertTo-CatalogJobMessageRows $job.Messages()) | Export-Csv -LiteralPath $JobMessagesCsv -NoTypeInformation -Encoding UTF8
        # Closing the handle ends anything still in this job (kill on close).
        $job.Dispose()
    }
    [pscustomobject]$result
}

# --- Pure functions: analysis of job.csv and job.messages.csv (any platform).

function Format-CatalogNumber {
    param([AllowNull()][object]$Value, [int]$Digits = 3)
    if ($null -eq $Value) { return 'n/a' }
    ([double]$Value).ToString("F$Digits", [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-CatalogJobRows {
    param([object[]]$Rows)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    @($Rows | ForEach-Object {
            [pscustomobject]@{
                Time        = [DateTimeOffset]::Parse([string]$_.Utc, $culture)
                Elapsed     = [double]::Parse([string]$_.ElapsedSeconds, $culture)
                User        = [long]$_.UserTicks
                Kernel      = [long]$_.KernelTicks
                Cpu         = ([double][long]$_.UserTicks + [double][long]$_.KernelTicks) / [TimeSpan]::TicksPerSecond
                Total       = [int]$_.TotalProcesses
                Active      = [int]$_.ActiveProcesses
                LimitKilled = [int]$_.LimitTerminatedProcesses
            }
        })
}

function Get-CatalogJobValueAt {
    # The last row at or before Time, if it is at most MaxGapSeconds before it.
    param([object[]]$Rows, [DateTimeOffset]$Time, [double]$MaxGapSeconds)
    $before = @($Rows | Where-Object { $_.Time -le $Time })
    if ($before.Count -eq 0) { return [pscustomobject]@{ Row = $null; GapSeconds = $null; Problem = "no job row at or before $($Time.ToString('o'))" } }
    $row = $before[$before.Count - 1]
    $gap = ($Time - $row.Time).TotalSeconds
    $problem = if ($gap -gt $MaxGapSeconds) { [string]::Format([Globalization.CultureInfo]::InvariantCulture, 'last job row {0:F3} s before {1} (> {2} s)', $gap, $Time.ToString('o'), $MaxGapSeconds) } else { $null }
    [pscustomobject]@{ Row = $row; GapSeconds = $gap; Problem = $problem }
}

function Get-CatalogJobMembership {
    # A process identity (PID@creation as UTC DateTime ticks) is a member of the
    # job if the job posted JOB_OBJECT_MSG_NEW_PROCESS for that PID between
    # MembershipSlackSeconds before and MembershipWindowSeconds after its
    # creation. A message for an earlier or later process with the same PID does
    # not match. No PID list read at one moment is used.
    param([object[]]$Messages, [string[]]$MonitorKeys = @(), [System.Collections.IDictionary]$Limits = $script:CatalogJob)
    $new = @($Messages | Where-Object { [int]$_.Message -eq $script:CatalogJobMessage.NewProcess })
    $slack = [long]($Limits.MembershipSlackSeconds * [TimeSpan]::TicksPerSecond)
    $window = [long]($Limits.MembershipWindowSeconds * [TimeSpan]::TicksPerSecond)
    $notInJob = New-Object System.Collections.Generic.List[string]
    $inJob = 0
    foreach ($key in $MonitorKeys) {
        $parts = ([string]$key).Split('@')
        $processId = 0L; $created = 0L
        if ($parts.Count -ne 2 -or -not [long]::TryParse($parts[0], [ref]$processId) -or -not [long]::TryParse($parts[1], [ref]$created)) { $notInJob.Add([string]$key); continue }
        $hit = @($new | Where-Object { [long]$_.ProcessId -eq $processId -and [long]$_.UtcTicks -ge $created - $slack -and [long]$_.UtcTicks -le $created + $window })
        if ($hit.Count -gt 0) { $inJob++ } else { $notInJob.Add([string]$key) }
    }
    [pscustomobject]@{ InJob = $inJob; NotInJob = @($notInJob) }
}

function Get-CatalogJobCpu {
    <#
    Whole-run CPU of one run from its job rows and messages, and the checks
    that make it valid. Phases: the report's phases object. MonitorKeys: the
    identities (PID@creation UTC ticks) of every process the monitor saw in the
    tree during the run. Returns RunCpuSeconds (job CPU at the end of the
    idle-after phase), StartupCpuSeconds and LoadCpuSeconds (diagnostic),
    membership and completeness counts, and Problems (empty = valid).
    CompletionRule (or $Limits.CompletionRule; 'exit-messages' when neither
    gives one) decides how the end of the run is confirmed; see
    $script:CatalogJob.CompletionRule and protocol §7.
    #>
    param(
        [object[]]$Rows,
        [object[]]$Messages,
        [Parameter(Mandatory = $true)][object]$Phases,
        [string[]]$MonitorKeys = @(),
        [System.Collections.IDictionary]$Limits = $script:CatalogJob,
        # Overrides $Limits.CompletionRule; the summarizer passes the rule the
        # runner recorded in configuration.json (jobLimits).
        [string]$CompletionRule
    )
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $problems = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $result = [ordered]@{
        RunCpuSeconds = $null; StartupCpuSeconds = $null; LoadCpuSeconds = $null; EndGapSeconds = $null
        JobProcesses = $null; JobActiveAtEnd = $null; MonitorProcesses = $MonitorKeys.Count; MonitorProcessesInJob = $null
        MonitorProcessesNotInJob = ''; JobProcessesNeverSeenByMonitor = $null; MaxRowIntervalSeconds = $null; MaxClockDriftSeconds = $null
        CompletionRule = $null; JobExitMessages = $null; JobExitMessagesMissing = $null
        Problems = $problems; Notes = $notes
    }
    $parsed = @(ConvertFrom-CatalogJobRows $Rows)
    if ($parsed.Count -eq 0) { $problems.Add('no job rows'); return [pscustomobject]$result }
    $idleBefore = ConvertTo-CatalogTimestamp $Phases.idleBeforeStartedAt
    $end = ConvertTo-CatalogTimestamp $Phases.endedAt

    # Counters never decrease; nothing was terminated by a job limit.
    for ($i = 1; $i -lt $parsed.Count; $i++) {
        $a = $parsed[$i - 1]; $b = $parsed[$i]
        if ($b.User -lt $a.User -or $b.Kernel -lt $a.Kernel -or $b.Total -lt $a.Total -or $b.Time -lt $a.Time -or $b.Elapsed -lt $a.Elapsed) {
            $problems.Add("job counters or timestamps decrease at row $i"); break
        }
    }
    if (@($parsed | Where-Object { $_.Active -gt $_.Total -or $_.Active -lt 0 }).Count -gt 0) { $problems.Add('job active count above total') }
    if (@($parsed | Where-Object { $_.LimitKilled -ne 0 }).Count -gt 0) { $problems.Add('a process was terminated by a job limit') }

    # Sampling covered the interval: started before the app's first phase, no long gap up to the end.
    if ($parsed[0].Time -gt $idleBefore) { $problems.Add('first job row after the idle-before phase started') }
    # Rows up to the end of the interval and the first row after it.
    $upToEnd = @($parsed | Where-Object { $_.Time -le $end })
    $afterEnd = @($parsed | Where-Object { $_.Time -gt $end })
    if ($afterEnd.Count -gt 0) { $upToEnd += $afterEnd[0] }
    $maxInterval = 0.0
    for ($i = 1; $i -lt $upToEnd.Count; $i++) { $maxInterval = [Math]::Max($maxInterval, ($upToEnd[$i].Time - $upToEnd[$i - 1].Time).TotalSeconds) }
    $result.MaxRowIntervalSeconds = $maxInterval
    if ($maxInterval -gt $Limits.MaxRowIntervalSeconds) { $problems.Add([string]::Format([Globalization.CultureInfo]::InvariantCulture, 'job rows {0:F3} s apart up to the end (> {1} s)', $maxInterval, $Limits.MaxRowIntervalSeconds)) }
    $drift = 0.0
    foreach ($row in $parsed) { $drift = [Math]::Max($drift, [Math]::Abs((($row.Time - $parsed[0].Time).TotalSeconds) - ($row.Elapsed - $parsed[0].Elapsed))) }
    $result.MaxClockDriftSeconds = $drift
    if ($drift -gt $Limits.MaxClockDriftSeconds) { $problems.Add([string]::Format([Globalization.CultureInfo]::InvariantCulture, 'wall clock drifted {0:F3} s from the stopwatch (> {1} s)', $drift, $Limits.MaxClockDriftSeconds)) }

    # The interval ends at endedAt: the last row at or before it; nothing after it counts.
    $atEnd = Get-CatalogJobValueAt -Rows $parsed -Time $end -MaxGapSeconds $Limits.MaxBoundaryGapSeconds
    if ($null -ne $atEnd.Problem) { $problems.Add("end of the interval: $($atEnd.Problem)") }
    elseif ($null -ne $atEnd.Row) { $result.RunCpuSeconds = $atEnd.Row.Cpu; $result.EndGapSeconds = $atEnd.GapSeconds }
    $atWarmup = Get-CatalogJobValueAt -Rows $parsed -Time (ConvertTo-CatalogTimestamp $Phases.warmupStartedAt) -MaxGapSeconds $Limits.MaxBoundaryGapSeconds
    if ($null -eq $atWarmup.Problem) { $result.StartupCpuSeconds = $atWarmup.Row.Cpu } else { $notes.Add("startup CPU: $($atWarmup.Problem)") }
    $atLoadStart = Get-CatalogJobValueAt -Rows $parsed -Time (ConvertTo-CatalogTimestamp $Phases.loadStartedAt) -MaxGapSeconds $Limits.MaxBoundaryGapSeconds
    $atLoadEnd = Get-CatalogJobValueAt -Rows $parsed -Time (ConvertTo-CatalogTimestamp $Phases.loadEndedAt) -MaxGapSeconds $Limits.MaxBoundaryGapSeconds
    if ($null -eq $atLoadStart.Problem -and $null -eq $atLoadEnd.Problem) { $result.LoadCpuSeconds = $atLoadEnd.Row.Cpu - $atLoadStart.Row.Cpu }
    else { $notes.Add("load CPU: $(@($atLoadStart.Problem, $atLoadEnd.Problem) | Where-Object { $_ })") }

    # Every process of the job has exited by the last row.
    $last = $parsed[$parsed.Count - 1]
    $result.JobProcesses = $last.Total
    $result.JobActiveAtEnd = $last.Active
    if ($last.Active -ne 0) { $problems.Add("$($last.Active) job process(es) still running at the last job row") }

    # Messages. Every process added to the job must have its NEW_PROCESS
    # message: membership is decided from these messages only, so a lost one
    # leaves membership unverified under either rule.
    $rule = if ($PSBoundParameters.ContainsKey('CompletionRule')) { $CompletionRule }
    elseif ($Limits.Contains('CompletionRule')) { [string]$Limits['CompletionRule'] }
    else { 'exit-messages' }
    if ($script:CatalogJobCompletionRules -notcontains $rule) { throw "Unknown job completion rule '$rule'." }
    $result.CompletionRule = $rule
    $messageList = @($Messages)
    $new = @($messageList | Where-Object { [int]$_.Message -eq $script:CatalogJobMessage.NewProcess })
    $exits = @($messageList | Where-Object { [int]$_.Message -eq $script:CatalogJobMessage.ExitProcess -or [int]$_.Message -eq $script:CatalogJobMessage.AbnormalExitProcess })
    $zero = @($messageList | Where-Object { [int]$_.Message -eq $script:CatalogJobMessage.ActiveProcessZero })
    $exited = $last.Total - $last.Active
    $result.JobExitMessages = $exits.Count
    if ($rule -eq 'exit-messages') {
        $complete = $new.Count -eq $last.Total -and $exits.Count -eq $exited -and ($last.Active -ne 0 -or $zero.Count -ge 1)
        if (-not $complete) { $problems.Add("job messages incomplete (new $($new.Count) of $($last.Total), exits $($exits.Count) of $exited, active-zero $($zero.Count)); membership not verified") }
    }
    else {
        if ($new.Count -ne $last.Total) { $problems.Add("job messages incomplete (new $($new.Count) of $($last.Total)); membership not verified") }
        if ($exits.Count -gt $exited) { $problems.Add("more exit messages ($($exits.Count)) than exited job processes ($exited)") }
        # Each message, in arrival order, must fit one process lifetime per PID:
        # an exit only after a NEW_PROCESS for that PID, and a second
        # NEW_PROCESS for a PID only after its exit. A PID reused without the
        # exit message in between is ambiguous and is refused.
        $open = @{}
        # Arrival order: the order the reader thread took them from the port,
        # which is the order of the messages file.
        # Limit notifications may also carry a PID. Only lifetime events
        # can open or close that PID's lifetime.
        $sequence = @($messageList | Where-Object {
            [int]$_.Message -eq $script:CatalogJobMessage.NewProcess -or
            [int]$_.Message -eq $script:CatalogJobMessage.ExitProcess -or
            [int]$_.Message -eq $script:CatalogJobMessage.AbnormalExitProcess
        })
        foreach ($message in $sequence) {
            $processId = [long]$message.ProcessId
            if ([int]$message.Message -eq $script:CatalogJobMessage.NewProcess) {
                if ($open.ContainsKey($processId)) { $problems.Add("PID $processId has a second new-process message without an exit message in between"); break }
                $open[$processId] = $true
            }
            else {
                if (-not $open.ContainsKey($processId)) { $problems.Add("exit message for PID $processId without a new-process message before it"); break }
                $open.Remove($processId)
            }
        }
        # Diagnostics only: the job's counters, not these messages, confirm that
        # every process has exited (ActiveProcesses = 0 at the last row, above).
        if ($last.Active -eq 0) {
            $missingExits = @($open.Keys | Sort-Object)
            if ($exits.Count -lt $exited) {
                $notes.Add("exit messages not delivered: $($exited - $exits.Count) of $exited (PID $($missingExits -join ', ')); completion from the job counters")
            }
            if ($zero.Count -eq 0) { $notes.Add('active-zero message not delivered; completion from the job counters') }
        }
    }
    $result.JobExitMessagesMissing = [Math]::Max(0, $exited - $exits.Count)

    # Membership: every monitor-tree identity has a NEW_PROCESS message for its PID close to its creation time.
    $membership = Get-CatalogJobMembership -Messages $messageList -MonitorKeys $MonitorKeys -Limits $Limits
    $matched = $membership.InJob
    $notInJob = $membership.NotInJob
    $result.MonitorProcessesInJob = $matched
    $result.MonitorProcessesNotInJob = $notInJob -join ';'
    $result.JobProcessesNeverSeenByMonitor = $last.Total - $matched
    if ($notInJob.Count -gt 0) { $problems.Add("monitor-tree process(es) without a job membership message: $($notInJob -join ', ')") }
    [pscustomobject]$result
}
