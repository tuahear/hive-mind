# Contributing an adapter

Guide for adding hive-mind support for a new AI coding tool.

## When to write an adapter

Write an adapter when:
- Your tool has a local config directory that could benefit from cross-machine sync.
- Memory/instructions/skills files exist that an agent edits during sessions.
- The tool has hooks, events, or an extension mechanism for triggering scripts.

## Reading the capability surface

Every adapter implements the shell contract defined in `core/adapter-loader.sh`. The authoritative reference is the `ADAPTER_*` variables and `adapter_*` functions listed there. Study `adapters/claude-code/adapter.sh` as the reference implementation.

### Required exports

| Variable | Purpose |
|---|---|
| `ADAPTER_API_VERSION` | Semver — the contract version this adapter targets |
| `ADAPTER_VERSION` | Semver — the adapter's own version |
| `ADAPTER_NAME` | Kebab-case identifier matching the directory name |
| `ADAPTER_DIR` | Absolute path to the tool's config/sync root |
| `ADAPTER_MEMORY_MODEL` | `flat` or `hierarchical` |
| `ADAPTER_GITIGNORE_TEMPLATE` | Path to the adapter's `.gitignore` template |
| `ADAPTER_GITATTRIBUTES_TEMPLATE` | Path to the adapter's `.gitattributes` template |
| `ADAPTER_SECRET_FILES` | Space-separated filenames that must never be synced |
| `ADAPTER_MARKER_TARGETS` | Newline-separated globs of files that can host commit markers |
| `ADAPTER_HAS_HOOK_SYSTEM` | `true` or `false` |
| `ADAPTER_LOG_PATH` | Absolute path to the sync-error log |

### Required functions

- `adapter_install_hooks` — Idempotent. Installs hive-mind hooks into the tool's config.
- `adapter_uninstall_hooks` — Clean inverse of install.
- `adapter_healthcheck` — Exit 0 if the tool is installed and addressable.
- `adapter_activation_instructions` — Stdout: what to do after install.
- `adapter_disable_instructions` — Stdout: how to temporarily disable.
- `adapter_migrate` — Called during upgrades with the previously-installed hive-mind version as `$1` (the value in `$HIVE_MIND_DIR/VERSION`, or `0.1.0` for pre-refactor installs without a VERSION file).

## Running the conformance test suite

```bash
ADAPTER_UNDER_TEST=your-adapter bats tests/adapter-conformance/conformance.bats
```

All 29 conformance tests must pass before a PR will be reviewed.

## Declaring ADAPTER_API_VERSION correctly

- Match the `HIVE_MIND_CORE_API_VERSION` in `core/adapter-loader.sh`.
- Major mismatch (either direction) = hard error on load.
- Adapter minor > core minor = hard error (adapter expects features core doesn't have).
- Adapter minor < core minor = fine (new capabilities are additive).
- Patch differences are ignored.

## PR checklist

- [ ] `ADAPTER_API_VERSION` declared and matches core major.
- [ ] All conformance tests pass (`ADAPTER_UNDER_TEST=<name> bats tests/adapter-conformance/`).
- [ ] Adapter-specific tests exist at `adapters/<name>/tests/`.
- [ ] Integration tests pass (`ADAPTER_UNDER_TEST=<name> bats tests/integration/`).
- [ ] `CHANGELOG.md` updated with a new entry.
- [ ] No hardcoded references to other adapters in your code.
- [ ] `ADAPTER_SECRET_FILES` declares any credential files the tool stores.

## What the hive-mind maintainers commit to

- Review within 7 days of a complete PR.
- Stability guarantees per the project's semver policy — your adapter won't break without a major version bump.
- The conformance test suite is the acceptance bar; passing it means the adapter is architecturally correct.
