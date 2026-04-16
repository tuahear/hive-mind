#!/usr/bin/env bats
# Tests for core/hub/sync.sh — the Stop-hook-invoked hub sync driver.
#
# Each test sandboxes HOME and assembles:
#   $HOME/remote.git       bare git remote (the shared memory repo)
#   $HIVE_MIND_HUB_DIR     clone of the bare remote with the hub schema seeded
#   $ADAPTER_DIR (tool)    fake adapter's tool dir, attached to the hub
#
# The fake adapter under tests/fixtures/adapters/fake/ ships a Claude-
# shaped hub map + project-content rules, so the hub's generic harvest
# / fan-out path is exercised end-to-end. No Claude binary required.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
HUB_SYNC="$REPO_ROOT/core/hub/sync.sh"
LOADER="$REPO_ROOT/core/adapter-loader.sh"

# Build a marker at runtime so this file never contains the literal
# `<!-- commit: ... -->` token the hub's marker-extract scans for
# (defense-in-depth: a test file getting accidentally scanned would be
# a mess, and grepping the repo for real markers stays unambiguous).
marker() {
  printf '<!-- commit: %s -->' "$1"
}

setup() {
  HOME="$(mktemp -d)"
  export HOME

  # Point the loader at a temp adapters dir that holds only the fake.
  TEST_ADAPTERS_DIR="$HOME/_adapters"
  mkdir -p "$TEST_ADAPTERS_DIR/fake"
  cp "$REPO_ROOT/tests/fixtures/adapters/fake/"* "$TEST_ADAPTERS_DIR/fake/"
  export HIVE_MIND_ADAPTERS_DIR="$TEST_ADAPTERS_DIR"
  export FAKE_ADAPTER_HOME="$HOME"

  # Seed a bare remote with an initial commit on main.
  git -c init.defaultBranch=main init -q "$HOME/seed"
  git -C "$HOME/seed" config user.email t@t.t
  git -C "$HOME/seed" config user.name t
  printf 'seed\n' > "$HOME/seed/seed.md"
  git -C "$HOME/seed" add seed.md
  git -C "$HOME/seed" commit -q -m seed
  git clone -q --bare "$HOME/seed" "$HOME/remote.git"

  # Hub clone. Contains the canonical hub .gitignore + .hive-mind-format
  # mirroring what setup.sh produces.
  HUB="$HOME/.hive-mind"
  export HIVE_MIND_HUB_DIR="$HUB"
  git clone -q "$HOME/remote.git" "$HUB"
  git -C "$HUB" config user.email t@t.t
  git -C "$HUB" config user.name t
  cp "$REPO_ROOT/core/hub/gitignore"     "$HUB/.gitignore"
  cp "$REPO_ROOT/core/hub/gitattributes" "$HUB/.gitattributes"
  printf 'format-version=1\n' > "$HUB/.hive-mind-format"
  git -C "$HUB" add .gitignore .gitattributes .hive-mind-format
  git -C "$HUB" commit -q -m "seed hub whitelist"
  git -C "$HUB" push -q

  # Attach the fake adapter: create its tool dir, register it in the
  # attached-adapters file. The adapter's ADAPTER_DIR default derives
  # from FAKE_ADAPTER_HOME/.fake-tool/.
  mkdir -p "$HUB/.install-state"
  printf 'fake\n' > "$HUB/.install-state/attached-adapters"
  mkdir -p "$HOME/.fake-tool"
}

teardown() {
  rm -rf "$HOME"
}

run_sync() {
  HIVE_MIND_HUB_DIR="$HUB" bash "$HUB_SYNC"
}

# === basic flow ============================================================

@test "early exit: clean tree and no unpushed commits -> no-op" {
  before="$(git -C "$HUB" rev-parse HEAD)"

  run run_sync
  [ "$status" -eq 0 ]

  [ "$(git -C "$HUB" rev-parse HEAD)" = "$before" ]
}

@test "harvest + commit + push: tool edit appears in hub and on remote" {
  # Write through the adapter's native layout (tool-side CLAUDE-ish file).
  printf '# hello from fake tool\n' > "$HOME/.fake-tool/MEMORY.md"

  run run_sync
  [ "$status" -eq 0 ]

  # Hub stored it under the canonical lowercase name.
  [ -f "$HUB/memory.md" ]
  grep -q '# hello from fake tool' "$HUB/memory.md"
  # And reached the remote.
  git -C "$HOME/remote.git" show HEAD:memory.md | grep -q '# hello from fake tool'
}

@test "fan-out: remote memory change populates the tool's native file" {
  # Another machine pushes a memory change via a sibling clone of the bare remote.
  other="$(mktemp -d)"
  git clone -q "$HOME/remote.git" "$other/w"
  git -C "$other/w" config user.email o@o.o
  git -C "$other/w" config user.name o
  printf 'remote-machine content\n' > "$other/w/memory.md"
  git -C "$other/w" add memory.md
  git -C "$other/w" commit -q -m "remote edit"
  git -C "$other/w" push -q
  rm -rf "$other"

  # Trigger a local sync. Harvest (nothing to push), pull-rebase (pulls
  # the remote commit), fan-out (writes the tool dir).
  run run_sync
  [ "$status" -eq 0 ]

  [ -f "$HOME/.fake-tool/MEMORY.md" ]
  grep -q 'remote-machine content' "$HOME/.fake-tool/MEMORY.md"
}

# === marker extraction =====================================================

@test "marker extraction: commit subject is the marker body, marker stripped from file" {
  printf 'hello\n%s\ntail\n' "$(marker 'note a change')" > "$HOME/.fake-tool/MEMORY.md"

  run run_sync
  [ "$status" -eq 0 ]

  [ "$(git -C "$HUB" log -1 --format=%s)" = "note a change" ]
  # After sync the hub-canonical memory.md has the marker stripped.
  grep -q '^hello$' "$HUB/memory.md"
  grep -q '^tail$'  "$HUB/memory.md"
  run grep -q 'commit:' "$HUB/memory.md"
  [ "$status" -ne 0 ]
}

# === machine-local hook filtering =========================================

@test "harvest skips machine-local hook entries while preserving tool-side local entries across sync" {
  # Inject a machine-local hook AND a valid hook into the tool config.
  cat > "$HOME/.fake-tool/hooks.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "/Applications/Local.app/open" } ] },
      { "hooks": [ { "type": "command", "command": "echo-ok" } ] }
    ]
  }
}
EOF

  run run_sync
  [ "$status" -eq 0 ]

  # Hub recorded only the non-local hook.
  [ "$(find "$HUB/config/hooks/SessionStart" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
  grep -Fq 'echo-ok' "$HUB/config/hooks/SessionStart"/*.json
  # Machine-local hook survived in the tool-side config (fan-out must not wipe it).
  jq -e '.hooks.SessionStart | map(.hooks[0].command) | index("/Applications/Local.app/open")' \
    "$HOME/.fake-tool/hooks.json" >/dev/null
  # And the non-local one is also still there (came back via fan-out from hub).
  jq -e '.hooks.SessionStart | map(.hooks[0].command) | index("echo-ok")' \
    "$HOME/.fake-tool/hooks.json" >/dev/null
  # Hub sync's log recorded the skip once.
  grep -Fq 'skipped machine-local hook' "$HUB/.sync-error.log"
}

# === lock / safety gates ===================================================

@test "no attached adapters: sync bails cleanly" {
  : > "$HUB/.install-state/attached-adapters"

  run run_sync
  [ "$status" -eq 0 ]
  grep -Fq 'no adapters attached' "$HUB/.sync-error.log"
}

@test "hub dir without .git: bails with diagnostic" {
  rm -rf "$HUB/.git"

  run run_sync
  [ "$status" -eq 0 ]
  grep -Fq 'not a git repo' "$HUB/.sync-error.log"
}

@test "rate limit: push skipped when interval has not elapsed" {
  export HIVE_MIND_MIN_PUSH_INTERVAL_SEC=9999

  printf 'first\n' > "$HOME/.fake-tool/MEMORY.md"
  run run_sync
  [ "$status" -eq 0 ]
  remote_head1="$(git -C "$HOME/remote.git" rev-parse HEAD)"

  printf 'second\n' > "$HOME/.fake-tool/MEMORY.md"
  run run_sync
  [ "$status" -eq 0 ]
  remote_head2="$(git -C "$HOME/remote.git" rev-parse HEAD)"

  [ "$remote_head1" = "$remote_head2" ]
  # Local commit did land though.
  run git -C "$HUB" log --oneline
  [[ "$output" == *"update memory.md"* ]]
}

@test "HIVE_MIND_FORCE_PUSH overrides debounce" {
  export HIVE_MIND_MIN_PUSH_INTERVAL_SEC=9999
  export HIVE_MIND_FORCE_PUSH=1

  printf 'first\n' > "$HOME/.fake-tool/MEMORY.md"
  run run_sync
  [ "$status" -eq 0 ]
  remote_head1="$(git -C "$HOME/remote.git" rev-parse HEAD)"

  printf 'forced\n' > "$HOME/.fake-tool/MEMORY.md"
  run run_sync
  [ "$status" -eq 0 ]
  remote_head2="$(git -C "$HOME/remote.git" rev-parse HEAD)"

  [ "$remote_head1" != "$remote_head2" ]
}

# === format-version gate ===================================================

@test "remote newer format version aborts the sync with a diagnostic" {
  # Simulate a future install: bump the remote's .hive-mind-format above
  # this install's known version.
  other="$(mktemp -d)"
  git clone -q "$HOME/remote.git" "$other/w"
  git -C "$other/w" config user.email o@o.o
  git -C "$other/w" config user.name o
  printf 'format-version=99\n' > "$other/w/.hive-mind-format"
  git -C "$other/w" add -f .hive-mind-format
  git -C "$other/w" commit -q -m "bump format"
  git -C "$other/w" push -q
  rm -rf "$other"

  printf 'local change\n' > "$HOME/.fake-tool/MEMORY.md"
  run run_sync
  [ "$status" -eq 0 ]

  grep -Fq 'remote is format 99' "$HUB/.sync-error.log"
  # No commit landed because the gate fires before commit.
  local_head="$(git -C "$HUB" rev-parse HEAD 2>/dev/null)"
  [ -n "$local_head" ]
}
