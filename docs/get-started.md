# Get started

A hive-mind install has two moving parts:

- A **hub** at `~/.hive-mind/` on each machine — a single git repo that holds your canonical memory.
- One or more **adapters** (Claude Code today; Codex, Qwen, Kimi planned) that attach the hub to each tool's native memory files.

The `hivemind` CLI keeps the two separate: `hivemind init` creates the hub, and each `hivemind attach <name>` wires one tool's native dir to it. Four steps end to end.

## 1. Make an empty private git repo

Any git host works — GitHub, GitLab, Bitbucket, Codeberg, self-hosted, even a local bare repo on another machine. No README, no license, no `.gitignore`. Just an empty box to hold your memory. Name it whatever feels right — `claude-memory`, `brain`, `second-brain`.

## 2. Install the `hivemind` CLI

Download the latest release tarball and install it globally with npm:

```bash
curl -L -o /tmp/hive-mind.tgz \
  https://github.com/tuahear/hive-mind/releases/download/cli-v0.3.0/hive-mind-0.3.0.tgz
npm install -g /tmp/hive-mind.tgz
hivemind --version                        # 0.3.0
```

The tarball ships the bash `core/` + `adapters/` + prebuilt `hivemind-hook` binaries for macOS (arm64/amd64), Linux (amd64/arm64), and Windows (amd64). No repo clone, no Go toolchain, no compile step — `git` and Node 18+ are all you need.

## 3. Create the hub and attach your first tool

`hivemind init` only creates `~/.hive-mind/` and points it at your memory repo. Attaching a tool is a separate, explicit command — the CLI never modifies a tool's dir (hooks, skills, settings) without your consent.

```bash
hivemind init --memory-repo git@github.com:YOU/your-memory.git
hivemind attach claude-code
```

`--memory-repo` accepts any URL `git` understands:

- SSH: `git@<host>:you/repo.git` (GitHub, GitLab, Bitbucket, self-hosted…)
- HTTPS: `https://<host>/you/repo.git`
- Local: `/path/to/bare.git` or `file:///path/to/bare.git`

### Attaching a second tool

One `hivemind attach` call per tool, against the same hub:

```bash
hivemind attach codex                     # same memory, second tool
```

This doesn't touch the first adapter's install. Both tools harvest and fan-out through `~/.hive-mind/` — a memory edit in one shows up in the other on the next sync cycle.

Useful companions:

```bash
hivemind status                           # hub + attached adapters, last sync, push state
hivemind detach codex                     # remove hive-mind from a tool (hub stays)
hivemind doctor                           # check prereqs, adapter layout, hook wiring
```

### Legacy `curl | bash` installer

The bash installer still works if you'd rather not use npm:

```bash
MEMORY_REPO=<your-memory-repo-url> \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/tuahear/hive-mind/main/setup.sh)"
ADAPTER=codex bash ~/.hive-mind/hive-mind/setup.sh   # attach a second tool
```

It clones hive-mind once and builds `hivemind-hook` from source, so it needs a Go toolchain (≥1.20). The CLI path avoids both.

## 4. Reload Claude Code

Type `/hooks` in any session or start a fresh one — the sync hooks activate. That's it. Every future edit to your memory gets committed and pushed automatically.

## What's next

- [How it works](/how-it-works) — the sync flow, conflict resolution, how cross-machine project identity is derived.
- [Adapters](/adapters/) — the hub-and-adapter split, adapter matrix, attaching a second tool.
- [Troubleshooting](/troubleshooting) — SSH auth errors, hooks not firing, `.sync-error.log`.
