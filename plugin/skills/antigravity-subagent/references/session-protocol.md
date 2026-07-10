# Session protocol

## Contents

1. Preflight and launch
2. Terminal signals
3. Status contract
4. Monitoring loop
5. Recovery ladder
6. Completion and verification

## 1. Preflight and launch

Resolve paths from the loaded skill:

- `skillDir`: directory containing `SKILL.md`
- `pluginRoot`: `Resolve-Path (Join-Path $skillDir '..\..')`
- `scriptsDir`: `<pluginRoot>\scripts`

Install or update the passive companion before the first session:

```powershell
pwsh -NoProfile -File "<scriptsDir>\install-observer.ps1"
```

Start the request broker with the terminal execution tool:

- command: `node "<scriptsDir>\start-agy-session.mjs"`
- `workdir`: exact absolute workspace
- `tty`: `true`
- initial yield: 1-3 seconds

Wait for:

```text
CODEX_AGY_REQUEST_READY=1
```

Send a single compact JSON line to that same terminal session:

```json
{"workspace":"C:\\absolute\\repo","task":"Concrete task and acceptance criteria","mode":"accept-edits","modelTier":"High"}
```

The broker reads the request in raw terminal mode, Base64-encodes workspace and task before PowerShell sees them, then launches `agy` inside the same PTY. Capture:

```text
CODEX_AGY_SESSION_KEY=<uuid>
CODEX_AGY_WORKSPACE=<absolute path>
CODEX_AGY_LOG_FILE=<path>
CODEX_AGY_AUTONOMY=full-machine
```

Use `mode: plan` only when the delegated work is explicitly research or planning. Coding defaults to `accept-edits`.

## 2. Terminal signals

Whenever terminal output materially changes the state, record a metadata-only signal:

```powershell
pwsh -NoProfile -File "<scriptsDir>\record-session-signal.ps1" `
  -SessionKey <uuid> -Kind <kind>
```

Allowed kinds and when to use them:

| Kind | Meaning |
| --- | --- |
| `terminal_output` | New PTY bytes without a more specific state |
| `turn_submitted` | Codex sent a new instruction after a prior turn; metadata only, never prompt text |
| `ready` | Explicit ready-for-input marker or clean prompt after a turn |
| `auth_required` | Login or browser authentication is required |
| `trust_required` | Workspace trust card is visible |
| `awaiting_input` | Unexpected question, review, or interactive choice |
| `recovery_started` | `Esc` recovery began |
| `recovery_prompt_sent` | Same-conversation continuation was submitted |
| `new_conversation` | `/clear` or a fresh `agy` process received a handoff |
| `hallucination_detected` | Claims conflict with inspected evidence |
| `exited` | `/exit` or process termination completed |

Do not put prompt text, code, tool arguments, or credentials in `Note`.

Trust handling:

1. Read the displayed workspace path from the TUI.
2. Normalize it with `GetFullPath`, trim trailing separators, and compare case-insensitively with the requested workspace.
3. Send Enter only if the exact path matches and the selector is on `Yes, I trust this folder`.
4. Otherwise record `awaiting_input` and ask the user.

Authentication handling:

- Record `auth_required`.
- Allow the CLI/keyring/browser flow to proceed.
- Never type passwords, OAuth codes, or account selectors on the user's behalf.

## 3. Status contract

Query status with:

```powershell
pwsh -NoProfile -File "<scriptsDir>\get-session-status.ps1" -SessionKey <uuid>
```

Add `-IncludeContent` only when retrieving the final Antigravity response after completion.

The JSON contract contains:

- `status`: `starting`, `running`, `awaiting_input`, `recovering`, `completed`, or `failed`
- `phase`: `thinking`, `researching`, `editing`, `running_command`, `background`, `idle`, or `unknown`
- `health`: `ok`, `suspected_stall`, or `stalled`
- workspace, model, mode, session key, conversation ID, last step/tool/activity
- process liveness, `fullyIdle`, termination reason, error, transcript path, and evidence

State precedence:

1. Current `Stop` hook with error or `max_steps_exceeded` -> `failed`
2. Current `Stop` with `fullyIdle: true` -> `completed`
3. Auth/trust/unexpected input signal -> `awaiting_input`
4. Recovery signal -> `recovering`
5. Live hook/transcript/process activity -> `running`
6. CLI exit without a completed `Stop` -> `failed`

Phase mapping:

- `PreInvocation` -> `thinking`
- view/list/grep/web transcript events -> `researching`
- `CODE_ACTION` -> `editing`
- `RUN_COMMAND` -> `running_command`
- running generic/background events or `fullyIdle: false` -> `background`
- completed `Stop` -> `idle`

The observer records only allowlisted lifecycle fields. It deliberately omits prompts, response content, tool arguments, commands, and diffs.

## 4. Monitoring loop

1. Poll the PTY with empty terminal input every 10-30 seconds.
2. When new output arrives, record `terminal_output` or a more specific signal.
3. Query the status helper.
4. Give the user a concise update at least once per 60 seconds while work continues.
5. If the TUI returns to a prompt but `fullyIdle` is false or background work is indicated, inspect `/tasks` and `/agents`; do not declare completion.
6. If a command produces no console output but its process CPU or task log continues changing, treat it as active.
7. After a verified idle turn, keep the PTY open for Codex review. Before sending any follow-up/fix request, record `turn_submitted` with a generic note such as `Codex review delta submitted`; then send the prompt directly to the same PTY. A `turn_submitted` signal makes the previous `Stop` non-current until Antigravity emits lifecycle events for the new turn.

The status helper marks:

- `suspected_stall` after 5 minutes without PTY, hook, transcript, task-log, or process-CPU progress
- `stalled` after 15 minutes under the same conditions

## 5. Recovery ladder

### Same-conversation recovery

At a confirmed stall:

1. Record `recovery_started`.
2. Send one `Esc` character to the PTY.
3. Wait up to 30 seconds for a `Stop` event or ready prompt.
4. Inspect Git state, task logs, and the last reliable events.
5. Send a concise continuation prompt containing verified facts, the remaining goal, and an instruction not to redo correct work.
6. Record `recovery_prompt_sent`.

Do this at most once per conversation.

### Immediate clean conversation

Skip directly here when any of these are verified:

- claimed files or edits do not exist;
- claimed tests were not run or contradict actual output;
- the agent repeats an incoherent loop after correction;
- it invents commands, paths, or completed work after evidence is shown;
- the PTY/process remains unhealthy after the same-conversation retry.

Build a handoff without placing task text in a shell command:

1. Start `node "<scriptsDir>\request-recovery-handoff.mjs"` with `tty: true`.
2. Wait for `CODEX_AGY_HANDOFF_READY=1`.
3. Send one JSON line containing `workspace`, `originalTask`, `failureReason`, `acceptanceCriteria`, `verifiedWork`, `remainingWork`, `testResults`, and `sessionKeys`.

The helper returns both `prompt` and `promptBase64`. If the TUI is responsive, send `/clear`, wait for the new prompt, then send `prompt` directly to the PTY. If it is not responsive, exit/terminate the old process and use the normal request broker with the handoff prompt.

Record `new_conversation`, retain all prior session and conversation IDs, and use Gemini 3.5 Flash High.

Maximum automatic budget per delegated task:

- original conversation: 1
- fresh recovery conversations: 2
- total: 3

Stop and ask the user after the third conversation fails.

## 6. Completion and verification

Completion requires all of:

1. `status` is `completed`;
2. `fullyIdle` is `true`;
3. the final response occurs after the latest Codex instruction;
4. no active background task/subagent remains;
5. the CLI process did not exit unexpectedly.

After completion:

1. Query with `-IncludeContent` and read the final response. If the current `agy` build leaves its transcript empty, use the final response already captured from the PTY; never invent missing content.
2. Inspect `git status --short`, diff/stat, and every changed file relevant to the task.
3. Check for out-of-scope or destructive changes.
4. Run proportionate tests independently when safe, or verify the exact Antigravity test output.
5. If claims conflict with evidence, enter recovery instead of reporting success.
6. Keep the PTY and workspace lock alive while Codex reviews the completed turn. If there is a concrete correction, send it in the same conversation after recording `turn_submitted`, then repeat the completion checks.
7. Send `/exit` and record `exited` only after Codex accepts the task with no further coding work, abandons/replaces the session, or recovery requires a new process. Preserve the conversation ID for `agy --conversation <id>`.
8. Report what changed, verification performed, recovery history, and unresolved risks.
