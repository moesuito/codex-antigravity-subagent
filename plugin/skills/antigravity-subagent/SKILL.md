---
name: antigravity-subagent
description: Delegate, monitor, recover, and verify coding tasks performed by Google Antigravity CLI (`agy`) in headless mode using the agy-acp JSON-RPC adapter. Use when Codex should employ Antigravity as a coding subagent, continue or inspect an agy conversation, monitor agent stages, recover a stalled session, or review changes produced by agy.
---

# Antigravity Subagent

Run `agy` only through the bundled `agy-acp` headless broker. Treat Antigravity as a coding subagent whose claims must be checked against the workspace.

This personal plugin starts `agy` via `agy-acp` with `--dangerously-skip-permissions` automatically. Before the first launch in a task, tell the user that the Antigravity process inherits broad machine access. Do not describe the session as sandboxed.

Before operating a session, read [references/session-protocol.md](references/session-protocol.md) completely. It contains the exact commands, state contract, recovery ladder, and stop rules.

## Core workflow

1. Determine the concrete coding task and one absolute workspace path. Use the active repository when unambiguous; do not guess between multiple roots.
2. Resolve the plugin root as two directories above this `SKILL.md`. Never hard-code the development source path because installed plugins run from a cache.
3. Start `scripts/start-agy-session.mjs` with the terminal execution tool and the workspace as `workdir`. Wait for `CODEX_AGY_REQUEST_READY=1`, then send one JSON request with `model: "gemini-3.5-flash"`, a separate `effort`, and `outputMode: "silent"`. Do not interpolate the task into a shell command.
4. Capture `CODEX_AGY_SESSION_KEY` from stdout, then enter standby on that same terminal. Never start a second session for the same workspace while the first lock is held.
5. Do not poll the PTY or `get-session-status.ps1` while the worker is silent. The broker wakes Codex with `CODEX_AGY_TURN_FINISHED` as soon as Antigravity returns its final response. It performs a passive health check at 5 minutes and emits a compact watchdog review only after 10 minutes of work with no lifecycle activity, at most once per minute thereafter.
6. On `CODEX_AGY_TURN_FINISHED`, query `scripts/get-session-status.ps1 -IncludeContent` once. On `CODEX_AGY_WATCHDOG_REVIEW`, query it once, inspect the minimal relevant evidence, then resume standby unless recovery is warranted.
7. Declare a turn complete only when status is `completed`, and the final response follows the latest Codex instruction. Every delegated task must request a concise final report covering outcome, changed files, validation, commit, and remaining risks; do not ask the worker for running narration.
8. Review the actual diff, files, and tests. Do not hand back an unverified Antigravity claim. To send a follow-up correction or multi-turn instruction, start a new invocation of `scripts/start-agy-session.mjs` with the same `sessionKey` (this resumes the warm conversation state seamlessly using the ACP adapter). Exit only when Codex accepts the task, abandons it, or recovery requires a new session.

## Multi-turn review loop

After each terminal completion signal, Codex must inspect the relevant files, diff, and validation results exactly once. If review finds a concrete code delta, start a new `start-agy-session.mjs` invocation passing the same `sessionKey` to submit only that delta. When the task is accepted and there is no further coding work, the session is complete.

## Model policy

- Default to model `gemini-3.5-flash` with effort `high`.
- Pass the base model slug through `model` and the reasoning level through the separate `effort` field. Never append effort to the model value or use the legacy friendly form such as `Gemini 3.5 Flash (High)`.
- Use effort `medium` or `low` only for an unmistakably trivial initial task.
- Use effort `high` for every recovery conversation.
- Do not switch automatically to Gemini 3.1 Pro, Claude, or another model family.

## Recovery policy

- Treat `suspected_stall` as a diagnostic trigger, not proof of failure.
- At `stalled`, inspect the process/task evidence and perform one same-conversation recovery: cancel the current execution (or let it timeout), then provide a factual continuation prompt using the same `sessionKey`.
- On a repeated stall or evidence-backed hallucination, build a clean handoff with `scripts/build-recovery-handoff.ps1` and start a new conversation (without passing the prior `sessionKey` to trigger a clean workspace handoff).
- Permit at most two fresh conversations after the original. After three conversations total, stop and ask the user.
- Skip the same-conversation retry when the model's claims directly contradict files, Git state, or test results.

## Safety and integrity

- Never use Computer Use or automate unrelated desktop applications for this workflow.
- Never feed secrets, credentials, or unrelated file contents into the observer or recovery metadata.
- Do not edit overlapping files while Antigravity owns the workspace. Inspect and verify only after its turn is completed.
- Preserve unrelated user changes and treat a dirty worktree as user-owned.
