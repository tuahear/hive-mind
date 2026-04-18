# Claude Code adapter

The Claude Code adapter attaches [Claude Code](https://claude.com/claude-code) to your `~/.hive-mind/` hub. After install, Claude Code still reads and writes its native files in `~/.claude/` — `CLAUDE.md`, per-project memory under `~/.claude/projects/`, skills under `~/.claude/skills/` — but those files now flow through the hub on every session boundary.

## What `setup.sh` does on install

When you run the installer (the default `ADAPTER=claude-code` is assumed if you don't set one):

1. **Clones hive-mind** into `~/.hive-mind/hive-mind/` (machine-local, gitignored).
2. **Creates the hub repo** at `~/.hive-mind/.git` with your `MEMORY_REPO` as `origin`.
3. **Seeds bundled skills** — including the `hive-mind` skill that teaches the agent to embed commit markers in memory edits — into `~/.hive-mind/skills/`.
4. **Builds or refreshes** the native `hivemind-hook` launcher under `~/.hive-mind/bin/`.
5. **Registers three local hooks** in `~/.claude/settings.json` (details below), pointing them at the launcher-backed entrypoint.

## Hooks registered in `~/.claude/settings.json`

| Event | Command | Purpose |
|---|---|---|
| `SessionStart` | `"$HOME/.hive-mind/bin/hivemind-hook[.exe]" claude-code session-start "<claude-dir>"` | Runs the shared launcher, which shells into hub sync first and then `check-dupes.sh` so a new Claude session sees fresh cross-machine memory before the first turn. |
| `Stop` (end of each turn) | `"$HOME/.hive-mind/bin/hivemind-hook[.exe]" claude-code stop` | Runs the shared launcher, which shells into the hub sync entry point and stays otherwise silent. |
| `PostToolUse` on `Edit\|Write\|NotebookEdit` | `"$HOME/.hive-mind/bin/hivemind-hook[.exe]" claude-code post-tool-use "<claude-dir>"` | Runs the shared launcher, which shells into `marker-nudge.sh` with the Claude dir wired in. |

## Memory file mapping

The adapter declares two mapping strings for the hub root and per-project content (`ADAPTER_HUB_MAP` and `ADAPTER_PROJECT_CONTENT_RULES`) that the hub sync engine reads bidirectionally:

| Hub path | Claude-side path |
|---|---|
| `content.md` | `~/.claude/CLAUDE.md` |
| `projects/<id>/content.md` | `~/.claude/projects/<encoded-cwd>/MEMORY.md` |
| `projects/<id>/memory/` | `~/.claude/projects/<encoded-cwd>/memory/` |

Skills are synced separately — not via `ADAPTER_HUB_MAP`. The engine walks `~/.claude/skills/<name>/` ↔ `~/.hive-mind/skills/<name>/` directly, renaming each skill's main content file (`SKILL.md` ↔ `content.md`); other files in the skill dir pass through unchanged.

`~/.claude/settings.json` is intentionally local-only. hive-mind manages only its own hook entries there during install/upgrade; Claude permissions remain machine-local and do not round-trip through the hub.

Lowercase filenames on the hub side signal "hive-mind canonical".

## After install

Type `/hooks` in any Claude Code session, or start a fresh session — the sync hooks activate. From then on:

- **SessionStart** pulls any cross-machine updates before the session renders.
- Every turn's **Stop** commits memory edits with a marker-derived commit subject and pushes them.

See [Get started](/get-started) for the full install walkthrough and [Troubleshooting](/troubleshooting) if anything fires off unexpectedly.
