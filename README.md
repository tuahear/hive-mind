# hive-mind

Git-backed auto-sync for your AI coding assistant's memory and config, across
machines. Currently supports Claude Code (`~/.claude`); designed to grow.

Ever discover a useful preference or project insight while working on your
laptop, only to lose it when you switch to your desktop? hive-mind makes that
knowledge portable: memory files and global config live in a private git
repo, pulled at session start and pushed whenever an agent writes something.

## What gets synced

Across any machine running this setup:

- **Global config** — `settings.json` (hooks, permissions, model defaults)
- **Global instructions** — `CLAUDE.md` (cross-project preferences)
- **Per-project memory** — `projects/*/memory/` (auto-memory records)

Everything else in `~/.claude/` (session transcripts, shell history, IDE
state, plugin caches) stays local — the `.gitignore` whitelist only tracks
portable bits.

## Install

1. **Create a private GitHub repo** for your memory — empty, no README or
   license. Name it whatever you like (e.g. `<you>/claude-memory`).
2. **Run the installer**, passing your repo's SSH URL:

   ```bash
   MEMORY_REPO=git@github.com:<you>/<your-memory-repo>.git \
     bash -c "$(curl -fsSL https://raw.githubusercontent.com/tuahear/hive-mind/main/setup.sh)"
   ```

3. **Activate the hooks** in Claude Code by typing `/hooks` at the prompt,
   or by starting a fresh session. Hooks added mid-session need a reload to
   take effect.

### What the installer does

- Detects state: fresh machine / already synced / existing local memory
- Backs up `~/.claude` before anything destructive (to `~/.claude.backup-<ts>`)
- Clones this repo to `~/.claude/sync/` (gitignored by the memory repo)
- Seeds `~/.claude/.gitignore` + `.gitattributes` from `templates/`
- Clones your memory repo, or merges it with your local state via
  `--allow-unrelated-histories` when you already have local memories
- Merges the hook config from `templates/settings.json` into your existing
  `~/.claude/settings.json` (doesn't replace)
- Runs a verification sync cycle

### Prerequisites

- `git`, `jq`, `curl`
- An SSH key on the machine, added to your GitHub account
- Claude Code installed
- On Windows: **Git Bash** (bundled with Git for Windows) — `setup.sh` needs
  bash; does not run in PowerShell or cmd

## How it works at runtime

Two hooks registered in `settings.json`:

| Event | Behavior |
|---|---|
| `SessionStart` | `git pull --rebase --autostash`, then `check-dupes.sh` nudges the model if union-merged duplicates exist in memory files |
| `Stop` (end of each turn) | `sync.sh`: early-exits in ~20ms if nothing changed; otherwise pull, commit, push |

Failures (network down, push rejected) log to `~/.claude/.sync-error.log`
without blocking the session.

### Conflict resolution

Concurrent edits to `CLAUDE.md` or `projects/**/*.md` auto-merge via git's
`union` driver (see [templates/gitattributes](templates/gitattributes)) —
both sides' conflicting hunks are concatenated. Duplicates are possible but
`check-dupes.sh` flags them to the next session for cleanup.

`settings.json` conflicts (rare, since it's rarely agent-edited) require
manual merge — would break JSON otherwise.

## Manual sync

Auto-sync covers normal use. For a mid-session force-sync from anywhere:

```bash
~/.claude/sync/scripts/sync.sh
```

Handy alias — add to `~/.zshrc` / `~/.bashrc`:

```bash
alias csync='~/.claude/sync/scripts/sync.sh'
```

## Disable temporarily

```bash
jq 'del(.hooks)' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

Or stop pushing while keeping everything else:

```bash
git -C ~/.claude remote remove origin
```

## Repo layout

```
hive-mind/
├── setup.sh              ← installer
├── scripts/
│   ├── sync.sh           ← pull-rebase + commit + push, gated on local changes
│   └── check-dupes.sh    ← SessionStart helper: flag union-merge duplicates
├── templates/
│   ├── gitignore         ← memory-repo whitelist
│   ├── gitattributes     ← union merge driver
│   └── settings.json     ← hook snippet merged into ~/.claude/settings.json
├── .gitignore
├── .gitattributes
├── LICENSE               ← MIT
└── README.md
```

## License

MIT — see [LICENSE](LICENSE).
