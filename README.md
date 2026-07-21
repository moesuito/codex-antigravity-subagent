# Codex Antigravity Subagent

Use Google Antigravity CLI (`agy`) as a monitored coding subagent from Codex. Codex delegates implementation, reviews the actual workspace state, sends corrections to the same session, and only asks the user for real decisions.

## Install

Prerequisites:

- Codex CLI/Desktop installed and signed in.
- Antigravity CLI (`agy`) 1.1.5+ installed and signed in.
- Windows PowerShell 7+.

Run this from PowerShell on the target machine:

```powershell
irm https://raw.githubusercontent.com/moesuito/codex-antigravity-subagent/main/scripts/install.ps1 | iex
```

The installer downloads the latest GitHub release asset, installs:

- the Codex plugin at `~/plugins/antigravity-subagent`;
- updates the personal marketplace entry and runs `codex plugin add antigravity-subagent@personal`.

Existing plugin and skill directories are backed up under `~/.codex/antigravity-subagent-backups/` before replacement. Re-run the same command to update to the newest release.

For a more inspectable install, download the script first:

```powershell
irm https://raw.githubusercontent.com/moesuito/codex-antigravity-subagent/main/scripts/install.ps1 -OutFile .\install-antigravity-subagent.ps1
notepad .\install-antigravity-subagent.ps1
.\install-antigravity-subagent.ps1
```

Start a new Codex task after installation so the updated plugin and skill are loaded.

## What it does

- Launches a headless ACP server using the compiled `agy-acp` adapter binary.
- Uses model `gemini-3.5-flash` with separate effort `high` by default and `accept-edits` mode.
- Passes `--model <slug>` and `--effort <low|medium|high>` independently, matching the agy 1.1.5+ CLI contract while migrating legacy persisted model names on resume.
- Locks one live session per workspace, while allowing other workspaces in parallel.
- Detects completion only from `Stop` plus `fullyIdle` events via sqlite db streaming.
- Keeps Codex in silent standby: the worker's final response emits one completion wake-up instead of streaming progress into Codex context.
- Runs a passive watchdog check at 5 minutes, then checks each minute after 10 minutes and wakes Codex only when ACP lifecycle activity is absent.
- Keeps an idle worker session open while Codex reviews the diff, commit, and tests.
- Sends review deltas directly to the same worker session; no user copy/paste bridge.
- Persists the real ACP session ID for follow-ups and upgrades v2.1 session records from their conversation history when possible.
- Treats quota, timeout, nonzero worker exits, and missing final responses as structured failures instead of successful completion.
- Recovers stalls with bounded retries and evidence-backed handoffs.

## Security model

The plugin launches Antigravity with `--dangerously-skip-permissions` inside the ACP container. Antigravity has the same broad machine access as the interactive CLI session; it is not sandboxed to the worktree. Review tasks and worktree paths before delegation.

No sensitive prompts, source code, tool arguments, command output, or credentials are leaked or stored.

## Repository layout

- `plugin/` — marketplace-installable Codex plugin source.
- `scripts/install.ps1` — release-aware Windows installer used by the one-liner.
- `scripts/build-release.ps1` — creates the release ZIP asset.

## Uninstall

```powershell
codex plugin remove antigravity-subagent@personal
Remove-Item "$HOME\plugins\antigravity-subagent" -Recurse -Force
```

Remove the `antigravity-subagent` entry from `~/.agents/plugins/marketplace.json` only if it is no longer needed.

## License

[MIT](LICENSE)
