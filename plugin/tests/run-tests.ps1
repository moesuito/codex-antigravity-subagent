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
$statusScript = Join-Path $scripts 'get-session-status.ps1'
$handoffScript = Join-Path $scripts 'build-recovery-handoff.ps1'
$brokerScript = Join-Path $scripts 'start-agy-session.mjs'
$temporaryRoot = Join-Path $env:TEMP "antigravity-subagent-tests-$([guid]::NewGuid().ToString('N'))"
$temporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null

try {
    $sessionKey = [guid]::NewGuid().ToString()
    $stateRoot = Join-Path $temporaryRoot 'state'
    $sessionDirectory = Join-Path $stateRoot "sessions\$sessionKey"
    New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null
    $transcriptPath = Join-Path $temporaryRoot 'brain\conversation\.system_generated\logs\transcript.jsonl'

    # Completed status with final response.
    $now = [DateTimeOffset]::UtcNow
    Write-Json (Join-Path $sessionDirectory 'metadata.json') ([ordered]@{
        schemaVersion = 1; sessionKey = $sessionKey; workspace = $temporaryRoot
        launcherPid = $PID; model = 'Gemini 3.5 Flash (High)'; mode = 'accept-edits'
        autonomy = 'full-machine'; startedAt = $now.AddSeconds(-10).ToString('o')
        updatedAt = $now.AddSeconds(-10).ToString('o'); endedAt = $null
        exitCode = $null; launcherState = 'running'; logPath = (Join-Path $sessionDirectory 'agy.log')
    })
    Write-JsonLines $transcriptPath @(
        [ordered]@{ step_index = 0; type = 'USER_INPUT'; status = 'DONE'; created_at = $now.AddSeconds(-8).ToString('o'); content = 'hidden' },
        [ordered]@{ step_index = 1; type = 'PLANNER_RESPONSE'; status = 'DONE'; created_at = $now.AddSeconds(-4).ToString('o'); content = 'OK' }
    )
    Write-JsonLines (Join-Path $sessionDirectory 'events.jsonl') @(
        [ordered]@{ eventType = 'PreInvocation'; observedAt = $now.AddSeconds(-10).ToString('o'); conversationId = $null; transcriptPath = $transcriptPath },
        [ordered]@{ eventType = 'Stop'; observedAt = $now.AddSeconds(-2).ToString('o'); conversationId = $null; fullyIdle = $true; terminationReason = 'model_stop' }
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
            launcherPid = $PID; model = 'Gemini 3.5 Flash (High)'; mode = 'accept-edits'
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
    Write-JsonLines (Join-Path $awaitDirectory 'signals.jsonl') @(
        [ordered]@{
            schemaVersion = 1; sessionKey = $awaitKey; kind = 'auth_required'
            observedAt = $now.ToString('o'); conversationId = $null
        }
    )
    $awaitStatus = & $statusScript -SessionKey $awaitKey -StateRoot $stateRoot -Now ([DateTimeOffset]::UtcNow) -NoWriteHealth | ConvertFrom-Json
    Assert-Equal $awaitStatus.status 'awaiting_input' 'auth signal has status precedence'

    # A broker that disappears without recording a completed Stop must never be
    # presented as a still-running session.
    $deadKey = [guid]::NewGuid().ToString()
    $deadDirectory = Join-Path $stateRoot "sessions\$deadKey"
    Write-Json (Join-Path $deadDirectory 'metadata.json') ([ordered]@{
        schemaVersion = 1; sessionKey = $deadKey; workspace = $temporaryRoot
        launcherPid = 999996; model = 'Gemini 3.5 Flash (High)'; mode = 'accept-edits'
        autonomy = 'full-machine'; startedAt = $now.ToString('o'); updatedAt = $now.ToString('o')
        endedAt = $null; exitCode = $null; launcherState = 'running'; logPath = (Join-Path $deadDirectory 'missing.log')
    })
    Write-JsonLines (Join-Path $deadDirectory 'events.jsonl') @(
        [ordered]@{ eventType = 'PreInvocation'; observedAt = $now.ToString('o'); conversationId = $null; transcriptPath = $null }
    )
    $deadStatus = & $statusScript -SessionKey $deadKey -StateRoot $stateRoot -Now $now -NoWriteHealth | ConvertFrom-Json
    Assert-Equal $deadStatus.status 'failed' 'dead broker without Stop is failed'

    # Legacy v2.1 sessions could record a successful Stop with exit 0 while the
    # final response was empty. Public status must reject that false completion.
    $emptyKey = [guid]::NewGuid().ToString()
    $emptyDirectory = Join-Path $stateRoot "sessions\$emptyKey"
    Write-Json (Join-Path $emptyDirectory 'metadata.json') ([ordered]@{
        schemaVersion = 1; sessionKey = $emptyKey; workspace = $temporaryRoot
        launcherPid = 999995; model = 'Gemini 3.5 Flash (High)'; mode = 'accept-edits'
        autonomy = 'full-machine'; startedAt = $now.ToString('o'); updatedAt = $now.ToString('o')
        endedAt = $now.ToString('o'); exitCode = 0; brokerExitCode = 0
        launcherState = 'exited'; finalResponse = ''
    })
    Write-JsonLines (Join-Path $emptyDirectory 'events.jsonl') @(
        [ordered]@{ eventType = 'PreInvocation'; observedAt = $now.AddSeconds(-1).ToString('o'); conversationId = $null },
        [ordered]@{ eventType = 'Stop'; observedAt = $now.ToString('o'); conversationId = $null; fullyIdle = $true; terminationReason = 'model_stop' }
    )
    $emptyStatus = & $statusScript -SessionKey $emptyKey -StateRoot $stateRoot -Now $now -IncludeContent -NoWriteHealth | ConvertFrom-Json
    Assert-Equal $emptyStatus.status 'failed' 'empty final response is never completed'
    Assert-Equal $emptyStatus.errorCode 'missing_final_response' 'empty legacy response has explicit error code'

    $legacyErrorKey = [guid]::NewGuid().ToString()
    $legacyErrorDirectory = Join-Path $stateRoot "sessions\$legacyErrorKey"
    Write-Json (Join-Path $legacyErrorDirectory 'metadata.json') ([ordered]@{
        schemaVersion = 1; sessionKey = $legacyErrorKey; workspace = $temporaryRoot
        launcherPid = 999994; startedAt = $now.ToString('o'); updatedAt = $now.ToString('o')
        endedAt = $now.ToString('o'); exitCode = 1; launcherState = 'failed'; finalResponse = ''
    })
    Write-JsonLines (Join-Path $legacyErrorDirectory 'events.jsonl') @(
        [ordered]@{ eventType = 'PreInvocation'; observedAt = $now.AddSeconds(-1).ToString('o'); conversationId = $null },
        [ordered]@{ eventType = 'Stop'; observedAt = $now.ToString('o'); conversationId = $null; fullyIdle = $true; terminationReason = 'error'; error = "unknown sessionId: $legacyErrorKey" }
    )
    $legacyErrorStatus = & $statusScript -SessionKey $legacyErrorKey -StateRoot $stateRoot -Now $now -NoWriteHealth | ConvertFrom-Json
    Assert-Equal $legacyErrorStatus.errorCode 'session_not_resumable' 'legacy unknown session error is normalized'
    Assert-Equal $legacyErrorStatus.recoveryHint 'start_fresh_conversation' 'legacy unknown session has recovery hint'

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
    
    $mockAcpBat = Join-Path $temporaryRoot 'mock-acp.bat'
    $mockContent = '@echo off' + [Environment]::NewLine + 'node -e "const rl = require(''readline'').createInterface({input: process.stdin}); const reply=(m)=>console.log(JSON.stringify(m)); const chunk=(t)=>reply({jsonrpc:''2.0'',method:''session/update'',params:{update:{sessionUpdate:''agent_message_chunk'',content:{type:''text'',text:t}}}}); rl.on(''line'', l => { try { const msg=JSON.parse(l); if(msg.method===''initialize''){reply({jsonrpc:''2.0'',id:msg.id,result:{protocolVersion:1}});} else if(msg.method===''session/new''){reply({jsonrpc:''2.0'',id:msg.id,result:{sessionId:''test-session''}});} else if(msg.method===''session/load''){if([''test-session'',''legacy-acp-session''].includes(msg.params.sessionId)){reply({jsonrpc:''2.0'',id:msg.id,result:{sessionId:msg.params.sessionId}});}else{reply({jsonrpc:''2.0'',id:msg.id,error:{code:-32000,message:''unknown sessionId: ''+msg.params.sessionId}});}} else if(msg.method===''session/setConfigOption''){reply({jsonrpc:''2.0'',id:msg.id,result:{}});} else if(msg.method===''session/prompt''){const task=msg.params.prompt.map(p=>p.text||'''').join('' ''); if(/quota/i.test(task)){reply({jsonrpc:''2.0'',id:msg.id,error:{code:-32000,message:''agy failed: Error: Individual quota reached. Resets in 1h.''}});} else if(/timeout/i.test(task)){reply({jsonrpc:''2.0'',id:msg.id,error:{code:-32000,message:''agy failed: Error: timeout waiting for response''}});} else if(/exit one/i.test(task)){reply({jsonrpc:''2.0'',id:msg.id,error:{code:-32000,message:''agy exited with status: exit code: 1''}});} else if(/missing response/i.test(task)){reply({jsonrpc:''2.0'',id:msg.id,result:{stopReason:''end_turn''}});} else if(/active watchdog/i.test(task)){chunk(''A''); const timer=setInterval(()=>chunk(''A''),400); setTimeout(()=>{clearInterval(timer); reply({jsonrpc:''2.0'',id:msg.id,result:{stopReason:''end_turn''}});},3000);} else {chunk(''PONG''); setTimeout(()=>reply({jsonrpc:''2.0'',id:msg.id,result:{stopReason:''end_turn''}}), /lock test/i.test(task)?3000:50);}} } catch(e){} });"'
    Set-Content -LiteralPath $mockAcpBat -Value $mockContent
    $mockAcpStore = Join-Path $temporaryRoot 'mock-acp-sessions.json'
    Write-Json $mockAcpStore ([ordered]@{
        sessions = [ordered]@{
            'legacy-acp-session' = [ordered]@{ conversation_id = 'legacy-conversation'; last_step_idx = 12; model_id = $null }
        }
    })

    function Invoke-MockBrokerTurn {
        param(
            [Parameter(Mandatory = $true)][string]$Task,
            [string]$ExistingSessionKey,
            [switch]$FastWatchdog
        )
        $info = [System.Diagnostics.ProcessStartInfo]::new()
        $info.FileName = 'node'
        $info.Arguments = $brokerScript
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.UseShellExecute = $false
        $info.EnvironmentVariables['CODEX_AGY_STATE_ROOT'] = $lockState
        $info.EnvironmentVariables['CODEX_AGY_ACP_PATH'] = $mockAcpBat
        $info.EnvironmentVariables['CODEX_AGY_ACP_STORE_PATH'] = $mockAcpStore
        $process = [System.Diagnostics.Process]::Start($info)
        $readyLine = $process.StandardOutput.ReadLine()
        $request = [ordered]@{
            workspace = $workspace; task = $Task; mode = 'plan'; modelTier = 'High'; outputMode = 'silent'
        }
        if ($ExistingSessionKey) { $request.sessionKey = $ExistingSessionKey }
        if ($FastWatchdog) {
            $request.watchdog = @{ passiveCheckSeconds = 1; escalationAfterSeconds = 1; escalationIntervalSeconds = 1 }
        }
        $process.StandardInput.WriteLine(($request | ConvertTo-Json -Compress -Depth 8))
        $process.StandardInput.Flush()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $keyMatch = [regex]::Match($stdout, 'CODEX_AGY_SESSION_KEY=([0-9a-f-]{36})')
        $turnKey = if ($keyMatch.Success) { $keyMatch.Groups[1].Value } else { $ExistingSessionKey }
        $signalMatch = [regex]::Match($stdout, 'CODEX_AGY_TURN_FINISHED=(\{[^\r\n]+\})')
        $signal = if ($signalMatch.Success) { $signalMatch.Groups[1].Value | ConvertFrom-Json } else { $null }
        $turnMetadata = if ($turnKey) {
            Get-Content -Raw (Join-Path $lockState "sessions\$turnKey\metadata.json") | ConvertFrom-Json
        } else { $null }
        return [pscustomobject]@{
            Ready = $readyLine; ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr
            SessionKey = $turnKey; Signal = $signal; Metadata = $turnMetadata
        }
    }

    $pInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $pInfo.FileName = "node"
    $pInfo.Arguments = $brokerScript
    $pInfo.RedirectStandardInput = $true
    $pInfo.RedirectStandardOutput = $true
    $pInfo.RedirectStandardError = $true
    $pInfo.UseShellExecute = $false
    $pInfo.EnvironmentVariables["CODEX_AGY_STATE_ROOT"] = $lockState
    $pInfo.EnvironmentVariables["CODEX_AGY_ACP_PATH"] = $mockAcpBat

    $proc = [System.Diagnostics.Process]::Start($pInfo)
    $ready = $proc.StandardOutput.ReadLine()
    Assert-Equal $ready "CODEX_AGY_REQUEST_READY=1" "broker prints ready line"

    # Validate the requested workspace before creating state or attempting a
    # child spawn, which turns a bad path into an actionable request error.
    $invalidWorkspaceRequest = @{
        workspace = (Join-Path $temporaryRoot 'missing-workspace')
        task = 'invalid workspace test'
        mode = 'plan'
        modelTier = 'High'
    } | ConvertTo-Json -Compress
    $invalidInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $invalidInfo.FileName = 'node'
    $invalidInfo.Arguments = $brokerScript
    $invalidInfo.RedirectStandardInput = $true
    $invalidInfo.RedirectStandardOutput = $true
    $invalidInfo.RedirectStandardError = $true
    $invalidInfo.UseShellExecute = $false
    $invalidInfo.EnvironmentVariables['CODEX_AGY_STATE_ROOT'] = $lockState
    $invalidInfo.EnvironmentVariables['CODEX_AGY_ACP_PATH'] = $mockAcpBat
    $invalidProc = [System.Diagnostics.Process]::Start($invalidInfo)
    [void]$invalidProc.StandardOutput.ReadLine()
    $invalidProc.StandardInput.WriteLine($invalidWorkspaceRequest)
    $invalidProc.StandardInput.Flush()
    $invalidProc.WaitForExit()
    Assert-Equal $invalidProc.ExitCode 2 'broker rejects missing workspace before launch'

    $requestJson = @{
        workspace = $workspace
        task = "lock test"
        mode = "plan"
        modelTier = "High"
        outputMode = "silent"
        watchdog = @{ passiveCheckSeconds = 1; escalationAfterSeconds = 1; escalationIntervalSeconds = 1 }
    } | ConvertTo-Json -Compress

    $proc.StandardInput.WriteLine($requestJson)
    $proc.StandardInput.Flush()

    $lockFound = $false
    for ($i = 0; $i -lt 30; $i++) {
        if (Get-ChildItem -LiteralPath (Join-Path $lockState 'locks') -Filter '*.lock' -File -ErrorAction SilentlyContinue) {
            $lockFound = $true; break
        }
        Start-Sleep -Milliseconds 100
    }
    Assert-True $lockFound 'first launcher holds workspace lock'

    $pInfo2 = [System.Diagnostics.ProcessStartInfo]::new()
    $pInfo2.FileName = "node"
    $pInfo2.Arguments = $brokerScript
    $pInfo2.RedirectStandardInput = $true
    $pInfo2.RedirectStandardOutput = $true
    $pInfo2.RedirectStandardError = $true
    $pInfo2.UseShellExecute = $false
    $pInfo2.EnvironmentVariables["CODEX_AGY_STATE_ROOT"] = $lockState
    $pInfo2.EnvironmentVariables["CODEX_AGY_ACP_PATH"] = $mockAcpBat

    $proc2 = [System.Diagnostics.Process]::Start($pInfo2)
    $ready2 = $proc2.StandardOutput.ReadLine()
    $proc2.StandardInput.WriteLine($requestJson)
    $proc2.StandardInput.Flush()
    $proc2.WaitForExit()
    Assert-Equal $proc2.ExitCode 73 'second launcher is rejected for same workspace'

    $proc.WaitForExit(10000) | Out-Null
    if (-not $proc.HasExited) { $proc.Kill() }
    $brokerOutput = $proc.StandardOutput.ReadToEnd()
    Assert-True ($brokerOutput -match 'CODEX_AGY_TURN_FINISHED') 'silent broker emits one completion signal'
    Assert-True ($brokerOutput -match 'CODEX_AGY_WATCHDOG_REVIEW') 'watchdog escalates after configured threshold'
    Assert-True (-not $brokerOutput.Contains('PONG')) 'silent broker hides streamed worker output'
    $launchedSession = [regex]::Match($brokerOutput, 'CODEX_AGY_SESSION_KEY=([0-9a-f-]{36})').Groups[1].Value
    $brokerMetadata = Get-Content -Raw (Join-Path $lockState "sessions\$launchedSession\metadata.json") | ConvertFrom-Json
    Assert-True (-not [string]::IsNullOrWhiteSpace($brokerMetadata.workerLastActivityAt)) 'worker activity is persisted for watchdog health'
    
    Start-Sleep -Milliseconds 200
    $remainingLocks = @(Get-ChildItem -LiteralPath (Join-Path $lockState 'locks') -Filter '*.lock' -File -ErrorAction SilentlyContinue)
    Assert-Equal $remainingLocks.Count 0 'launcher releases workspace lock on exit'

    # A local sessionKey must map back to the ACP sessionId returned by
    # session/new so a new broker process can load the same worker context.
    $resumeTurn = Invoke-MockBrokerTurn -Task 'follow-up correction' -ExistingSessionKey $launchedSession
    Assert-Equal $resumeTurn.ExitCode 0 'follow-up resumes with the same sessionKey'
    Assert-Equal $resumeTurn.Metadata.acpSessionId 'test-session' 'broker persists real ACP sessionId'
    Assert-Equal $resumeTurn.Signal.status 'completed' 'resumed turn completes normally'

    # Sessions created by v2.1.0 did not store acpSessionId. Recover those by
    # matching the last persisted conversationId (including event history) to
    # the adapter's durable session store.
    $legacyKey = [guid]::NewGuid().ToString()
    Write-Json (Join-Path $lockState "sessions\$legacyKey\metadata.json") ([ordered]@{
        schemaVersion = 1; sessionKey = $legacyKey; workspace = $workspace
        conversationId = $null; startedAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
    })
    Write-JsonLines (Join-Path $lockState "sessions\$legacyKey\events.jsonl") @(
        [ordered]@{ eventType = 'Stop'; observedAt = [DateTimeOffset]::UtcNow.AddSeconds(-30).ToString('o'); conversationId = 'legacy-conversation'; fullyIdle = $true; terminationReason = 'model_stop' }
    )
    $legacyResume = Invoke-MockBrokerTurn -Task 'legacy follow-up correction' -ExistingSessionKey $legacyKey
    Assert-Equal $legacyResume.ExitCode 0 'v2.1 session resumes from conversation history'
    Assert-Equal $legacyResume.Metadata.acpSessionId 'legacy-acp-session' 'legacy session is upgraded with ACP sessionId'

    # Failure classifications must survive all the way through the terminal
    # signal, metadata, and public status helper.
    $quotaTurn = Invoke-MockBrokerTurn -Task 'simulate quota failure'
    Assert-Equal $quotaTurn.ExitCode 1 'quota exits broker nonzero'
    Assert-Equal $quotaTurn.Signal.status 'failed' 'quota completion signal is failed'
    Assert-Equal $quotaTurn.Signal.terminationReason 'quota_exceeded' 'quota has specific termination reason'
    Assert-Equal $quotaTurn.Metadata.errorCode 'quota_exceeded' 'quota metadata is structured'
    Assert-True ($null -eq $quotaTurn.Metadata.finalResponse) 'quota has no final response'
    $quotaStatus = & $statusScript -SessionKey $quotaTurn.SessionKey -StateRoot $lockState -IncludeContent | ConvertFrom-Json
    Assert-Equal $quotaStatus.status 'failed' 'quota public status is failed'
    Assert-Equal $quotaStatus.recoveryHint 'wait_for_quota_reset' 'quota recovery hint is actionable'

    $timeoutTurn = Invoke-MockBrokerTurn -Task 'simulate timeout failure'
    Assert-Equal $timeoutTurn.Signal.status 'failed' 'timeout completion signal is failed'
    Assert-Equal $timeoutTurn.Metadata.terminationReason 'response_timeout' 'timeout has specific termination reason'
    Assert-Equal $timeoutTurn.Metadata.brokerExitCode 1 'timeout records broker exit code'

    $exitTurn = Invoke-MockBrokerTurn -Task 'simulate exit one failure'
    Assert-Equal $exitTurn.Signal.status 'failed' 'worker exit one completion signal is failed'
    Assert-Equal $exitTurn.Metadata.errorCode 'worker_process_failed' 'worker exit one is classified'
    Assert-Equal $exitTurn.Metadata.workerExitCode 1 'worker exit code is recorded'

    $missingTurn = Invoke-MockBrokerTurn -Task 'simulate missing response'
    Assert-Equal $missingTurn.Signal.status 'failed' 'missing final response signal is failed'
    Assert-Equal $missingTurn.Metadata.errorCode 'missing_final_response' 'missing response is classified'
    Assert-True (-not $missingTurn.Signal.hasFinalResponse) 'missing response signal reports no final response'

    $expiredKey = [guid]::NewGuid().ToString()
    Write-Json (Join-Path $lockState "sessions\$expiredKey\metadata.json") ([ordered]@{
        schemaVersion = 1; sessionKey = $expiredKey; workspace = $workspace
        acpSessionId = 'expired-acp-session'; startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $expiredTurn = Invoke-MockBrokerTurn -Task 'follow-up on expired session' -ExistingSessionKey $expiredKey
    Assert-Equal $expiredTurn.Signal.status 'failed' 'expired session signal is failed'
    Assert-Equal $expiredTurn.Metadata.errorCode 'session_not_resumable' 'expired session has explicit error code'
    Assert-Equal $expiredTurn.Metadata.recoveryHint 'start_fresh_conversation' 'expired session has recovery hint'

    $activeWatchdogTurn = Invoke-MockBrokerTurn -Task 'active watchdog test' -FastWatchdog
    Assert-Equal $activeWatchdogTurn.Signal.status 'completed' 'active watchdog turn completes'
    Assert-True (-not ($activeWatchdogTurn.Stdout -match 'CODEX_AGY_WATCHDOG_REVIEW')) 'watchdog does not alert while ACP activity continues'
}
finally {
    if ($temporaryRoot.StartsWith([IO.Path]::GetFullPath($env:TEMP), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output "RESULT passed=$script:Passed failed=$script:Failed"
if ($script:Failed -gt 0) { exit 1 }
