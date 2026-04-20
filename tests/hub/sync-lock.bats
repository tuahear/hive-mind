#!/usr/bin/env bats
# Tests for the sync lock in core/hub/sync.sh.
#
# The lock is a directory created via `mkdir` (atomic). On successful
# acquire, sync.sh writes a heartbeat file inside with the acquisition
# timestamp. If a prior sync crashed before its EXIT trap could release
# the lock, the heartbeat is how a subsequent sync tells the lock is
# stale and safe to break — without this, one crash turns into hours of
# silent no-op syncs hitting the retry cap.
#
# Each test runs sync.sh against a hub with no adapters attached, so
# sync bails early after the lock phase. That keeps these tests tightly
# scoped to lock behavior without needing a full harvest/fanout fixture.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
HUB_SYNC="$REPO_ROOT/core/hub/sync.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME

  HUB="$HOME/.hive-mind"
  mkdir -p "$HUB"
  git -c init.defaultBranch=main init -q "$HUB"
  # The no-adapters branch is fine — sync exits 0 after acquiring
  # the lock, so we still cover the acquire/release path cleanly.
  mkdir -p "$HUB/.install-state"

  export HIVE_MIND_HUB_DIR="$HUB"
  LOCK_DIR="$HUB/.hive-mind-state/sync.lock"
  LOG="$HUB/.sync-error.log"
}

teardown() {
  rm -rf "$HOME"
}

run_sync() {
  bash "$HUB_SYNC"
}

@test "clean acquire: heartbeat file written, released on exit" {
  run run_sync
  [ "$status" -eq 0 ]
  # Lock was released by the trap, so the dir should be gone.
  [ ! -d "$LOCK_DIR" ]
}

@test "stale lock is broken: heartbeat older than HIVE_MIND_LOCK_STALE_SECS" {
  # Pre-create a lock with a heartbeat from 10 minutes ago.
  mkdir -p "$LOCK_DIR"
  echo "$(( $(date +%s) - 600 ))" > "$LOCK_DIR/heartbeat"

  run run_sync
  [ "$status" -eq 0 ]
  [ ! -d "$LOCK_DIR" ]
  grep -q "breaking stale lock" "$LOG"
}

@test "legacy lock with no heartbeat file is broken" {
  # A lock created by the old code (pre-heartbeat) has no heartbeat
  # file. Treat it as stale — it's from before this feature shipped or
  # was created by a crash between mkdir and the heartbeat write.
  mkdir -p "$LOCK_DIR"

  run run_sync
  [ "$status" -eq 0 ]
  [ ! -d "$LOCK_DIR" ]
  grep -q "no heartbeat" "$LOG"
}

@test "HIVE_MIND_LOCK_STALE_SECS env override tightens the threshold" {
  # Heartbeat 30s old, threshold 10s → should break.
  mkdir -p "$LOCK_DIR"
  echo "$(( $(date +%s) - 30 ))" > "$LOCK_DIR/heartbeat"

  HIVE_MIND_LOCK_STALE_SECS=10 run run_sync
  [ "$status" -eq 0 ]
  [ ! -d "$LOCK_DIR" ]
  grep -q "breaking stale lock" "$LOG"
}

@test "fresh lock is respected: sync exits 0 without breaking" {
  # Heartbeat from now → not stale under default 300s threshold.
  # sync.sh will hit the 5-retry cap (5 × 2s = ~10s) and exit 0 with
  # the lock still held. That's unchanged behaviour vs. pre-fix; what
  # matters is that we don't accidentally break a live lock.
  mkdir -p "$LOCK_DIR"
  date +%s > "$LOCK_DIR/heartbeat"
  pre_hb="$(cat "$LOCK_DIR/heartbeat")"

  run run_sync
  [ "$status" -eq 0 ]
  # Lock must still be there.
  [ -d "$LOCK_DIR" ]
  # Heartbeat unchanged — nobody rewrote it.
  [ "$(cat "$LOCK_DIR/heartbeat")" = "$pre_hb" ]
  # No "breaking" log line.
  run grep "breaking" "$LOG"
  [ "$status" -ne 0 ]
}
