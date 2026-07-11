[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SessionKey,

    [string]$StateRoot,

    [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,

    [ValidateRange(30, 86400)]
    [int]$SuspectedStallSeconds = 300,

    [ValidateRange(60, 172800)]
    [int]$StalledSeconds = 900,

    [switch]$IncludeContent,
    [switch]$NoWriteHealth
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-StateRoot {
    if ($StateRoot) { return [System.IO.Path]::GetFullPath($StateRoot) }
    if ($env:CODEX_AGY_STATE_ROOT) { return [System.IO.Path]::GetFullPath($env:CODEX_AGY_STATE_ROOT) }
    return Join-Path $env:LOCALAPPDATA 'Codex\antigravity-subagent'
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Read-JsonLines {
    param([string]$Path)
    $items = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $items }
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $items.Add(($line | ConvertFrom-Json)) }
        catch { continue }
    }
    return $items
}

function Convert-ToDate {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToUniversalTime() }
    try { return [DateTimeOffset]::Parse([string]$Value).ToUniversalTime() }
    catch { return $null }
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Write-JsonAtomic {
    param([string]$Path, $Value)
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText(
        $temporaryPath,
        ($Value | ConvertTo-Json -Depth 10),
        $utf8NoBom
    )
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-ProcessTreeSample {
    param([int]$RootPid)
    $result = [ordered]@{ alive = $false; processCount = 0; cpuSeconds = 0.0; processIds = @() }
    if ($RootPid -le 0) { return [pscustomobject]$result }

    try { $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop) }
    catch { $allProcesses = @() }

    $ids = [System.Collections.Generic.HashSet[int]]::new()
    [void]$ids.Add($RootPid)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($process in $allProcesses) {
            if ($ids.Contains([int]$process.ParentProcessId) -and -not $ids.Contains([int]$process.ProcessId)) {
                [void]$ids.Add([int]$process.ProcessId)
                $changed = $true
            }
        }
    }

    $liveIds = [System.Collections.Generic.List[int]]::new()
    $cpu = 0.0
    foreach ($id in $ids) {
        $process = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($process) {
            $liveIds.Add($id)
            if ($null -ne $process.CPU) { $cpu += [double]$process.CPU }
        }
    }

    $result.alive = $liveIds.Count -gt 0
    $result.processCount = $liveIds.Count
    $result.cpuSeconds = [Math]::Round($cpu, 3)
    $result.processIds = @($liveIds)
    return [pscustomobject]$result
}

$root = Get-StateRoot
$sessionDirectory = Join-Path $root "sessions\$SessionKey"
$metadataPath = Join-Path $sessionDirectory 'metadata.json'
$metadata = Read-JsonFile -Path $metadataPath
if (-not $metadata) { throw "Unknown or invalid Antigravity session: $SessionKey" }

$events = @(Read-JsonLines -Path (Join-Path $sessionDirectory 'events.jsonl'))
$signals = @(Read-JsonLines -Path (Join-Path $sessionDirectory 'signals.jsonl'))
$lastEvent = if ($events.Count) { $events[-1] } else { $null }
$lastSignal = if ($signals.Count) { $signals[-1] } else { $null }

$transcriptPath = $null
for ($index = $events.Count - 1; $index -ge 0; $index--) {
    $candidate = Get-PropertyValue $events[$index] 'transcriptPath'
    if ($candidate) { $transcriptPath = [string]$candidate; break }
}
if ($transcriptPath -and -not (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) {
    $transcriptDirectory = Split-Path -Parent $transcriptPath
    foreach ($name in @('transcript.jsonl', 'transcript_full.jsonl')) {
        $candidatePath = Join-Path $transcriptDirectory $name
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $transcriptPath = $candidatePath
            break
        }
    }
}
$transcript = @()
if ($transcriptPath) { $transcript = @(Read-JsonLines -Path $transcriptPath) }
$lastTranscript = if ($transcript.Count) { $transcript[-1] } else { $null }

$completionResponse = Get-PropertyValue $metadata 'finalResponse'
if ([string]::IsNullOrWhiteSpace([string]$completionResponse) -and $transcript.Count) {
    $lastUserIndexForCompletion = -1
    for ($index = 0; $index -lt $transcript.Count; $index++) {
        if ((Get-PropertyValue $transcript[$index] 'type') -eq 'USER_INPUT') { $lastUserIndexForCompletion = $index }
    }
    for ($index = $transcript.Count - 1; $index -gt $lastUserIndexForCompletion; $index--) {
        if ((Get-PropertyValue $transcript[$index] 'type') -eq 'PLANNER_RESPONSE') {
            $completionResponse = Get-PropertyValue $transcript[$index] 'content'
            break
        }
    }
}
$hasFinalResponse = -not [string]::IsNullOrWhiteSpace([string]$completionResponse)

$conversationId = $null
for ($index = $events.Count - 1; $index -ge 0; $index--) {
    $candidate = Get-PropertyValue $events[$index] 'conversationId'
    if ($candidate) { $conversationId = [string]$candidate; break }
}
if (-not $conversationId -and $lastSignal) {
    $candidate = Get-PropertyValue $lastSignal 'conversationId'
    if ($candidate) { $conversationId = [string]$candidate }
}

$latestTaskTime = $null
if ($transcriptPath) {
    $logsDirectory = Split-Path -Parent $transcriptPath
    $systemGeneratedDirectory = Split-Path -Parent $logsDirectory
    $tasksDirectory = Join-Path $systemGeneratedDirectory 'tasks'
    if (Test-Path -LiteralPath $tasksDirectory -PathType Container) {
        $latestTask = Get-ChildItem -LiteralPath $tasksDirectory -File -Force -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($latestTask) { $latestTaskTime = [DateTimeOffset]$latestTask.LastWriteTimeUtc }
    }
}

$activityCandidates = [System.Collections.Generic.List[DateTimeOffset]]::new()
foreach ($value in @(
    (Get-PropertyValue $metadata 'startedAt'),
    (Get-PropertyValue $metadata 'updatedAt'),
    (Get-PropertyValue $lastEvent 'observedAt'),
    (Get-PropertyValue $lastSignal 'observedAt')
)) {
    $date = Convert-ToDate $value
    if ($date) { $activityCandidates.Add($date) }
}
foreach ($path in @($transcriptPath, (Get-PropertyValue $metadata 'logPath'))) {
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        $activityCandidates.Add([DateTimeOffset](Get-Item -LiteralPath $path).LastWriteTimeUtc)
    }
}
if ($latestTaskTime) { $activityCandidates.Add($latestTaskTime) }

$launcherPid = [int](Get-PropertyValue $metadata 'launcherPid')
$processSample = Get-ProcessTreeSample -RootPid $launcherPid
$healthPath = Join-Path $sessionDirectory 'health.json'
$previousHealth = Read-JsonFile -Path $healthPath
$lastActivityAt = if ($activityCandidates.Count) {
    ($activityCandidates | Sort-Object -Descending | Select-Object -First 1)
}
else {
    $Now.ToUniversalTime()
}
if ($previousHealth) {
    $previousActivity = Convert-ToDate (Get-PropertyValue $previousHealth 'lastActivityAt')
    if ($previousActivity -and $previousActivity -gt $lastActivityAt) { $lastActivityAt = $previousActivity }
    $previousCpu = [double](Get-PropertyValue $previousHealth 'cpuSeconds')
    if ($processSample.alive -and ($processSample.cpuSeconds - $previousCpu) -ge 0.05) {
        $lastActivityAt = $Now.ToUniversalTime()
    }
}

$inactiveSeconds = [Math]::Max(0, [int](($Now.ToUniversalTime() - $lastActivityAt).TotalSeconds))
$health = if ($inactiveSeconds -ge $StalledSeconds) {
    'stalled'
}
elseif ($inactiveSeconds -ge $SuspectedStallSeconds) {
    'suspected_stall'
}
else {
    'ok'
}

if (-not $NoWriteHealth) {
    Write-JsonAtomic -Path $healthPath -Value ([ordered]@{
        schemaVersion  = 1
        sampledAt      = $Now.ToUniversalTime().ToString('o')
        lastActivityAt = $lastActivityAt.ToString('o')
        cpuSeconds     = $processSample.cpuSeconds
        processCount   = $processSample.processCount
    })
}

$lastEventType = [string](Get-PropertyValue $lastEvent 'eventType')
$lastStopIndex = -1
$lastPreInvocationIndex = -1
for ($index = 0; $index -lt $events.Count; $index++) {
    $type = [string](Get-PropertyValue $events[$index] 'eventType')
    if ($type -eq 'Stop') { $lastStopIndex = $index }
    elseif ($type -eq 'PreInvocation') { $lastPreInvocationIndex = $index }
}
$stopIsCurrent = $lastStopIndex -ge 0 -and $lastStopIndex -gt $lastPreInvocationIndex
$lastTurnSubmitted = $null
for ($index = $signals.Count - 1; $index -ge 0; $index--) {
    if (([string](Get-PropertyValue $signals[$index] 'kind')) -eq 'turn_submitted') {
        $lastTurnSubmitted = $signals[$index]
        break
    }
}
if ($stopIsCurrent -and $lastTurnSubmitted) {
    $lastStopAt = Convert-ToDate (Get-PropertyValue $events[$lastStopIndex] 'observedAt')
    $lastTurnSubmittedAt = Convert-ToDate (Get-PropertyValue $lastTurnSubmitted 'observedAt')
    if ($lastStopAt -and $lastTurnSubmittedAt -and $lastTurnSubmittedAt -gt $lastStopAt) {
        # A new Codex instruction invalidates the prior completed turn
        # before agy has emitted its next PreInvocation hook.
        $stopIsCurrent = $false
    }
}
$currentStop = if ($stopIsCurrent) { $events[$lastStopIndex] } else { $null }
$fullyIdle = if ($stopIsCurrent) { Get-PropertyValue $currentStop 'fullyIdle' } else { $null }
$terminationReason = if ($stopIsCurrent) { Get-PropertyValue $currentStop 'terminationReason' } else { Get-PropertyValue $metadata 'terminationReason' }
$errorMessage = if ($stopIsCurrent) { Get-PropertyValue $currentStop 'error' } else { Get-PropertyValue $metadata 'error' }
$errorCode = if ($stopIsCurrent) { Get-PropertyValue $currentStop 'errorCode' } else { Get-PropertyValue $metadata 'errorCode' }
$recoveryHint = Get-PropertyValue $metadata 'recoveryHint'
$brokerExitCode = Get-PropertyValue $metadata 'brokerExitCode'
if ($null -eq $brokerExitCode) { $brokerExitCode = Get-PropertyValue $metadata 'exitCode' }
$workerExitCode = Get-PropertyValue $metadata 'workerExitCode'

$awaitingKinds = @('auth_required', 'trust_required', 'awaiting_input')
$lastSignalAt = Convert-ToDate (Get-PropertyValue $lastSignal 'observedAt')
$lastEventAt = Convert-ToDate (Get-PropertyValue $lastEvent 'observedAt')
$signalIsCurrent = $lastSignal -and (-not $lastEventAt -or ($lastSignalAt -and $lastSignalAt -ge $lastEventAt))
$lastSignalKind = [string](Get-PropertyValue $lastSignal 'kind')
$awaitingInput = $signalIsCurrent -and ($awaitingKinds -contains [string](Get-PropertyValue $lastSignal 'kind'))
$recovering = $signalIsCurrent -and (@('recovery_started', 'recovery_prompt_sent', 'new_conversation') -contains [string](Get-PropertyValue $lastSignal 'kind'))

$status = 'starting'
$knownFailureReasons = @(
    'error', 'max_steps_exceeded', 'quota_exceeded', 'response_timeout',
    'worker_process_failed', 'missing_final_response', 'session_not_resumable', 'execution_error'
)
$brokerFailed = $null -ne $brokerExitCode -and [int]$brokerExitCode -ne 0
if ((Get-PropertyValue $metadata 'launcherState') -eq 'failed' -or $brokerFailed -or $errorMessage -or $terminationReason -in $knownFailureReasons) {
    $status = 'failed'
}
elseif ($stopIsCurrent -and $fullyIdle -eq $true -and -not $hasFinalResponse) {
    $status = 'failed'
    $terminationReason = 'missing_final_response'
    $errorCode = 'missing_final_response'
    $errorMessage = 'Antigravity ended the turn without a final response.'
    $recoveryHint = 'resume_or_start_fresh'
}
elseif ($stopIsCurrent -and $fullyIdle -eq $true -and $hasFinalResponse) {
    $status = 'completed'
}
elseif ($awaitingInput) {
    $status = 'awaiting_input'
}
elseif ($recovering) {
    $status = 'recovering'
}
elseif (-not $processSample.alive -and -not $stopIsCurrent -and (Get-PropertyValue $metadata 'launcherState') -eq 'running') {
    $status = 'failed'
    $errorMessage = 'The broker process is no longer running and no completed Stop event was observed.'
}
elseif ((Get-PropertyValue $metadata 'endedAt') -and -not $processSample.alive -and -not $stopIsCurrent) {
    $status = 'failed'
    $errorMessage = 'The CLI exited before a completed Stop event was observed.'
}
elseif ($events.Count -or $transcript.Count -or $processSample.alive) {
    $status = 'running'
}

if ($status -in @('completed', 'failed', 'awaiting_input')) { $health = 'ok' }

$phase = 'unknown'
$transcriptType = [string](Get-PropertyValue $lastTranscript 'type')
$transcriptStatus = [string](Get-PropertyValue $lastTranscript 'status')
if ($stopIsCurrent -and $fullyIdle -eq $true) {
    $phase = 'idle'
}
elseif ($stopIsCurrent -and $fullyIdle -eq $false) {
    $phase = 'background'
}
elseif ($lastEventType -eq 'PreInvocation') {
    $phase = 'thinking'
}
elseif ($signalIsCurrent -and $lastSignalKind -eq 'turn_submitted') {
    $phase = 'thinking'
}
elseif ($transcriptType -in @('VIEW_FILE', 'LIST_DIRECTORY', 'GREP_SEARCH', 'SEARCH_WEB', 'READ_URL_CONTENT')) {
    $phase = 'researching'
}
elseif ($transcriptType -eq 'CODE_ACTION') {
    $phase = 'editing'
}
elseif ($transcriptType -eq 'RUN_COMMAND') {
    $phase = 'running_command'
}
elseif ($transcriptType -eq 'GENERIC' -and $transcriptStatus -eq 'RUNNING') {
    $phase = 'background'
}
elseif ($transcriptType -eq 'PLANNER_RESPONSE') {
    $phase = 'thinking'
}

$lastTool = $null
for ($index = $transcript.Count - 1; $index -ge 0 -and -not $lastTool; $index--) {
    $toolCalls = Get-PropertyValue $transcript[$index] 'tool_calls'
    if ($toolCalls -and $toolCalls.Count) {
        $candidate = Get-PropertyValue $toolCalls[-1] 'name'
        if ($candidate) { $lastTool = [string]$candidate }
    }
}
if (-not $lastTool -and $transcriptType) { $lastTool = $transcriptType }

$finalResponse = if ($IncludeContent -and $hasFinalResponse) { $completionResponse } else { $null }

$evidence = [System.Collections.Generic.List[string]]::new()
if ($lastEventType) { $evidence.Add("hook:$lastEventType") }
if ($stopIsCurrent) { $evidence.Add("hook:Stop"); $evidence.Add("fullyIdle:$fullyIdle") }
if ($transcriptType) { $evidence.Add("transcript:$transcriptType/$transcriptStatus") }
if ($lastSignal) { $evidence.Add("signal:$([string](Get-PropertyValue $lastSignal 'kind'))") }
$evidence.Add("processTree:$($processSample.processCount)")
$evidence.Add("inactiveSeconds:$inactiveSeconds")

[ordered]@{
    schemaVersion      = 1
    sessionKey         = $SessionKey
    conversationId     = $conversationId
    workspace          = Get-PropertyValue $metadata 'workspace'
    model              = Get-PropertyValue $metadata 'model'
    mode               = Get-PropertyValue $metadata 'mode'
    autonomy           = Get-PropertyValue $metadata 'autonomy'
    status             = $status
    phase              = $phase
    health             = $health
    lastStep           = Get-PropertyValue $lastTranscript 'step_index'
    lastTool           = $lastTool
    lastActivityAt     = $lastActivityAt.ToString('o')
    inactiveSeconds    = $inactiveSeconds
    processAlive       = $processSample.alive
    processCount       = $processSample.processCount
    fullyIdle          = $fullyIdle
    terminationReason  = $terminationReason
    brokerExitCode     = $brokerExitCode
    workerExitCode     = $workerExitCode
    hasFinalResponse   = $hasFinalResponse
    errorCode          = $errorCode
    error              = $errorMessage
    recoveryHint       = $recoveryHint
    transcriptPath     = $transcriptPath
    eventCount         = $events.Count
    transcriptStepCount = $transcript.Count
    finalResponse      = $finalResponse
    evidence           = @($evidence)
} | ConvertTo-Json -Depth 10
