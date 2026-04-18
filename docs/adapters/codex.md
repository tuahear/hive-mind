# Codex adapter

The Codex adapter attaches [OpenAI Codex CLI](https://github.com/openai/codex) to your `~/.hive-mind/` hub. After install, Codex still reads and writes its native files in `~/.codex/`, but hive-mind keeps the portable parts in sync through the hub: both global memory files and bundled skills. `hooks.json` stays Codex-local and is managed directly by the installer.

## What `setup.sh` does on install

When you run `ADAPTER=codex bash ~/.hive-mind/hive-mind/setup.sh`:

1. It loads the Codex adapter contract from `adapters/codex/adapter.sh`.
2. It seeds bundled skills into the hub, then fans them out to `~/.agents/skills/`.
3. It builds or refreshes the native `hivemind-hook` launcher under `~/.hive-mind/bin/`.
4. It wires `~/.codex/hooks.json` to that launcher.
5. It enables Codex hook execution with `[features] codex_hooks = true` in `~/.codex/config.toml` without replacing unrelated config.

On every subsequent sync cycle, both `~/.codex/AGENTS.md` and `~/.codex/AGENTS.override.md` round-trip through the hub - no one-time seed step is needed.

## Hooks installed for Codex

Codex currently loads hook definitions from `~/.codex/hooks.json`, gated by `[features].codex_hooks` in `~/.codex/config.toml`.

| Event | Command | Purpose |
|---|---|---|
| `SessionStart` | `"$HOME/.hive-mind/bin/hivemind-hook[.exe]" session-start "<codex-dir>"` | Launches the bash-backed sync + duplicate-scan flow through a native wrapper so Windows never has to parse a `bash ...` hook command itself. |
| `Stop` | `"$HOME/.hive-mind/bin/hivemind-hook[.exe]" stop` | Launches the bash-backed sync flow through the same native wrapper and emits valid JSON back to Codex. |

Codex's current hook surface does not expose the Claude-style `PostToolUse` edit event that hive-mind uses for marker nudges in Claude Code, so the bundled Codex skill reminds the model to add commit markers explicitly when it edits hive-mind-managed files.

## Memory file mapping

Codex natively reads both `AGENTS.md` (the user's own memory) and `AGENTS.override.md` (an override layer) at startup and concatenates them at runtime. hive-mind syncs each through its own section of the hub's canonical `content.md`, using the section selector extension to `ADAPTER_HUB_MAP`:

| Hub path | Codex-side path | Semantics |
|---|---|---|
| `content.md[0]` | `~/.codex/AGENTS.md` | Shared tier - every adapter reads/writes this |
| `content.md[1]` | `~/.codex/AGENTS.override.md` | Codex-scoped override tier |

Section 0 is the default bucket in `content.md` (everything outside any `<!-- hive-mind:section=N START/END -->` block). Section 1 lives inside a paired marker block. See `docs/contributing.md` for the section registry and the full selector contract.

Skills are synced separately through `~/.agents/skills/` and are not declared in `ADAPTER_HUB_MAP`.
`hooks.json` is also intentionally local to Codex: the installer manages it directly so shell-specific hook commands from other adapters never fan out into Codex's PowerShell-facing hook surface.

Codex permissions are not mapped in this first adapter release. Current Codex permissions are profile-based inside `config.toml`, which does not match hive-mind's canonical allow/deny/ask text lists cleanly enough to round-trip without data loss.

## After install

Restart Codex so it reloads `~/.codex/hooks.json`. From then on:

- `SessionStart` pulls any cross-machine updates before the session begins.
- `Stop` syncs Codex's active memory layer back through the shared hub.

See [Get started](/get-started) for the install flow and [Technical reference](/reference) for the shared hook and hub details.
