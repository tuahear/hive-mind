# 🧠 hive-mind

**Your AI's memory, synced across every machine you work on — and every AI coding tool on each of them.**

📖 **Full docs: [tuahear.github.io/hive-mind](https://tuahear.github.io/hive-mind)**

You teach your AI something useful on your laptop in the morning — a project quirk, a shell preference, a debugging insight. By lunchtime you're at your desktop and it has no idea. Or you're trying Codex on the side and explaining everything again in its terms.

hive-mind fixes both. It installs a single `~/.hive-mind/` hub on each machine and attaches your AI tools (Claude Code today; Codex, Qwen, Kimi planned) to it. Your existing memory files stay exactly where they are — `~/.claude/CLAUDE.md` keeps working like always — but the content flows through the hub so every attached tool on every machine shares it. Quietly pulled when your AI starts a session, pushed back when it finishes. Per-project memory auto-bridges too.

```
   ┌─────────────────────────────────────────────────────┐
   │  ~/.hive-mind/ hub (one per machine, one git repo)  │
   │                                                     │
   │   memory.md ── skills/ ── projects/<id>/            │
   │                                                     │
   │  ├─ attached ──▶ ~/.claude/   (CLAUDE.md, skills)   │
   │  ├─ attached ──▶ ~/.codex/    (AGENTS.md, ...)      │
   │  └─ attached ──▶ ~/.qwen/     (QWEN.md, ...)        │
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

Only using one computer with one AI tool? hive-mind still earns its keep: automatic memory backup, a full `git log` of every memory edit, easy rollback if a bad memory gets written, and your memory stays in your own private repo — not a vendor cloud.

---

## Get started in 3 steps

### 1. Make an empty private git repo

Any git host works — GitHub, GitLab, Bitbucket, Codeberg, self-hosted, even a local bare repo on another machine. No README, no license, no `.gitignore`. Just an empty box to hold your memory. Name it whatever feels right — `claude-memory`, `brain`, `second-brain`.

### 2. Run the installer

```bash
MEMORY_REPO=<your-memory-repo-url> \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/tuahear/hive-mind/main/setup.sh)"
```

Attaching a second AI tool to the same hub (once additional adapters ship) is the same installer with a different `ADAPTER=`:

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

- **Ultralight** — ~175 tokens fully loaded, ~85 tokens idle. Almost zero context overhead.
- **Synced everywhere** — Sync your global and project memories across every machine. macOS, Linux, Windows.
- **Cross-provider** — One hub per machine can attach to multiple AI tools (Claude Code, Codex, Qwen, Kimi planned); they all read from the same canonical memory.
- **Your data, your repo** — Memory lives in a private git repo you control. No vendor lock-in.
- **Conflict-tolerant** — Edit memory from any machine, anytime. No problem.
- **Meaningful git history** — Every lesson is auto-committed — git log becomes your AI's learning journal.
- **Works offline** — Sync failures retry next turn. Your AI never blocks on a bad network.

Deeper explanations of each — plus the sync flow, conflict resolution, commit marker convention, and repo layout — live in the **[docs site](https://tuahear.github.io/hive-mind)**.

---

## Contributing / development

This README is for end users. If you want to hack on hive-mind itself:

1. Fork the repo and clone
2. Run `scripts/install-dev-hooks.sh` once in your clone — installs a pre-commit hook that keeps bundled skills clean
3. Edit `adapters/claude-code/skills/hive-mind/SKILL.md` to change the bundled Claude skill (not the copy in `~/.claude/skills/hive-mind/` — that's a user-facing install target that gets refreshed each time setup.sh runs)
4. Install [bats-core](https://github.com/bats-core/bats-core) + GNU `parallel` — `brew install bats-core parallel` (macOS), `apt install bats parallel` (Linux). Run `./test` from the repo root.
5. PRs welcome

---

## Roadmap: AI-agnostic

hive-mind v0.3.0 splits the design in two: a provider-agnostic **hub** at `~/.hive-mind/` holds the canonical memory schema, and **adapters** teach the hub how to read/write each tool's native layout (Claude's `CLAUDE.md` + `~/.claude/settings.json`, Codex's `AGENTS.md` + TOML, Qwen's `QWEN.md`, etc.). Today Claude Code is the only shipped adapter; Codex ([#11](https://github.com/tuahear/hive-mind/issues/11)), Qwen ([#19](https://github.com/tuahear/hive-mind/issues/19)), and Kimi ([#23](https://github.com/tuahear/hive-mind/issues/23)) are on the roadmap.

Writing a new adapter is mostly declaring two mapping strings (`ADAPTER_HUB_MAP`, `ADAPTER_PROJECT_CONTENT_RULES`) plus a few contract functions — a few hundred lines of shell at most. See [docs/CONTRIBUTING-adapters.md](docs/CONTRIBUTING-adapters.md). PRs and issues welcome.

---

## Troubleshooting

See the **[troubleshooting page](https://tuahear.github.io/hive-mind/troubleshooting)** on the docs site — covers SSH auth errors, hooks not firing, `.sync-error.log`, rename-induced project-id drift, and projects without an `origin` remote.

---

## License

MIT — see [LICENSE](LICENSE).

Built for [Claude Code](https://claude.com/claude-code). See the Roadmap section for how it's designed to grow.
