#!/usr/bin/env bats
# Adapter conformance tests — parameterized over every registered adapter.
# Verifies that each adapter implements the full capability surface defined
# by the shell contract (Appendix A).
#
# To run against a specific adapter:
#   ADAPTER_UNDER_TEST=fake bats tests/adapter-conformance/conformance.bats
#   ADAPTER_UNDER_TEST=claude-code bats tests/adapter-conformance/conformance.bats
#
# Default: runs against the fake adapter.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
LOADER="$REPO_ROOT/core/adapter-loader.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME

  adapter="${ADAPTER_UNDER_TEST:-fake}"
  if [ "$adapter" = "fake" ]; then
    # Link fake adapter into the adapters/ tree so load_adapter finds it.
    mkdir -p "$REPO_ROOT/adapters/fake"
    cp "$REPO_ROOT/tests/fixtures/adapters/fake/"* "$REPO_ROOT/adapters/fake/"
    export FAKE_ADAPTER_HOME="$HOME"
  fi

  source "$LOADER"
  load_adapter "$adapter"
}

teardown() {
  # Clean up fake adapter symlink.
  rm -rf "$REPO_ROOT/adapters/fake"
  rm -rf "$HOME"
}

# === A. Identity & location ================================================

@test "ADAPTER_API_VERSION is valid semver" {
  [[ "$ADAPTER_API_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "ADAPTER_VERSION is valid semver" {
  [[ "$ADAPTER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "ADAPTER_NAME is non-empty kebab-case" {
  [ -n "$ADAPTER_NAME" ]
  [[ "$ADAPTER_NAME" =~ ^[a-z][a-z0-9-]*$ ]]
}

@test "ADAPTER_DIR is an absolute path" {
  [[ "$ADAPTER_DIR" = /* ]]
}

@test "ADAPTER_MEMORY_MODEL is flat or hierarchical" {
  [[ "$ADAPTER_MEMORY_MODEL" = "flat" || "$ADAPTER_MEMORY_MODEL" = "hierarchical" ]]
}

@test "flat model: ADAPTER_GLOBAL_MEMORY is set and absolute" {
  [ "$ADAPTER_MEMORY_MODEL" != "flat" ] && skip "not flat model"
  [ -n "$ADAPTER_GLOBAL_MEMORY" ]
  [[ "$ADAPTER_GLOBAL_MEMORY" = /* ]]
}

@test "flat model: ADAPTER_PROJECT_MEMORY_DIR contains {encoded_cwd} placeholder" {
  [ "$ADAPTER_MEMORY_MODEL" != "flat" ] && skip "not flat model"
  [[ "$ADAPTER_PROJECT_MEMORY_DIR" = *"{encoded_cwd}"* ]]
}

@test "hierarchical model: adapter_list_memory_files is a function" {
  [ "$ADAPTER_MEMORY_MODEL" != "hierarchical" ] && skip "not hierarchical model"
  declare -f adapter_list_memory_files >/dev/null 2>&1
}

# === B. Files & sync rules =================================================

@test "ADAPTER_GITIGNORE_TEMPLATE points to an existing file" {
  [ -f "$ADAPTER_GITIGNORE_TEMPLATE" ]
}

@test "ADAPTER_GITATTRIBUTES_TEMPLATE points to an existing file" {
  [ -f "$ADAPTER_GITATTRIBUTES_TEMPLATE" ]
}

@test "gitignore template is valid (git can parse it)" {
  # git check-ignore uses the file as-is; a parse error exits non-zero.
  tmpdir="$(mktemp -d)"
  git -c init.defaultBranch=main init -q "$tmpdir"
  cp "$ADAPTER_GITIGNORE_TEMPLATE" "$tmpdir/.gitignore"
  # Write a dummy file and check git status doesn't error.
  touch "$tmpdir/dummy"
  git -C "$tmpdir" status --porcelain >/dev/null
  rm -rf "$tmpdir"
}

@test "gitattributes template is valid (git can parse it)" {
  tmpdir="$(mktemp -d)"
  git -c init.defaultBranch=main init -q "$tmpdir"
  cp "$ADAPTER_GITATTRIBUTES_TEMPLATE" "$tmpdir/.gitattributes"
  touch "$tmpdir/dummy"
  git -C "$tmpdir" status --porcelain >/dev/null
  rm -rf "$tmpdir"
}

@test "ADAPTER_MARKER_TARGETS is non-empty" {
  [ -n "$ADAPTER_MARKER_TARGETS" ]
}

@test "ADAPTER_SECRET_FILES is declared (may be empty)" {
  # Just verify the variable exists (even if empty string).
  [ "${ADAPTER_SECRET_FILES+x}" = "x" ]
}

# === C. Lifecycle touchpoints ==============================================

@test "ADAPTER_HAS_HOOK_SYSTEM is true or false" {
  [[ "$ADAPTER_HAS_HOOK_SYSTEM" = "true" || "$ADAPTER_HAS_HOOK_SYSTEM" = "false" ]]
}

@test "lifecycle events: each supported event has a non-empty name" {
  if [ "$ADAPTER_HAS_HOOK_SYSTEM" = "true" ]; then
    # At minimum, session_start and turn_end should be wired.
    [ -n "${ADAPTER_EVENT_SESSION_START:-}" ] || [ -n "${ADAPTER_EVENT_TURN_END:-}" ]
  fi
}

@test "adapter_install_hooks is idempotent — running twice produces the same config" {
  [ "$ADAPTER_HAS_HOOK_SYSTEM" != "true" ] && skip "no hook system"
  mkdir -p "$ADAPTER_DIR"

  adapter_install_hooks
  if [ -d "$ADAPTER_DIR" ]; then
    snapshot1="$(find "$ADAPTER_DIR" -type f -exec md5sum {} + 2>/dev/null \
                 || find "$ADAPTER_DIR" -type f -exec md5 {} +)"
  else
    snapshot1=""
  fi

  adapter_install_hooks
  if [ -d "$ADAPTER_DIR" ]; then
    snapshot2="$(find "$ADAPTER_DIR" -type f -exec md5sum {} + 2>/dev/null \
                 || find "$ADAPTER_DIR" -type f -exec md5 {} +)"
  else
    snapshot2=""
  fi

  [ "$snapshot1" = "$snapshot2" ]
}

@test "adapter_uninstall_hooks is a clean inverse" {
  [ "$ADAPTER_HAS_HOOK_SYSTEM" != "true" ] && skip "no hook system"
  mkdir -p "$ADAPTER_DIR"

  # Capture pre-install state.
  pre="$(find "$ADAPTER_DIR" -type f 2>/dev/null | sort)"

  adapter_install_hooks
  adapter_uninstall_hooks

  post="$(find "$ADAPTER_DIR" -type f 2>/dev/null | sort)"
  [ "$pre" = "$post" ]
}

# === D. Skills ==============================================================

@test "ADAPTER_SKILL_ROOT is declared (may be empty)" {
  [ "${ADAPTER_SKILL_ROOT+x}" = "x" ]
}

@test "ADAPTER_SKILL_FORMAT is declared (may be empty)" {
  [ "${ADAPTER_SKILL_FORMAT+x}" = "x" ]
}

# === E. Settings merge =====================================================

@test "ADAPTER_SETTINGS_MERGE_BINDINGS is declared" {
  [ "${ADAPTER_SETTINGS_MERGE_BINDINGS+x}" = "x" ]
}

# === F. User education =====================================================

@test "adapter_activation_instructions produces output" {
  out="$(adapter_activation_instructions)"
  [ -n "$out" ]
}

@test "adapter_disable_instructions produces output" {
  out="$(adapter_disable_instructions)"
  [ -n "$out" ]
}

# === G. Fallback ============================================================

@test "ADAPTER_FALLBACK_STRATEGY is declared" {
  [ "${ADAPTER_FALLBACK_STRATEGY+x}" = "x" ]
}

@test "fallback strategy is valid if hook system is absent" {
  [ "$ADAPTER_HAS_HOOK_SYSTEM" = "true" ] && skip "has hook system"
  [[ "$ADAPTER_FALLBACK_STRATEGY" =~ ^(watcher|polling|manual)$ ]]
}

# === H. Logging =============================================================

@test "ADAPTER_LOG_PATH is an absolute path" {
  [[ "$ADAPTER_LOG_PATH" = /* ]]
}

# === Healthcheck ============================================================

@test "adapter_healthcheck succeeds for an installed tool" {
  run adapter_healthcheck
  [ "$status" -eq 0 ]
}

@test "adapter_healthcheck is a function" {
  declare -f adapter_healthcheck >/dev/null 2>&1
}

# === Migration ==============================================================

@test "adapter_migrate is a function" {
  declare -f adapter_migrate >/dev/null 2>&1
}
