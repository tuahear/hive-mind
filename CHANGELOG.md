# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`hivemind` CLI + npm distribution (prototype, [#13](https://github.com/tuahear/hive-mind/issues/13))** — new `cli/` TypeScript package that bundles the bash `core/`, `adapters/`, `cmd/`, `setup.sh`, `VERSION`, and `go.mod` into its npm tarball (~72 KB). `hivemind init` stages those bundled assets into `~/.hive-mind/hive-mind/` and invokes `setup.sh` with `HIVE_MIND_SKIP_CLONE=1`, removing the "clone the whole hive-mind repo on every install" requirement. Subcommands: `init / attach / detach / status / sync / pull / doctor / version / assets-path`. Legacy `curl | bash` install path is untouched. `setup.sh` gained an `HIVE_MIND_SKIP_CLONE` branch (guarded on absent `.git`) so it can consume a CLI-staged source tree.
- **Codex adapter** (`adapters/codex/`) — attaches [OpenAI Codex CLI](https://github.com/openai/codex) to the hub. Syncs both `~/.codex/AGENTS.md` (shared tier) and `~/.codex/AGENTS.override.md` (Codex-scoped override tier) bidirectionally on every sync cycle. Installs SessionStart + Stop hooks via `~/.codex/hooks.json` gated by `[features].codex_hooks` in `~/.codex/config.toml`. Treats `auth.json` as a secret file so it never reaches the hub remote. (issue #11)
- **Sectioned `content.md` hub format** — a single hub file can carry multiple memory tiers, delimited by `<!-- hive-mind:section=N START/END -->` paired HTML-comment markers. Unlocks multi-file tool surfaces (Codex's AGENTS.md + AGENTS.override.md split) without leaking adapter-specific filenames into the hub.
- **`ADAPTER_HUB_MAP` section selectors** — bracket syntax on the hub-path side declares which tiers a tool file round-trips: `content.md[0]` (single section, plain), `content.md[0,1]` (multiple sections with markers), `content.md[*]` (all sections currently present — forward-compat for any future tier without an adapter update). Selector-less entries keep their legacy verbatim-copy semantics.
- **Section id registry** in `docs/contributing.md` for cross-adapter coordination. Section 0 = shared tier (implicit, all adapters); section 1 = codex override layer.
- Bundled adapter-scoped skills (`hive-mind-claude`, `hive-mind-codex`) so Claude and Codex can coexist on the same hub without overwriting each other's hub skill content.

### Changed
- Claude Code adapter's `ADAPTER_HUB_MAP` entry for `CLAUDE.md` migrates from the legacy verbatim form to `content.md[*]\tCLAUDE.md`, so Claude sees every tier of the hub's memory and auto-picks-up any new tier a future adapter introduces.
- Claude Code no longer round-trips `settings.json` hooks or permissions through the shared hub. `CLAUDE.md`, project memory, and skills stay synced; hook installation and Claude permissions are now machine-local only.

### Fixed
- **Codex and Claude hook configs now enter through a native launcher instead of direct shell commands in their tool config.** `setup.sh` builds a small `hivemind-hook` binary and the adapters render their hook config against that single executable, which then shells into the existing bash scripts internally. This keeps the installed hook command surface down to one native entrypoint instead of fragile direct-bash or inline-shell invocations.
- **`ADAPTER_DIR` leak across sequential adapter loads in hub sync.** `core/adapter-loader.sh` preserves `ADAPTER_DIR` across its clear step as a caller-override hook, but sync.sh's sequential multi-adapter loops treated adapter N's tool dir as a caller override for adapter N+1's load - so codex (loaded second) was writing its `hooks.json` and `AGENTS.override.md` under `~/.claude/` instead of `~/.codex/`. Fixed by `unset ADAPTER_DIR` at the top of each loop iteration in both harvest + fan-out phases.

### Removed
- `config/hooks/**` and `config/permissions/**` from the documented hub schema and hub whitelist. Those paths are no longer a source of truth for shared state.
- `ADAPTER_MARKER_TARGETS` from the adapter contract. Declared and validated by the loader but never consumed by core — marker extraction runs from `HUB_MARKER_TARGETS` in `core/hub/sync.sh`. Removed from the loader, docs, fixtures, and both production adapters.
- Claude Code adapter's `adapter_migrate` body and its dedicated test suite (including `tests/integration/claude-migration.bats`). hive-mind is pre-release with no known users carrying legacy settings.json shapes, so the v0.1/v0.2 → v0.3 hook-path rewriter has no audience. The `adapter_migrate` contract hook (and `PREV_HIVE_MIND_VERSION` plumbing in `setup.sh`) stays so future adapters can opt in to cross-version migrations.

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
- `docs/contributing.md` — guide for community adapter authors (renamed from `docs/CONTRIBUTING-adapters.md` in the docs-site restructure).

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
