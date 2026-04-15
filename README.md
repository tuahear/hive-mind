# 🧠 hive-mind

**Your AI's memory, synced across every machine you work on.**

You teach Claude something useful on your laptop in the morning — a project quirk, a shell preference, a debugging insight. By lunchtime you're at your desktop and Claude has no idea. You explain it again. And again tomorrow on the work machine.

hive-mind fixes that. Memory files live in your own private Git repo, quietly pulled when Claude starts a session and pushed back when it finishes. Your assistant carries every lesson forward, everywhere.

```
  laptop ──┐                  ┌── desktop
           │                  │
           ▼                  ▼
     ┌──────────────────────────────┐
     │  your private memory repo    │   ← GitHub (or your own remote)
     │  (CLAUDE.md, projects/,      │
     │   skills/, settings)         │
     └──────────────────────────────┘
           ▲                  ▲
           │                  │
  work mac ┘                  └── any new machine you set up
```

---

## Get started in 3 steps

### 1. Make an empty private GitHub repo

No README, no license, no `.gitignore`. Just an empty box to hold your memory. Name it whatever feels right — `claude-memory`, `brain`, `second-brain`.

### 2. Run the installer

```bash
MEMORY_REPO=git@github.com:<you>/<your-memory-repo>.git \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/tuahear/hive-mind/main/setup.sh)"
```

Works on macOS, Linux, and Windows (Git Bash). You need: `git`, an SSH key registered with GitHub, and Claude Code installed.

### 3. Reload Claude Code

Type `/hooks` in any session or start a fresh one — the sync hooks activate. That's it. Every future edit to your memory gets committed and pushed automatically.

---

## Ultra-light skill

Two things by design: the `hive-mind` skill adds **almost nothing** to your context, and those few tokens only load when actually needed. An idle session sees only the one-line skill description (~80 tokens); the body (~110 tokens) loads on demand, only while Claude is editing a memory or skill file. **Fully loaded: only ~190 tokens.**

---

## What gets synced

Only the portable stuff. Machine-local noise (session transcripts, shell history, IDE state, plugin caches) stays out by default.

| File | What it is |
|---|---|
| `CLAUDE.md` | Your global instructions (the preferences that apply to every project) |
| `projects/<name>/MEMORY.md` | Per-project memory index — the TOC of what you've taught Claude about each project |
| `projects/<name>/memory/*.md` | Individual per-project memory entries |
| `skills/*/` | Claude's "skills" (on-demand playbooks that load when relevant) |
| `settings.json` | Global hook + permission config |

The bundled **`hive-mind` skill** installs automatically — it teaches your agent to embed one-line commit markers in memory edits, which sync.sh extracts as the git commit message. Every change to your memory gets a real, meaningful commit in git log.

---

## How it works (the short version)

Two hooks do everything:

- **Session starts** → `git pull --rebase` from your memory repo so you're caught up with what another machine wrote since you were last here
- **Agent turn ends** → if anything changed, commit + push in ~1 second

Between those two moments, no network traffic. Claude runs at full speed. If the network is down, sync fails silently and retries next turn.

### The cross-machine story

```
Monday 10am:  laptop — you ask Claude to remember a new Kafka setup gotcha
                       ↓
              agent writes projects/kafka-thing/memory/gotcha.md
                       ↓
              Stop hook fires → commit → push
                       ↓
                   (github)

Monday 2pm:   desktop — you start a Claude session
                       ↓
              SessionStart hook → pull
                       ↓
              Claude sees Monday-10am's memory and continues where laptop left off
```

No copy-paste between machines, no forgetting what you told Claude where.

---

## Features you'll appreciate

- **Backups before anything destructive.** The installer copies `~/.claude` to `~/.claude.backup-<timestamp>` before touching a thing.
- **Works offline.** Sync failures log to `~/.claude/.sync-error.log` and retry next turn. Claude never blocks on a bad network.
- **Conflict-tolerant.** Concurrent memory edits from two machines auto-merge via git's `union` driver (concatenates both sides). A tiny `check-dupes.sh` flags duplicates for the next session to clean up.
- **Meaningful git history.** The bundled `hive-mind` skill trains your agent to drop a one-line commit marker with each edit — so `git log` reads like a changelog, not `update file.md` stubs.
- **Whitelist-only `.gitignore`.** Default is "ignore everything, re-allow portable bits." No risk of accidentally committing session-secret files.

---

## Manual control

Auto-sync covers normal use. For the odd moment you want explicit action, add these to `~/.zshrc` / `~/.bashrc`:

```bash
# Pull latest memory (read-only, use mid-session to catch up on what another
# machine wrote)
alias mind='git -C ~/.claude pull --rebase --autostash'

# Full bidirectional sync — pull then stage/commit/push. Same thing the Stop
# hook runs; use when you want local changes pushed immediately.
alias msync='~/.claude/hive-mind/scripts/sync.sh'
```

## Temporarily disable

Remove the hooks (keeps everything else intact):

```bash
jq 'del(.hooks)' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

Or stop pushing without removing hooks:

```bash
git -C ~/.claude remote remove origin
```

---

## How it works (technical deep-dive)

### Hooks registered in `settings.json`

| Event | Script | Behavior |
|---|---|---|
| `SessionStart` | `scripts/check-dupes.sh` | `git pull --rebase --autostash`, then scan memory files for union-merge duplicates and nudge the model to clean them up |
| `Stop` (end of each turn) | `scripts/sync.sh` | Early-exit in ~20 ms if nothing changed; otherwise pull-rebase, commit, push |

### Commit marker convention

The bundled `hive-mind` skill instructs Claude to embed an HTML comment like `<!-- commit: <one-line summary> -->` inside any memory/skill edit. `sync.sh` extracts non-fenced markers, joins them with ` + ` across files, strips them from disk (so they never enter history), then commits with that message. Markers inside ` ``` ` code fences are preserved — lets the skill's own docs show example markers without triggering extraction.

Fallback (no markers found): `update <basename>` or `update <f1>, <f2>, <f3>, +N more` so even uninstrumented edits get a recognizable commit message.

### What gets synced vs ignored

The memory repo's `.gitignore` (seeded from [templates/gitignore](templates/gitignore)) is whitelist-only:

- `!/CLAUDE.md`
- `!/settings.json` (via a hook snippet merge, not wholesale replacement)
- `!/projects/*/MEMORY.md` — per-project index
- `!/projects/*/memory/` — per-project memory entries
- `!/skills/**` — skill definitions (including any scripts or resources)

Everything else under `~/.claude/` stays local by default.

### Conflict resolution

Text-content conflicts in `CLAUDE.md` or `projects/**/*.md` auto-merge with git's `union` driver (concatenates both sides' hunks). Duplicates may result; `check-dupes.sh` detects union-merged regions and asks the next session to dedupe.

`settings.json` merges are trickier because JSON breaks under union semantics. We register a custom `jsonmerge` driver (in `scripts/jsonmerge.sh`) that deep-merges both versions of `settings.json` at the key level and unions the `permissions.allow` array.

### Repo layout

```
hive-mind/
├── setup.sh                      ← installer (run once per machine)
├── scripts/
│   ├── sync.sh                   ← Stop-hook: pull + commit + push
│   ├── check-dupes.sh            ← SessionStart-hook: union-merge duplicate detector
│   ├── jsonmerge.sh              ← custom git merge driver for settings.json
│   └── install-dev-hooks.sh      ← maintainer-only; pre-commit hook for this repo
├── templates/
│   ├── gitignore                 ← whitelist-only pattern dropped into memory repo
│   ├── gitattributes             ← union driver + jsonmerge driver bindings
│   ├── settings.json             ← hook + permission snippet merged into user settings
│   └── skills/
│       └── hive-mind/            ← bundled skill that teaches the commit-marker convention
├── LICENSE
└── README.md
```

---

## Contributing / development

This README is for end users. If you want to hack on hive-mind itself:

1. Fork the repo and clone
2. Run `scripts/install-dev-hooks.sh` once in your clone — installs a pre-commit hook that keeps bundled skills clean
3. Edit `templates/skills/hive-mind/SKILL.md` to change skill content (not the copy in `~/.claude/skills/hive-mind/` — that's the user-facing install target)
4. PRs welcome

---

## Troubleshooting

**"Permission denied (publickey)" on push** — your GitHub SSH key isn't set up on this machine. Add one: <https://github.com/settings/keys>.

**Hooks don't fire** — Claude Code needs to reload them. Type `/hooks` in an active session, or start a fresh one.

**`.sync-error.log` fills up** — check the log; usually a push rejection from someone else pushing first. Next turn's auto-rebase-and-retry clears it. If it doesn't, run `git -C ~/.claude pull --rebase --autostash` and `git -C ~/.claude push` manually.

**I accidentally committed something sensitive** — git history is permanent. Rotate the secret, force-push a cleaned history, and consider amending the `.gitignore` to prevent recurrence.

---

## License

MIT — see [LICENSE](LICENSE).

Built for [Claude Code](https://claude.com/claude-code), architected to grow for any AI assistant that keeps memory in a directory.
