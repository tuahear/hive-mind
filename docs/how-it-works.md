# How it works

Two hooks do everything:

- **Session starts** → `git pull --rebase` from your memory git repo so you're caught up with what another tool or another machine wrote since you were last here.
- **Agent turn ends** → if anything changed, harvest into the hub, commit + push, then fan out to every other attached tool on this machine. All in ~1 second.

Between those two moments, no network traffic. Your AI runs at full speed. If the network is down, sync fails silently and retries next turn.

## The cross-provider story

You've attached both Claude Code and Codex to the same hub on one machine.

1. You teach Claude Code something useful. It writes to `~/.claude/CLAUDE.md`.
2. Claude's Stop hook fires → harvest reads `CLAUDE.md` into `~/.hive-mind/content.md` → commit + push.
3. Still inside that same Stop hook: fan-out rewrites `~/.codex/AGENTS.md` from the updated hub.
4. Next time you open Codex, the lesson is already there.

No manual sync, no re-teaching. Same flow applies to per-project memory, skills, permissions, and hooks.

## The cross-machine story

```
Monday 10am:  laptop — you ask your AI to remember a new Kafka setup gotcha
                       ↓
              agent writes projects/kafka-thing/memory/gotcha.md
                       ↓
              Stop hook fires → commit → push
                       ↓
              (your memory git remote)

Monday 2pm:   desktop — you start a new AI session
                       ↓
              SessionStart hook → pull
                       ↓
              your AI sees Monday-10am's memory and continues where laptop left off
```

No copy-paste between machines, no forgetting what you told it where.

## What gets synced

Only the portable stuff. Machine-local noise (session transcripts, shell history, IDE state, plugin caches) stays out by default.

| File | What it is |
|---|---|
| `CLAUDE.md` | Your global instructions (the preferences that apply to every project) |
| `projects/<name>/MEMORY.md` | Per-project memory index |
| `projects/<name>/memory/*.md` | Individual per-project memory entries |
| `skills/*/` | Claude Code's on-demand playbooks |
| `settings.json` | Global hook + permission config |

The bundled `hive-mind` skill installs automatically — it teaches your agent to embed one-line commit markers in memory edits, which `sync.sh` extracts as the git commit message. Every change to your memory gets a real, meaningful commit in `git log`.

## Auto-bridging project memory

Same repo on two machines often lives in two totally different folders under the hood — the path encoding bakes in your OS and username, so `/Users/alice/Repo/foo` on Mac and `C:\Users\bob\Repo\foo` on Windows look like unrelated projects to Claude Code.

hive-mind auto-bridges them. If both variants' underlying project points at the same git remote, hive-mind treats them as one project and keeps their memory in sync — no setup, no config. An edit on one machine cleanly replaces the old content on the others; true concurrent additions from two offline machines merge together; projects with different remotes (or no remote) stay isolated.

## Manual control

Auto-sync covers normal use. For the odd moment you want explicit action, add these to `~/.zshrc` / `~/.bashrc`:

```bash
# Pull latest memory (read-only, use mid-session to catch up)
alias mind='git -C ~/.hive-mind pull --rebase --autostash'

# Full bidirectional sync — pull then stage/commit/push, also fans out
# back into every attached adapter's tool dir.
alias msync='~/.hive-mind/bin/sync'
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
