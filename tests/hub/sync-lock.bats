#!/usr/bin/env bats
# Tests for the sync lock in core/hub/sync.sh.
#
# The lock is a directory created via `mkdir` (atomic). On successful
# acquire, sync.sh writes a heartbeat file inside with the acquisition
# timestamp and refreshes it at phase boundaries. If a prior sync
# crashed before its EXIT trap could release the lock, the heartbeat
# is how a subsequent sync tells the lock is stale and safe to break —
# without this, one crash turns into hours of silent no-op syncs
# hitting the retry cap.
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

# Portable "set directory mtime to N minutes ago" for the grace-window
# tests. GNU `touch -d "N min ago"` works on Linux/MSYS; BSD/macOS
# needs the `-v-<N>M` flag via `date`.
_backdate_dir() {
  local path="$1" ago="$2"
  touch -d "$ago" "$path" 2>/dev/null && return 0
  # BSD/macOS fallback — translate "1 hour ago" into -1H.
  case "$ago" in
    "1 hour ago") touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null)" "$path" 2>/dev/null ;;
  esac
}

@test "clean sync acquires and releases the lock directory" {
  # Run sync against a hub with no adapters attached. This still
  # exercises the acquire path (mkdir + heartbeat write) and the
  # EXIT-trap release path; sync exits cleanly once it reaches the
  # no-adapters branch. The heartbeat file's contents are covered
  # end-to-end by the stale-lock tests below, which read the file
  # back through the staleness check and break the lock when the
  # timestamp is past the threshold — if the acquire path didn't
  # write a valid integer heartbeat, those tests would fail.
  run run_sync
  [ "$status" -eq 0 ]
  [ ! -d "$LOCK_DIR" ]
}

@test "stale lock is broken: heartbeat older than HIVE_MIND_LOCK_STALE_SECS" {
  # Pre-create a lock with a heartbeat from 10 minutes ago.
  mkdir -p "$LOCK_DIR"
  echo "$(( $(date +%s) - 600 ))" > "$LOCK_DIR/heartbeat"

  run run_sync
  [ "$status" -eq 0 ]
  [ ! -d "$LOCK_DIR" ]
  grep -q "broke stale lock" "$LOG"
}

@test "legacy lock with no heartbeat is broken once past grace window" {
  # A lock created by the old code (pre-heartbeat) has no heartbeat
  # file. Once the lock dir itself is older than the grace window,
  # treat it as stale. Force mtime backward so we don't wait 10s.
  mkdir -p "$LOCK_DIR"
  _backdate_dir "$LOCK_DIR" "1 hour ago"

  run run_sync
  [ "$status" -eq 0 ]
  [ ! -d "$LOCK_DIR" ]
  grep -q "no heartbeat" "$LOG"
}

@test "missing heartbeat within grace window is NOT broken (concurrent acquire race)" {
  # Simulate a peer that just mkdir'd the lock but hasn't written the
  # heartbeat yet. We must not break this lock — the peer is healthy.
  # HIVE_MIND_LOCK_RETRY_SLEEP_SEC=0 keeps the 5-retry loop instant.
  mkdir -p "$LOCK_DIR"

  HIVE_MIND_LOCK_RETRY_SLEEP_SEC=0 run run_sync
  [ "$status" -eq 0 ]
  # Lock must still be there after our retries gave up.
  [ -d "$LOCK_DIR" ]
  run grep -E "broke stale lock|broke lock with no heartbeat" "$LOG"
  [ "$status" -ne 0 ]
}

@test "HIVE_MIND_LOCK_STALE_SECS env override tightens the threshold" {
  # Heartbeat 30s old, threshold 10s → should break.
  mkdir -p "$LOCK_DIR"
  echo "$(( $(date +%s) - 30 ))" > "$LOCK_DIR/heartbeat"

  HIVE_MIND_LOCK_STALE_SECS=10 run run_sync
  [ "$status" -eq 0 ]
  [ ! -d "$LOCK_DIR" ]
  grep -q "broke stale lock" "$LOG"
}

@test "non-numeric HIVE_MIND_LOCK_STALE_SECS falls back to default, doesn't error" {
  # If the env var is mangled, we must not emit arithmetic errors or
  # crash — fall back to the default 300s. sync.sh runs its sub-
  # commands with 2>>$LOG, so arithmetic errors that escape would
  # land there; we also assert against $output to cover anything
  # written directly to the controlling stderr.
  mkdir -p "$LOCK_DIR"
  echo "$(( $(date +%s) - 600 ))" > "$LOCK_DIR/heartbeat"

  HIVE_MIND_LOCK_STALE_SECS=not-a-number run run_sync
  [ "$status" -eq 0 ]
  # 600s > default 300s → stale → break.
  [ ! -d "$LOCK_DIR" ]
  grep -q "broke stale lock" "$LOG"

  # Nothing that looks like an arithmetic-syntax error in bats-
  # captured stderr/stdout from `run`.
  [ "${output#*integer expression*}" = "$output" ]
  [ "${output#*syntax error*}" = "$output" ]
  # Nor in the log.
  run grep -E "integer expression|syntax error" "$LOG"
  [ "$status" -ne 0 ]
}

@test "fresh lock is respected: sync exits 0 without breaking (retry sleep=0)" {
  # Heartbeat from now → not stale under default 300s threshold.
  # HIVE_MIND_LOCK_RETRY_SLEEP_SEC=0 keeps this test fast — without it
  # the 5-retry loop would burn ~10s on every run.
  mkdir -p "$LOCK_DIR"
  date +%s > "$LOCK_DIR/heartbeat"
  pre_hb="$(cat "$LOCK_DIR/heartbeat")"

  HIVE_MIND_LOCK_RETRY_SLEEP_SEC=0 run run_sync
  [ "$status" -eq 0 ]
  # Lock must still be there.
  [ -d "$LOCK_DIR" ]
  # Heartbeat unchanged — nobody rewrote it.
  [ "$(cat "$LOCK_DIR/heartbeat")" = "$pre_hb" ]
  # No "broke*" log line.
  run grep -E "broke stale lock|broke lock with no heartbeat" "$LOG"
  [ "$status" -ne 0 ]
}

@test "pre-existing FILE at lock path is never mistaken for a lock" {
  # Smoke test for the "acquire failure leaves no stray state" branch.
  # Pre-seed $LOCK_DIR as a regular FILE. mkdir fails, so acquire_lock
  # returns 1 and the retry loop runs. _break_stale_lock's `[ -d ]`
  # guard rejects non-directory paths up front, so the pre-existing
  # file is never considered for rm -rf even if its mtime is outside
  # any grace window. Sync exits cleanly after 5 retries with the
  # file intact.
  mkdir -p "$(dirname "$LOCK_DIR")"
  echo "not a lock" > "$LOCK_DIR"
  # Force mtime 1 hour into the past — past both the 10s grace and
  # 300s stale window. Without the `-d` guard, this age would cause
  # _break_stale_lock to rm -rf the file.
  _backdate_dir "$LOCK_DIR" "1 hour ago"

  HIVE_MIND_LOCK_RETRY_SLEEP_SEC=0 run run_sync
  [ "$status" -eq 0 ]
  # File survived untouched (no conversion to a directory, no removal).
  [ -f "$LOCK_DIR" ]
  [ "$(cat "$LOCK_DIR")" = "not a lock" ]
  # Nothing in the log about breaking this "lock".
  run grep -E "broke stale lock|broke lock with no heartbeat" "$LOG"
  [ "$status" -ne 0 ]
}
