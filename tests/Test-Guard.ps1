#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$artifactRoot = Join-Path $projectRoot '.test-artifacts'
$runDirectory = Join-Path $artifactRoot ([datetime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$guardDirectory = Join-Path $runDirectory 'guard'
$targetDirectory = Join-Path $runDirectory 'target'
$targetPath = Join-Path $targetDirectory 'OneDrive.App.exe'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$guardProcess = $null
$otherProcess = $null
$targetProcess = $null
$lockedStream = $null
$results = New-Object 'Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-TestPath {
    param([string]$LiteralPath)
    $absolute = [IO.Path]::GetFullPath($LiteralPath)
    $prefix = [IO.Path]::GetFullPath($runDirectory).TrimEnd('\') + '\'
    Assert-True ($absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) "Path escaped test directory: $absolute"
}

function Wait-Until {
    param([scriptblock]$Condition, [string]$Message, [int]$TimeoutSeconds = 12)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return }
        if ($null -ne $guardProcess -and $guardProcess.HasExited) {
            $details = Get-Content -LiteralPath (Join-Path $guardDirectory 'stderr.txt') -Raw -ErrorAction SilentlyContinue
            throw "Guard exited unexpectedly: $details"
        }
        Start-Sleep -Milliseconds 50
    } while ([datetime]::UtcNow -lt $deadline)
    throw $Message
}

function Record-Pass {
    param([string]$Name)
    $results.Add($Name)
    Write-Output "PASS: $Name"
}

function Start-TestGuard {
    param([string]$OutputName = 'stdout.txt', [string]$ErrorName = 'stderr.txt')
    $argumentLine = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -TestDirectory "{1}" -CheckIntervalSeconds 3 -LogMaxBytes 1024' -f
        (Join-Path $guardDirectory 'Watch-OneDriveApp.ps1'), $targetDirectory
    $started = Start-Process -FilePath $powerShellPath -ArgumentList $argumentLine -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $guardDirectory $OutputName) -RedirectStandardError (Join-Path $guardDirectory $ErrorName)
    # Keep the native handle open so Windows PowerShell can read ExitCode even
    # when a duplicate instance exits before the caller inspects it.
    [void]$started.Handle
    return $started
}

try {
    [void][IO.Directory]::CreateDirectory($guardDirectory)
    [void][IO.Directory]::CreateDirectory($targetDirectory)
    foreach ($file in @('Watch-OneDriveApp.ps1', 'Install.ps1', 'Uninstall.ps1', 'tests\Test-Guard.ps1', 'tools\Build-Release.ps1')) {
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot $file), [ref]$tokens, [ref]$parseErrors)
        Assert-True (@($parseErrors).Count -eq 0) "Parse error in $file`: $parseErrors"
    }
    Record-Pass 'All scripts parse in Windows PowerShell 5.1'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'Watch-OneDriveApp.ps1') -Destination $guardDirectory
    [IO.File]::WriteAllText($targetPath, 'startup target')
    $keepFile = Join-Path $targetDirectory 'OneDrive.exe'
    [IO.File]::WriteAllText($keepFile, 'unrelated file must survive')
    $guardProcess = Start-TestGuard
    Wait-Until { -not [IO.File]::Exists($targetPath) } 'Existing target was not removed.'
    Record-Pass 'Startup removes existing target; unrelated file survives'
    Assert-True ([IO.File]::Exists($keepFile)) 'Unrelated OneDrive.exe was removed.'

    # Check event latency separately from the three-second fallback timer.
    Start-Sleep -Milliseconds 600
    $latency = [Diagnostics.Stopwatch]::StartNew()
    [IO.File]::WriteAllText($targetPath, 'created')
    Wait-Until { -not [IO.File]::Exists($targetPath) } 'Created target was not removed.'
    $creationMilliseconds = $latency.ElapsedMilliseconds
    Assert-True ($creationMilliseconds -lt 2500) 'Directory event response was unexpectedly slow.'
    Record-Pass "Creation event removes target (${creationMilliseconds}ms)"

    $temporaryDownload = Join-Path $targetDirectory 'download.tmp'
    [IO.File]::WriteAllText($temporaryDownload, 'renamed')
    [IO.File]::Move($temporaryDownload, $targetPath)
    Wait-Until { -not [IO.File]::Exists($targetPath) } 'Renamed target was not removed.'
    Record-Pass 'Temporary download renamed to target is removed'

    $lockedStream = New-Object IO.FileStream($targetPath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Start-Sleep -Seconds 2
    Assert-True ([IO.File]::Exists($targetPath)) 'Locked target should still exist before releasing the handle.'
    $lockedStream.Dispose()
    $lockedStream = $null
    Wait-Until { -not [IO.File]::Exists($targetPath) } 'Target was not removed after releasing the lock.'
    Record-Pass 'Sharing violation retries and recovers after handle release'

    $probeExe = Join-Path $runDirectory 'probe.exe'
    # Use a Windows-bundled executable as an inert, hidden waiting process. This
    # needs no compiler, downloads, network traffic, or generated executable code.
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $probeExe
    $otherDirectory = Join-Path $runDirectory 'unrelated'
    [void][IO.Directory]::CreateDirectory($otherDirectory)
    $otherExe = Join-Path $otherDirectory 'OneDrive.App.exe'
    Copy-Item -LiteralPath $probeExe -Destination $otherExe
    $otherProcess = Start-Process -FilePath $otherExe -ArgumentList '/d /q /k' -WindowStyle Hidden -PassThru
    # Hold the destination open until process startup, avoiding the intentional
    # creation/delete race when testing the occupied-executable branch.
    $lockedStream = New-Object IO.FileStream($targetPath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    $bytes = [IO.File]::ReadAllBytes($probeExe)
    $lockedStream.Write($bytes, 0, $bytes.Length)
    $lockedStream.Flush()
    Start-Sleep -Milliseconds 800
    $lockedStream.Dispose()
    $lockedStream = $null
    $targetProcess = Start-Process -FilePath $targetPath -ArgumentList '/d /q /k' -WindowStyle Hidden -PassThru
    Wait-Until { $targetProcess.HasExited -and -not [IO.File]::Exists($targetPath) } 'Target process was not stopped and deleted.'
    Assert-True (-not $otherProcess.HasExited) 'A same-name executable in another directory was terminated.'
    Record-Pass 'Occupied executable is stopped; same-name process at another path survives'

    $movedDirectory = Join-Path $runDirectory 'old-target'
    Assert-TestPath $targetDirectory
    Assert-TestPath $movedDirectory
    Move-Item -LiteralPath $targetDirectory -Destination $movedDirectory
    [void][IO.Directory]::CreateDirectory($targetDirectory)
    [IO.File]::WriteAllText($targetPath, 'after directory replacement')
    Wait-Until { -not [IO.File]::Exists($targetPath) } 'Target survived directory replacement.'
    Record-Pass 'Directory rename/recreation restores monitoring'

    Assert-TestPath $targetDirectory
    [IO.Directory]::Delete($targetDirectory)
    Start-Sleep -Milliseconds 500
    [void][IO.Directory]::CreateDirectory($targetDirectory)
    [IO.File]::WriteAllText($targetPath, 'after deletion')
    Wait-Until { -not [IO.File]::Exists($targetPath) } 'Target survived directory deletion/recreation.'
    Record-Pass 'Absent target directory can be recreated'

    [void][IO.Directory]::CreateDirectory($targetPath)
    $insideDirectory = Join-Path $targetPath 'keep.txt'
    [IO.File]::WriteAllText($insideDirectory, 'never recurse')
    Start-Sleep -Seconds 2
    Assert-True ([IO.File]::Exists($insideDirectory)) 'A directory matching the filename was recursively removed.'
    [IO.File]::Delete($insideDirectory)
    [IO.Directory]::Delete($targetPath)
    [IO.File]::WriteAllText($targetPath, 'normal again')
    Wait-Until { -not [IO.File]::Exists($targetPath) } 'Guard did not recover from directory-shaped target.'
    Record-Pass 'Directory-shaped target is refused without deleting contents'

    $outsideDirectory = Join-Path $runDirectory 'junction-destination'
    [void][IO.Directory]::CreateDirectory($outsideDirectory)
    $outsideFile = Join-Path $outsideDirectory 'OneDrive.App.exe'
    [IO.File]::WriteAllText($outsideFile, 'must survive junction')
    Assert-TestPath $targetDirectory
    [IO.Directory]::Delete($targetDirectory)
    New-Item -ItemType Junction -Path $targetDirectory -Target $outsideDirectory | Out-Null
    Start-Sleep -Seconds 2
    Assert-True ([IO.File]::Exists($outsideFile)) 'Guard followed a junction and removed its destination.'
    [IO.Directory]::Delete($targetDirectory)
    Assert-True ([IO.File]::Exists($outsideFile)) 'Removing the junction affected the destination.'
    [void][IO.Directory]::CreateDirectory($targetDirectory)
    [IO.File]::WriteAllText($targetPath, 'after junction removal')
    Wait-Until { -not [IO.File]::Exists($targetPath) } 'Guard did not recover after junction removal.'
    Record-Pass 'Junction is refused; destination survives; normal monitoring recovers'

    $duplicate = Start-TestGuard 'duplicate-stdout.txt' 'duplicate-stderr.txt'
    Assert-True ($duplicate.WaitForExit(6000)) 'Duplicate guard did not exit.'
    Assert-True ($duplicate.ExitCode -eq 0) 'Duplicate guard exited with an error.'
    $duplicateMessage = Get-Content -LiteralPath (Join-Path $guardDirectory 'duplicate-stdout.txt') -Raw
    Assert-True ($duplicateMessage -match 'already monitoring') 'Duplicate guard did not report singleton protection.'
    $duplicate.Dispose()
    Record-Pass 'Second instance exits cleanly'

    $lockedStream = New-Object IO.FileStream($targetPath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Start-Sleep -Seconds 11
    $retryWarnings = @(Get-ChildItem -LiteralPath $guardDirectory -Filter 'OneDriveAppGuard.log*' -File |
        ForEach-Object { Get-Content -LiteralPath $_.FullName } |
        Where-Object { $_ -match 'Removal failed after bounded retries' })
    Assert-True ($retryWarnings.Count -eq 1) 'Bounded retry exhaustion should produce one warning.'
    $guardProcess.Refresh()
    $failureCpuStart = $guardProcess.TotalProcessorTime.TotalSeconds
    Start-Sleep -Seconds 3
    $guardProcess.Refresh()
    $failureCpuDelta = $guardProcess.TotalProcessorTime.TotalSeconds - $failureCpuStart
    Assert-True ($failureCpuDelta -lt 0.15) 'Persistent sharing violation caused excessive CPU use.'
    Record-Pass 'Persistent failure enters cooldown without repeated logging or a busy loop'
    $lockedStream.Dispose()
    $lockedStream = $null
    $guardProcess.Kill()
    [void]$guardProcess.WaitForExit(5000)
    $guardProcess.Dispose()
    $guardProcess = Start-TestGuard 'restarted-stdout.txt' 'restarted-stderr.txt'
    Wait-Until { -not [IO.File]::Exists($targetPath) } 'Restarted guard did not remove the leftover target.'
    Record-Pass 'Unexpected process termination can be followed by a clean restart'

    for ($iteration = 0; $iteration -lt 25; $iteration++) {
        [IO.File]::WriteAllText($targetPath, "rotation $iteration")
        Wait-Until { -not [IO.File]::Exists($targetPath) } 'Target was not removed during rotation test.'
    }
    $logFiles = @(Get-ChildItem -LiteralPath $guardDirectory -Filter 'OneDriveAppGuard.log*' -File)
    Assert-True ($logFiles.Count -eq 3) 'Expected exactly three rotating log files.'
    foreach ($logFile in $logFiles) { Assert-True ($logFile.Length -le 1024) 'Log exceeded the configured rotation size.' }
    Record-Pass 'Logs remain beside script and rotate to exactly three bounded files'

    $guardProcess.Refresh()
    $cpuStart = $guardProcess.TotalProcessorTime.TotalSeconds
    $idleClock = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds 10
    $guardProcess.Refresh()
    $idleCorePercent = 100 * ($guardProcess.TotalProcessorTime.TotalSeconds - $cpuStart) / $idleClock.Elapsed.TotalSeconds
    $workingSetMB = [Math]::Round($guardProcess.WorkingSet64 / 1MB, 1)
    $privateMB = [Math]::Round($guardProcess.PrivateMemorySize64 / 1MB, 1)
    Assert-True ($idleCorePercent -lt 5) 'Idle CPU exceeds five percent of a single core.'
    Record-Pass ('Idle sample: {0:N2}% of one CPU core; working set {1} MB; private memory {2} MB' -f $idleCorePercent, $workingSetMB, $privateMB)

    $report = [ordered]@{
        Passed = $true
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Tests = $results.ToArray()
        CreationLatencyMilliseconds = $creationMilliseconds
        IdleCpuCorePercent = [Math]::Round($idleCorePercent, 3)
        WorkingSetMB = $workingSetMB
        PrivateMemoryMB = $privateMB
        ArtifactDirectory = $runDirectory
    }
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDirectory 'results.json') -Encoding UTF8
    Write-Output "All tests passed. Artifacts: $runDirectory"
}
finally {
    if ($null -ne $lockedStream) { $lockedStream.Dispose() }
    foreach ($process in @($guardProcess, $targetProcess, $otherProcess)) {
        if ($null -ne $process) {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
    }
}
