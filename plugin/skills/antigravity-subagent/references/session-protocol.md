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
{"workspace":"C:\\absolute\\repo","task":"Concrete task and acceptance criteria","mode":"accept-edits","modelTier":"High"}
```

To resume a session (multi-turn), also include `sessionKey`:

```json
{"workspace":"C:\\absolute\\repo","task":"Correction or follow-up prompt","mode":"accept-edits","modelTier":"High","sessionKey":"<prior-session-key>"}
```

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
- workspace, model, mode, session key, conversation ID
- process liveness, `fullyIdle`, error, and evidence

State precedence:

1. Process failure or execution error -> `failed`
2. Stop event with `fullyIdle: true` -> `completed`
3. Running broker process -> `running`

The broker automatically appends events to `events.jsonl` matching the old observer schema, allowing `get-session-status.ps1` to parse status seamlessly.

## 3. Monitoring loop

1. Poll the running broker process by reading its output.
2. Query the status helper `get-session-status.ps1` periodically.
3. Give the user a concise update at least once per 60 seconds while work continues.
4. If the broker finishes with code 0, read the metadata final response.

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
