# Codex Antigravity Subagent

Use Google Antigravity CLI (`agy`) as a monitored coding subagent from Codex. Codex delegates implementation, reviews the actual workspace state, sends corrections to the same session, and only asks the user for real decisions.

## Install

Prerequisites:

- Codex CLI/Desktop installed and signed in.
- Antigravity CLI (`agy`) installed and signed in.
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

- Starts `agy` inside a real persistent PTY.
- Uses `Gemini 3.5 Flash (High)` by default with `accept-edits` mode.
- Locks one live session per workspace, while allowing other workspaces in parallel.
- Installs a passive Antigravity observer for lifecycle metadata only.
- Detects completion only from `Stop` plus `fullyIdle`.
- Keeps an idle worker session open while Codex reviews the diff, commit, and tests.
- Sends review deltas directly to the same worker session; no user copy/paste bridge.
- Recovers stalls with bounded retries and evidence-backed handoffs.

## Security model

The plugin launches Antigravity with `--dangerously-skip-permissions`. Antigravity has the same broad machine access as the interactive CLI session; it is not sandboxed to the worktree. Review tasks and worktree paths before delegation.

The companion observer records lifecycle metadata only. It does not record prompts, source code, tool arguments, command output, credentials, or modify Antigravity permission decisions.

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
