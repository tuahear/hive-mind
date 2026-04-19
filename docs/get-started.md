# Get started

A hive-mind install has two moving parts:

- A **hub** at `~/.hive-mind/` on each machine — a single git repo that holds your canonical memory.
- One or more **adapters** (Claude Code today; Codex, Qwen, Kimi planned) that attach the hub to each tool's native memory files.

Three steps: create an empty memory repo, run the installer (hub + first adapter in one shot), reload the tool.

## 1. Make an empty private git repo

Any git host works — GitHub, GitLab, Bitbucket, Codeberg, self-hosted, even a local bare repo on another machine. No README, no license, no `.gitignore`. Just an empty box to hold your memory. Name it whatever feels right — `claude-memory`, `brain`, `second-brain`.

## 2. Run the installer

```bash
MEMORY_REPO=<your-memory-repo-url> \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/tuahear/hive-mind/main/setup.sh)"
```

That creates `~/.hive-mind/`, clones your memory repo into it, and attaches Claude Code to the hub.

**Or (prototype, not yet on npm) — `hivemind` CLI:** ships the bash core inside the npm tarball so install doesn't require cloning the hive-mind repo. `npm install -g hive-mind && hivemind init`. See [`cli/README.md`](https://github.com/tuahear/hive-mind/tree/main/cli) and issue [#13](https://github.com/tuahear/hive-mind/issues/13).

`MEMORY_REPO` accepts any URL `git` understands:

- SSH: `git@<host>:you/repo.git` (GitHub, GitLab, Bitbucket, self-hosted…)
- HTTPS: `https://<host>/you/repo.git`
- Local: `/path/to/bare.git` or `file:///path/to/bare.git`

Works on macOS, Linux, and Windows (Git Bash). You need: `git`, a Go toolchain (≥1.20 — the installer builds the native `hivemind-hook` launcher from source), and SSH access (or HTTPS credentials) for your memory-repo host. The installer itself clones hive-mind from GitHub over SSH once, so GitHub SSH access is required for this step only — not for ongoing sync.

### Attaching a second tool

Once another adapter ships, attach it to the same hub with a different `ADAPTER=` value:

```bash
ADAPTER=codex bash ~/.hive-mind/hive-mind/setup.sh   # same memory, second tool
# or, via the CLI prototype:
hivemind attach codex
```

This does not touch the first adapter's install. Both tools then harvest and fan-out through the same `~/.hive-mind/` — memory edits in one tool appear in the other on the next sync cycle.

## 3. Reload Claude Code

Type `/hooks` in any session or start a fresh one — the sync hooks activate. That's it. Every future edit to your memory gets committed and pushed automatically.

## What's next

- [How it works](/how-it-works) — the sync flow, conflict resolution, how cross-machine project identity is derived.
- [Adapters](/adapters/) — the hub-and-adapter split, adapter matrix, attaching a second tool.
- [Troubleshooting](/troubleshooting) — SSH auth errors, hooks not firing, `.sync-error.log`.
