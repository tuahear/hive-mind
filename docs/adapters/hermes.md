# Hermes adapter

The Hermes adapter attaches [Hermes Agent](https://github.com/NousResearch/hermes-agent) to your `~/.hive-mind/` hub. Unlike the other adapters, Hermes does **not** participate in the shared `content.md` tier — its whole tool dir is mirrored as a blob into `hub/hermes/` and back, isolated from Claude / Codex memory.

## What gets synced

| Hub path | Hermes-side path | Semantics |
|---|---|---|
| `hub/hermes/` | `~/.hermes/` (or `$HERMES_HOME`) | Whole-dir blob mirror, bidirectional |

There is no `content.md` mapping, no `hub/skills/` rename, and no `projects/<id>/` per-project content. Hermes' skills, memories, MCP config, and gateway config all ride along inside the blob.

## Source-side `.gitignore` is respected

Hermes' own `~/.hermes/.gitignore` is honored by the hub on every sync. The standard install ignores `.env`, `cache/`, `logs/`, `tmp/`, and `*.log`. The hub's directory mirror reads that file and:

- Skips matching files in the **harvest copy pass** (they never reach `hub/hermes/`, so they never get pushed).
- Skips matching files in the **fan-out delete pass** — critical safety: on a fresh machine pulling the hub, the gitignored paths don't exist in `hub/hermes/`, and without this filter the delete pass would wipe legitimate local files such as `~/.hermes/cache/`.

`.env` is also declared as an `ADAPTER_SECRET_FILES` entry, so the hub's basename-keyed secret gate unstages it even if a future config change moves the file out from under the gitignore.

## What `setup.sh` does on install

When you run `ADAPTER=hermes bash ~/.hive-mind/hive-mind/setup.sh`:

1. It loads the Hermes adapter contract from `adapters/hermes/adapter.sh`.
2. It appends `hermes` to `~/.hive-mind/.install-state/attached-adapters`.
3. It does **not** modify any file under `~/.hermes/` (no hooks to install).

## Hooks

Hermes does not currently expose a stable hook surface, so the adapter declares `ADAPTER_HAS_HOOK_SYSTEM=false` and `ADAPTER_FALLBACK_STRATEGY=manual`. Sync runs when:

- Another attached adapter (`claude-code`, `codex`) fires its Stop hook — the shared hub sync engine harvests and fans out every attached adapter on the same cycle, so Hermes piggybacks for free.
- You run `hivemind sync` manually.

A standalone-Hermes install (no other adapter attached) will not auto-sync until either condition above is met. Adding a polling/watcher fallback is a possible future enhancement.

## After install

There is no Hermes-side restart step. The next sync triggered by any other adapter (or `hivemind sync`) will harvest the current state of `~/.hermes/` into `hub/hermes/`. On a second machine, fan-out reproduces the same tree in place.

See [Get started](/get-started) for the install flow and [Technical reference](/reference) for the hub details.
