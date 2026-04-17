# Codex adapter

The Codex adapter attaches [OpenAI Codex CLI](https://github.com/openai/codex) to your `~/.hive-mind/` hub. After install, Codex still reads and writes its native files in `~/.codex/`, but hive-mind keeps the portable parts in sync through the hub: the active global memory layer, shared hook definitions, and bundled skills.

## What `setup.sh` does on install

When you run `ADAPTER=codex bash ~/.hive-mind/hive-mind/setup.sh`:

1. It loads the Codex adapter contract from `adapters/codex/adapter.sh`.
2. It seeds bundled skills into the hub, then fans them out to `~/.agents/skills/`.
3. It ensures Codex's active global memory file exists at `~/.codex/AGENTS.override.md`, seeding it from `~/.codex/AGENTS.md` on first attach when needed.
4. It merges hive-mind's shared hooks into `~/.codex/hooks.json`.
5. It enables Codex hook execution with `[features] codex_hooks = true` in `~/.codex/config.toml` without replacing unrelated config.

## Hooks installed for Codex

Codex currently loads hook definitions from `~/.codex/hooks.json`, gated by `[features].codex_hooks` in `~/.codex/config.toml`.

| Event | Command | Purpose |
|---|---|---|
| `SessionStart` | `"$HOME/.hive-mind/bin/sync"` then `"$HOME/.hive-mind/hive-mind/core/check-dupes.sh"` | Pulls fresh memory from the hub remote before the session starts, then scans for duplicate lines caused by union merges. |
| `Stop` | `"$HOME/.hive-mind/bin/sync"` | Harvests Codex-side files into the hub, syncs the shared memory repo, then fans the merged state back out. |

Codex's current hook surface does not expose the Claude-style `PostToolUse` edit event that hive-mind uses for marker nudges in Claude Code, so the bundled Codex skill reminds the model to add commit markers explicitly when it edits hive-mind-managed files.

## Memory file mapping

The first shipped Codex adapter keeps the mapping intentionally small and lossless:

| Hub path | Codex-side path |
|---|---|
| `content.md` | `~/.codex/AGENTS.override.md` |
| `config/hooks` | `~/.codex/hooks.json#hooks` |

Skills are synced separately through `~/.agents/skills/` and are not declared in `ADAPTER_HUB_MAP`.

Codex permissions are not mapped in this first adapter release. Current Codex permissions are profile-based inside `config.toml`, which does not match hive-mind's canonical allow/deny/ask text lists cleanly enough to round-trip without data loss.

## After install

Restart Codex so it reloads `~/.codex/hooks.json`. From then on:

- `SessionStart` pulls any cross-machine updates before the session begins.
- `Stop` syncs Codex's active memory layer back through the shared hub.

See [Get started](/get-started) for the install flow and [Technical reference](/reference) for the shared hook and hub details.
