#!/usr/bin/env bats
# Hermes adapter-specific tests. Pins the standalone-blob shape: whole
# ~/.hermes dir maps to hub/hermes/, with NO content.md / skills /
# project rules, NO hook system, and source-side .gitignore respected
# in both harvest and fan-out.

REPO_ROOT="$BATS_TEST_DIRNAME/../../.."
LOADER="$REPO_ROOT/core/adapter-loader.sh"
HARVEST_FANOUT="$REPO_ROOT/core/hub/harvest-fanout.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  source "$LOADER"
  load_adapter "hermes"
}

teardown() {
  rm -rf "$HOME"
}

# === A. Identity & basics ===================================================

@test "ADAPTER_DIR defaults to $HOME/.hermes" {
  [ "$ADAPTER_DIR" = "$HOME/.hermes" ]
}

@test "HERMES_HOME env var overrides ADAPTER_DIR default" {
  custom="$HOME/alt-hermes"
  mkdir -p "$custom"
  (
    unset ADAPTER_DIR
    export HERMES_HOME="$custom"
    source "$LOADER"
    load_adapter "hermes"
    [ "$ADAPTER_DIR" = "$custom" ]
  )
}

@test "ADAPTER_DIR pre-set by the caller is preserved on adapter load" {
  custom="$HOME/preset-hermes"
  mkdir -p "$custom"
  (
    ADAPTER_DIR="$custom"
    export ADAPTER_DIR
    source "$LOADER"
    load_adapter "hermes"
    [ "$ADAPTER_DIR" = "$custom" ]
    [ "$ADAPTER_LOG_PATH" = "$custom/.sync-error.log" ]
  )
}

# === B. Hub mapping shape ==================================================

@test "ADAPTER_HUB_MAP mirrors whole dir, no content.md tier" {
  # Single entry: blob mirror only.
  count="$(printf '%s\n' "$ADAPTER_HUB_MAP" | grep -c .)"
  [ "$count" = "1" ]
  # No content.md tier — that is the entire point of the design.
  ! printf '%s' "$ADAPTER_HUB_MAP" | grep -q 'content\.md'
  # Hub side is the directory `hermes`, tool side is `.` (whole ADAPTER_DIR).
  tab=$'\t'
  printf '%s' "$ADAPTER_HUB_MAP" | grep -q "^hermes${tab}\.$"
}

@test "ADAPTER_PROJECT_CONTENT_RULES is empty" {
  [ -z "$ADAPTER_PROJECT_CONTENT_RULES" ]
}

@test "ADAPTER_SKILL_ROOT and ADAPTER_SKILL_FORMAT are empty" {
  # Hermes' skills ride along inside the blob; they must NOT round-trip
  # through hub/skills/ (which would leak them to Claude / Codex).
  [ -z "$ADAPTER_SKILL_ROOT" ]
  [ -z "$ADAPTER_SKILL_FORMAT" ]
}

# === C. No hook system =====================================================

@test "ADAPTER_HAS_HOOK_SYSTEM is false" {
  [ "$ADAPTER_HAS_HOOK_SYSTEM" = "false" ]
}

@test "ADAPTER_FALLBACK_STRATEGY is manual" {
  [ "$ADAPTER_FALLBACK_STRATEGY" = "manual" ]
}

@test "adapter_install_hooks and adapter_uninstall_hooks are no-ops" {
  mkdir -p "$ADAPTER_DIR"
  pre="$(find "$ADAPTER_DIR" -type f 2>/dev/null | sort)"
  adapter_install_hooks
  adapter_uninstall_hooks
  post="$(find "$ADAPTER_DIR" -type f 2>/dev/null | sort)"
  [ "$pre" = "$post" ]
}

# === D. Secret-file gate ===================================================

@test "ADAPTER_SECRET_FILES declares .env" {
  # Hermes' setup wizard writes API keys to $ADAPTER_DIR/.env. The hub
  # secret gate must unstage it on every cycle.
  printf '%s\n' "$ADAPTER_SECRET_FILES" | tr ' ' '\n' | grep -qx '.env'
}

# === E. Healthcheck ========================================================

@test "adapter_healthcheck passes when $ADAPTER_DIR exists" {
  mkdir -p "$ADAPTER_DIR"
  run adapter_healthcheck
  [ "$status" -eq 0 ]
}

@test "adapter_healthcheck fails when $ADAPTER_DIR is absent and hermes is not on PATH" {
  rm -rf "$ADAPTER_DIR"
  # Drop PATH to ONLY the host's coreutils dirs (so `date` etc. still
  # resolve inside the loader) and exclude every dir that could ship a
  # `hermes` binary. Calling adapter_healthcheck in-process avoids
  # spawning a new bash whose own startup depends on a fuller PATH.
  saved_path="$PATH"
  PATH="/usr/bin:/bin"
  run adapter_healthcheck
  PATH="$saved_path"
  [ "$status" -ne 0 ]
}

# === F. Blob mirror round-trip via harvest/fan-out =========================

@test "harvest mirrors ADAPTER_DIR into hub/hermes/" {
  source "$HARVEST_FANOUT"
  mkdir -p "$ADAPTER_DIR/skills/foo"
  echo "alpha" > "$ADAPTER_DIR/MEMORY.md"
  echo "bravo" > "$ADAPTER_DIR/skills/foo/SKILL.md"

  hub_dir="$HOME/.hive-mind"
  mkdir -p "$hub_dir"
  hub_harvest "$ADAPTER_DIR" "$hub_dir"

  [ -f "$hub_dir/hermes/MEMORY.md" ]
  [ -f "$hub_dir/hermes/skills/foo/SKILL.md" ]
  # SKILL.md was NOT renamed to content.md — Hermes opts out of the
  # provider-agnostic skill tier.
  [ ! -f "$hub_dir/skills/foo/content.md" ]
}

@test "fan-out mirrors hub/hermes/ back into ADAPTER_DIR" {
  source "$HARVEST_FANOUT"
  hub_dir="$HOME/.hive-mind"
  mkdir -p "$hub_dir/hermes/skills/foo"
  echo "alpha" > "$hub_dir/hermes/MEMORY.md"
  echo "bravo" > "$hub_dir/hermes/skills/foo/SKILL.md"

  mkdir -p "$ADAPTER_DIR"
  hub_fan_out "$hub_dir" "$ADAPTER_DIR"

  [ -f "$ADAPTER_DIR/MEMORY.md" ]
  [ -f "$ADAPTER_DIR/skills/foo/SKILL.md" ]
  [ "$(cat "$ADAPTER_DIR/MEMORY.md")" = "alpha" ]
}

# === G. Source-side .gitignore respected ===================================

@test "harvest skips files matching ADAPTER_DIR/.gitignore (.env, cache/, *.log)" {
  source "$HARVEST_FANOUT"
  mkdir -p "$ADAPTER_DIR/cache" "$ADAPTER_DIR/logs" "$ADAPTER_DIR/sub"
  cat > "$ADAPTER_DIR/.gitignore" <<'EOF'
.env
cache/
logs/
*.log
EOF
  echo "secret" > "$ADAPTER_DIR/.env"
  echo "kept"   > "$ADAPTER_DIR/MEMORY.md"
  echo "trash"  > "$ADAPTER_DIR/cache/blob"
  echo "trash"  > "$ADAPTER_DIR/logs/run.log"
  echo "trash"  > "$ADAPTER_DIR/sub/old.log"

  hub_dir="$HOME/.hive-mind"
  mkdir -p "$hub_dir"
  hub_harvest "$ADAPTER_DIR" "$hub_dir"

  [ -f "$hub_dir/hermes/MEMORY.md" ]
  [ -f "$hub_dir/hermes/.gitignore" ]
  [ ! -e "$hub_dir/hermes/.env" ]
  [ ! -e "$hub_dir/hermes/cache/blob" ]
  [ ! -e "$hub_dir/hermes/logs/run.log" ]
  [ ! -e "$hub_dir/hermes/sub/old.log" ]
}

@test "fan-out delete-pass preserves dst files matching src .gitignore" {
  # The cross-machine safety case: machine B pulls the hub, then runs
  # fan-out. The hub does not contain cache/ (it was gitignored on
  # machine A), but ~/.hermes/cache/ exists locally. The delete pass
  # must NOT wipe it.
  source "$HARVEST_FANOUT"
  hub_dir="$HOME/.hive-mind"
  mkdir -p "$hub_dir/hermes"
  cat > "$hub_dir/hermes/.gitignore" <<'EOF'
.env
cache/
*.log
EOF
  echo "from-hub" > "$hub_dir/hermes/MEMORY.md"

  mkdir -p "$ADAPTER_DIR/cache" "$ADAPTER_DIR/sub"
  echo "local"  > "$ADAPTER_DIR/cache/blob"
  echo "local"  > "$ADAPTER_DIR/sub/build.log"
  echo "local"  > "$ADAPTER_DIR/.env"

  hub_fan_out "$hub_dir" "$ADAPTER_DIR"

  [ -f "$ADAPTER_DIR/MEMORY.md" ]
  # Critical: locally-gitignored files must survive fan-out.
  [ -f "$ADAPTER_DIR/cache/blob" ]
  [ -f "$ADAPTER_DIR/sub/build.log" ]
  [ -f "$ADAPTER_DIR/.env" ]
}
