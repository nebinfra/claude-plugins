param([string]$FixtureBinOutput)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$hook = Join-Path $repoRoot 'plugins\nebcore-ai\codex\session-start.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("nebcore-hook-{0}" -f [guid]::NewGuid())
$fakeBin = Join-Path $testRoot 'bin'
New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null

function Assert-Equal {
    param($Expected, $Actual, [string]$Label)

    if ($Actual -ne $Expected) {
        throw "$Label got <$Actual>, want <$Expected>"
    }
}

function Assert-ProcessGone {
    param([int]$ProcessId, [string]$Label)

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -ne $process) {
        throw "$Label process $ProcessId is still running"
    }
}

$fakeSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

public static class FakeNebcli
{
    public static int Main(string[] args)
    {
        string mode = Environment.GetEnvironmentVariable("NEBCORE_FIXTURE_MODE") ?? "success";
        if (args.Length == 1 && args[0] == "grandchild")
        {
            new ManualResetEvent(false).WaitOne();
            return 0;
        }
        if (args.Length == 1 && args[0] == "--version")
        {
            if (mode == "old") Console.Out.WriteLine("nebcli version 6.12.0");
            else if (mode == "unreadable") Console.Out.WriteLine("secret-version-marker");
            else if (mode == "version-overflow") Console.Out.Write(new string('1', 16385));
            else if (mode == "component-overflow") Console.Out.WriteLine("nebcli version 2147483648.13.0");
            else if (mode == "version-block") BlockWithGrandchild();
            else Console.Out.WriteLine("nebcli version 6.17.1");
            return 0;
        }
        if (args.Length != 1 || args[0] != "mcp") return 91;
        if (Console.In.Read() != -1) return 92;
        if (mode == "login")
        {
            Console.Error.WriteLine("no platform URL configured: set PLATFORM_URL env or run `nebcli login`");
            return 1;
        }
        if (mode == "bridge-overflow")
        {
            Console.Error.Write(new string('s', 16385));
            return 1;
        }
        if (mode == "bridge-block") BlockWithGrandchild();
        if (mode == "unexpected")
        {
            Console.Error.WriteLine("secret-bridge-marker");
            return 1;
        }
        if (mode == "marker")
        {
            File.WriteAllText(Environment.GetEnvironmentVariable("NEBCORE_FIXTURE_MARKER"), "resumed");
        }
        return 0;
    }

    private static void BlockWithGrandchild()
    {
        string application = Process.GetCurrentProcess().MainModule.FileName;
        var child = Process.Start(new ProcessStartInfo {
            FileName = application,
            Arguments = "grandchild",
            UseShellExecute = false,
            CreateNoWindow = true
        });
        File.WriteAllText(
            Environment.GetEnvironmentVariable("NEBCORE_FIXTURE_PIDS"),
            Process.GetCurrentProcess().Id + Environment.NewLine + child.Id + Environment.NewLine
        );
        string readyName = Environment.GetEnvironmentVariable("NEBCORE_FIXTURE_READY");
        if (!String.IsNullOrEmpty(readyName))
        {
            EventWaitHandle.OpenExisting(readyName).Set();
        }
        string readyFile = Environment.GetEnvironmentVariable("NEBCORE_FIXTURE_READY_FILE");
        if (!String.IsNullOrEmpty(readyFile))
        {
            File.WriteAllText(readyFile, "ready");
        }
        new ManualResetEvent(false).WaitOne();
    }
}
'@

try {
    $fake = Join-Path $fakeBin 'nebcli.exe'
    Add-Type -TypeDefinition $fakeSource -Language CSharp -OutputAssembly $fake -OutputType ConsoleApplication
    . $hook
    Initialize-NebcoreSupervisor
    $originalPath = $env:PATH
    $env:PATH = "$fakeBin;$originalPath"

    function Invoke-DiagnosticFixture {
        param([string]$Mode)

        $env:NEBCORE_FIXTURE_MODE = $Mode
        return ((Invoke-NebcoreDiagnostic | Out-String).TrimEnd())
    }

    function Invoke-SupervisorFixture {
        param(
            [string[]]$Arguments,
            [string]$FailureStep,
            [string]$DeadlineEventName
        )

        $absoluteDeadline = [NebcoreHookSupervisor]::DeadlineAfterMilliseconds(
            $script:NebcoreBudgetMilliseconds
        )
        $workDeadline = $absoluteDeadline - [long](
            $script:NebcoreCleanupMilliseconds * [Diagnostics.Stopwatch]::Frequency / 1000
        )
        return [NebcoreHookSupervisor]::Run(
            $fake,
            $Arguments,
            $script:NebcoreChildMilliseconds,
            $script:NebcoreStreamLimit,
            $workDeadline,
            $absoluteDeadline,
            $FailureStep,
            $DeadlineEventName
        )
    }

    $withoutFake = ($originalPath -split ';' | Where-Object {
        -not (Test-Path (Join-Path $_ 'nebcli.exe'))
    }) -join ';'
    $env:PATH = $withoutFake
    Assert-Equal $script:NebcoreMissing ((Invoke-NebcoreDiagnostic | Out-String).TrimEnd()) 'missing'
    $env:PATH = "$fakeBin;$originalPath"

    Assert-Equal 'NebCore AI tools are unavailable because nebcli 6.12.0 is older than the required 6.13.0. Upgrade nebcli, run nebcli login, then start a new Codex session.' (Invoke-DiagnosticFixture old) 'old'
    Assert-Equal $script:NebcoreLoginMissing (Invoke-DiagnosticFixture login) 'login'
    Assert-Equal '' (Invoke-DiagnosticFixture success) 'success'
    $unreadable = Invoke-DiagnosticFixture unreadable
    Assert-Equal $script:NebcoreVersionFailure $unreadable 'unreadable'
    if ($unreadable.Contains('secret-version-marker')) { throw 'version output leaked' }
    $unexpected = Invoke-DiagnosticFixture unexpected
    Assert-Equal '' $unexpected 'unexpected'
    if ($unexpected.Contains('secret-bridge-marker')) { throw 'bridge output leaked' }
    Assert-Equal $script:NebcoreVersionFailure (Invoke-DiagnosticFixture version-overflow) 'version-overflow'
    Assert-Equal $script:NebcoreVersionFailure (Invoke-DiagnosticFixture component-overflow) 'component-overflow'
    Assert-Equal $script:NebcoreBridgeFailure (Invoke-DiagnosticFixture bridge-overflow) 'bridge-overflow'

    $env:NEBCORE_FIXTURE_MODE = 'success'
    $exact = Invoke-SupervisorFixture @('--version') $null $null
    Assert-Equal 'exit' $exact.Outcome 'exact supervisor exit'
    Assert-Equal $true $exact.ReadersCompleted 'exact readers'
    $env:NEBCORE_FIXTURE_MODE = 'version-overflow'
    $overflow = Invoke-SupervisorFixture @('--version') $null $null
    Assert-Equal 'overflow' $overflow.Outcome 'overflow supervisor outcome'
    Assert-Equal 16384 $overflow.Stdout.Length 'overflow retained bytes'
    Assert-Equal $true $overflow.ReadersCompleted 'overflow readers'

    foreach ($stage in @(
        'stdout-pipe', 'stderr-pipe', 'stdin-pipe', 'job-create',
        'job-configure', 'overflow-event', 'attribute-size', 'attribute-init',
        'handle-list', 'attribute-update', 'process-create', 'job-assign',
        'readers-start', 'thread-resume'
    )) {
        $marker = Join-Path $testRoot "failure-$stage-marker"
        $env:NEBCORE_FIXTURE_MODE = 'marker'
        $env:NEBCORE_FIXTURE_MARKER = $marker
        try {
            [void](Invoke-SupervisorFixture @('--version') $stage $null)
            throw "failure step $stage did not fail"
        }
        catch {
            if (-not $_.Exception.Message.Contains("injected failure after $stage")) {
                throw
            }
        }
        if ($stage -ne 'thread-resume' -and (Test-Path $marker)) {
            throw "$stage resumed the suspended child"
        }
        $env:NEBCORE_FIXTURE_MODE = 'success'
        $afterFailure = Invoke-SupervisorFixture @('--version') $null $null
        Assert-Equal 'exit' $afterFailure.Outcome "$stage cleanup reuse"
        Assert-Equal $true $afterFailure.ReadersCompleted "$stage reader cleanup"
    }

    foreach ($stage in @('version', 'bridge')) {
        $eventName = "Local\nebcore-hook-{0}" -f [guid]::NewGuid()
        $pidFile = Join-Path $testRoot "$stage-pids"
        $env:NEBCORE_FIXTURE_MODE = "$stage-block"
        $env:NEBCORE_FIXTURE_READY = $eventName
        $env:NEBCORE_FIXTURE_PIDS = $pidFile
        $arguments = if ($stage -eq 'version') { @('--version') } else { @('mcp') }
        $result = Invoke-SupervisorFixture $arguments $null $eventName
        Assert-Equal 'timeout' $result.Outcome "$stage deadline"
        Assert-Equal $true $result.ReadersCompleted "$stage deadline readers"
        $pids = Get-Content -LiteralPath $pidFile | ForEach-Object { [int]$_ }
        Assert-Equal 2 $pids.Count "$stage process count"
        foreach ($processId in $pids) {
            Assert-ProcessGone $processId "$stage descendant"
        }
    }

    Assert-Equal 12000 $script:NebcoreBudgetMilliseconds 'total budget'
    Assert-Equal 2000 $script:NebcoreCleanupMilliseconds 'cleanup reserve'
    $budgetPids = Join-Path $testRoot 'budget-pids'
    $budgetReady = Join-Path $testRoot 'budget-ready'
    $env:NEBCORE_FIXTURE_MODE = 'version-block'
    $env:NEBCORE_FIXTURE_PIDS = $budgetPids
    $env:NEBCORE_FIXTURE_READY = $null
    $env:NEBCORE_FIXTURE_READY_FILE = $budgetReady
    $budgetClock = [Diagnostics.Stopwatch]::StartNew()
    $absoluteDeadline = [NebcoreHookSupervisor]::DeadlineAfterMilliseconds(750)
    $workDeadline = [NebcoreHookSupervisor]::DeadlineAfterMilliseconds(250)
    $budgetResult = [NebcoreHookSupervisor]::Run(
        $fake,
        @('--version'),
        $script:NebcoreChildMilliseconds,
        $script:NebcoreStreamLimit,
        $workDeadline,
        $absoluteDeadline,
        $null,
        $null
    )
    $budgetClock.Stop()
    Assert-Equal 'budget' $budgetResult.Outcome 'total deadline outcome'
    Assert-Equal $true $budgetResult.ReadersCompleted 'total deadline readers'
    if (-not (Test-Path -LiteralPath $budgetReady)) { throw 'budget fixture did not start' }
    $pids = Get-Content -LiteralPath $budgetPids | ForEach-Object { [int]$_ }
    Assert-Equal 2 $pids.Count 'budget process count'
    foreach ($processId in $pids) {
        Assert-ProcessGone $processId 'budget descendant'
    }
    if ($budgetClock.ElapsedMilliseconds -ge 1500) {
        throw "scaled total budget exceeded 1500 ms: $($budgetClock.ElapsedMilliseconds)"
    }
    if ($script:NebcoreBudgetMilliseconds -ge 15000) {
        throw 'production budget must remain below the Codex outer timeout'
    }

    if (-not [string]::IsNullOrEmpty($FixtureBinOutput)) {
        New-Item -ItemType Directory -Path $FixtureBinOutput -Force | Out-Null
        Copy-Item -LiteralPath $fake -Destination (Join-Path $FixtureBinOutput 'nebcli.exe') -Force
    }
    Write-Output 'PASS: nebcore-ai Windows prerequisite diagnostics'
}
finally {
    Remove-Item Env:NEBCORE_FIXTURE_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:NEBCORE_FIXTURE_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:NEBCORE_FIXTURE_READY -ErrorAction SilentlyContinue
    Remove-Item Env:NEBCORE_FIXTURE_READY_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:NEBCORE_FIXTURE_PIDS -ErrorAction SilentlyContinue
    if ($null -ne (Get-Variable originalPath -ErrorAction SilentlyContinue)) {
        $env:PATH = $originalPath
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
