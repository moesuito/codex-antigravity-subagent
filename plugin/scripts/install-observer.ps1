[CmdletBinding()]
param(
    [string]$PluginRoot,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PluginRoot) {
    $PluginRoot = Split-Path -Parent $PSScriptRoot
}
$PluginRoot = [System.IO.Path]::GetFullPath($PluginRoot)
$source = Join-Path $PluginRoot 'assets\antigravity-observer'
$sourceManifestPath = Join-Path $source 'plugin.json'
if (-not (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) {
    throw "Observer source is missing: $source"
}

$agyCommand = Get-Command agy.exe, agy -ErrorAction SilentlyContinue | Select-Object -First 1
$agyPath = if ($agyCommand) { $agyCommand.Source } else { Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe' }
if (-not (Test-Path -LiteralPath $agyPath -PathType Leaf)) {
    throw 'Antigravity CLI was not found.'
}

$validationOutput = & $agyPath plugin validate $source 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Antigravity rejected the observer plugin: $($validationOutput -join [Environment]::NewLine)"
}

$sourceManifest = Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json
$installedCandidates = @(
    (Join-Path $env:USERPROFILE '.gemini\config\plugins\codex-antigravity-observer'),
    (Join-Path $env:USERPROFILE '.gemini\antigravity-cli\plugins\codex-antigravity-observer')
)
$installedRoot = $installedCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
if (-not $installedRoot) { $installedRoot = $installedCandidates[0] }
$installedManifestPath = Join-Path $installedRoot 'plugin.json'
$installedHookPath = Join-Path $installedRoot 'scripts\observer-hook.mjs'
$action = 'installed'

if (Test-Path -LiteralPath $installedRoot -PathType Container) {
    if (-not (Test-Path -LiteralPath $installedHookPath -PathType Leaf)) {
        throw "A different plugin already occupies the observer name: $installedRoot"
    }

    $installedManifest = if (Test-Path -LiteralPath $installedManifestPath -PathType Leaf) {
        Get-Content -LiteralPath $installedManifestPath -Raw | ConvertFrom-Json
    }
    else { $null }

    $sourceFiles = @('plugin.json', 'hooks.json', 'scripts\observer-hook.mjs')
    $filesMatch = $true
    foreach ($relativePath in $sourceFiles) {
        $sourceFile = Join-Path $source $relativePath
        $installedFile = Join-Path $installedRoot $relativePath
        if (-not (Test-Path -LiteralPath $installedFile -PathType Leaf) -or
            (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $installedFile -Algorithm SHA256).Hash) {
            $filesMatch = $false
            break
        }
    }

    if (-not $Force -and $installedManifest -and
        $installedManifest.version -eq $sourceManifest.version -and $filesMatch) {
        $action = 'already-current'
    }
    else {
        $uninstallOutput = & $agyPath plugin uninstall codex-antigravity-observer 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not uninstall the previous observer: $($uninstallOutput -join [Environment]::NewLine)"
        }
        $action = 'updated'
    }
}

if ($action -ne 'already-current') {
    $installOutput = & $agyPath plugin install $source 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not install the observer: $($installOutput -join [Environment]::NewLine)"
    }
}

$installedRoot = $installedCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
if (-not $installedRoot) { $installedRoot = $installedCandidates[0] }
$installedHookPath = Join-Path $installedRoot 'scripts\observer-hook.mjs'
if (-not (Test-Path -LiteralPath $installedHookPath -PathType Leaf)) {
    throw "agy reported success, but the observer was not materialized at $installedRoot"
}
$installedItem = Get-Item -LiteralPath $installedRoot -Force
if (($installedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The observer must be installed as a real directory, not a symlink or junction.'
}

[ordered]@{
    observer = 'codex-antigravity-observer'
    version  = $sourceManifest.version
    action   = $action
    source   = $source
    installedPath = $installedRoot
    realDirectory = $true
} | ConvertTo-Json -Depth 5
