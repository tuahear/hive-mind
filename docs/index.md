---
layout: home

hero:
  name: "hive-mind"
  text: "One memory. Every AI coding tool. Every machine."
  tagline: Attach Claude Code, Codex, Qwen, or Kimi to one hub. Sync through your own private git repo. Teach it once — everywhere.
  actions:
    - theme: brand
      text: Get started
      link: /#get-started-in-3-steps
    - theme: alt
      text: View on GitHub
      link: https://github.com/tuahear/hive-mind

features:
  - title: 🧭 AI-agnostic
    details: "One memory across Claude, Codex, Qwen, and Kimi. Swap tools, add tools, or try new ones — your memory moves with you."
  - title: 🪶 Ultralight
    details: ~175 tokens fully loaded, ~85 tokens idle. Almost zero context overhead.
  - title: 🔒 Your data, your repo
    details: Memory lives in a private git repo you control. No vendor lock-in.
  - title: 🌐 Synced everywhere
    details: Global and project memories stay in sync across every machine. macOS, Linux, Windows.
  - title: 📚 Meaningful git history
    details: Every lesson is auto-committed — git log becomes your AI's learning journal.
  - title: 🔁 Works offline
    details: Sync failures retry next turn. Your AI never blocks on a bad network.
---

## The problem

You teach Claude Code something useful today — a project quirk, a shell preference, a debugging insight. Tomorrow you reach for Codex, or try Qwen on a side task, or open the same project on another machine. They all start from zero. You re-explain everything, every time.

hive-mind fixes that. A single `~/.hive-mind/` hub per machine holds one canonical memory. You attach each AI tool to the hub, and the hub keeps each tool's native memory files in sync without forcing any of them to change. Claude Code keeps writing to `~/.claude/CLAUDE.md`, Codex keeps reading `~/.codex/AGENTS.md`, and so on. Same hub on a second machine pulls from the same private git repo, so whatever you teach Claude on your laptop shows up in Codex on your desktop.

```
   ┌─────────────────────────────────────────────────────┐
   │  ~/.hive-mind/ hub (one per machine, one git repo)  │
   │                                                     │
   │   content.md ── skills/ ── projects/<id>/           │
   │                                                     │
   │  ├─ attached ──▶ ~/.claude/   (CLAUDE.md, skills)   │
   │  ├─ attached ──▶ ~/.codex/    (AGENTS.md, ...)      │
   │  ├─ attached ──▶ ~/.qwen/     (QWEN.md, ...)        │
   │  └─ attached ──▶ ~/.kimi/     (KIMI.md, ...)        │
   └──────────────────────┬──────────────────────────────┘
                          │ push/pull
                          ▼
            ┌───────────────────────────────┐
            │  your private memory git repo │
            └───────────────────────────────┘
                          ▲
                          │
       same hub on a second machine pulls the same content down
```

Only using one AI tool on one computer today? hive-mind still earns its keep: automatic memory backup, a full `git log` of every memory edit, easy rollback if a bad memory gets written, and your memory stays in your own private repo — not a vendor cloud. The day you add a second tool or a second machine, nothing in your workflow changes.

## Get started in 3 steps

### 1. Make an empty private git repo

Any git host works — GitHub, GitLab, Bitbucket, Codeberg, self-hosted, even a local bare repo on another machine. No README, no license, no `.gitignore`. Just an empty box to hold your memory.

### 2. Run the installer

```bash
MEMORY_REPO=<your-memory-repo-url> \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/tuahear/hive-mind/main/setup.sh)"
```

`MEMORY_REPO` accepts any URL `git` understands — SSH, HTTPS, or a local bare repo. Works on macOS, Linux, and Windows (Git Bash).

To attach a second tool later (once its adapter ships) it's the same installer with a different `ADAPTER=`:

```bash
ADAPTER=codex bash setup.sh   # same memory, second tool
```

### 3. Reload Claude Code

Type `/hooks` in any session or start a fresh one — the sync hooks activate. That's it.
