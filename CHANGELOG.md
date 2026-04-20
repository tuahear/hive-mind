# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.2] - 2026-04-20

### Fixed

- **Orphan project variants now bootstrap their `.hive-mind` marker from the variant dirname when no session jsonl is available ([#32](https://github.com/tuahear/hive-mind/issues/32), [#34](https://github.com/tuahear/hive-mind/pull/34)).** `mirror-projects.sh`'s `derive_id_from_cwd` only scanned `*.jsonl` for a `cwd` field; variants with memory but no sessions (e.g. sessions trimmed by the tool, or memory copied from another machine) silently stayed unbootstrapped. `hub_harvest` then skipped them, and their memory never reached the hub. Added `derive_id_from_dirname` fallback that decodes the Claude-style encoded-cwd dirname (`/`, `\`, `:` → `-`) against the real filesystem, enumerating every path that resolves on disk and succeeding only when exactly one does (ambiguity fails closed; `LC_ALL=C` dedup). jsonl remains authoritative when present. Supports both Unix (`-Users-...`) and Windows drive-prefix (`c--Users-...`) encodings.
- **Hub sync lock now self-heals stale locks instead of silent no-op for hours ([#33](https://github.com/tuahear/hive-mind/issues/33), [#35](https://github.com/tuahear/hive-mind/pull/35)).** Prior behavior: a sync killed uncleanly left `$HIVE_MIND_HUB_DIR/.hive-mind-state/sync.lock` behind; every subsequent sync hit the 5×2s retry cap and exited 0 with no log line — indistinguishable from a healthy no-op. Now `acquire_lock` writes a timestamp heartbeat inside the lock dir (rolls back the dir if the heartbeat write fails), the retry path breaks locks whose heartbeat is older than `HIVE_MIND_LOCK_STALE_SECS` (default 300s), missing-heartbeat locks get a dir-mtime-keyed grace window (`HIVE_MIND_LOCK_NO_HB_GRACE_SECS`, default 10s) to race-safely handle peers mid-acquire, and long-running syncs refresh the heartbeat at every phase boundary (harvest, pull-rebase, push, fan-out) so an in-progress sync can't be broken by a peer. Operates only on real directories (rejects symlinks + non-dir paths via `[ -d ] && [ ! -L ]` guards on both the lock dir and the heartbeat file). Log lines use `broke …` on successful break and a `could not remove …` warning on failure.

### Added

- **`HIVE_MIND_LOCK_STALE_SECS` / `HIVE_MIND_LOCK_NO_HB_GRACE_SECS`** env var escape hatches for deployments with unusually long phases (huge harvest corpora, very slow network).

## [0.3.1] - 2026-04-19

### Added
- **`hivemind init` is now upgrade-aware — one command for install and upgrade.** On a fresh machine it sets up the hub (unchanged). On an existing install it detects the hub + origin, restages the bundled assets over `~/.hive-mind/hive-mind/`, and re-runs each currently-attached adapter's install so hook wiring, launcher binary, and bundled skills all match the new release. The separate `hivemind restage` command has been removed from the CLI surface — `init` covers both cases.
- **BREAKING (prototype only): `hivemind init` is now hub-only.** Previously `init` attached `claude-code` by default, silently modifying `~/.claude/settings.json` without the user ever typing "attach". Every tool-dir write now requires an explicit `hivemind attach <name>`, matching the consent boundary already applied to Codex. `--adapter` is removed from `init`. The new flow is `hivemind init --memory-repo <url>` followed by one `hivemind attach <name>` per tool. The post-init provider-detection hint (below) now surfaces every detected provider, since none are attached by default.
- **`hivemind attach` is now a slim operation.** Previously `attach` re-ran setup.sh's full 6-step flow (stage source / seed hub / memory-repo clone / attach / skills / sync) on every call, even though init had already done the first three. The CLI now passes `HIVE_MIND_ATTACH_MODE=1` which collapses the attach flow to 3 phases (attach / skills / sync) and adds a preflight that fails fast with "run `hivemind init` first" if the hub isn't installed. Log output on every subsequent attach drops from ~14 lines to ~6.
- **First-attach backup now narrow-scoped.** Previously `cp -a $ADAPTER_DIR $ADAPTER_DIR.backup-<ts>` copied the entire tool dir, triggering `Device or resource busy` errors on SQLite WAL files, lock files, and other runtime ephemera. New adapter-contract field `ADAPTER_BACKUP_PATHS` lists only the files hive-mind will modify (`settings.json CLAUDE.md skills` for Claude Code, `hooks.json config.toml AGENTS.md AGENTS.override.md` for Codex). Unset → fallback to full-dir for safety.
- **`hivemind init` post-install provider hints** — after a successful install, `init` scans the machine for well-known provider markers (`~/.claude/`, `~/.codex/config.toml`) and prints a short "you could also attach these" hint for unattached providers it finds. Purely informational; no side effects. Users still run `hivemind attach <name>` explicitly to wire up a second adapter.
- **`hivemind` CLI + npm distribution (prototype, [#13](https://github.com/tuahear/hive-mind/issues/13))** — new `cli/` TypeScript package that bundles the bash `core/`, `adapters/`, `cmd/`, `setup.sh`, `VERSION`, `go.mod`, and **prebuilt `hivemind-hook` launchers** (macOS arm64/amd64, Linux amd64/arm64, Windows amd64) into its npm tarball (~4 MB gzipped). `hivemind init` stages those bundled assets into `~/.hive-mind/hive-mind/` and invokes `setup.sh` with `HIVE_MIND_SKIP_CLONE=1`, removing the "clone the whole hive-mind repo on every install" requirement. setup.sh picks the matching prebuilt launcher for the user's OS/arch, so **users do not need the Go toolchain installed** (Go is only required when building the CLI from source). Upgrade path is two steps: `npm install -g hive-mind@latest` refreshes the CLI's bundled assets, then `hivemind restage` copies them over the staged hub source (hooks and attached adapters are untouched). Subcommands: `init / attach / detach / restage / status / sync / pull / doctor / version / assets-path`. Legacy `curl | bash` install path is untouched. `setup.sh` gained an `HIVE_MIND_SKIP_CLONE` branch (guarded on absent `.git`) so it can consume a CLI-staged source tree, and an `HIVE_MIND_PREV_VERSION` override so `PREV_HIVE_MIND_VERSION` stays meaningful after the CLI has overwritten `$HIVE_MIND_SRC/VERSION`.
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
