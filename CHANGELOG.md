# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-04-16

### Added
- **Hub topology** — one provider-agnostic `~/.hive-mind/` hub per machine replaces the per-adapter git repo. Single git repo, single remote, one schema; tool config dirs (`~/.claude/`, `~/.codex/`, …) stay at their native paths and copy-sync through the hub. Unlocks cross-provider + cross-machine memory sharing in one codebase. (issue #24)
- `core/hub/sync.sh` — hub sync entry point invoked by every attached tool's Stop hook at `$HIVE_MIND_HUB_DIR/bin/sync`. Acquires the hub lock, harvests every attached adapter's tool dir into the hub, pull-rebase-pushes the git cycle, and fans out back to each tool. Reuses marker extraction, format-version gate, push rate-limit, and backoff from the v0.2 per-adapter sync.
- `core/hub/harvest-fanout.sh` — bidirectional mapper between a tool's native config and the hub schema. Dispatches on path shape (file ↔ file, dir ↔ dir, file ↔ JSON subkey, dir ↔ per-event JSON subkey split).
- `core/hub/gitignore` + `core/hub/gitattributes` — hub-level whitelist + merge-driver bindings.
- **Machine-local filter** — hook entries whose command references `/Applications/`, `/opt/homebrew/`, `/Library/`, Windows drive letters, etc. are skipped by harvest. Fan-out preserves any machine-local entries already present in a tool's native config so a laptop's "open Finder" Stop hook isn't silently wiped by a cross-machine sync.
- Adapter contract fields `ADAPTER_HUB_MAP` and `ADAPTER_PROJECT_CONTENT_RULES` for declaring the mapping between hub canonical paths and tool-native paths.
- New tests at `tests/hub/`: `harvest-fanout.bats` (unit), `sync.bats` (end-to-end against a fake adapter), `cross-machine.bats` (two hub clones sharing a bare remote).

### Changed
- `setup.sh` reshaped around two operations: install hub (first run) + attach adapter (same or subsequent run). Rerunning with `ADAPTER=<name>` attaches a second tool to the same hub without touching the first.
- Claude Code adapter's Stop hook now points at `$HOME/.hive-mind/bin/sync`; SessionStart and PostToolUse helpers point at `$HOME/.hive-mind/hive-mind/core/<script>.sh`.
- `adapter_migrate` in `adapters/claude-code/adapter.sh` rewrites v0.1 (`scripts/`) and v0.2 (`~/.claude/hive-mind/core/`) hook paths to the v0.3 hub-topology paths. Existing installs upgrade cleanly on next `setup.sh` run.
- Hub sync does `git fetch` before deciding whether to short-circuit, so remote commits from another machine reach this machine's tool dirs even when the local tree is clean.

### Removed
- `core/sync.sh` — the per-adapter sync engine. Replaced by `core/hub/sync.sh`.
- `scripts/sync.sh`, `scripts/check-dupes.sh`, `scripts/jsonmerge.sh`, `scripts/marker-nudge.sh`, `scripts/mirror-projects.sh` — v0.1 forwarding shims. Pre-0.3 hook paths are handled by `adapter_migrate` instead.
- `templates/` directory — orphaned v0.1 leftovers; current templates live under `adapters/<name>/` and `core/hub/`.
- `tests/sync.bats` + `tests/integration/sync-flow.bats` + `tests/versioning/format_version.bats` — per-adapter-repo tests superseded by `tests/hub/`.

### Migration

No explicit steps required. Re-run `setup.sh` on any pre-0.3 machine: it creates the hub, harvests your existing `~/.claude/` content into it, and rewrites the Stop hook to point at the new entry. Your old `~/.claude/.git` survives untouched (you can delete it once you've confirmed the hub is working).

## [0.2.0] - 2026-04-16

### Added
- **Adapter pattern** — core logic is now tool-agnostic; Claude Code is the first adapter (`adapters/claude-code/`). New adapters slot in without touching core.
- `core/adapter-loader.sh` — loads and validates adapters against the shell contract (Appendix A).
- `core/log.sh` — shared logging helpers with level control and credential stripping.
- `core/marker-extract.sh` — standalone fence-aware commit-marker extractor.
- `core/tomlmerge.sh` — TOML merge driver for non-JSON config files.
- Fake adapter (`tests/fixtures/adapters/fake/`) for core test isolation.
- Adapter conformance test suite (`tests/adapter-conformance/`).
- Integration test suite (`tests/integration/`) with two-machine and concurrent-edit scenarios.
- Claude Code adapter-specific tests (`adapters/claude-code/tests/`).
- Rate limiting and debounce logic in `core/sync.sh` (min push interval, exponential backoff on errors).
- Version management: `ADAPTER_API_VERSION`, memory repo format version (`.hive-mind-format`), install version (`VERSION`).
- Version compliance test suite (`tests/versioning/`).
- `CHANGELOG.md` (this file).
- `docs/CONTRIBUTING-adapters.md` — guide for community adapter authors.

### Changed
- Core scripts moved from `scripts/` to `core/` and made adapter-agnostic (use `ADAPTER_DIR` instead of hardcoded `~/.claude`).
- Hook command strings in templates updated from `scripts/` to `core/` paths.

### Deprecated
- `scripts/*.sh` are now thin forwarding shims. Will be removed in the next major version.

## [0.1.0] - 2026-04-15

### Added
- Initial release: git-backed auto-sync for Claude Code memory.
- `sync.sh` (Stop hook), `check-dupes.sh` (SessionStart hook), `marker-nudge.sh` (PostToolUse hook).
- `mirror-projects.sh` — cross-machine project memory mirroring via git remote identity.
- `jsonmerge.sh` — custom git merge driver for settings.json.
- Commit-marker convention with fence-aware extraction.
- VitePress docs site.
