Set-StrictMode -Version 2.0

# Spike (#36 decision 6691611439): CPU time of a whole process tree,
# including processes that exit before any sample can read them, from the
# kernel's accounting of a Windows Job Object. A process started suspended
# and assigned to a job before it runs keeps every descendant in that job
# (unless a descendant is allowed to break away, which this job does not
# allow). The job's basic accounting holds the user and kernel time of all
# its processes, active and terminated, so a process that lived a few
# milliseconds is still counted. No elevation, no tracing session, no
# events that can be lost: one query reads kernel counters.

$script:NativeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class TmwrJobCpu
{
    const uint CREATE_SUSPENDED = 0x00000004;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;

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

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, int length, out int returned);
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
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CreateJob()
    {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return job;
    }

    // Starts commandLine suspended, assigns it to the job, then lets it run,
    // so the process and everything it starts are in the job from the first
    // instruction. Returns the process handle (held by the caller) and PID.
    public static IntPtr StartInJob(IntPtr job, string commandLine, string currentDirectory, uint extraFlags, out int processId)
    {
        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | extraFlags, IntPtr.Zero, currentDirectory, ref si, out pi))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        if (!AssignProcessToJobObject(job, pi.hProcess))
        {
            int error = Marshal.GetLastWin32Error();
            TerminateProcess(pi.hProcess, 1);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            throw new System.ComponentModel.Win32Exception(error);
        }
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
        processId = pi.dwProcessId;
        return pi.hProcess;
    }

    // userTicks, kernelTicks, totalProcesses, activeProcesses, terminatedProcesses
    public static long[] Accounting(IntPtr job)
    {
        int size = Marshal.SizeOf(typeof(BASIC_ACCOUNTING));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            int returned;
            if (!QueryInformationJobObject(job, 1, buffer, size, out returned))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            BASIC_ACCOUNTING a = (BASIC_ACCOUNTING)Marshal.PtrToStructure(buffer, typeof(BASIC_ACCOUNTING));
            return new long[] { a.TotalUserTime, a.TotalKernelTime, a.TotalProcesses, a.ActiveProcesses, a.TotalTerminatedProcesses };
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static int[] ProcessIds(IntPtr job)
    {
        int capacity = 256;
        while (true)
        {
            int size = 8 + IntPtr.Size * capacity;
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                int returned;
                bool ok = QueryInformationJobObject(job, 3, buffer, size, out returned);
                int assigned = Marshal.ReadInt32(buffer, 0);
                int listed = Marshal.ReadInt32(buffer, 4);
                if (!ok && Marshal.GetLastWin32Error() != 234) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
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

    // Exit state (1 exited, 0 running) and user + kernel ticks of a held handle.
    public static long[] ProcessCpu(IntPtr process)
    {
        uint wait = WaitForSingleObject(process, 0);
        long creation, exit, kernel, user;
        if (!GetProcessTimes(process, out creation, out exit, out kernel, out user))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return new long[] { wait == 0 ? 1 : 0, kernel + user };
    }

    public static bool WaitExit(IntPtr process, uint milliseconds) { return WaitForSingleObject(process, milliseconds) == 0; }

    public static void Close(IntPtr handle) { if (handle != IntPtr.Zero) CloseHandle(handle); }
}
'@

function Initialize-JobCpuNative {
    if ($null -eq ('TmwrJobCpu' -as [type])) {
        Add-Type -TypeDefinition $script:NativeSource -Language CSharp
    }
}

function New-CpuJob {
    Initialize-JobCpuNative
    [TmwrJobCpu]::CreateJob()
}

function Start-ProcessInCpuJob {
    # CommandLine is passed to CreateProcess as is (quote the executable).
    # DetachedConsole starts a console program with no console, so no
    # conhost.exe is added to the job.
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Job,
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [string]$WorkingDirectory = (Get-Location).Path,
        [switch]$DetachedConsole
    )
    $flags = if ($DetachedConsole) { [uint32]0x00000008 } else { [uint32]0 }
    $processId = 0
    $handle = [TmwrJobCpu]::StartInJob($Job, $CommandLine, $WorkingDirectory, $flags, [ref]$processId)
    [pscustomobject]@{ Pid = $processId; Handle = $handle }
}

function Get-CpuJobAccounting {
    param([Parameter(Mandatory = $true)][IntPtr]$Job)
    $a = [TmwrJobCpu]::Accounting($Job)
    [pscustomobject]@{
        CpuSeconds          = ([double]$a[0] + [double]$a[1]) / [TimeSpan]::TicksPerSecond
        UserSeconds         = [double]$a[0] / [TimeSpan]::TicksPerSecond
        KernelSeconds       = [double]$a[1] / [TimeSpan]::TicksPerSecond
        TotalProcesses      = [int]$a[2]
        ActiveProcesses     = [int]$a[3]
        TerminatedProcesses = [int]$a[4]
    }
}

function Get-CpuJobProcessIds {
    param([Parameter(Mandatory = $true)][IntPtr]$Job)
    @([TmwrJobCpu]::ProcessIds($Job))
}

function Get-HeldProcessCpu {
    # The reference: CPU time through a handle held since the process was created.
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)
    $r = [TmwrJobCpu]::ProcessCpu($Handle)
    [pscustomobject]@{ Exited = ($r[0] -eq 1); CpuSeconds = [double]$r[1] / [TimeSpan]::TicksPerSecond }
}

function Wait-HeldProcess {
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [int]$TimeoutMilliseconds = 60000)
    [TmwrJobCpu]::WaitExit($Handle, [uint32]$TimeoutMilliseconds)
}

function Close-JobCpuHandle {
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)
    [TmwrJobCpu]::Close($Handle)
}

Export-ModuleMember -Function New-CpuJob, Start-ProcessInCpuJob, Get-CpuJobAccounting, Get-CpuJobProcessIds, Get-HeldProcessCpu, Wait-HeldProcess, Close-JobCpuHandle
