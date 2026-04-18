# Technical reference

## Hooks registered in `settings.json`

Every attached AI tool registers the same single entry point in its native hook config. For Claude Code that's `~/.claude/settings.json`:

| Event | Command | Behavior |
|---|---|---|
| `SessionStart` | `"$HOME/.hive-mind/bin/hivemind-hook[.exe]" claude-code session-start "<claude-dir>"` | Native launcher entrypoint. Shells into hub sync first, then `check-dupes.sh`, so a new session on a second machine sees cross-machine edits immediately |
| `Stop` (end of each turn) | `"$HOME/.hive-mind/bin/hivemind-hook[.exe]" claude-code stop` | Native launcher entrypoint. Shells into the hub sync entry point, which harvests the tool dir → hub, pull-rebase-pushes the shared memory repo, and fans the merged state back out to every attached tool |
| `PostToolUse` on `Edit|Write|NotebookEdit` | `"$HOME/.hive-mind/bin/hivemind-hook[.exe]" claude-code post-tool-use "<claude-dir>"` | Native launcher entrypoint. Shells into `marker-nudge.sh`, which reminds the model to drop a `<!-- commit: ... -->` marker when it edits memory |

Other adapters can reuse the same native launcher while mapping their own hook events/actions to the appropriate helper scripts — see [Adapters](./adapters/).

## Commit marker convention

The bundled `hive-mind` skill instructs the agent to embed an HTML comment like `<!-- commit: <one-line summary> -->` inside any memory/skill edit. The hub sync extracts non-fenced markers, joins them with ` + ` across files, strips them from disk (so they never enter history), then commits with that message. Markers inside ` ``` ` code fences are preserved — lets the skill's own docs show example markers without triggering extraction.

Fallback (no markers found): `update <basename>` or `update <f1>, <f2>, <f3>, +N more` so even uninstrumented edits get a recognizable commit message.

## Hub schema

The shared memory git repo's `.gitignore` (written from `core/hub/gitignore`) whitelists only:

- `!/content.md` — canonical global content (maps to CLAUDE.md, AGENTS.md, etc.)
- `!/projects/<project-id>/content.md` + `!/projects/<project-id>/**` — canonical per-project content (subdirs preserved via project rules)
- `!/skills/**` — provider-agnostic skill definitions
- `!/config/env.sh` — reserved for v0.3.1+ (cross-provider env vars)
- `!/.hive-mind-format` — format-version gate file

Machine-local state stays out: `hive-mind/` (source clone), `bin/` (symlinked entry), `.install-state/attached-adapters`, `.hive-mind-state/` (lock + last-push).

## Conflict resolution

Text-content conflicts on `content.md` and `projects/**/*.md` auto-merge with git's built-in `union` driver (concatenates both sides' hunks) — configured in `core/hub/gitattributes`. Duplicates may result; `core/check-dupes.sh` detects union-merged regions from the SessionStart hook and asks the next session to dedupe.

Shared hub conflicts are line-oriented by design: global/project markdown content merges through git's union driver, while skill files pass through as ordinary files. Tool-local configs such as Claude's `settings.json` and Codex's `hooks.json` stay out of the hub; the `jsonmerge`/`tomlmerge` drivers in `core/` remain available for adapters that want local config-aware merges or future schema extensions.

## Repo layout

```
hive-mind/
├── cmd/
│   └── hivemind-hook/            ← native hook launcher (Codex + Claude entrypoint)
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
│       ├── claude-hook-session-start.sh ← Claude SessionStart wrapper
│       ├── claude-hook-stop.sh    ← Claude Stop wrapper
│       ├── claude-hook-post-tool-use.sh ← Claude PostToolUse wrapper
│       ├── codex-hook-session-start.sh ← Codex SessionStart wrapper
│       ├── codex-hook-stop.sh     ← Codex Stop wrapper
│       ├── sync.sh                ← THE hub sync entry point (installed to bin/sync)
│       ├── harvest-fanout.sh      ← bidirectional tool ↔ hub mapper
│       ├── project-gc.sh          ← orphan-variant GC
│       ├── gitignore              ← hub-level whitelist
│       └── gitattributes          ← hub-level merge-driver bindings
├── adapters/
│   ├── claude-code/
│   │   ├── adapter.sh             ← contract surface for Claude Code
│   │   ├── settings.json          ← hook template (installed into ~/.claude/)
│   │   ├── gitignore              ← reserved (per-adapter tool-dir ignores)
│   │   ├── gitattributes          ← reserved (per-adapter tool-dir attrs)
│   │   ├── skills/                ← bundled skills (installed into hub)
│   │   └── tests/                 ← Claude-specific adapter tests
│   └── codex/
│       ├── adapter.sh             ← contract surface for Codex CLI
│       ├── hooks.json             ← hook template (installed into ~/.codex/)
│       ├── skills/                ← bundled skills (installed into hub)
│       └── tests/                 ← Codex-specific adapter tests
├── scripts/
│   └── install-dev-hooks.sh       ← maintainer-only; pre-commit for this repo
├── tests/                         ← bats test suite (see ./test runner)
└── docs/                          ← docs site
```
