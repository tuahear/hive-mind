# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
