# Session protocol (headless agy-acp)

## Contents

1. Preflight and launch
2. Status contract
3. Monitoring loop
4. Recovery ladder
5. Completion and verification

## 1. Preflight and launch

Resolve paths from the loaded skill:

- `skillDir`: directory containing `SKILL.md`
- `pluginRoot`: `Resolve-Path (Join-Path $skillDir '..\..')`
- `scriptsDir`: `<pluginRoot>\scripts`

Start the request broker with the terminal execution tool:

- command: `node "<scriptsDir>\start-agy-session.mjs"`
- `workdir`: exact absolute workspace
- `tty`: `false` or `true`
- initial yield: 1-2 seconds

Wait for:

```text
CODEX_AGY_REQUEST_READY=1
```

Send a single compact JSON line to that same terminal session:

```json
{"workspace":"C:\\absolute\\repo","task":"Concrete task and acceptance criteria. Final report: outcome, files, validation, commit, risks.","mode":"accept-edits","model":"gemini-3.5-flash","effort":"high","outputMode":"silent"}
```

To resume a session (multi-turn), also include `sessionKey`:

```json
{"workspace":"C:\\absolute\\repo","task":"Correction or follow-up prompt","mode":"accept-edits","model":"gemini-3.5-flash","effort":"high","sessionKey":"<prior-session-key>","outputMode":"silent"}
```

`model` is an agy 1.1.5+ base slug. `effort` is independently validated as `low`, `medium`, or `high` and becomes the CLI's `--effort` argument. The broker accepts the old `modelTier` field only as a migration fallback for existing callers; new requests must use `effort`.

The broker launches `agy-acp.exe` and handles the JSON-RPC handshake over stdin/stdout. Capture:

```text
CODEX_AGY_SESSION_KEY=<uuid>
CODEX_AGY_WORKSPACE=<absolute path>
CODEX_AGY_LOG_FILE=<path>
CODEX_AGY_AUTONOMY=full-machine
```

## 2. Status contract

Query status with:

```powershell
pwsh -NoProfile -File "<scriptsDir>\get-session-status.ps1" -SessionKey <uuid>
```

Add `-IncludeContent` only when retrieving the final Antigravity response after completion.

The JSON contract contains:

- `status`: `starting`, `running`, `completed`, `recovering`, or `failed`
- `phase`: `thinking`, `background`, `idle`, or `unknown`
- `health`: `ok`, `suspected_stall`, or `stalled`
- workspace, model, effort, mode, session key, conversation ID
- process liveness, `fullyIdle`, error, and evidence
- `brokerExitCode`, `workerExitCode`, `hasFinalResponse`, `errorCode`, and `recoveryHint`

State precedence:

1. Nonzero broker/worker exit, structured execution error, quota, or timeout -> `failed`
2. Stop with `fullyIdle: true`, exit 0, and a non-empty final response -> `completed`
3. Stop with `fullyIdle: true` and an empty final response -> `failed` with `missing_final_response`
4. Running broker process -> `running`

The broker automatically appends events to `events.jsonl` matching the old observer schema, allowing `get-session-status.ps1` to parse status seamlessly.

## 3. Standby and watchdog

1. Submit the request with `outputMode: "silent"`, then leave that same terminal waiting. Do not poll terminal output or invoke the status helper during normal execution.
2. The broker stores worker chunks and tool events locally but does not relay them to Codex. This prevents progress chatter from consuming Codex context.
3. On the final ACP response, the broker persists `finalResponse`, emits `Stop`, and writes one `CODEX_AGY_TURN_FINISHED` line. That line is the completion wake-up signal.
   Its payload is authoritative and includes `status`, `terminationReason`, `hasFinalResponse`, and failure recovery fields when applicable.
4. The broker records a passive watchdog checkpoint at 5 minutes. It remains silent at that point.
5. After 10 minutes, it checks once per minute. A `CODEX_AGY_WATCHDOG_REVIEW` line is emitted only if no ACP lifecycle activity occurred for the preceding escalation interval. On that event, query `get-session-status.ps1` once and inspect minimal evidence; resume standby unless recovery is justified.
6. When `CODEX_AGY_TURN_FINISHED` arrives, query `get-session-status.ps1 -IncludeContent` exactly once, then review the diff and tests.

For follow-ups, the local `sessionKey` resolves to the persisted ACP session ID. Sessions created by v2.1.0 are upgraded by matching their last conversation ID, including event history, against the adapter store. If no safe mapping exists, the broker returns `session_not_resumable` with `start_fresh_conversation`; it must not expose an opaque `unknown sessionId` as the public result.

The status helper marks:

- `suspected_stall` after 5 minutes without log or CPU progress
- `stalled` after 15 minutes under the same conditions

## 4. Recovery ladder

### Same-conversation recovery

At a confirmed stall:

1. Terminate or cancel the current broker process (sending SIGTERM or letting it exit).
2. Wait up to 30 seconds for cleanup.
3. Start a new broker invocation with the same `sessionKey` and a concise continuation prompt containing verified facts and the remaining goal.

Do this at most once per conversation.

### Immediate clean conversation

Skip directly here when any of these are verified:

- claimed files or edits do not exist;
- claimed tests were not run or contradict actual output;
- the agent repeats an incoherent loop after correction;
- it invents commands, paths, or completed work;
- the process remains unhealthy after the same-conversation retry.

Build a handoff:

1. Start `node "<scriptsDir>\request-recovery-handoff.mjs"` with `tty: true`.
2. Wait for `CODEX_AGY_HANDOFF_READY=1`.
3. Send one JSON line containing `workspace`, `originalTask`, `failureReason`, `acceptanceCriteria`, `verifiedWork`, `remainingWork`, `testResults`, and `sessionKeys`.
4. Spawn a brand-new broker process (without passing the prior `sessionKey`) with the handoff prompt returned by the helper.

Maximum automatic budget per delegated task:

- original conversation: 1
- fresh recovery conversations: 2
- total: 3

Stop and ask the user after the third conversation fails.

## 5. Completion and verification

Completion requires all of:

1. `status` is `completed`;
2. the broker process exited with code 0;
3. the final response occurs after the latest Codex instruction.

After completion:

1. Query status with `-IncludeContent` and read `finalResponse`.
2. Inspect `git status --short`, diff/stat, and every changed file.
3. Check for out-of-scope or destructive changes.
4. Run proportionate tests independently when safe.
5. If claims conflict with evidence, enter recovery instead of reporting success.
