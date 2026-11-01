#Requires -Version 5.1
<#
Deletes only C:\Program Files\Microsoft OneDrive\OneDrive.App.exe.
Directory notifications wake the process; a periodic check repairs missed events.
TestDirectory redirects the fixed filename to an isolated directory for testing.
Logs always live alongside this script. No downloaded code is executed.
#>
[CmdletBinding()]
param(
    [string]$TestDirectory,
    [ValidateRange(2, 3600)]
    [int]$CheckIntervalSeconds = 60,
    [ValidateRange(1024, 10485760)]
    [int]$LogMaxBytes = 1048576
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:LogPath = Join-Path $PSScriptRoot 'OneDriveAppGuard.log'
$script:LogEncoding = New-Object System.Text.UTF8Encoding($false)
$script:LastLogWarning = [datetime]::MinValue

function Get-PathAttributes {
    param([string]$LiteralPath)
    try { return [IO.File]::GetAttributes($LiteralPath) }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
}

function Assert-NoReparsePoint {
    param([string]$LiteralPath)
    $current = [IO.Path]::GetFullPath($LiteralPath)
    while ($current) {
        $attributes = Get-PathAttributes $current
        if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing a symbolic link or directory junction: $current"
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Write-GuardLog {
    param([string]$Level, [string]$Message)
    try {
        $line = '{0} [{1}] {2}{3}' -f [DateTimeOffset]::Now.ToString('o'), $Level,
            ($Message -replace '[\r\n]+', ' '), [Environment]::NewLine
        Assert-NoReparsePoint $PSScriptRoot
        foreach ($logFile in @($script:LogPath, "$script:LogPath.1", "$script:LogPath.2")) {
            Assert-NoReparsePoint $logFile
            $attributes = Get-PathAttributes $logFile
            if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::Directory)) {
                throw "Log path is a directory: $logFile"
            }
        }
        if ([IO.File]::Exists($script:LogPath) -and
            (([IO.FileInfo]$script:LogPath).Length + $script:LogEncoding.GetByteCount($line) -gt $LogMaxBytes)) {
            if ([IO.File]::Exists("$script:LogPath.2")) { [IO.File]::Delete("$script:LogPath.2") }
            if ([IO.File]::Exists("$script:LogPath.1")) { [IO.File]::Move("$script:LogPath.1", "$script:LogPath.2") }
            [IO.File]::Move($script:LogPath, "$script:LogPath.1")
        }
        [IO.File]::AppendAllText($script:LogPath, $line, $script:LogEncoding)
    }
    catch {
        # A full disk or log problem must not disable removal or create a busy loop.
        if (([datetime]::UtcNow - $script:LastLogWarning).TotalSeconds -ge 60) {
            Write-Warning "Unable to write the guard log: $($_.Exception.Message)"
            $script:LastLogWarning = [datetime]::UtcNow
        }
    }
}

function Stop-ExactTargetProcess {
    # Use Process objects, and verify the full executable path before terminating.
    $processes = [Diagnostics.Process]::GetProcessesByName('OneDrive.App')
    foreach ($candidate in $processes) {
        try {
            $imagePath = $candidate.MainModule.FileName
            if ([string]::Equals([IO.Path]::GetFullPath($imagePath), $script:TargetPath,
                    [StringComparison]::OrdinalIgnoreCase)) {
                Assert-NoReparsePoint $script:TargetPath
                $processId = $candidate.Id
                $candidate.Kill()
                [void]$candidate.WaitForExit(1000)
                Write-GuardLog 'INFO' "Stopped target process PID $processId."
            }
        }
        catch {
            # Another process with the same name, or a process that already exited,
            # is never terminated based on its name alone.
            Write-Verbose "Unable to inspect or stop a process: $($_.Exception.Message)"
        }
        finally { $candidate.Dispose() }
    }
}

function Remove-ExactTarget {
    param([bool]$TryStopProcess)
    try {
        Assert-NoReparsePoint $script:TargetPath
        $attributes = Get-PathAttributes $script:TargetPath
        if ($null -eq $attributes) { return @{ Outcome = 'Absent' } }
        if ($attributes -band [IO.FileAttributes]::Directory) {
            throw 'The target is a directory; recursive deletion is never permitted.'
        }
        if ($attributes -band [IO.FileAttributes]::ReadOnly) {
            [IO.File]::SetAttributes($script:TargetPath, ($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
        }
        try { [IO.File]::Delete($script:TargetPath) }
        catch {
            $nativeCode = $_.Exception.GetBaseException().HResult -band 65535
            # Windows can report a mapped executable as ACCESS_DENIED (5),
            # rather than SHARING_VIOLATION (32) or LOCK_VIOLATION (33).
            if ($TryStopProcess -and $nativeCode -in @(5, 32, 33)) {
                Stop-ExactTargetProcess
                Assert-NoReparsePoint $script:TargetPath
                [IO.File]::Delete($script:TargetPath)
            }
            else { throw }
        }
        # A writer may recreate the name immediately after deletion.
        if ($null -ne (Get-PathAttributes $script:TargetPath)) {
            throw 'Target was recreated during removal.'
        }
        return @{ Outcome = 'Deleted' }
    }
    catch {
        $detail = $_.Exception.GetBaseException().Message
        if ($detail.Length -gt 1000) { $detail = $detail.Substring(0, 1000) }
        return @{ Outcome = 'Retry'; Detail = $detail }
    }
}

# Event handlers run on .NET threads. They only set flags and signal one wait
# handle; they never execute PowerShell, queue unbounded jobs, or delete files.
$signalSource = @'
using System;
using System.IO;
using System.Threading;

namespace OneDriveAppGuard {
    public sealed class DirectorySignals : IDisposable {
        public const int Dirty = 1;
        public const int Rebuild = 2;
        public const int Failure = 4;
        private readonly AutoResetEvent wake = new AutoResetEvent(false);
        private readonly string directory;
        private readonly string filename;
        private FileSystemWatcher anchor;
        private FileSystemWatcher target;
        private int flags;
        private string lastError;

        public DirectorySignals(string directory, string filename) {
            this.directory = directory;
            this.filename = filename;
        }
        private void Mark(int value) {
            int prior;
            do { prior = Interlocked.CompareExchange(ref flags, 0, 0); }
            while (Interlocked.CompareExchange(ref flags, prior | value, prior) != prior);
            try { wake.Set(); } catch (ObjectDisposedException) { }
        }
        private void TargetChanged(object sender, FileSystemEventArgs args) { Mark(Dirty); }
        private void AnchorChanged(object sender, FileSystemEventArgs args) { Mark(Dirty | Rebuild); }
        private void WatcherFailed(object sender, ErrorEventArgs args) {
            Interlocked.Exchange(ref lastError, args.GetException().Message);
            Mark(Dirty | Rebuild | Failure);
        }
        public int ConsumeFlags() { return Interlocked.Exchange(ref flags, 0); }
        public string ConsumeError() { return Interlocked.Exchange(ref lastError, null); }
        public void Wait(int timeoutMilliseconds) { wake.WaitOne(timeoutMilliseconds); }
        public void CloseWatchers() {
            if (target != null) { target.Dispose(); target = null; }
            if (anchor != null) { anchor.Dispose(); anchor = null; }
        }
        public void Rebind() {
            CloseWatchers();
            try {
                string parent = Path.GetDirectoryName(directory);
                if (Directory.Exists(parent)) {
                    anchor = new FileSystemWatcher(parent, Path.GetFileName(directory));
                    anchor.IncludeSubdirectories = false;
                    anchor.NotifyFilter = NotifyFilters.DirectoryName;
                    anchor.Created += AnchorChanged;
                    anchor.Deleted += AnchorChanged;
                    anchor.Renamed += AnchorChanged;
                    anchor.Error += WatcherFailed;
                    anchor.EnableRaisingEvents = true;
                }
                if (Directory.Exists(directory)) {
                    target = new FileSystemWatcher(directory, filename);
                    target.IncludeSubdirectories = false;
                    target.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size;
                    target.Created += TargetChanged;
                    target.Renamed += TargetChanged;
                    target.Changed += TargetChanged;
                    target.Error += WatcherFailed;
                    target.EnableRaisingEvents = true;
                }
            } catch { CloseWatchers(); throw; }
        }
        public void Dispose() { CloseWatchers(); wake.Dispose(); }
    }
}
'@

$mutex = $null
$ownsMutex = $false
$signals = $null
$exitCode = 0
try {
    if ($TestDirectory) {
        if (-not [IO.Path]::IsPathRooted($TestDirectory)) { throw 'TestDirectory must be an absolute path.' }
        $fullTestPath = [IO.Path]::GetFullPath($TestDirectory)
        if ($fullTestPath.TrimEnd('\') -eq [IO.Path]::GetPathRoot($fullTestPath).TrimEnd('\')) {
            throw 'A drive root is not a valid test directory.'
        }
        $targetDirectory = $fullTestPath.TrimEnd('\')
        if ($targetDirectory -eq 'C:\Program Files\Microsoft OneDrive') {
            throw 'TestDirectory must not be the production OneDrive directory.'
        }
    }
    else { $targetDirectory = 'C:\Program Files\Microsoft OneDrive' }
    if ($null -eq [IO.Directory]::GetParent($targetDirectory)) { throw 'A drive root is not a valid target directory.' }
    $script:TargetPath = Join-Path $targetDirectory 'OneDrive.App.exe'

    $hashProvider = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hashProvider.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:TargetPath.ToUpperInvariant()))
        $mutexSuffix = ([BitConverter]::ToString($digest)).Replace('-', '').Substring(0, 24)
    }
    finally { $hashProvider.Dispose() }
    $mutex = New-Object Threading.Mutex($false, "Global\OneDriveAppGuard-$mutexSuffix")
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) {
        # Do not write to the same rotating log from a second instance.
        Write-Output 'An instance is already monitoring this target.'
    }
    else {
        Write-GuardLog 'INFO' "Starting. Target=$script:TargetPath; check interval=${CheckIntervalSeconds}s."
        if (-not ('OneDriveAppGuard.DirectorySignals' -as [type])) { Add-Type -TypeDefinition $signalSource }
        # Release temporary compilation objects once; never force GC in the idle loop.
        [GC]::Collect()
        $signals = New-Object OneDriveAppGuard.DirectorySignals($targetDirectory, 'OneDrive.App.exe')
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $nextHealth = 0.0
        $nextAttempt = 0.0
        $nextAllowedAttempt = 0.0
        $nextRebindAllowed = 0.0
        $rebindPending = $true
        $retryIndex = 0
        $retryDelays = @(0.5, 1.0, 2.0, 5.0)
        $lastWatchState = ''
        $readyLogged = $false

        while ($true) {
            $now = $clock.Elapsed.TotalSeconds
            $flags = $signals.ConsumeFlags()
            if ($flags -band 4) { Write-GuardLog 'WARN' "Directory notification error: $($signals.ConsumeError())" }
            if ($flags -band 2) { $rebindPending = $true }
            if ($now -ge $nextHealth) {
                $rebindPending = $true
                $nextHealth = $now + $CheckIntervalSeconds
                if ([double]::IsPositiveInfinity($nextAttempt)) {
                    $nextAttempt = [Math]::Max($now, $nextAllowedAttempt)
                }
            }
            if (($flags -band 1) -and [double]::IsPositiveInfinity($nextAttempt)) {
                $nextAttempt = [Math]::Max($now, $nextAllowedAttempt)
            }
            if ($rebindPending -and $now -ge $nextRebindAllowed) {
                $rebindPending = $false
                # Directory churn cannot force unlimited watcher recreation.
                $nextRebindAllowed = $now + 1.0
                try {
                    Assert-NoReparsePoint $targetDirectory
                    $signals.Rebind()
                    $state = if ([IO.Directory]::Exists($targetDirectory)) { 'Watching target directory.' }
                        else { 'Target directory absent; waiting for creation.' }
                    if ($state -ne $lastWatchState) {
                        Write-GuardLog 'INFO' $state
                        $lastWatchState = $state
                    }
                }
                catch {
                    $signals.CloseWatchers()
                    $state = "Watcher unavailable: $($_.Exception.GetBaseException().Message)"
                    if ($state -ne $lastWatchState) { Write-GuardLog 'WARN' $state; $lastWatchState = $state }
                }
                # Scan after binding too, closing the gap during a directory swap.
                if ([double]::IsPositiveInfinity($nextAttempt)) {
                    $nextAttempt = [Math]::Max($now, $nextAllowedAttempt)
                }
            }

            if ($now -ge $nextAttempt) {
                # A downloader may release its handle and launch the app between
                # retries, so path-verified termination is allowed on each attempt.
                $result = Remove-ExactTarget -TryStopProcess $true
                $now = $clock.Elapsed.TotalSeconds
                if ($result.Outcome -eq 'Retry') {
                    if ($retryIndex -lt $retryDelays.Count) {
                        $nextAttempt = $now + $retryDelays[$retryIndex]
                        $retryIndex++
                    }
                    else {
                        Write-GuardLog 'WARN' "Removal failed after bounded retries: $($result.Detail) Next attempt in 60s."
                        $retryIndex = 0
                        $nextAllowedAttempt = $now + 60.0
                        $nextAttempt = $nextAllowedAttempt
                    }
                }
                else {
                    if ($result.Outcome -eq 'Deleted') { Write-GuardLog 'INFO' "Deleted: $script:TargetPath" }
                    if (-not $readyLogged) {
                        Write-GuardLog 'INFO' "Ready. PID=$PID; initial cleanup completed."
                        $readyLogged = $true
                    }
                    $retryIndex = 0
                    $nextAttempt = [double]::PositiveInfinity
                    # Cap rapid recreation/removal cycles at two per second.
                    $nextAllowedAttempt = $now + 0.5
                }
            }
            $deadline = [Math]::Min($nextHealth, $nextAttempt)
            if ($rebindPending) { $deadline = [Math]::Min($deadline, $nextRebindAllowed) }
            $waitMilliseconds = [int][Math]::Min(60000, [Math]::Max(1,
                    [Math]::Ceiling(($deadline - $clock.Elapsed.TotalSeconds) * 1000)))
            $signals.Wait($waitMilliseconds)
        }
    }
}
catch {
    Write-GuardLog 'ERROR' "Fatal error: $($_.Exception.GetBaseException().Message)"
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    $exitCode = 1
}
finally {
    if ($null -ne $signals) { $signals.Dispose() }
    if ($ownsMutex -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
exit $exitCode
