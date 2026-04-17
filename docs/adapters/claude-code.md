# Claude Code adapter

The Claude Code adapter attaches [Claude Code](https://claude.com/claude-code) to your `~/.hive-mind/` hub. After install, Claude Code still reads and writes its native files in `~/.claude/` — `CLAUDE.md`, per-project memory under `~/.claude/projects/`, skills under `~/.claude/skills/` — but those files now flow through the hub on every session boundary.

## What `setup.sh` does on install

When you run the installer (the default `ADAPTER=claude-code` is assumed if you don't set one):

1. **Clones hive-mind** into `~/.hive-mind/hive-mind/` (machine-local, gitignored).
2. **Creates the hub repo** at `~/.hive-mind/.git` with your `MEMORY_REPO` as `origin`.
3. **Seeds bundled skills** — including the `hive-mind` skill that teaches the agent to embed commit markers in memory edits — into `~/.hive-mind/skills/`.
4. **Registers three hooks** in `~/.claude/settings.json` (details below).
5. **Runs `adapter_migrate`** to bring pre-0.3 installs forward to the hub topology.

## Hooks registered in `~/.claude/settings.json`

| Event | Command | Purpose |
|---|---|---|
| `SessionStart` | `"$HOME/.hive-mind/bin/sync"` then `"$HOME/.hive-mind/hive-mind/core/check-dupes.sh"` | Pulls fresh memory from the hub remote, then scans for union-merge duplicates and nudges the model to clean them up. |
| `Stop` (end of each turn) | `"$HOME/.hive-mind/bin/sync"` | Harvests `~/.claude/` into the hub, pull-rebase-pushes the shared repo, fans the merged state back out. |
| `PostToolUse` on `Edit\|Write\|NotebookEdit` | `"$HOME/.hive-mind/hive-mind/core/marker-nudge.sh"` | Reminds the model to drop a `<!-- commit: ... -->` marker so the next sync gets a meaningful commit subject. |

## Memory file mapping

The adapter declares two mapping strings for the hub root and per-project content (`ADAPTER_HUB_MAP` and `ADAPTER_PROJECT_CONTENT_RULES`) that the hub sync engine reads bidirectionally:

| Hub path | Claude-side path |
|---|---|
| `content.md` | `~/.claude/CLAUDE.md` |
| `config/hooks` | `~/.claude/settings.json#hooks` |
| `config/permissions/{allow,deny,ask}.txt` | `~/.claude/settings.json#permissions.{allow,deny,ask}` |
| `projects/<id>/content.md` | `~/.claude/projects/<encoded-cwd>/MEMORY.md` |
| `projects/<id>/memory/` | `~/.claude/projects/<encoded-cwd>/memory/` |

Skills are synced separately — not via `ADAPTER_HUB_MAP`. The engine walks `~/.claude/skills/<name>/` ↔ `~/.hive-mind/skills/<name>/` directly, renaming each skill's main content file (`SKILL.md` ↔ `content.md`); other files in the skill dir pass through unchanged.

Lowercase filenames on the hub side signal "hive-mind canonical".

## Migration from pre-0.3 installs

Pre-0.3 hive-mind installed the per-tool git repo at `~/.claude/.git` (the now-legacy adapter-owns-git-repo model). `adapter_migrate` (in `adapters/claude-code/adapter.sh`) runs on every `setup.sh` invocation and transparently moves the git metadata to `~/.hive-mind/.git`, updates the hook commands to point at `~/.hive-mind/bin/sync`, and preserves your memory content. Re-running `setup.sh` on a pre-0.3 install is safe and idempotent.

## After install

Type `/hooks` in any Claude Code session, or start a fresh session — the sync hooks activate. From then on:

- **SessionStart** pulls any cross-machine updates before the session renders.
- Every turn's **Stop** commits memory edits with a marker-derived commit subject and pushes them.

See [Get started](/get-started) for the full install walkthrough and [Troubleshooting](/troubleshooting) if anything fires off unexpectedly.
