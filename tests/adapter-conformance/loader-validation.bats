#!/usr/bin/env bats
# Negative tests for core/adapter-loader.sh's _validate_adapter.
#
# The loader validates the capability surface before returning success:
# absolute paths for any var core scripts later pass to `cd` or
# `>>`, a strict enum on ADAPTER_HAS_HOOK_SYSTEM, required-non-empty
# values on the contract vars, and (for hierarchical adapters) a
# declared adapter_list_memory_files. Each test stages a near-valid
# adapter with ONE field intentionally broken and asserts the loader
# rejects it with a recognizable error. Accepting a broken adapter
# here means sync.sh / setup.sh would fail later with a much harder-
# to-debug message.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
LOADER="$REPO_ROOT/core/adapter-loader.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  export TEST_ADAPTERS_DIR="$HOME/_test_adapters"
  mkdir -p "$TEST_ADAPTERS_DIR"
  export HIVE_MIND_ADAPTERS_DIR="$TEST_ADAPTERS_DIR"
}

teardown() {
  rm -rf "$HOME"
}

# Helper: write an adapter.sh with sensible defaults, then apply an
# override block (bash run AFTER the defaults) so each test can poke a
# single field.
write_adapter() {
  local name="$1"; shift
  local override="$*"
  local dir="$TEST_ADAPTERS_DIR/$name"
  mkdir -p "$dir"
  cat > "$dir/gitignore" <<'G'
/*
G
  cat > "$dir/gitattributes" <<'G'
*.md merge=union
G
  cat > "$dir/adapter.sh" <<ADAPTER_EOF
#!/usr/bin/env bash
set -euo pipefail
ADAPTER_API_VERSION="1.0.0"
ADAPTER_VERSION="0.1.0"
ADAPTER_NAME="$name"
ADAPTER_DIR="\$HOME/.test-tool"
ADAPTER_MEMORY_MODEL="flat"
ADAPTER_GLOBAL_MEMORY="\$ADAPTER_DIR/MEMORY.md"
ADAPTER_PROJECT_MEMORY_DIR="\$ADAPTER_DIR/projects/{encoded_cwd}/memory"
adapter_list_memory_files() { :; }
ADAPTER_GITIGNORE_TEMPLATE="\${ADAPTER_ROOT}/gitignore"
ADAPTER_GITATTRIBUTES_TEMPLATE="\${ADAPTER_ROOT}/gitattributes"
ADAPTER_SECRET_FILES=""
ADAPTER_MARKER_TARGETS=\$'*.md'
ADAPTER_HAS_HOOK_SYSTEM=true
ADAPTER_EVENT_SESSION_START="SessionStart"
ADAPTER_EVENT_TURN_END="Stop"
ADAPTER_EVENT_POST_EDIT="PostToolUse"
adapter_install_hooks() { :; }
adapter_uninstall_hooks() { :; }
ADAPTER_SKILL_ROOT=""
ADAPTER_SKILL_FORMAT=""
ADAPTER_SETTINGS_MERGE_BINDINGS=""
adapter_activation_instructions() { echo "activate"; }
adapter_disable_instructions() { echo "disable"; }
ADAPTER_FALLBACK_STRATEGY=""
ADAPTER_HUB_MAP=""
ADAPTER_PROJECT_CONTENT_RULES=""
ADAPTER_LOG_PATH="\$ADAPTER_DIR/.sync-error.log"
adapter_healthcheck() { :; }
adapter_migrate() { :; }

# --- override block ---
$override
ADAPTER_EOF
}

try_load() {
  local name="$1"
  bash -c "HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' source '$LOADER' && HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter '$name'" 2>&1
}

# === absolute-path checks =================================================

@test "relative ADAPTER_DIR is rejected (core scripts cd into it)" {
  write_adapter "rel-dir" 'ADAPTER_DIR="relative/path"'
  run try_load "rel-dir"
  [ "$status" -ne 0 ]
  [[ "$output" = *"ADAPTER_DIR must be an absolute path"* ]]
}

@test "relative ADAPTER_LOG_PATH is rejected (sync.sh appends via >>)" {
  write_adapter "rel-log" 'ADAPTER_LOG_PATH="logs/sync.log"'
  run try_load "rel-log"
  [ "$status" -ne 0 ]
  [[ "$output" = *"ADAPTER_LOG_PATH must be an absolute path"* ]]
}

@test "relative ADAPTER_SKILL_ROOT (when non-empty) is rejected" {
  # setup.sh uses ADAPTER_SKILL_ROOT as a filesystem path when
  # installing skills. A relative value would create files in whatever
  # cwd setup.sh happens to run from (user's current dir), not under
  # the adapter's config root. Absolute required whenever non-empty;
  # empty is still allowed (falls back to $MEMORY_DIR/skills in
  # manage_claude_skills).
  write_adapter "rel-skill-root" 'ADAPTER_SKILL_ROOT="relative/skills"'
  run try_load "rel-skill-root"
  [ "$status" -ne 0 ]
  [[ "$output" = *"ADAPTER_SKILL_ROOT must be an absolute path"* ]]
}

@test "empty ADAPTER_SKILL_ROOT is accepted (adapter opts out of distinct skills dir)" {
  # Negative control: the absolute-path requirement applies only when
  # the value is non-empty. An adapter without a separate skill system
  # declares empty; the validator must not confuse "empty" with
  # "relative".
  write_adapter "empty-skill-root" 'ADAPTER_SKILL_ROOT=""'
  run try_load "empty-skill-root"
  [ "$status" -eq 0 ]
}

@test "relative ADAPTER_PROJECT_MEMORY_DIR (flat model) is rejected" {
  # setup.sh and mirror-projects treat ADAPTER_PROJECT_MEMORY_DIR as a
  # filesystem path for flat adapters. Relative values drift with cwd.
  write_adapter "rel-proj-memory" 'ADAPTER_PROJECT_MEMORY_DIR="projects/{encoded_cwd}/memory"'
  run try_load "rel-proj-memory"
  [ "$status" -ne 0 ]
  [[ "$output" = *"ADAPTER_PROJECT_MEMORY_DIR must be an absolute path"* ]]
}

@test "relative ADAPTER_GLOBAL_MEMORY (flat model) is rejected" {
  write_adapter "rel-mem" 'ADAPTER_GLOBAL_MEMORY="memory/MEMORY.md"'
  run try_load "rel-mem"
  [ "$status" -ne 0 ]
  [[ "$output" = *"ADAPTER_GLOBAL_MEMORY must be an absolute path"* ]]
}

# === enum / boolean checks ================================================

@test "ADAPTER_HAS_HOOK_SYSTEM is strictly true|false (no truthy aliases)" {
  # Silent acceptance of 'yes' / '1' / 'on' would let core dispatch
  # hook logic for an adapter whose hook system is actually absent.
  write_adapter "bad-enum" 'ADAPTER_HAS_HOOK_SYSTEM=yes'
  run try_load "bad-enum"
  [ "$status" -ne 0 ]
  [[ "$output" = *"ADAPTER_HAS_HOOK_SYSTEM must be 'true' or 'false'"* ]]
}

# === required-non-empty vars ==============================================

@test "empty ADAPTER_NAME is rejected (can't route dispatch)" {
  write_adapter "empty-name" 'ADAPTER_NAME=""'
  run try_load "empty-name"
  [ "$status" -ne 0 ]
  [[ "$output" = *"ADAPTER_NAME"* ]]
}

@test "missing ADAPTER_SECRET_FILES declaration is rejected" {
  # Empty string is a valid value (no secrets), but the variable MUST
  # be declared -- missing declaration means the adapter author never
  # considered the secret-file gate, which is a safety regression.
  write_adapter "no-secrets" 'unset ADAPTER_SECRET_FILES'
  run try_load "no-secrets"
  [ "$status" -ne 0 ]
  [[ "$output" = *"ADAPTER_SECRET_FILES"* ]]
}

@test "missing ADAPTER_SKILL_ROOT declaration is rejected" {
  # ADAPTER_SKILL_ROOT may be empty (adapter with no distinct skill
  # system falls back to MEMORY_DIR/skills) but it must be declared so
  # the contract surface is explicit. The conformance suite requires
  # this; the loader must match or an adapter can load in production
  # while still failing conformance.
  write_adapter "no-skill-root" 'unset ADAPTER_SKILL_ROOT'
  run try_load "no-skill-root"
  [ "$status" -ne 0 ]
  [[ "$output" = *"ADAPTER_SKILL_ROOT"* ]]
}

@test "missing ADAPTER_SKILL_FORMAT declaration is rejected" {
  # Pairs with SKILL_ROOT above — both are part of the skill-surface
  # contract. Forcing declaration makes adapters authors explicitly
  # answer "do you have a skill system and what shape is it".
  write_adapter "no-skill-format" 'unset ADAPTER_SKILL_FORMAT'
  run try_load "no-skill-format"
  [ "$status" -ne 0 ]
  [[ "$output" = *"ADAPTER_SKILL_FORMAT"* ]]
}

# === hierarchical model invariant =========================================

@test "hierarchical adapter without adapter_list_memory_files is rejected" {
  # Contract surface requirement: hierarchical adapters must declare
  # adapter_list_memory_files so the adapter's own install/diagnostic
  # tooling has a standard enumeration entry point, and so core can
  # layer hierarchical mirror support on top in a future release
  # without a contract break. No core script currently invokes it
  # (core/mirror-projects.sh and core/check-dupes.sh scope to the
  # flat projects/<encoded-cwd>/ layout), but the function must be
  # defined for load to succeed.
  write_adapter "hier-no-fn" 'ADAPTER_MEMORY_MODEL="hierarchical"
unset -f adapter_list_memory_files'
  run try_load "hier-no-fn"
  [ "$status" -ne 0 ]
  [[ "$output" = *"adapter_list_memory_files"* ]]
}

# === positive control =====================================================

@test "well-formed adapter loads successfully" {
  write_adapter "healthy" ''
  run try_load "healthy"
  [ "$status" -eq 0 ]
}

# === cross-load state isolation ===========================================

@test "load_adapter clears previous ADAPTER_* vars before sourcing the next adapter" {
  # Scenario: load adapter A (healthy, all vars declared), then load
  # adapter B which "forgets" to declare ADAPTER_LOG_PATH. Without
  # state clearing, B inherits A's ADAPTER_LOG_PATH and passes
  # validation — silently masking a contract omission. With clearing,
  # B's missing declaration is caught by _validate_adapter.
  write_adapter "first"  ''
  write_adapter "second" 'unset ADAPTER_LOG_PATH'

  run bash -c "
    HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' source '$LOADER'
    HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter 'first' || exit 11
    HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter 'second'
  "
  # The second load must fail (non-zero) because ADAPTER_LOG_PATH is
  # missing. If state-clearing is broken, the leftover value from
  # 'first' would let 'second' pass validation and this assertion
  # wrongly holds.
  [ "$status" -ne 0 ]
  [[ "$output" = *"ADAPTER_LOG_PATH"* ]]
}

@test "load_adapter clears previous adapter_* functions before sourcing the next adapter" {
  # Same class of bug for functions. adapter_migrate is in the
  # required-function contract; if the second adapter forgets to
  # define it, _validate_adapter rejects the load. This test verifies
  # the state-clearing step (not the validation) — after loading
  # second_fn (which unsets adapter_migrate), the first adapter's
  # definition must not leak through.
  write_adapter "first_fn"  'adapter_migrate() { echo "from-first"; }'
  write_adapter "second_fn" 'unset -f adapter_migrate'

  run bash -c "
    HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' source '$LOADER'
    HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter 'first_fn' >/dev/null 2>&1 || exit 11
    HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter 'second_fn' >/dev/null 2>&1 || true
    # Probe: adapter_migrate must NOT be defined after 'second_fn'
    # was sourced. Print a sentinel the parent can grep.
    if declare -f adapter_migrate >/dev/null 2>&1; then
      echo 'LEAK: adapter_migrate still defined from first adapter'
      exit 1
    fi
    echo 'CLEAN'
  "
  [ "$status" -eq 0 ]
  [[ "$output" = *"CLEAN"* ]]
  [[ "$output" != *"LEAK"* ]]
}
