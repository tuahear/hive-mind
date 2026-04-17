# Technical reference

## Hooks registered in `settings.json`

Every attached AI tool registers the same single entry point in its native hook config. For Claude Code that's `~/.claude/settings.json`:

| Event | Command | Behavior |
|---|---|---|
| `SessionStart` | `"$HOME/.hive-mind/bin/sync"` then `"$HOME/.hive-mind/hive-mind/core/check-dupes.sh"` | Pulls fresh memory from the hub remote (so a new session on a second machine sees cross-machine edits immediately), then scans for union-merge duplicates and nudges the model to clean them up |
| `Stop` (end of each turn) | `"$HOME/.hive-mind/bin/sync"` | Hub sync entry point. Harvests the tool dir → hub, pull-rebase-pushes the shared memory repo, fans the merged state back out to every attached tool |
| `PostToolUse` on `Edit|Write|NotebookEdit` | `"$HOME/.hive-mind/hive-mind/core/marker-nudge.sh"` | Reminds the model to drop a `<!-- commit: ... -->` marker when it edits memory so the next sync gets a meaningful commit subject |

Other adapters (Codex, Qwen, Kimi) will wire the same three events to the same three paths in their native hook config formats — see [Adapters](./adapters/).

## Commit marker convention

The bundled `hive-mind` skill instructs the agent to embed an HTML comment like `<!-- commit: <one-line summary> -->` inside any memory/skill edit. The hub sync extracts non-fenced markers, joins them with ` + ` across files, strips them from disk (so they never enter history), then commits with that message. Markers inside ` ``` ` code fences are preserved — lets the skill's own docs show example markers without triggering extraction.

Fallback (no markers found): `update <basename>` or `update <f1>, <f2>, <f3>, +N more` so even uninstrumented edits get a recognizable commit message.

## Hub schema

The shared memory git repo's `.gitignore` (written from `core/hub/gitignore`) whitelists only:

- `!/content.md` — canonical global content (maps to CLAUDE.md, AGENTS.md, etc.)
- `!/projects/<project-id>/content.md` + `!/projects/<project-id>/**` — canonical per-project content (subdirs preserved via project rules)
- `!/skills/**` — provider-agnostic skill definitions
- `!/config/hooks/<event>/<id>.json` — tool-agnostic hook entries
- `!/config/permissions/{allow,deny,ask}.txt` — permission rule lists
- `!/config/env.sh` — reserved for v0.3.1+ (cross-provider env vars)
- `!/.hive-mind-format` — format-version gate file

Machine-local state stays out: `hive-mind/` (source clone), `bin/` (symlinked entry), `.install-state/attached-adapters`, `.hive-mind-state/` (lock + last-push).

## Conflict resolution

Text-content conflicts on `content.md` and `projects/**/*.md` auto-merge with git's built-in `union` driver (concatenates both sides' hunks) — configured in `core/hub/gitattributes`. Duplicates may result; `core/check-dupes.sh` detects union-merged regions from the SessionStart hook and asks the next session to dedupe.

Tool-side JSON config conflicts are resolved before they hit the hub: harvest extracts the relevant subkey into the canonical hub shape (text lines for permission arrays, per-event/per-entry files for hooks), the git merge happens on those line-oriented forms, then fan-out rebuilds the JSON. The `jsonmerge`/`tomlmerge` drivers in `core/` remain available for adapters that want to carry a full JSON/TOML config through the hub unchanged.

## Repo layout

```
hive-mind/
├── setup.sh                       ← installer: set up hub + attach an adapter
├── VERSION                        ← installed hive-mind version
├── core/
│   ├── adapter-loader.sh          ← sources adapter.sh, validates contract surface
│   ├── check-dupes.sh             ← SessionStart helper (duplicate-line scanner)
│   ├── marker-nudge.sh            ← PostToolUse helper (commit-marker prompt)
│   ├── marker-extract.sh          ← fence-aware commit-marker extractor
│   ├── mirror-projects.sh         ← bootstraps project-id sidecars pre-sync
│   ├── jsonmerge.sh               ← custom git merge driver for JSON configs
│   ├── tomlmerge.sh               ← custom git merge driver for TOML configs
│   ├── log.sh                     ← shared logging helpers
│   └── hub/
│       ├── sync.sh                ← THE hub sync entry point (installed to bin/sync)
│       ├── harvest-fanout.sh      ← bidirectional tool ↔ hub mapper
│       ├── gitignore              ← hub-level whitelist
│       └── gitattributes          ← hub-level merge-driver bindings
├── adapters/
│   └── claude-code/
│       ├── adapter.sh             ← contract surface for Claude Code
│       ├── settings.json          ← hook template (installed into ~/.claude/)
│       ├── gitignore              ← reserved (per-adapter tool-dir ignores)
│       ├── gitattributes          ← reserved (per-adapter tool-dir attrs)
│       ├── skills/                ← bundled skills (installed into hub)
│       └── tests/                 ← Claude-specific adapter tests
├── scripts/
│   └── install-dev-hooks.sh       ← maintainer-only; pre-commit for this repo
├── tests/                         ← bats test suite (see ./test runner)
└── docs/                          ← docs site
```

