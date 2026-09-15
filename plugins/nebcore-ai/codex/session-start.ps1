$ErrorActionPreference = 'Stop'

$script:NebcoreMinimumVersion = [version]'6.13.0'
$script:NebcoreStreamLimit = 16384
$script:NebcoreChildMilliseconds = 5000
$script:NebcoreBudgetMilliseconds = 12000
$script:NebcoreCleanupMilliseconds = 2000
$script:NebcoreMissing = 'NebCore AI tools are unavailable because nebcli is not installed. Install nebcli, run nebcli login, then start a new Codex session.'
$script:NebcoreVersionFailure = 'NebCore AI tools are unavailable because the installed nebcli version could not be verified. Upgrade nebcli to 6.13.0 or newer, run nebcli login, then start a new Codex session.'
$script:NebcoreLoginMissing = 'NebCore AI tools are unavailable because nebcli is not logged in. Run nebcli login, then start a new Codex session.'
$script:NebcoreBridgeFailure = 'NebCore AI tools are unavailable because the nebcli prerequisite check did not complete safely. Verify nebcli 6.13.0 or newer, run nebcli login, then start a new Codex session.'

$script:NebcoreSupervisorSource = @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public static class NebcoreHookSupervisor
{
    private const uint CreateSuspended = 0x00000004;
    private const uint CreateNoWindow = 0x08000000;
    private const uint ExtendedStartupInfoPresent = 0x00080000;
    private const uint StartfUseStdHandles = 0x00000100;
    private const uint HandleFlagInherit = 0x00000001;
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const uint WaitObject0 = 0x00000000;
    private const uint WaitTimeout = 0x00000102;
    private const int JobObjectExtendedLimitInformation = 9;
    private static readonly IntPtr ProcThreadAttributeHandleList = new IntPtr(0x00020002);

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Length;
        public IntPtr SecurityDescriptor;
        public int InheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int Size;
        public string Reserved;
        public string Desktop;
        public string Title;
        public uint X;
        public uint Y;
        public uint XSize;
        public uint YSize;
        public uint XCountChars;
        public uint YCountChars;
        public uint FillAttribute;
        public uint Flags;
        public short ShowWindow;
        public short ReservedBytes;
        public IntPtr ReservedPointer;
        public IntPtr StandardInput;
        public IntPtr StandardOutput;
        public IntPtr StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public IntPtr AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr Process;
        public IntPtr Thread;
        public uint ProcessId;
        public uint ThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    public sealed class Result
    {
        public string Outcome;
        public int ExitCode;
        public byte[] Stdout;
        public byte[] Stderr;
        public bool ReadersCompleted;
    }

    private sealed class Capture
    {
        public byte[] Bytes;
        public bool Overflow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out IntPtr readPipe, out IntPtr writePipe,
        ref SecurityAttributes attributes, uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateEvent(IntPtr attributes, bool manualReset,
        bool initialState, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetEvent(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr attributeList,
        int attributeCount, int flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr attributeList,
        uint flags, IntPtr attribute, IntPtr value, IntPtr size,
        IntPtr previousValue, IntPtr returnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass,
        IntPtr info, uint infoLength);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref StartupInfoEx startupInfo,
        out ProcessInformation processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForMultipleObjects(uint count, IntPtr[] handles,
        bool waitAll, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static void Require(bool value, string operation)
    {
        if (!value)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }
    }

    private static void Inject(string requested, string completed)
    {
        if (String.Equals(requested, completed, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("injected failure after " + completed);
        }
    }

    private static void Close(ref IntPtr handle)
    {
        if (handle != IntPtr.Zero)
        {
            CloseHandle(handle);
            handle = IntPtr.Zero;
        }
    }

    private static uint RemainingMilliseconds(long deadlineTimestamp)
    {
        long remainingTicks = deadlineTimestamp - Stopwatch.GetTimestamp();
        if (remainingTicks <= 0)
        {
            return 0;
        }
        long milliseconds = checked(
            (remainingTicks * 1000L + Stopwatch.Frequency - 1L) /
            Stopwatch.Frequency);
        return checked((uint)Math.Min(milliseconds, UInt32.MaxValue));
    }

    private static int RemainingTaskMilliseconds(long deadlineTimestamp)
    {
        return checked((int)Math.Min(
            RemainingMilliseconds(deadlineTimestamp),
            Int32.MaxValue));
    }

    private static long DeadlineAfter(long startedTimestamp, int milliseconds)
    {
        long duration = checked(
            ((long)milliseconds * Stopwatch.Frequency + 999L) / 1000L);
        return checked(startedTimestamp + duration);
    }

    public static long DeadlineAfterMilliseconds(int milliseconds)
    {
        return DeadlineAfter(Stopwatch.GetTimestamp(), milliseconds);
    }

    private static void RequireTime(long deadlineTimestamp, string operation)
    {
        if (RemainingMilliseconds(deadlineTimestamp) == 0)
        {
            throw new TimeoutException(operation + " exceeded the hook budget");
        }
    }

    private static bool WaitReaders(
        Task<Capture> stdoutTask,
        Task<Capture> stderrTask,
        long deadlineTimestamp)
    {
        Task[] tasks;
        if (stdoutTask == null && stderrTask == null)
        {
            return true;
        }
        if (stdoutTask == null)
        {
            tasks = new Task[] { stderrTask };
        }
        else if (stderrTask == null)
        {
            tasks = new Task[] { stdoutTask };
        }
        else
        {
            tasks = new Task[] { stdoutTask, stderrTask };
        }
        return Task.WaitAll(tasks, RemainingTaskMilliseconds(deadlineTimestamp));
    }

    private static Capture ReadPipe(IntPtr rawHandle, int byteLimit, IntPtr overflowEvent)
    {
        using (var safeHandle = new SafeFileHandle(rawHandle, true))
        using (var stream = new FileStream(safeHandle, FileAccess.Read, 4096, false))
        using (var retained = new MemoryStream(byteLimit))
        {
            var chunk = new byte[4096];
            while (true)
            {
                int count = stream.Read(chunk, 0, chunk.Length);
                if (count == 0)
                {
                    return new Capture { Bytes = retained.ToArray(), Overflow = false };
                }
                int room = byteLimit - checked((int)retained.Length);
                int keep = Math.Min(room, count);
                if (keep > 0)
                {
                    retained.Write(chunk, 0, keep);
                }
                if (count > keep)
                {
                    Require(SetEvent(overflowEvent), "SetEvent overflow");
                    return new Capture { Bytes = retained.ToArray(), Overflow = true };
                }
            }
        }
    }

    private static string Quote(string value)
    {
        if (value.IndexOf('"') >= 0)
        {
            throw new ArgumentException("child arguments cannot contain a quote");
        }
        return "\"" + value + "\"";
    }

    public static Result Run(string application, string[] arguments,
        int childMilliseconds, int byteLimit, long workDeadlineTimestamp,
        long absoluteDeadlineTimestamp, string failureStep,
        string deadlineEventName)
    {
        IntPtr stdoutRead = IntPtr.Zero;
        IntPtr stdoutWrite = IntPtr.Zero;
        IntPtr stderrRead = IntPtr.Zero;
        IntPtr stderrWrite = IntPtr.Zero;
        IntPtr stdinRead = IntPtr.Zero;
        IntPtr stdinWrite = IntPtr.Zero;
        IntPtr job = IntPtr.Zero;
        IntPtr overflowEvent = IntPtr.Zero;
        IntPtr deadlineEvent = IntPtr.Zero;
        IntPtr attributeList = IntPtr.Zero;
        IntPtr inheritedHandles = IntPtr.Zero;
        ProcessInformation process = new ProcessInformation();
        bool processCreated = false;
        bool assigned = false;
        Task<Capture> stdoutTask = null;
        Task<Capture> stderrTask = null;

        try
        {
            RequireTime(workDeadlineTimestamp, "supervisor setup");
            var security = new SecurityAttributes {
                Length = Marshal.SizeOf(typeof(SecurityAttributes)),
                InheritHandle = 1
            };
            Require(CreatePipe(out stdoutRead, out stdoutWrite, ref security, 0), "CreatePipe stdout");
            Require(SetHandleInformation(stdoutRead, HandleFlagInherit, 0), "SetHandleInformation stdout");
            Inject(failureStep, "stdout-pipe");
            Require(CreatePipe(out stderrRead, out stderrWrite, ref security, 0), "CreatePipe stderr");
            Require(SetHandleInformation(stderrRead, HandleFlagInherit, 0), "SetHandleInformation stderr");
            Inject(failureStep, "stderr-pipe");
            Require(CreatePipe(out stdinRead, out stdinWrite, ref security, 0), "CreatePipe stdin");
            Require(SetHandleInformation(stdinWrite, HandleFlagInherit, 0), "SetHandleInformation stdin");
            Inject(failureStep, "stdin-pipe");

            job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject");
            }
            Inject(failureStep, "job-create");
            var limits = new JobObjectExtendedLimitInformation();
            limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            int limitsSize = Marshal.SizeOf(typeof(JobObjectExtendedLimitInformation));
            IntPtr limitsPointer = Marshal.AllocHGlobal(limitsSize);
            try
            {
                Marshal.StructureToPtr(limits, limitsPointer, false);
                Require(SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                    limitsPointer, checked((uint)limitsSize)), "SetInformationJobObject");
            }
            finally
            {
                Marshal.FreeHGlobal(limitsPointer);
            }
            Inject(failureStep, "job-configure");

            overflowEvent = CreateEvent(IntPtr.Zero, true, false, null);
            if (overflowEvent == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateEvent overflow");
            }
            Inject(failureStep, "overflow-event");
            if (!String.IsNullOrEmpty(deadlineEventName))
            {
                deadlineEvent = CreateEvent(IntPtr.Zero, true, false, deadlineEventName);
                if (deadlineEvent == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateEvent deadline");
                }
            }

            IntPtr attributeListSize = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeListSize);
            if (attributeListSize == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "InitializeProcThreadAttributeList size");
            }
            Inject(failureStep, "attribute-size");
            attributeList = Marshal.AllocHGlobal(attributeListSize);
            Require(InitializeProcThreadAttributeList(attributeList, 1, 0,
                ref attributeListSize), "InitializeProcThreadAttributeList");
            Inject(failureStep, "attribute-init");
            inheritedHandles = Marshal.AllocHGlobal(IntPtr.Size * 3);
            Marshal.WriteIntPtr(inheritedHandles, 0, stdinRead);
            Marshal.WriteIntPtr(inheritedHandles, IntPtr.Size, stdoutWrite);
            Marshal.WriteIntPtr(inheritedHandles, IntPtr.Size * 2, stderrWrite);
            Inject(failureStep, "handle-list");
            Require(UpdateProcThreadAttribute(attributeList, 0,
                ProcThreadAttributeHandleList, inheritedHandles,
                new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero),
                "UpdateProcThreadAttribute handle list");
            Inject(failureStep, "attribute-update");

            var startup = new StartupInfoEx {
                StartupInfo = new StartupInfo {
                    Size = Marshal.SizeOf(typeof(StartupInfoEx)),
                    Flags = StartfUseStdHandles,
                    StandardInput = stdinRead,
                    StandardOutput = stdoutWrite,
                    StandardError = stderrWrite
                },
                AttributeList = attributeList
            };
            var commandLine = new StringBuilder(Quote(application));
            foreach (string argument in arguments)
            {
                commandLine.Append(' ').Append(Quote(argument));
            }
            RequireTime(workDeadlineTimestamp, "CreateProcessW");
            Require(CreateProcess(application, commandLine, IntPtr.Zero, IntPtr.Zero,
                true, CreateSuspended | CreateNoWindow | ExtendedStartupInfoPresent,
                IntPtr.Zero, Environment.CurrentDirectory, ref startup, out process),
                "CreateProcessW");
            processCreated = true;
            Inject(failureStep, "process-create");

            DeleteProcThreadAttributeList(attributeList);
            Marshal.FreeHGlobal(attributeList);
            attributeList = IntPtr.Zero;
            Marshal.FreeHGlobal(inheritedHandles);
            inheritedHandles = IntPtr.Zero;

            Require(AssignProcessToJobObject(job, process.Process), "AssignProcessToJobObject");
            assigned = true;
            Inject(failureStep, "job-assign");

            Close(ref stdoutWrite);
            Close(ref stderrWrite);
            Close(ref stdinRead);
            Close(ref stdinWrite);

            IntPtr ownedStdoutRead = stdoutRead;
            stdoutTask = Task.Factory.StartNew(
                () => ReadPipe(ownedStdoutRead, byteLimit, overflowEvent),
                TaskCreationOptions.LongRunning);
            stdoutRead = IntPtr.Zero;
            IntPtr ownedStderrRead = stderrRead;
            stderrTask = Task.Factory.StartNew(
                () => ReadPipe(ownedStderrRead, byteLimit, overflowEvent),
                TaskCreationOptions.LongRunning);
            stderrRead = IntPtr.Zero;
            Inject(failureStep, "readers-start");

            RequireTime(workDeadlineTimestamp, "ResumeThread");
            long childDeadlineTimestamp = Math.Min(
                workDeadlineTimestamp,
                DeadlineAfter(Stopwatch.GetTimestamp(), childMilliseconds));
            if (ResumeThread(process.Thread) == UInt32.MaxValue)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "ResumeThread");
            }
            Close(ref process.Thread);
            Inject(failureStep, "thread-resume");

            IntPtr[] waits = deadlineEvent == IntPtr.Zero
                ? new IntPtr[] { process.Process, overflowEvent }
                : new IntPtr[] { process.Process, overflowEvent, deadlineEvent };
            uint wait = WaitForMultipleObjects(checked((uint)waits.Length), waits, false,
                RemainingMilliseconds(childDeadlineTimestamp));
            string outcome;
            if (wait == WaitObject0)
            {
                outcome = "exit";
                Require(TerminateJobObject(job, 125), "TerminateJobObject cleanup");
            }
            else if (wait == WaitObject0 + 1)
            {
                outcome = "overflow";
                Require(TerminateJobObject(job, 123), "TerminateJobObject overflow");
            }
            else if (deadlineEvent != IntPtr.Zero && wait == WaitObject0 + 2)
            {
                outcome = "timeout";
                Require(TerminateJobObject(job, 124), "TerminateJobObject injected deadline");
            }
            else if (wait == WaitTimeout)
            {
                outcome = childDeadlineTimestamp == workDeadlineTimestamp
                    ? "budget"
                    : "timeout";
                Require(TerminateJobObject(job, 124), "TerminateJobObject timeout");
            }
            else
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForMultipleObjects");
            }

            Require(WaitForSingleObject(
                process.Process,
                RemainingMilliseconds(absoluteDeadlineTimestamp)) == WaitObject0,
                "WaitForSingleObject reap");
            Require(WaitReaders(stdoutTask, stderrTask, absoluteDeadlineTimestamp),
                "pipe reader reap");
            Capture stdout = stdoutTask.Result;
            Capture stderr = stderrTask.Result;
            if (stdout.Overflow || stderr.Overflow)
            {
                outcome = "overflow";
            }
            uint exitCode;
            Require(GetExitCodeProcess(process.Process, out exitCode), "GetExitCodeProcess");
            return new Result {
                Outcome = outcome,
                ExitCode = checked((int)exitCode),
                Stdout = stdout.Bytes,
                Stderr = stderr.Bytes,
                ReadersCompleted = true
            };
        }
        catch
        {
            if (assigned && job != IntPtr.Zero)
            {
                TerminateJobObject(job, 126);
            }
            else if (processCreated && process.Process != IntPtr.Zero)
            {
                TerminateProcess(process.Process, 126);
            }
            if (processCreated && process.Process != IntPtr.Zero)
            {
                WaitForSingleObject(
                    process.Process,
                    RemainingMilliseconds(absoluteDeadlineTimestamp));
            }
            throw;
        }
        finally
        {
            Close(ref process.Thread);
            Close(ref stdoutWrite);
            Close(ref stderrWrite);
            Close(ref stdinRead);
            Close(ref stdinWrite);
            if (stdoutTask != null || stderrTask != null)
            {
                WaitReaders(stdoutTask, stderrTask, absoluteDeadlineTimestamp);
            }
            Close(ref process.Process);
            Close(ref stdoutRead);
            Close(ref stderrRead);
            if (attributeList != IntPtr.Zero)
            {
                DeleteProcThreadAttributeList(attributeList);
                Marshal.FreeHGlobal(attributeList);
            }
            if (inheritedHandles != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(inheritedHandles);
            }
            Close(ref deadlineEvent);
            Close(ref overflowEvent);
            Close(ref job);
        }
    }
}
'@

function Initialize-NebcoreSupervisor {
    if ($null -eq ('NebcoreHookSupervisor' -as [type])) {
        Add-Type -TypeDefinition $script:NebcoreSupervisorSource -Language CSharp
    }
}

function Invoke-NebcoreChild {
    param(
        [Parameter(Mandatory = $true)][string]$Application,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][long]$WorkDeadline,
        [Parameter(Mandatory = $true)][long]$AbsoluteDeadline,
        [string]$FailureStep,
        [string]$DeadlineEventName
    )

    if ([Diagnostics.Stopwatch]::GetTimestamp() -ge $WorkDeadline) {
        return [pscustomobject]@{ Outcome = 'budget' }
    }
    return [NebcoreHookSupervisor]::Run(
        $Application,
        $Arguments,
        $script:NebcoreChildMilliseconds,
        $script:NebcoreStreamLimit,
        $WorkDeadline,
        $AbsoluteDeadline,
        $FailureStep,
        $DeadlineEventName
    )
}

function ConvertFrom-NebcoreUtf8 {
    param([byte[]]$Bytes)

    $encoding = [Text.UTF8Encoding]::new($false, $true)
    return $encoding.GetString($Bytes)
}

function Invoke-NebcoreDiagnostic {
    $started = [Diagnostics.Stopwatch]::GetTimestamp()
    $absoluteDeadline = $started + [long](
        $script:NebcoreBudgetMilliseconds * [Diagnostics.Stopwatch]::Frequency / 1000
    )
    $workDeadline = $absoluteDeadline - [long](
        $script:NebcoreCleanupMilliseconds * [Diagnostics.Stopwatch]::Frequency / 1000
    )
    $stage = 'version'
    $nebcli = Get-Command nebcli -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $nebcli) {
        Write-Output $script:NebcoreMissing
        return
    }

    try {
        Initialize-NebcoreSupervisor
        $versionResult = Invoke-NebcoreChild -Application $nebcli.Source -Arguments @('--version') -WorkDeadline $workDeadline -AbsoluteDeadline $absoluteDeadline
        if ($versionResult.Outcome -ne 'exit' -or $versionResult.ExitCode -ne 0) {
            Write-Output $script:NebcoreVersionFailure
            return
        }
        $rawVersion = (ConvertFrom-NebcoreUtf8 $versionResult.Stdout) + (ConvertFrom-NebcoreUtf8 $versionResult.Stderr)
        $match = [regex]::Match($rawVersion, '(?<![0-9])v?([0-9]+)\.([0-9]+)\.([0-9]+)(?![0-9])')
        if (-not $match.Success) {
            Write-Output $script:NebcoreVersionFailure
            return
        }
        $installed = [version]::new(
            [int]$match.Groups[1].Value,
            [int]$match.Groups[2].Value,
            [int]$match.Groups[3].Value
        )
        $normalized = '{0}.{1}.{2}' -f $installed.Major, $installed.Minor, $installed.Build
        if ($installed -lt $script:NebcoreMinimumVersion) {
            Write-Output "NebCore AI tools are unavailable because nebcli $normalized is older than the required 6.13.0. Upgrade nebcli, run ``nebcli login``, then start a new Codex session."
            return
        }

        $stage = 'bridge'
        $bridgeResult = Invoke-NebcoreChild -Application $nebcli.Source -Arguments @('mcp') -WorkDeadline $workDeadline -AbsoluteDeadline $absoluteDeadline
        if ($bridgeResult.Outcome -in @('timeout', 'overflow', 'budget')) {
            Write-Output $script:NebcoreBridgeFailure
            return
        }
        if ($bridgeResult.Outcome -ne 'exit') {
            Write-Output $script:NebcoreBridgeFailure
            return
        }
        try {
            $bridgeOutput = (ConvertFrom-NebcoreUtf8 $bridgeResult.Stdout) + (ConvertFrom-NebcoreUtf8 $bridgeResult.Stderr)
        }
        catch {
            return
        }
        if ($bridgeOutput.Contains('no platform URL configured: set PLATFORM_URL env or run `nebcli login`')) {
            Write-Output $script:NebcoreLoginMissing
        }
    }
    catch {
        if ($stage -eq 'version') {
            Write-Output $script:NebcoreVersionFailure
        }
        else {
            Write-Output $script:NebcoreBridgeFailure
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-NebcoreDiagnostic
}
