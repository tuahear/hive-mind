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

**Or (prototype) — `hivemind` CLI:** ships the bash core inside the npm tarball so install doesn't require cloning the hive-mind repo. Today the prereleases live on GitHub Releases — download the tarball, `npm install -g` it, then `hivemind init` + explicit `hivemind attach <name>` per tool you want wired up. See [`cli/README.md`](https://github.com/tuahear/hive-mind/tree/main/cli) and issue [#13](https://github.com/tuahear/hive-mind/issues/13).

`MEMORY_REPO` accepts any URL `git` understands:

- SSH: `git@<host>:you/repo.git` (GitHub, GitLab, Bitbucket, self-hosted…)
- HTTPS: `https://<host>/you/repo.git`
- Local: `/path/to/bare.git` or `file:///path/to/bare.git`

Works on macOS, Linux, and Windows (Git Bash). You need: `git`, a Go toolchain (≥1.20 — the installer builds the native `hivemind-hook` launcher from source), and SSH access (or HTTPS credentials) for your memory-repo host. The **legacy `curl | bash` installer above** also clones hive-mind from GitHub once — by default over SSH, but you can point `HIVE_MIND_REPO` at an `https://` clone URL instead (no SSH key required). Ongoing sync only uses your `MEMORY_REPO`, and the CLI path doesn't clone the hive-mind repo at all (the source ships inside the npm tarball).

### Attaching a second tool

Once another adapter ships, attach it to the same hub with a different `ADAPTER=` value (legacy installer), or one `hivemind attach` call per tool (CLI prototype):

```bash
ADAPTER=codex bash ~/.hive-mind/hive-mind/setup.sh   # legacy flow
# CLI prototype flow:
hivemind attach codex                                # explicit consent per adapter
```

The CLI deliberately does not auto-attach adapters — `hivemind init` sets up the hub only, and each `hivemind attach <name>` explicitly modifies that tool's dir (hooks, skills, settings). This avoids surprise modifications to tools hive-mind doesn't own.

This does not touch the first adapter's install. Both tools then harvest and fan-out through the same `~/.hive-mind/` — memory edits in one tool appear in the other on the next sync cycle.

## 3. Reload Claude Code

Type `/hooks` in any session or start a fresh one — the sync hooks activate. That's it. Every future edit to your memory gets committed and pushed automatically.

## What's next

- [How it works](/how-it-works) — the sync flow, conflict resolution, how cross-machine project identity is derived.
- [Adapters](/adapters/) — the hub-and-adapter split, adapter matrix, attaching a second tool.
- [Troubleshooting](/troubleshooting) — SSH auth errors, hooks not firing, `.sync-error.log`.
