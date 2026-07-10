[CmdletBinding()]
param(
    [string]$Repository = 'moesuito/codex-antigravity-subagent',
    [string]$ReleaseTag,
    [string]$HomePath = $HOME,
    [switch]$SkipCodexPluginInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($temporaryPath, ($Value | ConvertTo-Json -Depth 20), $encoding)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Ensure-Property {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $Object.$Name = $Value
    }
}

function Install-Directory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (Test-Path -LiteralPath $Destination) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
        $backup = Join-Path $BackupRoot (Split-Path -Leaf $Destination)
        Move-Item -LiteralPath $Destination -Destination $backup -Force
        Write-Host "Backed up $Destination to $backup"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

if (-not (Test-Path -LiteralPath $HomePath -PathType Container)) {
    throw "Home path does not exist: $HomePath"
}
$HomePath = [System.IO.Path]::GetFullPath($HomePath)

$releaseApi = if ($ReleaseTag) {
    "https://api.github.com/repos/$Repository/releases/tags/$ReleaseTag"
}
else {
    "https://api.github.com/repos/$Repository/releases/latest"
}
$release = Invoke-RestMethod -Uri $releaseApi -Headers @{ Accept = 'application/vnd.github+json' }
$asset = @($release.assets | Where-Object { $_.name -eq 'codex-antigravity-subagent.zip' } | Select-Object -First 1)
if (-not $asset) {
    throw "Release $($release.tag_name) does not contain codex-antigravity-subagent.zip."
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codex-antigravity-subagent-$([guid]::NewGuid().ToString('N'))"
$archivePath = Join-Path $temporaryRoot 'release.zip'
$expandedPath = Join-Path $temporaryRoot 'expanded'
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null

try {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archivePath
    Expand-Archive -LiteralPath $archivePath -DestinationPath $expandedPath -Force

    $pluginSource = Join-Path $expandedPath 'plugin'
    if (-not (Test-Path -LiteralPath (Join-Path $pluginSource '.codex-plugin\plugin.json') -PathType Leaf)) {
        throw 'Release asset is missing plugin/.codex-plugin/plugin.json.'
    }

    $backupRoot = Join-Path $HomePath ".codex\antigravity-subagent-backups\$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    $pluginDestination = Join-Path $HomePath 'plugins\antigravity-subagent'
    Install-Directory -Source $pluginSource -Destination $pluginDestination -BackupRoot $backupRoot

    $marketplacePath = Join-Path $HomePath '.agents\plugins\marketplace.json'
    $marketplaceDirectory = Split-Path -Parent $marketplacePath
    New-Item -ItemType Directory -Path $marketplaceDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $marketplacePath -PathType Leaf) {
        $marketplace = Get-Content -LiteralPath $marketplacePath -Raw | ConvertFrom-Json
    }
    else {
        $marketplace = [pscustomobject]@{
            name = 'personal'
            interface = [pscustomobject]@{ displayName = 'Personal' }
            plugins = @()
        }
    }
    Ensure-Property -Object $marketplace -Name 'name' -Value 'personal'
    if (-not $marketplace.interface) {
        Ensure-Property -Object $marketplace -Name 'interface' -Value ([pscustomobject]@{ displayName = 'Personal' })
    }
    if (-not $marketplace.interface.displayName) {
        Ensure-Property -Object $marketplace.interface -Name 'displayName' -Value 'Personal'
    }
    $entry = [pscustomobject]@{
        name = 'antigravity-subagent'
        source = [pscustomobject]@{
            source = 'local'
            path = './plugins/antigravity-subagent'
        }
        policy = [pscustomobject]@{
            installation = 'AVAILABLE'
            authentication = 'ON_INSTALL'
        }
        category = 'Productivity'
    }
    $existing = @($marketplace.plugins | Where-Object { $_.name -ne 'antigravity-subagent' })
    Ensure-Property -Object $marketplace -Name 'plugins' -Value @($existing + $entry)
    Write-JsonAtomic -Path $marketplacePath -Value $marketplace

    if (-not $SkipCodexPluginInstall) {
        $codex = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $codex) {
            throw 'Codex CLI was not found. Install Codex, then rerun this installer.'
        }
        $marketplaceName = [string]$marketplace.name
        & $codex.Source plugin add "antigravity-subagent@$marketplaceName"
        if ($LASTEXITCODE -ne 0) {
            throw "codex plugin add failed with exit code $LASTEXITCODE."
        }
    }

    if (-not (Get-Command agy -ErrorAction SilentlyContinue)) {
        Write-Warning 'agy was not found on PATH. Install and sign in to Antigravity CLI before delegating work.'
    }
    Write-Host "Installed release $($release.tag_name). Start a new Codex task before using the plugin."
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
