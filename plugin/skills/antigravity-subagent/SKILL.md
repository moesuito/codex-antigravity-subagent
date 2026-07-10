---
name: antigravity-subagent
description: Delegate, monitor, recover, and verify coding tasks performed by Google Antigravity CLI (`agy`) in a persistent Windows PTY. Use when Codex should employ Antigravity as a coding subagent, continue or inspect an agy conversation, monitor agent stages/background work, recover a stalled or hallucinating Antigravity session, or review changes produced by agy.
---

# Antigravity Subagent

Run `agy` only through the bundled PTY launcher. Treat Antigravity as a coding subagent whose claims must be checked against the workspace.

This personal plugin intentionally starts `agy` with `--dangerously-skip-permissions` and does not confine it to the workspace. Before the first launch in a task, tell the user that the Antigravity process inherits broad machine access. Do not describe the session as sandboxed.

Before operating a session, read [references/session-protocol.md](references/session-protocol.md) completely. It contains the exact commands, state contract, recovery ladder, and stop rules.

## Core workflow

1. Determine the concrete coding task and one absolute workspace path. Use the active repository when unambiguous; do not guess between multiple roots.
2. Resolve the plugin root as two directories above this `SKILL.md`. Never hard-code the development source path because installed plugins run from a cache.
3. Run `scripts/install-observer.ps1`. Announce when the skill installs or updates the companion Antigravity plugin.
4. Start `scripts/start-agy-session.mjs` with the terminal execution tool using `tty: true` and the workspace as `workdir`. Wait for `CODEX_AGY_REQUEST_READY=1`, then send one JSON request with the terminal input tool. Do not interpolate the task into a shell command.
5. Capture `CODEX_AGY_SESSION_KEY`, record terminal signals, and poll the same PTY every 10-30 seconds. Never start a second session for the same workspace while the first lock is held.
6. Query `scripts/get-session-status.ps1` after material output and during monitoring. Report useful progress at least once per minute during long work.
7. Accept a workspace trust prompt automatically only when its displayed normalized path exactly equals the requested workspace and `Yes, I trust this folder` is selected. Never automate login, credentials, or an unexpected prompt.
8. Declare a turn complete only when status is `completed`, `fullyIdle` is `true`, and the final response follows the latest Codex instruction.
9. Review the actual diff, files, and tests. Do not hand back an unverified Antigravity claim.
10. Keep a verified idle session open while Codex reviews and corrects the result. For each correction, record `turn_submitted` without prompt content, then send the exact review delta to the same PTY. Exit only when Codex accepts the task, abandons it, replaces the session, or recovery requires it. Preserve every conversation ID.

## Multi-turn review loop

After each turn reaches `completed` and `fullyIdle`, Codex must inspect the relevant files, diff, and validation results. If review finds a concrete code delta, keep the same PTY/conversation and submit only that delta. Do not bridge messages through the user. When the task is accepted and there is no further coding work, close with `/exit`; do not send an empty acknowledgement to `agy`.

## Model policy

- Default to `Gemini 3.5 Flash (High)`.
- Use Medium or Low only for an unmistakably trivial initial task.
- Use High for every recovery conversation.
- Do not switch automatically to Gemini 3.1 Pro, Claude, or another model family.

## Recovery policy

- Treat `suspected_stall` as a diagnostic trigger, not proof of failure.
- At `stalled`, inspect the process/task evidence and perform one same-conversation recovery: send `Esc`, wait up to 30 seconds, then provide a factual continuation prompt.
- On a repeated stall or evidence-backed hallucination, build a clean handoff with `scripts/build-recovery-handoff.ps1` and start a new conversation.
- Permit at most two fresh conversations after the original. After three conversations total, stop and ask the user.
- Skip the same-conversation retry when the model's claims directly contradict files, Git state, or test results.

## Safety and integrity

- Never use Computer Use or automate unrelated desktop applications for this workflow.
- Never feed secrets, credentials, or unrelated file contents into the observer or recovery metadata.
- The companion observer must remain passive: no `PreToolUse`, no permission changes, no injected steps, and no edits to Antigravity settings.
- Do not edit overlapping files while Antigravity owns the workspace. Inspect and verify only after its turn is fully idle or cancelled.
- Preserve unrelated user changes and treat a dirty worktree as user-owned.
