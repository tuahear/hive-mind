#!/usr/bin/env bats
# Tests for memory repo format version management.
# Covers .hive-mind-format seeding, remote-newer abort, remote-equal pass.
#
# Tool-agnostic: uses a generic $ADAPTER_ROOT dir name (not ~/.claude)
# and a generic MEMORY.md memory file (not CLAUDE.md). Exercises the
# format version logic against any adapter that follows the contract.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
SYNC="$REPO_ROOT/core/sync.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME

  ADAPTER_ROOT="$HOME/adapter-root"
  MEMORY_FILE="$ADAPTER_ROOT/MEMORY.md"

  # Seed a working remote with an initial commit.
  git -c init.defaultBranch=main init -q "$HOME/seed"
  git -C "$HOME/seed" config user.email t@t.t
  git -C "$HOME/seed" config user.name t
  printf 'seed\n' > "$HOME/seed/seed.md"
  git -C "$HOME/seed" add seed.md
  git -C "$HOME/seed" commit -q -m seed
  git clone -q --bare "$HOME/seed" "$HOME/remote.git"

  git clone -q "$HOME/remote.git" "$ADAPTER_ROOT"
  git -C "$ADAPTER_ROOT" config user.email t@t.t
  git -C "$ADAPTER_ROOT" config user.name t

  cat > "$ADAPTER_ROOT/.gitignore" <<'EOF'
/*
!/.gitignore
!/.gitattributes
!/.hive-mind-format
!/MEMORY.md
!/projects/
/projects/*
!/projects/*/
/projects/*/*
!/projects/*/memory/
!/projects/*/MEMORY.md
!/skills/
!/skills/**
EOF
  git -C "$ADAPTER_ROOT" add .gitignore
  git -C "$ADAPTER_ROOT" commit -q -m "add gitignore"
  git -C "$ADAPTER_ROOT" push -q
}

teardown() {
  rm -rf "$HOME"
}

run_sync() {
  ADAPTER_DIR="$ADAPTER_ROOT" bash "$SYNC"
}

@test "fresh_empty_repo: first sync writes .hive-mind-format with format-version=1" {
  printf 'hello\n' > "$MEMORY_FILE"

  run run_sync
  [ "$status" -eq 0 ]

  [ -f "$ADAPTER_ROOT/.hive-mind-format" ]
  grep -q 'format-version=1' "$ADAPTER_ROOT/.hive-mind-format"

  # Verify it was committed.
  git -C "$ADAPTER_ROOT" log --oneline --all -- .hive-mind-format | grep -q .
}

@test "remote_newer: remote has format 2, local on 1 → sync aborts, no writes to remote" {
  # Seed the remote with format-version=2.
  other="$(mktemp -d)"
  git clone -q "$HOME/remote.git" "$other/w"
  git -C "$other/w" config user.email t@t.t
  git -C "$other/w" config user.name t
  printf 'format-version=2\n' > "$other/w/.hive-mind-format"
  git -C "$other/w" add .hive-mind-format
  git -C "$other/w" commit -q -m "bump format to 2"
  git -C "$other/w" push -q
  rm -rf "$other"

  # Pull so local sees remote's format.
  git -C "$ADAPTER_ROOT" pull --rebase --quiet 2>/dev/null || true

  # Now try to sync — should abort.
  printf 'new content\n' > "$MEMORY_FILE"
  remote_head="$(git -C "$HOME/remote.git" rev-parse HEAD)"

  run run_sync
  [ "$status" -eq 0 ]  # sync never blocks

  # Remote HEAD unchanged.
  [ "$(git -C "$HOME/remote.git" rev-parse HEAD)" = "$remote_head" ]

  # Error logged.
  [ -f "$ADAPTER_ROOT/.sync-error.log" ]
  grep -q 'format.*2.*upgrade' "$ADAPTER_ROOT/.sync-error.log"
}

@test "remote_equal: both on format 1 → sync proceeds normally" {
  # Seed remote with format 1.
  other="$(mktemp -d)"
  git clone -q "$HOME/remote.git" "$other/w"
  git -C "$other/w" config user.email t@t.t
  git -C "$other/w" config user.name t
  printf 'format-version=1\n' > "$other/w/.hive-mind-format"
  git -C "$other/w" add .hive-mind-format
  git -C "$other/w" commit -q -m "set format 1"
  git -C "$other/w" push -q
  rm -rf "$other"

  git -C "$ADAPTER_ROOT" pull --rebase --quiet

  printf 'content\n' > "$MEMORY_FILE"
  run run_sync
  [ "$status" -eq 0 ]

  # Commit landed on remote.
  msg="$(git -C "$HOME/remote.git" log -1 --format=%s)"
  [ "$msg" = "update MEMORY.md" ]
}

@test "migration_idempotency: running sync twice doesn't duplicate format file" {
  printf 'first\n' > "$MEMORY_FILE"
  run run_sync
  [ "$status" -eq 0 ]

  printf 'second\n' > "$MEMORY_FILE"
  run run_sync
  [ "$status" -eq 0 ]

  # Only one format file, content unchanged.
  [ "$(wc -l < "$ADAPTER_ROOT/.hive-mind-format" | tr -d ' ')" = "1" ]
  grep -q 'format-version=1' "$ADAPTER_ROOT/.hive-mind-format"
}
