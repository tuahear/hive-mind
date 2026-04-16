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

# === hierarchical model invariant =========================================

@test "hierarchical adapter without adapter_list_memory_files is rejected" {
  # Core mirror-projects calls adapter_list_memory_files to discover
  # memory files when the model isn't flat. A no-op stub silently
  # breaks mirroring rather than failing fast.
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
