[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceBase64,

    [Parameter(Mandatory = $true)]
    [string]$PromptBase64,

    [ValidateSet('accept-edits', 'plan')]
    [string]$Mode = 'accept-edits',

    [ValidateSet('High', 'Medium', 'Low')]
    [string]$ModelTier = 'High',

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SessionKey,

    [string]$StateRoot,

    # Test-only escape hatch. Production callers must let the script resolve agy.
    [string]$AgyPathOverride,

    # Test-only lock hold. Production callers must leave this at zero.
    [ValidateRange(0, 30)]
    [int]$TestHoldSeconds = 0,

    # Agy otherwise falls back to its global scratch project when this directory
    # has not been registered as an Antigravity project yet.
    [switch]$NewProject
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function ConvertFrom-Base64Utf8 {
    param([Parameter(Mandatory = $true)][string]$Value)
    try {
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
    }
    catch {
        throw 'The supplied Base64 value is not valid UTF-8 data.'
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8NoBom)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Resolve-AgyPath {
    if ($AgyPathOverride) {
        $candidate = [System.IO.Path]::GetFullPath($AgyPathOverride)
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "AgyPathOverride does not exist: $candidate"
        }
        return $candidate
    }

    $command = Get-Command agy.exe, agy -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    $fallback = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
    if (Test-Path -LiteralPath $fallback -PathType Leaf) {
        return $fallback
    }

    throw 'Antigravity CLI was not found. Install agy and ensure it is available on PATH.'
}

$workspaceInput = ConvertFrom-Base64Utf8 -Value $WorkspaceBase64
$prompt = ConvertFrom-Base64Utf8 -Value $PromptBase64
if ([string]::IsNullOrWhiteSpace($prompt)) {
    throw 'The Antigravity task prompt cannot be empty.'
}
if (-not [System.IO.Path]::IsPathFullyQualified($workspaceInput)) {
    throw 'Workspace must be an absolute path.'
}

$workspace = [System.IO.Path]::GetFullPath($workspaceInput).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
    throw "Workspace does not exist: $workspace"
}

if (-not $SessionKey) {
    $SessionKey = [guid]::NewGuid().ToString()
}

if (-not $StateRoot) {
    $StateRoot = if ($env:CODEX_AGY_STATE_ROOT) {
        $env:CODEX_AGY_STATE_ROOT
    }
    else {
        Join-Path $env:LOCALAPPDATA 'Codex\antigravity-subagent'
    }
}
$StateRoot = [System.IO.Path]::GetFullPath($StateRoot)
$sessionsRoot = Join-Path $StateRoot 'sessions'
$locksRoot = Join-Path $StateRoot 'locks'
$sessionDirectory = Join-Path $sessionsRoot $SessionKey
New-Item -ItemType Directory -Path $sessionDirectory, $locksRoot -Force | Out-Null

$normalizedWorkspace = $workspace.ToLowerInvariant()
$hashBytes = [System.Security.Cryptography.SHA256]::HashData(
    [System.Text.Encoding]::UTF8.GetBytes($normalizedWorkspace)
)
$workspaceHash = [System.Convert]::ToHexString($hashBytes).ToLowerInvariant()
$lockPath = Join-Path $locksRoot "$workspaceHash.lock"
$lockStream = $null

try {
    $lockStream = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
}
catch [System.IO.IOException] {
    [Console]::Error.WriteLine("An Antigravity session is already active for workspace: $workspace")
    exit 73
}

$startedAt = [DateTimeOffset]::UtcNow.ToString('o')
$agyPath = Resolve-AgyPath
$logPath = Join-Path $sessionDirectory 'agy.log'
$metadataPath = Join-Path $sessionDirectory 'metadata.json'
$metadata = [ordered]@{
    schemaVersion       = 1
    sessionKey          = $SessionKey
    workspace           = $workspace
    normalizedWorkspace = $normalizedWorkspace
    workspaceHash       = $workspaceHash
    launcherPid         = $PID
    agyPath             = $agyPath
    model               = "Gemini 3.5 Flash ($ModelTier)"
    mode                = $Mode
    autonomy            = 'full-machine'
    startedAt           = $startedAt
    updatedAt           = $startedAt
    endedAt             = $null
    exitCode            = $null
    launcherState       = 'running'
    logPath             = $logPath
}
$previousSessionId = $env:CODEX_AGY_SESSION_ID
$previousStateDir = $env:CODEX_AGY_STATE_DIR
$previousWorkspace = $env:CODEX_AGY_WORKSPACE
$processExitCode = 1

try {
    $lockPayload = $utf8NoBom.GetBytes((@{
        sessionKey  = $SessionKey
        workspace   = $workspace
        launcherPid = $PID
        startedAt   = $startedAt
    } | ConvertTo-Json -Compress))
    $lockStream.SetLength(0)
    $lockStream.Write($lockPayload, 0, $lockPayload.Length)
    $lockStream.Flush($true)
    Write-JsonAtomic -Path $metadataPath -Value $metadata

    $env:CODEX_AGY_SESSION_ID = $SessionKey
    $env:CODEX_AGY_STATE_DIR = $sessionDirectory
    $env:CODEX_AGY_WORKSPACE = $workspace

    Write-Output "CODEX_AGY_SESSION_KEY=$SessionKey"
    Write-Output "CODEX_AGY_WORKSPACE=$workspace"
    Write-Output "CODEX_AGY_LOG_FILE=$logPath"
    Write-Output 'CODEX_AGY_AUTONOMY=full-machine'

    if ($TestHoldSeconds -gt 0) {
        Start-Sleep -Seconds $TestHoldSeconds
    }

    $agyArguments = @(
        '--new-project',
        '--mode', $Mode,
        '--dangerously-skip-permissions',
        '--model', "Gemini 3.5 Flash ($ModelTier)",
        '--log-file', $logPath,
        '-i', $prompt
    )

    Set-Location -LiteralPath $workspace
    if ([System.IO.Path]::GetExtension($agyPath) -ieq '.ps1') {
        & (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -File $agyPath @agyArguments
    }
    else {
        & $agyPath @agyArguments
    }
    $processExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $metadata.exitCode = $processExitCode
    $metadata.launcherState = if ($processExitCode -eq 0) { 'exited' } else { 'failed' }
    exit $processExitCode
}
finally {
    $endedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $metadata.endedAt = $endedAt
    $metadata.updatedAt = $endedAt
    if ($null -eq $metadata.exitCode) {
        $metadata.exitCode = $processExitCode
        $metadata.launcherState = 'failed'
    }
    try { Write-JsonAtomic -Path $metadataPath -Value $metadata } catch {}

    if ($null -eq $previousSessionId) { Remove-Item Env:CODEX_AGY_SESSION_ID -ErrorAction SilentlyContinue }
    else { $env:CODEX_AGY_SESSION_ID = $previousSessionId }
    if ($null -eq $previousStateDir) { Remove-Item Env:CODEX_AGY_STATE_DIR -ErrorAction SilentlyContinue }
    else { $env:CODEX_AGY_STATE_DIR = $previousStateDir }
    if ($null -eq $previousWorkspace) { Remove-Item Env:CODEX_AGY_WORKSPACE -ErrorAction SilentlyContinue }
    else { $env:CODEX_AGY_WORKSPACE = $previousWorkspace }

    if ($lockStream) {
        $lockStream.Dispose()
    }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
