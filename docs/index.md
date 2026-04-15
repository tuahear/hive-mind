---
layout: home

hero:
  name: "hive-mind"
  text: "Your AI's memory, synced across every machine."
  tagline: Git-backed auto-sync for Claude Code. Teach it once, remember everywhere.
  actions:
    - theme: brand
      text: Get started
      link: /#get-started-in-3-steps
    - theme: alt
      text: View on GitHub
      link: https://github.com/tuahear/hive-mind

features:
  - title: 🪶 Ultra-light
    details: ~175 tokens fully loaded, ~85 tokens idle. Almost zero context overhead.
  - title: 🔁 Works offline
    details: Sync failures retry next turn. Your AI never blocks on a bad network.
  - title: 🧬 Conflict-tolerant
    details: Concurrent edits from two machines auto-merge via git's union driver.
  - title: 🧭 Path-encoding tolerant
    details: Same project on Mac + Windows maps to one shared memory.
  - title: 📜 Meaningful git history
    details: Bundled skill trains your agent to drop one-line commit markers per edit.
  - title: 🔒 Whitelist-only .gitignore
    details: No risk of leaking session-secret files.
---

## The problem

You teach your AI something useful on your laptop in the morning — a project quirk, a shell preference, a debugging insight. By lunchtime you're at your desktop and it has no idea. You explain it again. And again tomorrow on the work machine.

hive-mind fixes that. It's a **Claude Code skill** today. Your existing memory files stay exactly where they are — hive-mind doesn't migrate, move, or reformat anything; it installs on top of whatever you already have and starts syncing it to your private git repo. Quietly pulled when your AI starts a session, pushed back when it finishes.

```
  laptop ──┐                  ┌── desktop
           │                  │
           ▼                  ▼
     ┌───────────────────────────────┐
     │  your private memory git repo │   ← any git remote you control
     │  (CLAUDE.md, projects/,       │
     │   skills/, settings)          │
     └───────────────────────────────┘
           ▲                  ▲
           │                  │
  work mac ┘                  └── any new machine you set up
```

Only using one computer? hive-mind still earns its keep: automatic memory backup, a full `git log` of every memory edit, easy rollback if a bad memory gets written, and your memory stays in your own private repo — not a vendor cloud.

## Get started in 3 steps

### 1. Make an empty private git repo

Any git host works — GitHub, GitLab, Bitbucket, Codeberg, self-hosted, even a local bare repo on another machine. No README, no license, no `.gitignore`. Just an empty box to hold your memory.

### 2. Run the installer

```bash
MEMORY_REPO=<your-memory-repo-url> \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/tuahear/hive-mind/main/setup.sh)"
```

`MEMORY_REPO` accepts any URL `git` understands — SSH, HTTPS, or a local bare repo. Works on macOS, Linux, and Windows (Git Bash).

### 3. Reload Claude Code

Type `/hooks` in any session or start a fresh one — the sync hooks activate. That's it.
