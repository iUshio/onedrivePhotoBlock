#Requires -Version 5.1
<#
Build a source distribution from an explicit allowlist, with a SHA-256 checksum.
Does not install, start, stop, or publish anything.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$outputDirectory = Join-Path $projectRoot 'dist'

function Assert-PlainPath {
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

$manifest = @(
    'Install.ps1',
    'Watch-OneDriveApp.ps1',
    'Uninstall.ps1',
    'README.md',
    'CHANGELOG.md',
    'VERSION',
    'tests/Test-Guard.ps1',
    'tools/Build-Release.ps1'
)
$temporaryArchive = $null
try {
    foreach ($relativePath in $manifest) {
        $sourcePath = Join-Path $projectRoot $relativePath
        Assert-PlainPath $sourcePath
        if (-not [IO.File]::Exists($sourcePath)) { throw "Missing release file: $relativePath" }
    }
    $version = ([IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION'))).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
        throw 'VERSION must contain a version such as 0.1.0 or 0.1.0-beta.1.'
    }
    Assert-PlainPath $outputDirectory
    [void][IO.Directory]::CreateDirectory($outputDirectory)
    $archiveName = "onedrivePhotoBlock-v$version.zip"
    $archivePath = Join-Path $outputDirectory $archiveName
    $checksumPath = "$archivePath.sha256"
    Assert-PlainPath $archivePath
    Assert-PlainPath $checksumPath
    $temporaryArchive = Join-Path $outputDirectory ([guid]::NewGuid().ToString('N') + '.tmp')

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [IO.File]::Open($temporaryArchive, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($relativePath in $manifest) {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,
                    (Join-Path $projectRoot $relativePath), $relativePath, [IO.Compression.CompressionLevel]::Optimal)
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }

    # Resolve and constrain both paths before replacing this generated archive.
    $outputPrefix = [IO.Path]::GetFullPath($outputDirectory).TrimEnd('\') + '\'
    foreach ($candidatePath in @($temporaryArchive, $archivePath)) {
        if (-not [IO.Path]::GetFullPath($candidatePath).StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Archive path escaped the build output directory.'
        }
    }
    Move-Item -LiteralPath $temporaryArchive -Destination $archivePath -Force
    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($checksumPath, "$hash  $archiveName" + [Environment]::NewLine, $encoding)
    Write-Output "Built: $archivePath"
    Write-Output "SHA256: $hash"
    Write-Output "Checksum file: $checksumPath"
    Write-Output "Files packaged: $($manifest.Count)"
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
finally {
    if ($temporaryArchive -and [IO.File]::Exists($temporaryArchive)) {
        [IO.File]::Delete($temporaryArchive)
    }
}
