# agy-acp

ACP (Agent Client Protocol) adapter for [Antigravity CLI](https://github.com/google-antigravity/antigravity-cli). Bridges `agy` into OpenAB's stdio JSON-RPC protocol.

> [!NOTE]
> **Credits**: This adapter was originally developed by the **OpenAB team** as part of the [OpenAB Project](https://github.com/openabdev/openab). All credits for the creation, architecture, and protocol design of `agy-acp` go to the OpenAB team.

## How it works

```
openab ──JSON-RPC──► agy-acp ──spawns──► agy -p "prompt" [--conversation <uuid>] [--model <slug>] [--effort <low|medium|high>]
                        │
                        ├─ Tracks conversation IDs via SQLite .db files
                        ├─ Extracts responses from protobuf step_payload (field 20.1)
                        └─ Persists session state (conversation_id, model, effort) for multi-turn conversations
```

## Build

```bash
cargo build --release
```

## Tests

```bash
# Unit tests
cargo test

# All tests including filesystem I/O tests
cargo test -- --include-ignored

# E2E test (requires agy in PATH + auth)
cargo test e2e -- --ignored --nocapture
```

### E2E requirements

The E2E test spawns `agy-acp` → `agy` and verifies a full round-trip prompt/response.

| Requirement | Local dev | CI |
|---|---|---|
| `agy` binary | `agy` on PATH (1.1.5+ validated) | Downloaded from GitHub release |
| Auth | System keychain (existing login) or `GEMINI_API_KEY` env var | `GEMINI_API_KEY` env var |

**Local setup:**
```bash
# Install agy 1.1.5+ (use the latest release for your platform)
gh release download 1.1.5 --repo google-antigravity/antigravity-cli \
  --pattern "agy_cli_*" --dir /tmp
# Extract the archive for your platform and put the `antigravity` (or `agy.exe`)
# binary on your PATH. On macOS/Linux:
ln -sf /tmp/antigravity ~/.local/bin/agy

# Run e2e
export PATH="$HOME/.local/bin:$PATH"
cargo test e2e -- --ignored --nocapture
```

> [!NOTE]
> `agy-acp` validates against `agy 1.1.5`. The adapter auto-migrates any session persisted under pre-1.1.5 model names (e.g. `Gemini 3.5 Flash (High)`) to 1.1.5 slugs + effort on `session/load`, so existing sessions keep working after upgrade.

**CI:** The GitHub Actions workflow (`.github/workflows/e2e-agy-acp.yml`) handles everything automatically. It uses the `GEMINI_API_KEY` repo secret.

**Windows local:** `cargo test --release -- --include-ignored test_e2e_agy_acp_full_round_trip` runs against an installed `agy.exe` on PATH (validated on Windows against `agy 1.1.5`).

### Updating the API key

```bash
gh secret set GEMINI_API_KEY --repo openabdev/openab
```

Get a free key from https://aistudio.google.com/apikey — the e2e sends one short prompt per run so cost is negligible.
