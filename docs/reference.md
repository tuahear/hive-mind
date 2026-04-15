# Technical reference

## Hooks registered in `settings.json`

| Event | Script | Behavior |
|---|---|---|
| `SessionStart` | `scripts/check-dupes.sh` | `git pull --rebase --autostash`, then scan memory files for union-merge duplicates and nudge the model to clean them up |
| `Stop` (end of each turn) | `scripts/sync.sh` | Early-exit in ~20 ms if nothing changed; otherwise pull-rebase, commit, push |

## Commit marker convention

The bundled `hive-mind` skill instructs the agent to embed an HTML comment like `<!-- commit: <one-line summary> -->` inside any memory/skill edit. `sync.sh` extracts non-fenced markers, joins them with ` + ` across files, strips them from disk (so they never enter history), then commits with that message. Markers inside ` ``` ` code fences are preserved — lets the skill's own docs show example markers without triggering extraction.

Fallback (no markers found): `update <basename>` or `update <f1>, <f2>, <f3>, +N more` so even uninstrumented edits get a recognizable commit message.

## What gets synced vs ignored

The memory git repo's `.gitignore` is whitelist-only:

- `!/CLAUDE.md`
- `!/settings.json` (via a hook snippet merge, not wholesale replacement)
- `!/projects/*/MEMORY.md` — per-project index
- `!/projects/*/memory/` — per-project memory entries
- `!/skills/**` — skill definitions (including any scripts or resources)

Everything else under `~/.claude/` stays local by default.

## Conflict resolution

Text-content conflicts in `CLAUDE.md` or `projects/**/*.md` auto-merge with git's `union` driver (concatenates both sides' hunks). Duplicates may result; `check-dupes.sh` detects union-merged regions and asks the next session to dedupe.

`settings.json` merges are trickier because JSON breaks under union semantics. We register a custom `jsonmerge` driver (in `scripts/jsonmerge.sh`) that deep-merges both versions of `settings.json` at the key level and unions the `permissions.allow` array.

## Repo layout

```
hive-mind/
├── setup.sh                      ← installer (run once per machine)
├── scripts/
│   ├── sync.sh                   ← Stop-hook: pull + commit + push
│   ├── mirror-projects.sh        ← pre-commit: mirror project memory across path-variant dirs
│   ├── check-dupes.sh            ← SessionStart-hook: union-merge duplicate detector
│   ├── jsonmerge.sh              ← custom git merge driver for settings.json
│   └── install-dev-hooks.sh      ← maintainer-only; pre-commit hook for this repo
├── templates/
│   ├── gitignore                 ← whitelist-only pattern dropped into memory git repo
│   ├── gitattributes             ← union driver + jsonmerge driver bindings
│   ├── settings.json             ← hook + permission snippet merged into user settings
│   └── skills/
│       └── hive-mind/            ← bundled skill that teaches the commit-marker convention
├── LICENSE
└── README.md
```

## Roadmap: AI-agnostic

hive-mind currently plugs into Claude Code's hook + skill surfaces. The architecture underneath — a git-backed memory directory, event-driven sync, portable file conventions — is deliberately independent of which AI reads those files. As other assistants (Cursor, Aider, Windsurf, local agents, …) stabilise similar hook and skill mechanisms, hive-mind is built to grow with them: swap the CLI-specific adapter, keep the sync core.

If you maintain an AI coding assistant that stores memory in a directory and runs per-session / per-turn hooks, a hive-mind adapter for your tool is likely a few hundred lines of shell at most. PRs and issues welcome.
