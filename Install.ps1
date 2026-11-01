#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'OneDriveAppGuard'
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$installDirectory = Join-Path $programFiles 'OneDriveAppGuard'
$installedScript = Join-Path $installDirectory 'Watch-OneDriveApp.ps1'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Assert-NormalPath {
    param([string]$LiteralPath)
    $current = [IO.Path]::GetFullPath($LiteralPath)
    while ($current) {
        try {
            if ([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing a symbolic link or junction: $current"
            }
        }
        catch [IO.FileNotFoundException] { }
        catch [IO.DirectoryNotFoundException] { }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Set-ProtectedPermissions {
    param([string]$LiteralPath, [bool]$IsDirectory)
    Assert-NormalPath $LiteralPath
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $acl = if ($IsDirectory) { New-Object Security.AccessControl.DirectorySecurity }
        else { New-Object Security.AccessControl.FileSecurity }
    $acl.SetOwner($admins)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($entry in @(@($admins, 'FullControl'), @($system, 'FullControl'), @($users, 'ReadAndExecute'))) {
        $rights = [Security.AccessControl.FileSystemRights]$entry[1]
        if ($IsDirectory) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($entry[0], $rights,
                [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        }
        else {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($entry[0], $rights,
                [Security.AccessControl.AccessControlType]::Allow)
        }
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $LiteralPath -AclObject $acl
}

try {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw 'Run Install.ps1 from 64-bit Windows PowerShell.'
    }
    foreach ($name in @('Watch-OneDriveApp.ps1', 'Uninstall.ps1')) {
        $source = Join-Path $PSScriptRoot $name
        Assert-NormalPath $source
        if (-not [IO.File]::Exists($source)) { throw "Missing installation file: $source" }
    }
    Assert-NormalPath $installDirectory
    $existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        $actions = @($existing.Actions)
        $expectedArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $installedScript
        if ($actions.Count -ne 1 -or $actions[0].Execute -ne $powerShellPath -or
            $actions[0].Arguments -ne $expectedArguments) {
            throw "A different task named $taskName already exists; it will not be overwritten."
        }
        Stop-ScheduledTask -TaskName $taskName -TaskPath '\'
        $stopDeadline = [datetime]::UtcNow.AddSeconds(15)
        do {
            $state = (Get-ScheduledTask -TaskName $taskName -TaskPath '\').State
            if ($state -ne 'Running') { break }
            Start-Sleep -Milliseconds 200
        } while ([datetime]::UtcNow -lt $stopDeadline)
        if ($state -eq 'Running') { throw 'The existing guard did not stop; installation cancelled.' }
    }

    if (-not [IO.Directory]::Exists($installDirectory)) {
        [void][IO.Directory]::CreateDirectory($installDirectory)
    }
    Set-ProtectedPermissions $installDirectory $true
    foreach ($name in @('Watch-OneDriveApp.ps1', 'Uninstall.ps1', 'README.md')) {
        $source = Join-Path $PSScriptRoot $name
        $destination = Join-Path $installDirectory $name
        Assert-NormalPath $destination
        if ([IO.File]::Exists($source)) {
            if (-not [string]::Equals([IO.Path]::GetFullPath($source), $destination,
                    [StringComparison]::OrdinalIgnoreCase)) {
                Copy-Item -LiteralPath $source -Destination $destination -Force
            }
            Set-ProtectedPermissions $destination $false
        }
    }
    foreach ($name in @('OneDriveAppGuard.log', 'OneDriveAppGuard.log.1', 'OneDriveAppGuard.log.2')) {
        $logFile = Join-Path $installDirectory $name
        Assert-NormalPath $logFile
        if ([IO.File]::Exists($logFile)) { Set-ProtectedPermissions $logFile $false }
    }

    $action = New-ScheduledTaskAction -Execute $powerShellPath -WorkingDirectory $installDirectory `
        -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $installedScript)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $definition = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Remove only Microsoft OneDrive\OneDrive.App.exe; event-driven with periodic recovery. Logs alongside the script.'
    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $definition -Force | Out-Null
    $launchTime = [datetime]::UtcNow
    Start-ScheduledTask -TaskName $taskName -TaskPath '\'

    $startDeadline = [datetime]::UtcNow.AddSeconds(15)
    $ready = $false
    $guardLog = Join-Path $installDirectory 'OneDriveAppGuard.log'
    do {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
        if ($task.State -eq 'Running' -and [IO.File]::Exists($guardLog)) {
            foreach ($line in @(Get-Content -LiteralPath $guardLog -Tail 15)) {
                if ($line -match '^\S+ \[INFO\] Ready\.') {
                    $timestamp = [DateTimeOffset]::Parse(($line -split ' ')[0])
                    if ($timestamp.UtcDateTime -ge $launchTime) { $ready = $true; break }
                }
            }
        }
        if ($ready) { break }
        Start-Sleep -Milliseconds 250
    } while ([datetime]::UtcNow -lt $startDeadline)
    if (-not $ready) { throw 'Task registered, but startup cleanup was not confirmed. Inspect the task result and guard log.' }
    Write-Output "Installed and started: $taskName"
    Write-Output "Script: $installedScript"
    Write-Output "Log: $(Join-Path $installDirectory 'OneDriveAppGuard.log')"
    Write-Output 'Startup: enabled. Account: SYSTEM. No interactive window. No execution time limit.'
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
