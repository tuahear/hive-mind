#!/usr/bin/env bats
# Integration tests for the full sync flow: edit memory → commit → push.
# Parameterized over adapters via ADAPTER_UNDER_TEST.
#
# Each test sets up a sandboxed HOME with:
#   - A bare git remote
#   - A clone of that remote at ADAPTER_DIR (the adapter's sync root)
#   - The adapter loaded via adapter-loader.sh

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
LOADER="$REPO_ROOT/core/adapter-loader.sh"
SYNC="$REPO_ROOT/core/sync.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME

  adapter="${ADAPTER_UNDER_TEST:-fake}"
  if [ "$adapter" = "fake" ]; then
    # Stage fake adapter into a temp dir; point the loader at it via
    # HIVE_MIND_ADAPTERS_DIR so the real $REPO_ROOT/adapters/ never gets
    # mutated (keeps concurrent bats runs safe, leaves no debris on abort).
    TEST_ADAPTERS_DIR="$HOME/_test_adapters"
    mkdir -p "$TEST_ADAPTERS_DIR/fake"
    cp "$REPO_ROOT/tests/fixtures/adapters/fake/"* "$TEST_ADAPTERS_DIR/fake/"
    export HIVE_MIND_ADAPTERS_DIR="$TEST_ADAPTERS_DIR"
    export FAKE_ADAPTER_HOME="$HOME"
  fi

  source "$LOADER"
  load_adapter "$adapter"

  # Set up bare remote + clone at ADAPTER_DIR.
  git -c init.defaultBranch=main init -q "$HOME/seed"
  git -C "$HOME/seed" config user.email t@t.t
  git -C "$HOME/seed" config user.name t
  printf 'seed\n' > "$HOME/seed/seed.md"
  git -C "$HOME/seed" add seed.md
  git -C "$HOME/seed" commit -q -m seed
  git clone -q --bare "$HOME/seed" "$HOME/remote.git"

  rm -rf "$ADAPTER_DIR"
  git clone -q "$HOME/remote.git" "$ADAPTER_DIR"
  git -C "$ADAPTER_DIR" config user.email t@t.t
  git -C "$ADAPTER_DIR" config user.name t

  # Lay down gitignore.
  cp "$ADAPTER_GITIGNORE_TEMPLATE" "$ADAPTER_DIR/.gitignore"
  git -C "$ADAPTER_DIR" add .gitignore
  git -C "$ADAPTER_DIR" commit -q -m "add gitignore"
  git -C "$ADAPTER_DIR" push -q
}

teardown() {
  # TEST_ADAPTERS_DIR lives under $HOME, which this rm -rf handles.
  rm -rf "$HOME"
}

run_sync() {
  # Pass the full ADAPTER_* set sync.sh consumes (matches how setup.sh
  # at step [5/5] invokes core/sync.sh). Without this the integration
  # test would silently miss wiring regressions — e.g. if a future
  # setup.sh edit forgot to propagate ADAPTER_SECRET_FILES,
  # ADAPTER_MARKER_TARGETS, or ADAPTER_LOG_PATH, sync.sh would fall
  # back to defaults and the test would still pass.
  ADAPTER_DIR="$ADAPTER_DIR" \
  ADAPTER_LOG_PATH="${ADAPTER_LOG_PATH:-}" \
  ADAPTER_MARKER_TARGETS="${ADAPTER_MARKER_TARGETS:-}" \
  ADAPTER_SECRET_FILES="${ADAPTER_SECRET_FILES:-}" \
  ADAPTER_EVENT_SESSION_START="${ADAPTER_EVENT_SESSION_START:-}" \
  ADAPTER_EVENT_TURN_END="${ADAPTER_EVENT_TURN_END:-}" \
  ADAPTER_EVENT_POST_EDIT="${ADAPTER_EVENT_POST_EDIT:-}" \
    bash "$SYNC"
}

marker() {
  printf '<!-- commit: %s -->' "$1"
}

# === Tests =================================================================

@test "edit memory → sync → commit appears on remote" {
  global="${ADAPTER_GLOBAL_MEMORY:-$ADAPTER_DIR/MEMORY.md}"
  printf 'new memory\n' > "$global"

  run run_sync
  [ "$status" -eq 0 ]

  # Verify commit pushed to remote.
  msg="$(git -C "$HOME/remote.git" log -1 --format=%s)"
  [[ "$msg" = *"update"* ]] || [[ "$msg" = *"MEMORY"* ]] || [[ "$msg" = *"CLAUDE"* ]]
}

@test "two-machine scenario: edit on clone A, pull on clone B, memory visible" {
  # Clone B.
  git clone -q "$HOME/remote.git" "$HOME/clone-b"
  git -C "$HOME/clone-b" config user.email t@t.t
  git -C "$HOME/clone-b" config user.name t

  # Edit on clone A (ADAPTER_DIR).
  global="${ADAPTER_GLOBAL_MEMORY:-$ADAPTER_DIR/MEMORY.md}"
  printf 'machine A memory\n' > "$global"
  run run_sync
  [ "$status" -eq 0 ]

  # Pull on clone B.
  git -C "$HOME/clone-b" pull --rebase --quiet

  # Memory visible on B.
  [ -f "$HOME/clone-b/$(basename "$global")" ]
  grep -q 'machine A memory' "$HOME/clone-b/$(basename "$global")"
}

@test "concurrent edits on both sides → union-merge preserves both" {
  global="${ADAPTER_GLOBAL_MEMORY:-$ADAPTER_DIR/MEMORY.md}"
  basename_mem="$(basename "$global")"

  # Set up clone B.
  git clone -q "$HOME/remote.git" "$HOME/clone-b"
  git -C "$HOME/clone-b" config user.email t@t.t
  git -C "$HOME/clone-b" config user.name t

  # Set up gitattributes for union merge on both sides.
  printf '%s merge=union\n' "$basename_mem" > "$ADAPTER_DIR/.gitattributes"
  git -C "$ADAPTER_DIR" add .gitattributes
  git -C "$ADAPTER_DIR" commit -q -m "add gitattributes"

  # Both sides start from the same baseline.
  printf '# shared\n' > "$global"
  git -C "$ADAPTER_DIR" add -A
  git -C "$ADAPTER_DIR" commit -q -m "baseline"
  git -C "$ADAPTER_DIR" push -q
  git -C "$HOME/clone-b" pull --rebase --quiet

  # Machine A adds a line.
  printf '# shared\n- from A\n' > "$global"
  git -C "$ADAPTER_DIR" add -A
  git -C "$ADAPTER_DIR" commit -q -m "A edit"
  git -C "$ADAPTER_DIR" push -q

  # Machine B adds a different line (without pulling first → conflict).
  printf '# shared\n- from B\n' > "$HOME/clone-b/$basename_mem"
  git -C "$HOME/clone-b" add "$basename_mem"
  git -C "$HOME/clone-b" commit -q -m "B edit"

  # B pulls with union merge — rebase applies B's commit on top of A's.
  git -C "$HOME/clone-b" pull --rebase --autostash --quiet 2>/dev/null || true

  # Both lines should survive via union merge.
  grep -q 'from A' "$HOME/clone-b/$basename_mem"
  grep -q 'from B' "$HOME/clone-b/$basename_mem"
}

@test "marker extraction works end-to-end" {
  global="${ADAPTER_GLOBAL_MEMORY:-$ADAPTER_DIR/MEMORY.md}"
  printf 'note\n%s\n' "$(marker 'add first memory')" > "$global"

  run run_sync
  [ "$status" -eq 0 ]

  msg="$(git -C "$ADAPTER_DIR" log -1 --format=%s)"
  [ "$msg" = "add first memory" ]

  # Marker stripped from file.
  run grep 'commit:' "$global"
  [ "$status" -ne 0 ]
}

@test "hook install → simulated event → correct side effect" {
  adapter_install_hooks

  # Simulate a turn-end event by running sync directly.
  global="${ADAPTER_GLOBAL_MEMORY:-$ADAPTER_DIR/MEMORY.md}"
  printf 'post-hook memory\n' > "$global"

  run run_sync
  [ "$status" -eq 0 ]

  msg="$(git -C "$HOME/remote.git" log -1 --format=%s)"
  [[ "$msg" != "seed" ]]
}
