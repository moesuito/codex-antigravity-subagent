[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkspaceBase64,
    [Parameter(Mandatory = $true)][string]$OriginalTaskBase64,
    [Parameter(Mandatory = $true)][string]$FailureReasonBase64,
    [string]$AcceptanceCriteriaBase64,
    [string]$VerifiedWorkBase64,
    [string]$RemainingWorkBase64,
    [string]$TestResultsBase64,
    [string]$SessionKeysBase64,
    [string]$StateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Decode([string]$Value) {
    if (-not $Value) { return '' }
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}

function Limit([string]$Value, [int]$Maximum = 8000) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Not provided; inspect and verify directly.' }
    if ($Value.Length -le $Maximum) { return $Value.Trim() }
    return $Value.Substring(0, $Maximum).Trim() + "`n[truncated by handoff builder]"
}

$workspaceInput = Decode $WorkspaceBase64
if (-not [System.IO.Path]::IsPathFullyQualified($workspaceInput)) { throw 'Workspace must be absolute.' }
$workspace = [System.IO.Path]::GetFullPath($workspaceInput).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $workspace -PathType Container)) { throw "Workspace does not exist: $workspace" }
$sessionKeys = @()
if ($SessionKeysBase64) {
    try {
        $decodedKeys = Decode $SessionKeysBase64 | ConvertFrom-Json
        $sessionKeys = @($decodedKeys | Where-Object { $_ -is [string] -and $_ -match '^[0-9a-fA-F-]{36}$' })
    }
    catch { throw 'SessionKeysBase64 must contain a JSON array of session UUIDs.' }
}

$isGit = $false
$gitStatus = 'Not a Git workspace.'
$gitDiffStat = 'Not a Git workspace.'
$gitChangedFiles = 'Not a Git workspace.'
try {
    & git -C $workspace rev-parse --is-inside-work-tree *> $null
    $isGit = $LASTEXITCODE -eq 0
}
catch { $isGit = $false }
if ($isGit) {
    $gitStatus = ((& git -C $workspace status --short 2>&1) -join "`n").Trim()
    if (-not $gitStatus) { $gitStatus = '(clean)' }
    $gitDiffStat = ((& git -C $workspace diff --stat 2>&1) -join "`n").Trim()
    if (-not $gitDiffStat) { $gitDiffStat = '(no unstaged diff stat)' }
    $gitChangedFiles = ((& git -C $workspace diff --name-only 2>&1) -join "`n").Trim()
    if (-not $gitChangedFiles) { $gitChangedFiles = '(no unstaged changed files)' }
}

$conversationSummaries = [System.Collections.Generic.List[string]]::new()
if ($sessionKeys.Count) {
    foreach ($key in $sessionKeys) {
        try {
            $arguments = @{ SessionKey = $key; IncludeContent = $false }
            if ($StateRoot) { $arguments.StateRoot = $StateRoot }
            $status = & (Join-Path $PSScriptRoot 'get-session-status.ps1') @arguments | ConvertFrom-Json
            $conversationSummaries.Add(
                "- session=$key conversation=$($status.conversationId) status=$($status.status) phase=$($status.phase) health=$($status.health) lastStep=$($status.lastStep)"
            )
        }
        catch {
            $conversationSummaries.Add("- session=$key status=unavailable")
        }
    }
}
if (-not $conversationSummaries.Count) { $conversationSummaries.Add('- No prior session metadata was available.') }

$originalTask = Limit (Decode $OriginalTaskBase64)
$failureReason = Limit (Decode $FailureReasonBase64) 4000
$acceptance = Limit (Decode $AcceptanceCriteriaBase64)
$verified = Limit (Decode $VerifiedWorkBase64)
$remaining = Limit (Decode $RemainingWorkBase64)
$tests = Limit (Decode $TestResultsBase64)
$conversationText = $conversationSummaries -join "`n"

$prompt = @"
You are continuing a coding task after a previous Antigravity conversation became unreliable or stalled.

## Original goal
$originalTask

## Acceptance criteria
$acceptance

## Workspace facts
- Workspace: $workspace
- This handoff is advisory. Inspect the filesystem and repository before trusting any claim below.
- Do not repeat work that is already present and correct.

## Verified completed work
$verified

## Unverified or remaining work
$remaining

## Tests and observed results
$tests

## Failure diagnosis
$failureReason

## Git status
$(Limit $gitStatus)

## Diff summary
$(Limit $gitDiffStat)

## Changed files
$(Limit $gitChangedFiles)

## Prior conversations
$conversationText

## Required continuation protocol
1. Inspect the current workspace, relevant instructions, and diff before editing.
2. Reconstruct the actual state from files and test output; do not rely on unverified claims from the prior conversation.
3. Continue the original task in place, preserving correct existing work.
4. Run proportionate verification and report concrete files, commands, and remaining risks.
"@

[ordered]@{
    schemaVersion = 1
    workspace = $workspace
    prompt = $prompt.Trim()
    promptBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($prompt.Trim()))
    priorSessions = @($sessionKeys)
    gitWorkspace = $isGit
} | ConvertTo-Json -Depth 6
