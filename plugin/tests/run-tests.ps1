[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0

function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -ceq $Expected) {
        $script:Passed++
        Write-Output "PASS $Name"
    }
    else {
        $script:Failed++
        Write-Output "FAIL $Name expected=[$Expected] actual=[$Actual]"
    }
}

function Assert-True([bool]$Condition, [string]$Name) {
    Assert-Equal $Condition $true $Name
}

function Encode([string]$Value) {
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function Write-Json([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Set-Content -LiteralPath $Path -Value ($Value | ConvertTo-Json -Depth 12) -Encoding utf8NoBOM
}

function Write-JsonLines([string]$Path, [object[]]$Values) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lines = $Values | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 12 }
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8NoBOM
}

$pluginRoot = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $pluginRoot 'scripts'
$observer = Join-Path $pluginRoot 'assets\antigravity-observer\scripts\observer-hook.mjs'
$statusScript = Join-Path $scripts 'get-session-status.ps1'
$signalScript = Join-Path $scripts 'record-session-signal.ps1'
$handoffScript = Join-Path $scripts 'build-recovery-handoff.ps1'
$launchScript = Join-Path $scripts 'launch-agy.ps1'
$temporaryRoot = Join-Path $env:TEMP "antigravity-subagent-tests-$([guid]::NewGuid().ToString('N'))"
$temporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null

try {
    # Observer allowlist and passive responses.
    $sessionKey = [guid]::NewGuid().ToString()
    $stateRoot = Join-Path $temporaryRoot 'state'
    $sessionDirectory = Join-Path $stateRoot "sessions\$sessionKey"
    New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null
    $oldSessionId = $env:CODEX_AGY_SESSION_ID
    $oldStateDir = $env:CODEX_AGY_STATE_DIR
    $env:CODEX_AGY_SESSION_ID = $sessionKey
    $env:CODEX_AGY_STATE_DIR = $sessionDirectory

    $transcriptPath = Join-Path $temporaryRoot 'brain\conversation\.system_generated\logs\transcript.jsonl'
    $sensitive = 'SENSITIVE_FIXTURE_TEXT_MUST_NOT_BE_RECORDED'
    $preInput = [ordered]@{
        conversationId = '11111111-1111-1111-1111-111111111111'
        workspacePaths = @($temporaryRoot)
        transcriptPath = $transcriptPath
        artifactDirectoryPath = (Split-Path -Parent (Split-Path -Parent $transcriptPath))
        invocationNum = 0
        initialNumSteps = 1
        prompt = $sensitive
        toolCall = @{ name = 'run_command'; args = @{ CommandLine = $sensitive } }
    } | ConvertTo-Json -Compress -Depth 8
    $preResponse = $preInput | & node $observer PreInvocation
    $preObject = $preResponse | ConvertFrom-Json
    Assert-Equal (($preObject.PSObject.Properties | Measure-Object).Count) 0 'observer pre-invocation is passive'

    $stopInput = [ordered]@{
        conversationId = '11111111-1111-1111-1111-111111111111'
        workspacePaths = @($temporaryRoot)
        transcriptPath = $transcriptPath
        artifactDirectoryPath = (Split-Path -Parent (Split-Path -Parent $transcriptPath))
        executionNum = 1
        terminationReason = 'model_stop'
        error = ''
        fullyIdle = $true
    } | ConvertTo-Json -Compress -Depth 8
    $stopResponse = $stopInput | & node $observer Stop | ConvertFrom-Json
    Assert-Equal $stopResponse.decision 'stop' 'observer stop allows termination'
    $postToolInput = [ordered]@{
        conversationId = '11111111-1111-1111-1111-111111111111'
        workspacePaths = @($temporaryRoot)
        transcriptPath = $transcriptPath
        artifactDirectoryPath = (Split-Path -Parent (Split-Path -Parent $transcriptPath))
        stepIdx = 3
        error = ''
    } | ConvertTo-Json -Compress -Depth 8
    $postToolInput | & node $observer PostToolUse | Out-Null
    $eventsRaw = Get-Content -LiteralPath (Join-Path $sessionDirectory 'events.jsonl') -Raw
    Assert-True (-not $eventsRaw.Contains($sensitive)) 'observer omits prompt and tool arguments'

    if ($null -eq $oldSessionId) { Remove-Item Env:CODEX_AGY_SESSION_ID -ErrorAction SilentlyContinue }
    else { $env:CODEX_AGY_SESSION_ID = $oldSessionId }
    if ($null -eq $oldStateDir) { Remove-Item Env:CODEX_AGY_STATE_DIR -ErrorAction SilentlyContinue }
    else { $env:CODEX_AGY_STATE_DIR = $oldStateDir }

    # Completed status with final response.
    $now = [DateTimeOffset]::UtcNow
    Write-Json (Join-Path $sessionDirectory 'metadata.json') ([ordered]@{
        schemaVersion = 1; sessionKey = $sessionKey; workspace = $temporaryRoot
        launcherPid = 999999; model = 'Gemini 3.5 Flash (High)'; mode = 'accept-edits'
        autonomy = 'full-machine'; startedAt = $now.AddSeconds(-10).ToString('o')
        updatedAt = $now.AddSeconds(-10).ToString('o'); endedAt = $null
        exitCode = $null; launcherState = 'running'; logPath = (Join-Path $sessionDirectory 'agy.log')
    })
    Write-JsonLines $transcriptPath @(
        [ordered]@{ step_index = 0; type = 'USER_INPUT'; status = 'DONE'; created_at = $now.AddSeconds(-8).ToString('o'); content = 'hidden' },
        [ordered]@{ step_index = 1; type = 'PLANNER_RESPONSE'; status = 'DONE'; created_at = $now.AddSeconds(-4).ToString('o'); content = 'OK' }
    )
    $status = & $statusScript -SessionKey $sessionKey -StateRoot $stateRoot -Now $now -IncludeContent -NoWriteHealth | ConvertFrom-Json
    Assert-Equal $status.status 'completed' 'completed status requires Stop fullyIdle'
    Assert-True ($status.evidence -contains 'hook:Stop') 'Stop remains current after trailing PostToolUse'
    Assert-Equal $status.phase 'idle' 'completed phase is idle'
    Assert-Equal $status.finalResponse 'OK' 'final response follows latest user input'

    # A follow-up instruction must reopen the same live session before
    # Antigravity has emitted its next PreInvocation hook.
    Write-JsonLines (Join-Path $sessionDirectory 'signals.jsonl') @(
        [ordered]@{
            schemaVersion = 1; sessionKey = $sessionKey; kind = 'turn_submitted'
            observedAt = $now.AddSeconds(1).ToString('o'); conversationId = $null
            note = 'Codex review delta submitted'
        }
    )
    $followUpStatus = & $statusScript -SessionKey $sessionKey -StateRoot $stateRoot -Now $now.AddSeconds(2) -NoWriteHealth | ConvertFrom-Json
    Assert-Equal $followUpStatus.status 'running' 'turn_submitted reopens completed turn'
    Assert-Equal $followUpStatus.phase 'thinking' 'turn_submitted phase is thinking'

    # Deterministic suspected/stalled classifications.
    foreach ($case in @(
        @{ Age = 360; Expected = 'suspected_stall' },
        @{ Age = 1200; Expected = 'stalled' }
    )) {
        $caseKey = [guid]::NewGuid().ToString()
        $caseDirectory = Join-Path $stateRoot "sessions\$caseKey"
        $old = $now.AddSeconds(-1 * $case.Age)
        Write-Json (Join-Path $caseDirectory 'metadata.json') ([ordered]@{
            schemaVersion = 1; sessionKey = $caseKey; workspace = $temporaryRoot
            launcherPid = 999998; model = 'Gemini 3.5 Flash (High)'; mode = 'accept-edits'
            autonomy = 'full-machine'; startedAt = $old.ToString('o'); updatedAt = $old.ToString('o')
            endedAt = $null; exitCode = $null; launcherState = 'running'; logPath = (Join-Path $caseDirectory 'missing.log')
        })
        Write-JsonLines (Join-Path $caseDirectory 'events.jsonl') @(
            [ordered]@{ eventType = 'PreInvocation'; observedAt = $old.ToString('o'); conversationId = $null; transcriptPath = $null }
        )
        $caseStatus = & $statusScript -SessionKey $caseKey -StateRoot $stateRoot -Now $now -NoWriteHealth | ConvertFrom-Json
        Assert-Equal $caseStatus.health $case.Expected "health $($case.Expected)"
    }

    # Awaiting-input signal precedence.
    $awaitKey = [guid]::NewGuid().ToString()
    $awaitDirectory = Join-Path $stateRoot "sessions\$awaitKey"
    Write-Json (Join-Path $awaitDirectory 'metadata.json') ([ordered]@{
        schemaVersion = 1; sessionKey = $awaitKey; workspace = $temporaryRoot
        launcherPid = 999997; model = 'Gemini 3.5 Flash (High)'; mode = 'accept-edits'
        autonomy = 'full-machine'; startedAt = $now.ToString('o'); updatedAt = $now.ToString('o')
        endedAt = $null; exitCode = $null; launcherState = 'running'; logPath = (Join-Path $awaitDirectory 'missing.log')
    })
    & $signalScript -SessionKey $awaitKey -Kind auth_required -StateRoot $stateRoot | Out-Null
    $awaitStatus = & $statusScript -SessionKey $awaitKey -StateRoot $stateRoot -Now ([DateTimeOffset]::UtcNow) -NoWriteHealth | ConvertFrom-Json
    Assert-Equal $awaitStatus.status 'awaiting_input' 'auth signal has status precedence'

    # Recovery handoff includes evidence and is round-trippable.
    $handoff = & $handoffScript `
        -WorkspaceBase64 (Encode $temporaryRoot) `
        -OriginalTaskBase64 (Encode 'Implement feature X') `
        -FailureReasonBase64 (Encode 'The prior agent contradicted the filesystem') `
        -AcceptanceCriteriaBase64 (Encode 'Tests pass') `
        -VerifiedWorkBase64 (Encode 'File A exists') `
        -RemainingWorkBase64 (Encode 'Finish file B') `
        -TestResultsBase64 (Encode 'Test Y failed') `
        -SessionKeysBase64 (Encode (@($sessionKey) | ConvertTo-Json -Compress)) `
        -StateRoot $stateRoot | ConvertFrom-Json
    Assert-True $handoff.prompt.Contains('Implement feature X') 'handoff contains original goal'
    Assert-True ($handoff.prompt -match '(?i)inspect the filesystem') 'handoff distrusts prior claims'
    Assert-Equal ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($handoff.promptBase64))) $handoff.prompt 'handoff Base64 round trip'

    # Exclusive workspace lock and cleanup after process exit.
    $lockState = Join-Path $temporaryRoot 'lock-state'
    $workspace = Join-Path $temporaryRoot 'workspace'
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    $whereExe = Join-Path $env:WINDIR 'System32\where.exe'
    $firstOut = Join-Path $temporaryRoot 'first.out'
    $firstErr = Join-Path $temporaryRoot 'first.err'
    $commonArgs = @(
        '-NoProfile', '-File', $launchScript,
        '-WorkspaceBase64', (Encode $workspace),
        '-PromptBase64', (Encode 'lock test'),
        '-Mode', 'plan', '-ModelTier', 'High',
        '-StateRoot', $lockState,
        '-AgyPathOverride', $whereExe
    )
    $first = Start-Process -FilePath 'pwsh' -ArgumentList ($commonArgs + @('-TestHoldSeconds', '3')) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $firstOut -RedirectStandardError $firstErr
    $lockFound = $false
    for ($i = 0; $i -lt 30; $i++) {
        if (Get-ChildItem -LiteralPath (Join-Path $lockState 'locks') -Filter '*.lock' -File -ErrorAction SilentlyContinue) {
            $lockFound = $true; break
        }
        Start-Sleep -Milliseconds 100
    }
    Assert-True $lockFound 'first launcher holds workspace lock'
    & pwsh @commonArgs *> $null
    Assert-Equal $LASTEXITCODE 73 'second launcher is rejected for same workspace'
    if (-not $first.WaitForExit(10000)) { Stop-Process -Id $first.Id -Force }
    Start-Sleep -Milliseconds 200
    $remainingLocks = @(Get-ChildItem -LiteralPath (Join-Path $lockState 'locks') -Filter '*.lock' -File -ErrorAction SilentlyContinue)
    Assert-Equal $remainingLocks.Count 0 'launcher releases workspace lock on exit'
}
finally {
    if ($temporaryRoot.StartsWith([IO.Path]::GetFullPath($env:TEMP), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output "RESULT passed=$script:Passed failed=$script:Failed"
if ($script:Failed -gt 0) { exit 1 }
