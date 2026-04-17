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

**Must be declared AND non-empty:**

| Variable | Purpose |
|---|---|
| `ADAPTER_API_VERSION` | Semver — the contract version this adapter targets |
| `ADAPTER_VERSION` | Semver — the adapter's own version |
| `ADAPTER_NAME` | Kebab-case identifier matching the directory name |
| `ADAPTER_DIR` | Absolute path to the tool's config/sync root |
| `ADAPTER_MEMORY_MODEL` | `flat` or `hierarchical` |
| `ADAPTER_GITIGNORE_TEMPLATE` | Path to the adapter's `.gitignore` template |
| `ADAPTER_GITATTRIBUTES_TEMPLATE` | Path to the adapter's `.gitattributes` template |
| `ADAPTER_MARKER_TARGETS` | Newline-separated globs of files that can host commit markers |
| `ADAPTER_HAS_HOOK_SYSTEM` | `true` or `false` |
| `ADAPTER_LOG_PATH` | Absolute path to the sync-error log |

**Must be declared (may be empty):**

These pass validation with an empty string but the assignment itself must be present; an undeclared variable fails loader validation and conformance.

| Variable | Purpose |
|---|---|
| `ADAPTER_SECRET_FILES` | Space-separated filenames that must never be synced (empty = no opt-out list) |
| `ADAPTER_SETTINGS_MERGE_BINDINGS` | Newline-separated whitespace-delimited `<path-pattern> <driver-name>` pairs — e.g. `settings.json jsonmerge` — registered as git merge drivers. `<driver-name>` must match a script at `core/<driver-name>.sh`. Empty = no drivers. |
| `ADAPTER_FALLBACK_STRATEGY` | How the adapter behaves when the tool's config is missing (empty = adapter's default) |
| `ADAPTER_SKILL_ROOT` | Absolute path to the tool's skills dir — the destination fan-out writes adapter-side skill files to. Empty means the adapter has no distinct skill dir (unusual). Under the hub topology (v0.3.0+) bundled skills are seeded into `$HIVE_MIND_HUB_DIR/skills/` and fan-out routes them to this path; there is no `$MEMORY_DIR/skills` fallback — that variable existed only in the pre-hub per-adapter-repo model. |
| `ADAPTER_SKILL_FORMAT` | Skill file layout identifier (empty = the tool has no distinct skill system) |
| `ADAPTER_HUB_MAP` | (v0.3.0 hub topology) Newline-separated TAB-delimited pairs `<hub-path>\t<tool-rel-path>` mapping hub-canonical items to the tool's native layout. The hub sync engine reads this bidirectionally (harvest and fan-out). Empty = adapter doesn't participate in hub sync yet. See the full spec below. |
| `ADAPTER_PROJECT_CONTENT_RULES` | (v0.3.0 hub topology) Newline-separated TAB-delimited pairs `<hub-rel>\t<tool-rel>` for files under `projects/<project-id>/**`. Lets the adapter whitelist what's safe to harvest/fan-out in per-project subtrees. Empty = adapter has no per-project concept. |

**Conditional — required only under certain memory models:**

| Variable / function | Required when | Purpose |
|---|---|---|
| `ADAPTER_GLOBAL_MEMORY` | `ADAPTER_MEMORY_MODEL=flat` | Absolute path to the global memory file (e.g. `CLAUDE.md`) |
| `ADAPTER_PROJECT_MEMORY_DIR` | `ADAPTER_MEMORY_MODEL=flat` | Absolute path template to per-project memory dirs |
| `adapter_list_memory_files` (function) | `ADAPTER_MEMORY_MODEL=hierarchical` | Emits newline-separated absolute paths of memory files this adapter recognizes for a given project. No core script currently invokes this — `core/mirror-projects.sh` and `core/check-dupes.sh` scope to the flat `projects/<encoded-cwd>/` layout only. Declare it as a contract-surface slot for the adapter's own install / diagnostic tooling and as forward-compat for future hierarchical sync. A no-op stub is an acceptable implementation today. |

### Required functions

- `adapter_install_hooks` — Idempotent. Installs hive-mind hooks into the tool's config.
- `adapter_uninstall_hooks` — Clean inverse of install.
- `adapter_healthcheck` — Exit 0 if the tool is installed and addressable.
- `adapter_activation_instructions` — Stdout: what to do after install.
- `adapter_disable_instructions` — Stdout: how to temporarily disable.
- `adapter_migrate` — Called during upgrades with the previously-installed hive-mind version as `$1`. `setup.sh` reads this value from `$HIVE_MIND_SRC/VERSION` (the hive-mind source clone under the hub — default `~/.hive-mind/hive-mind/VERSION`) BEFORE `git pull` rewrites it, so adapters can gate migrations on a specific transition. Pre-0.2 installs have no VERSION file; `setup.sh` falls back to `0.1.0` in that case.

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

## The two mapping strings in detail

Both `ADAPTER_HUB_MAP` and `ADAPTER_PROJECT_CONTENT_RULES` are newline-separated, TAB-delimited pairs: `<hub-path>\t<tool-rel-path>`. The harvest/fan-out engine (`core/hub/harvest-fanout.sh`) reads them bidirectionally.

### Path-shape cases

The engine dispatches on the shape of the two paths in each entry.

| Hub path | Tool path | Meaning |
|---|---|---|
| `content.md` | `CLAUDE.md` | File-to-file rename. `_hub_sync_file` copies on harvest; reverse on fan-out. |
| `config/permissions/allow.txt` | `settings.json#permissions.allow` | Tool-side JSON subkey ↔ hub-side text-lines. Harvest extracts the array and writes one entry per line; fan-out reads the lines and replaces the subkey. |
| `config/hooks` | `settings.json#hooks` | Tool-side JSON subkey that's an event-keyed map of entry arrays ↔ hub-side per-event/per-entry JSON files. Harvest splits each entry into `config/hooks/<event>/<id>.json` where `<id>` is a deterministic content hash; fan-out reconstructs the map. Machine-local entries (commands containing `/Applications/`, `/opt/homebrew/`, Windows drive letters, …) are filtered from harvest and preserved through fan-out. |

Skills are NOT declared in `ADAPTER_HUB_MAP`. The engine syncs `$ADAPTER_SKILL_ROOT/` ↔ `hub/skills/` directly, renaming each skill's main content file: tool's `SKILL.md` → hub's `content.md` on harvest, and the reverse on fan-out. Other files in each skill dir pass through unchanged.

The convention: hub paths with a file extension (`.md`, `.txt`, `.json`) are file-like; paths without an extension are directory-like. The `<file>#<jsonpath>` form on the tool side means "read/write a subkey of that JSON file"; the hub-side shape (file vs. dir) picks between text-lines and per-entry split.

### Example (the Claude Code adapter)

```bash
ADAPTER_HUB_MAP=$'content.md\tCLAUDE.md
config/hooks\tsettings.json#hooks
config/permissions/allow.txt\tsettings.json#permissions.allow
config/permissions/deny.txt\tsettings.json#permissions.deny
config/permissions/ask.txt\tsettings.json#permissions.ask'

# No `skills\tskills` — the engine handles skills directly, renaming
# SKILL.md ↔ content.md per skill subdir.

ADAPTER_PROJECT_CONTENT_RULES=$'content.md\tmemory/MEMORY.md
content.md\tMEMORY.md
memory\tmemory'
# Rules are last-writer-wins. Dir rules (memory\tmemory) sync the
# subdir tree; file rules (content.md\tMEMORY.md) map the main
# content file. Order matters — later file rules overwrite earlier.
```

### Per-project mapping

`ADAPTER_PROJECT_CONTENT_RULES` applies under `projects/<project-id>/**`. Variant discovery goes through the sidecar `<variant>/.hive-mind` at the variant root (written by `core/mirror-projects.sh`, with a legacy fallback to `<variant>/memory/.hive-mind` for pre-root-migration installs) which exposes `project-id=<normalized-remote>`. Variants without a sidecar are skipped by harvest; tools that don't have a per-project concept declare the field empty.

### Non-JSON config formats

If your tool stores hooks or permissions outside JSON (e.g. Codex's `config.toml` with `[[hooks]]` blocks), the `<file>#<jsonpath>` notation still applies to the hub side — the file extension (`.toml`) tells your adapter's own shell code which parser to invoke. The MVP engine in `core/hub/harvest-fanout.sh` only understands JSON; TOML-shaped adapters will need to extend the dispatch (see issue [#11](https://github.com/tuahear/hive-mind/issues/11) for the Codex implementation plan).

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
