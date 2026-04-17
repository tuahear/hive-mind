# 🧠 hive-mind

**One memory. Every AI coding tool. Every machine.**

📖 **Full docs: [tuahear.github.io/hive-mind](https://tuahear.github.io/hive-mind)**

You teach Claude Code something useful today — a project quirk, a shell preference, a debugging insight. Tomorrow you reach for Codex, or try Qwen on a side task, or open the same project on another machine. They all start from zero. You re-explain everything, every time.

hive-mind fixes that. A single `~/.hive-mind/` hub per machine holds one canonical memory. You attach each AI tool to the hub — Claude Code today; Codex, Qwen, and Kimi adapters planned — and the hub keeps each tool's native memory files in sync without forcing any of them to change. Claude Code keeps writing to `~/.claude/CLAUDE.md`, Codex keeps reading `~/.codex/AGENTS.md`, and so on. The hub just makes sure they all see the same thing. Same hub on a second machine pulls from the same private git repo you control, so whatever you teach Claude on your laptop shows up in Codex on your desktop.

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
            │  your private memory git repo │   ← any git remote you control
            └───────────────────────────────┘
                          ▲
                          │
       same hub on a second machine pulls the same content down
```

Only using one AI tool on one computer today? hive-mind still earns its keep: automatic memory backup, a full `git log` of every memory edit, easy rollback if a bad memory gets written, and your memory stays in your own private repo — not a vendor cloud. The day you add a second tool or a second machine, nothing in your workflow changes.

---

## Get started in 3 steps

### 1. Make an empty private git repo

Any git host works — GitHub, GitLab, Bitbucket, Codeberg, self-hosted, even a local bare repo on another machine. No README, no license, no `.gitignore`. Just an empty box to hold your memory. Name it whatever feels right — `claude-memory`, `brain`, `second-brain`.

### 2. Run the installer

```bash
MEMORY_REPO=<your-memory-repo-url> \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/tuahear/hive-mind/main/setup.sh)"
```

That attaches Claude Code to your hub. To attach a second tool later (once its adapter ships) it's the same installer, different `ADAPTER=`:

```bash
ADAPTER=codex bash setup.sh   # same memory, second tool
```

`MEMORY_REPO` accepts any URL `git` understands:

- SSH: `git@<host>:you/repo.git` (GitHub, GitLab, Bitbucket, self-hosted…)
- HTTPS: `https://<host>/you/repo.git`
- Local: `/path/to/bare.git` or `file:///path/to/bare.git`

Works on macOS, Linux, and Windows (Git Bash). You need: `git` and SSH access (or HTTPS credentials) for your memory-repo host. The installer itself clones hive-mind from GitHub over SSH once, so GitHub SSH access is required for this step only — not for ongoing sync.

### 3. Reload Claude Code

Type `/hooks` in any session or start a fresh one — the sync hooks activate. That's it. Every future edit to your memory gets committed and pushed automatically.

---

## Highlights

- **AI-agnostic** — One memory across Claude Code, Codex, Qwen, and Kimi. Swap tools, add tools, or try new ones — your memory moves with you.
- **Ultralight** — ~175 tokens fully loaded, ~85 tokens idle. Almost zero context overhead.
- **Your data, your repo** — Memory lives in a private git repo you control. No vendor lock-in.
- **Synced everywhere** — Global and project memories stay in sync across every machine. macOS, Linux, Windows.
- **Meaningful git history** — Every lesson is auto-committed — git log becomes your AI's learning journal.
- **Works offline** — Sync failures retry next turn. Your AI never blocks on a bad network.

Deeper explanations of each — plus the sync flow, conflict resolution, commit marker convention, and repo layout — live in the **[docs site](https://tuahear.github.io/hive-mind)**.

---

## Adapter status

| Adapter | Tool | Status |
|---|---|---|
| `claude-code` | [Claude Code](https://claude.com/claude-code) | Shipped |
| `codex` | [OpenAI Codex CLI](https://github.com/openai/codex) | Planned ([#11](https://github.com/tuahear/hive-mind/issues/11)) |
| `qwen` | [Qwen CLI](https://github.com/QwenLM/qwen-code) | Planned ([#19](https://github.com/tuahear/hive-mind/issues/19)) |
| `kimi` | [Kimi CLI](https://github.com/MoonshotAI/kimi-cli) | Planned ([#23](https://github.com/tuahear/hive-mind/issues/23)) |

Writing a new adapter is mostly declaring two mapping strings (`ADAPTER_HUB_MAP`, `ADAPTER_PROJECT_CONTENT_RULES`) plus a few contract functions — a few hundred lines of shell at most. See [docs/CONTRIBUTING-adapters.md](docs/CONTRIBUTING-adapters.md). PRs and issues welcome.

---

## Contributing / development

This README is for end users. If you want to hack on hive-mind itself:

1. Fork the repo and clone
2. Run `scripts/install-dev-hooks.sh` once in your clone — installs a pre-commit hook that keeps bundled skills clean
3. Edit `adapters/claude-code/skills/hive-mind/content.md` to change the bundled Claude skill (not the copy in `~/.claude/skills/hive-mind/` — that's a user-facing install target that gets refreshed each time setup.sh runs)
4. Install [bats-core](https://github.com/bats-core/bats-core) + GNU `parallel` — `brew install bats-core parallel` (macOS), `apt install bats parallel` (Linux). Run `./test` from the repo root.
5. PRs welcome

---

## Troubleshooting

See the **[troubleshooting page](https://tuahear.github.io/hive-mind/troubleshooting)** on the docs site — covers SSH auth errors, hooks not firing, `.sync-error.log`, rename-induced project-id drift, and projects without an `origin` remote.

---

## License

MIT — see [LICENSE](LICENSE).

Built for multi-provider AI tooling. Claude Code is the first shipped adapter; the architecture is designed to grow.
