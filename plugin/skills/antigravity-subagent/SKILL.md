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
3. Start `scripts/start-agy-session.mjs` with the terminal execution tool and the workspace as `workdir`. Wait for `CODEX_AGY_REQUEST_READY=1`, then send one JSON request with the terminal input tool. Do not interpolate the task into a shell command.
4. Capture `CODEX_AGY_SESSION_KEY` from stdout, and monitor execution. Never start a second session for the same workspace while the first lock is held.
5. Query `scripts/get-session-status.ps1` after material output and during monitoring. Report useful progress at least once per minute during long work.
6. Declare a turn complete only when status is `completed`, and the final response follows the latest Codex instruction.
7. Review the actual diff, files, and tests. Do not hand back an unverified Antigravity claim.
8. To send a follow-up correction or multi-turn instruction, start a new invocation of `scripts/start-agy-session.mjs` with the same `sessionKey` (this resumes the warm conversation state seamlessly using the ACP adapter). Exit only when Codex accepts the task, abandons it, or recovery requires a new session.

## Multi-turn review loop

After each turn reaches `completed`, Codex must inspect the relevant files, diff, and validation results. If review finds a concrete code delta, start a new `start-agy-session.mjs` invocation passing the same `sessionKey` to submit only that delta. When the task is accepted and there is no further coding work, the session is complete.

## Model policy

- Default to `Gemini 3.5 Flash (High)`.
- Use Medium or Low only for an unmistakably trivial initial task.
- Use High for every recovery conversation.
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
