#!/usr/bin/env bats
# Pin the CLI -> setup.sh handoff contract:
#   1. HIVE_MIND_SKIP_CLONE=1 only engages when .git is absent (never
#      pins a real git checkout).
#   2. HIVE_MIND_PREV_VERSION env-var overrides the $HIVE_MIND_SRC/VERSION
#      file probe, with whitespace stripped and empty falling back to
#      the 0.1.0 sentinel.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
SETUP="$REPO_ROOT/setup.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  SRC="$HOME/hive-mind"
  mkdir -p "$SRC"
  # Sentinel script so the SKIP_CLONE block's `-f setup.sh` check passes.
  : > "$SRC/setup.sh"
  # Stub `log` so the eval'd block doesn't try to write to the installer's
  # real log sink.
  log() { echo "$*" >> "$HOME/log.out"; }
  # Stub git so a test that falls through to the clone path would flag it.
  git() { echo "GIT CALLED: $*" >> "$HOME/log.out"; }
  export HIVE_MIND_SRC="$SRC"
  export PREV_HIVE_MIND_VERSION=""
  export HIVE_MIND_REPO="git@example:nobody/nothing.git"
}

teardown() {
  rm -rf "$HOME"
}

# Pull the exact SKIP_CLONE / elif / else block out of setup.sh so we
# test the real branch conditions instead of paraphrasing them.
_skip_clone_block() {
  awk '/HIVE_MIND_SKIP_CLONE:-0/,/^fi$/' "$SETUP"
}

# ============================================================
# SKIP_CLONE guard
# ============================================================

@test "SKIP_CLONE=1 with no .git takes the skip branch (no git invoked)" {
  export HIVE_MIND_SKIP_CLONE=1
  eval "$(_skip_clone_block)"
  # The skip branch intentionally has no log output — verifying by
  # negative: git was never invoked, so neither clone nor pull ran.
  ! grep -q "GIT CALLED" "$HOME/log.out" 2>/dev/null
}

@test "SKIP_CLONE=1 with existing .git directory ignores the override and pulls" {
  mkdir -p "$SRC/.git"
  export HIVE_MIND_SKIP_CLONE=1
  eval "$(_skip_clone_block)"
  grep -q "source already present; pulling latest" "$HOME/log.out"
  grep -q "GIT CALLED" "$HOME/log.out"
  ! grep -q "source staged by CLI" "$HOME/log.out"
}

@test "SKIP_CLONE unset with no .git falls through to clone" {
  rm -f "$SRC/setup.sh"
  rmdir "$SRC" 2>/dev/null || true
  unset HIVE_MIND_SKIP_CLONE
  eval "$(_skip_clone_block)"
  grep -q "GIT CALLED" "$HOME/log.out"
  ! grep -q "source staged by CLI" "$HOME/log.out"
}

@test "SKIP_CLONE=1 but setup.sh missing falls through (protects against unstaged dir)" {
  rm -f "$SRC/setup.sh"
  export HIVE_MIND_SKIP_CLONE=1
  eval "$(_skip_clone_block)"
  grep -q "GIT CALLED" "$HOME/log.out"
  ! grep -q "source staged by CLI" "$HOME/log.out"
}

# ============================================================
# PREV_HIVE_MIND_VERSION env-var override
# ============================================================

_prev_version_block() {
  # Lifted straight from setup.sh — mirrors the normalization block.
  cat <<'SH'
PREV_HIVE_MIND_VERSION="0.1.0"
if [ -n "${HIVE_MIND_PREV_VERSION:-}" ]; then
    _prev_norm="$(printf '%s' "$HIVE_MIND_PREV_VERSION" | tr -d '[:space:]')"
    [ -n "$_prev_norm" ] && PREV_HIVE_MIND_VERSION="$_prev_norm"
    unset _prev_norm
elif [ -f "$HIVE_MIND_SRC/VERSION" ]; then
    PREV_HIVE_MIND_VERSION="$(tr -d '[:space:]' < "$HIVE_MIND_SRC/VERSION" 2>/dev/null || echo "0.1.0")"
fi
SH
}

@test "PREV_VERSION env var wins over VERSION file" {
  echo "9.9.9" > "$SRC/VERSION"
  export HIVE_MIND_PREV_VERSION="0.5.1"
  eval "$(_prev_version_block)"
  [ "$PREV_HIVE_MIND_VERSION" = "0.5.1" ]
}

@test "PREV_VERSION env var normalizes whitespace" {
  export HIVE_MIND_PREV_VERSION="  0.2.5  "
  eval "$(_prev_version_block)"
  [ "$PREV_HIVE_MIND_VERSION" = "0.2.5" ]
}

@test "PREV_VERSION env var that's whitespace-only falls back to sentinel" {
  export HIVE_MIND_PREV_VERSION="   "
  eval "$(_prev_version_block)"
  [ "$PREV_HIVE_MIND_VERSION" = "0.1.0" ]
}

@test "PREV_VERSION env var empty falls back to VERSION file" {
  echo "0.4.2" > "$SRC/VERSION"
  export HIVE_MIND_PREV_VERSION=""
  eval "$(_prev_version_block)"
  [ "$PREV_HIVE_MIND_VERSION" = "0.4.2" ]
}

@test "PREV_VERSION both unset and VERSION file missing yields 0.1.0 sentinel" {
  unset HIVE_MIND_PREV_VERSION
  rm -f "$SRC/VERSION"
  eval "$(_prev_version_block)"
  [ "$PREV_HIVE_MIND_VERSION" = "0.1.0" ]
}

# ============================================================
# Prebuilt hivemind-hook preference
# ============================================================

@test "_prebuilt_hivemind_hook_name maps Darwin+arm64 correctly" {
  eval "$(awk '/^_prebuilt_hivemind_hook_name\(\)/,/^}$/' "$SETUP")"
  uname() { case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac; }
  [ "$(_prebuilt_hivemind_hook_name)" = "hivemind-hook-darwin-arm64" ]
}

@test "_prebuilt_hivemind_hook_name maps Linux+x86_64 correctly" {
  eval "$(awk '/^_prebuilt_hivemind_hook_name\(\)/,/^}$/' "$SETUP")"
  uname() { case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac; }
  [ "$(_prebuilt_hivemind_hook_name)" = "hivemind-hook-linux-amd64" ]
}

@test "_prebuilt_hivemind_hook_name maps MINGW+x86_64 to windows .exe" {
  eval "$(awk '/^_prebuilt_hivemind_hook_name\(\)/,/^}$/' "$SETUP")"
  uname() { case "$1" in -s) echo MINGW64_NT-10.0 ;; -m) echo x86_64 ;; esac; }
  [ "$(_prebuilt_hivemind_hook_name)" = "hivemind-hook-windows-amd64.exe" ]
}

@test "_prebuilt_hivemind_hook_name returns empty for unknown OS" {
  eval "$(awk '/^_prebuilt_hivemind_hook_name\(\)/,/^}$/' "$SETUP")"
  uname() { case "$1" in -s) echo FreeBSD ;; -m) echo amd64 ;; esac; }
  [ -z "$(_prebuilt_hivemind_hook_name)" ]
}
