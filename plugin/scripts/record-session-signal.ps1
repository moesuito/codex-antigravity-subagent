[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SessionKey,

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'terminal_output',
        'turn_submitted',
        'ready',
        'auth_required',
        'trust_required',
        'awaiting_input',
        'recovery_started',
        'recovery_prompt_sent',
        'new_conversation',
        'hallucination_detected',
        'exited'
    )]
    [string]$Kind,

    [string]$ConversationId,
    [string]$Note,
    [string]$StateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $StateRoot) {
    $StateRoot = if ($env:CODEX_AGY_STATE_ROOT) {
        $env:CODEX_AGY_STATE_ROOT
    }
    else {
        Join-Path $env:LOCALAPPDATA 'Codex\antigravity-subagent'
    }
}

$sessionDirectory = Join-Path ([System.IO.Path]::GetFullPath($StateRoot)) "sessions\$SessionKey"
if (-not (Test-Path -LiteralPath $sessionDirectory -PathType Container)) {
    throw "Unknown Antigravity session: $SessionKey"
}

if ($Note) {
    $Note = ($Note -replace '[\r\n]+', ' ').Trim()
    if ($Note.Length -gt 256) {
        $Note = $Note.Substring(0, 256)
    }
}

$record = [ordered]@{
    schemaVersion  = 1
    sessionKey     = $SessionKey
    kind           = $Kind
    observedAt     = [DateTimeOffset]::UtcNow.ToString('o')
    conversationId = if ($ConversationId) { $ConversationId } else { $null }
    note           = if ($Note) { $Note } else { $null }
}

$jsonLine = ($record | ConvertTo-Json -Compress) + [Environment]::NewLine
$bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($jsonLine)
$signalsPath = Join-Path $sessionDirectory 'signals.jsonl'
$stream = [System.IO.File]::Open(
    $signalsPath,
    [System.IO.FileMode]::Append,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::ReadWrite
)
try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
}
finally {
    $stream.Dispose()
}

$record | ConvertTo-Json -Depth 5
