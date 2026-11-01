#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$RemoveLogs
)

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

try {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw 'Run Uninstall.ps1 from 64-bit Windows PowerShell.'
    }
    Assert-NormalPath $installDirectory
    $existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        $expectedArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $installedScript
        $actions = @($existing.Actions)
        if ($actions.Count -ne 1 -or $actions[0].Execute -ne $powerShellPath -or
            $actions[0].Arguments -ne $expectedArguments) {
            throw 'The task does not match this installation; it will not be removed.'
        }
        Stop-ScheduledTask -TaskName $taskName -TaskPath '\'
        $stopDeadline = [datetime]::UtcNow.AddSeconds(15)
        do {
            $state = (Get-ScheduledTask -TaskName $taskName -TaskPath '\').State
            if ($state -ne 'Running') { break }
            Start-Sleep -Milliseconds 200
        } while ([datetime]::UtcNow -lt $stopDeadline)
        if ($state -eq 'Running') { throw 'The guard did not stop; uninstall cancelled.' }
        Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
    }
    # Delete only the explicitly named installation files. Never recurse, and
    # never delete the OneDrive directory or the workspace containing the source.
    $names = @('Watch-OneDriveApp.ps1', 'Uninstall.ps1', 'README.md')
    if ($RemoveLogs) { $names += @('OneDriveAppGuard.log', 'OneDriveAppGuard.log.1', 'OneDriveAppGuard.log.2') }
    foreach ($name in $names) {
        $path = Join-Path $installDirectory $name
        Assert-NormalPath $path
        if ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force }
    }
    if ([IO.Directory]::Exists($installDirectory) -and
        @(Get-ChildItem -LiteralPath $installDirectory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $installDirectory
    }
    Write-Output 'OneDriveAppGuard stopped and uninstalled. Startup disabled.'
    if (-not $RemoveLogs) { Write-Output "Existing logs retained in: $installDirectory" }
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
