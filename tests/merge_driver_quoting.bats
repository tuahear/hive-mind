#!/usr/bin/env bats
# Scanner-style tests that pin merge-driver placeholder quoting
# (%A / %O / %B) across every place they are either registered or
# documented.
#
# Context: git substitutes %A / %O / %B with absolute temp-file
# paths before invoking the driver via `sh -c`. A path containing
# spaces (Windows Git Bash "C:/Users/Jane Doe", spaced macOS home
# dirs) word-splits at invocation if the placeholders are not
# single-quoted, handing the driver the wrong arguments. We want
# every instance — runtime registration AND doc-example copy — to
# use the quoted form so users who follow any code path stay safe.

REPO_ROOT="$BATS_TEST_DIRNAME/.."

@test "setup.sh: every merge.*.driver registration quotes %A %O %B" {
  # Find all lines in setup.sh that register a merge driver. Any such
  # line must contain `'%A' '%O' '%B'` — unquoted forms will fail
  # this test and point at the file/line that regressed.
  violations="$(grep -nE "merge\.[^\"]*\.driver" "$REPO_ROOT/setup.sh" \
    | grep -v "'%A' '%O' '%B'" || true)"
  if [ -n "$violations" ]; then
    echo "setup.sh has merge-driver registrations missing quoted %A/%O/%B:" >&2
    echo "$violations" >&2
    return 1
  fi
}

@test "core/*.sh header docs: merge-driver example lines use quoted %A %O %B" {
  # The header comments in core/jsonmerge.sh / core/tomlmerge.sh show
  # an example `git config merge.<drv>.driver ...` invocation that
  # adapter authors may copy verbatim. Drifting doc → unsafe copy.
  # Scan any `merge\.[A-Za-z0-9_-]+\.driver` line and require the
  # quoted placeholder form.
  for f in "$REPO_ROOT/core/jsonmerge.sh" "$REPO_ROOT/core/tomlmerge.sh"; do
    # Skip files that don't exist (defensive — neither should be missing).
    [ -f "$f" ] || continue
    # Only comment lines (# ...) referencing merge.<drv>.driver; pure
    # code lines aren't expected in these driver scripts but we don't
    # need to exclude them, the pattern catches both.
    violations="$(grep -nE 'merge\.[A-Za-z0-9_-]+\.driver' "$f" \
      | grep -v "'%A' '%O' '%B'" || true)"
    if [ -n "$violations" ]; then
      echo "$(basename "$f") has merge-driver example(s) missing quoted placeholders:" >&2
      echo "$violations" >&2
      return 1
    fi
  done
}

@test "core/sync.sh: push-retry log lines compute timestamp at emission, not reuse \$TS" {
  # The outer $TS in core/sync.sh is captured once near the top of
  # the script. Retry-log lines inside the push backoff loop can fire
  # tens of seconds later (backoff caps at 30s per iteration, 5
  # iterations = up to ~62s of skew), so reusing $TS produces
  # misleading correlations with server-side push logs. Assert the
  # retry/error lines compute the time inline with `date`.
  sync="$REPO_ROOT/core/sync.sh"
  [ -f "$sync" ]
  # Extract the push-retry loop region (from `for (( _attempt=` up to
  # the closing `done`) and assert no `echo "$TS` remains inside it.
  loop="$(awk '/for[[:space:]]*\(\([[:space:]]*_attempt=/,/^[[:space:]]*done$/' "$sync")"
  [ -n "$loop" ]
  if printf '%s\n' "$loop" | grep -qE 'echo[[:space:]]+"\$TS'; then
    echo "core/sync.sh retry loop still reuses \$TS for log lines:" >&2
    printf '%s\n' "$loop" >&2
    return 1
  fi
  # And assert the retry/error log lines call date(1) inline.
  if ! printf '%s\n' "$loop" | grep -qE 'date -u \+%FT%TZ.*push failed'; then
    echo "core/sync.sh retry loop does not recompute timestamp at emission" >&2
    return 1
  fi
}

@test "setup.sh already_synced upgrade path runs sync.sh with HIVE_MIND_FORCE_PUSH=1 before exit" {
  # Regression: without this the upgrade flow made local edits
  # (refreshed .gitignore, migrated settings, re-installed hooks) and
  # exited without pushing, so cross-machine propagation waited for the
  # next hook-driven sync. That could be hours if the upgraded machine
  # didn't start a new session — defeating hive-mind's core value.
  # Scan the already_synced case block for a HIVE_MIND_FORCE_PUSH=1
  # invocation of core/sync.sh appearing BEFORE the terminating
  # exit 0. Implementation-level pin (regression smoke), not a full
  # end-to-end integration test, which would require substantial
  # setup.sh stubbing; combined with the existing setup-fresh-flow
  # integration test, the surface is covered.
  setup="$BATS_TEST_DIRNAME/../setup.sh"
  [ -f "$setup" ]
  block="$(awk '/^    already_synced\)/,/^        ;;/' "$setup")"
  [ -n "$block" ]
  # Force-push invocation present.
  printf '%s\n' "$block" | grep -Fq 'HIVE_MIND_FORCE_PUSH=1'
  # And it references core/sync.sh so a future rename of the script
  # does not silently defeat the propagation.
  printf '%s\n' "$block" | grep -Fq 'core/sync.sh'
  # The block still terminates with exit 0 — no regression of the
  # non-blocking guarantee.
  printf '%s\n' "$block" | grep -qE '^[[:space:]]*exit 0[[:space:]]*$'
}

@test "setup.sh already_synced sync invocation provides ADAPTER_DIR fallback for set -u" {
  # Regression: setup.sh runs under `set -euo pipefail`. If the adapter
  # failed to load (adapter-loader.sh missing or load_adapter returned
  # non-zero), ADAPTER_DIR is never set by the adapter. A bare
  # `ADAPTER_DIR="$ADAPTER_DIR"` expansion would then crash the
  # installer with "unbound variable" — right in the path that is
  # supposed to degrade gracefully. Pin the ${ADAPTER_DIR:-...} default
  # so a future refactor doesn't silently reintroduce the crash.
  setup="$BATS_TEST_DIRNAME/../setup.sh"
  [ -f "$setup" ]
  block="$(awk '/^    already_synced\)/,/^        ;;/' "$setup")"
  [ -n "$block" ]
  # The sync invocation must use a fallback form, not bare $ADAPTER_DIR.
  # Accept any `${ADAPTER_DIR:-...}` spelling; reject a bare
  # `ADAPTER_DIR="$ADAPTER_DIR"` on the sync env line.
  if printf '%s\n' "$block" | grep -qE 'ADAPTER_DIR="\$ADAPTER_DIR"[[:space:]]*\\?$'; then
    echo "bare \$ADAPTER_DIR (no :- fallback) in already_synced sync invocation" >&2
    return 1
  fi
  printf '%s\n' "$block" | grep -qE 'ADAPTER_DIR="\$\{ADAPTER_DIR:-[^}]+\}"'
}

@test "docs/*.md: any git config merge.*.driver example uses quoted %A %O %B" {
  # Same drift risk in contributor / adapter docs. If no doc yet
  # mentions the pattern this test trivially passes; if docs add a
  # merge-driver example in the future, the quoting invariant is
  # already pinned.
  if [ -d "$REPO_ROOT/docs" ]; then
    violations="$(grep -rnE 'merge\.[A-Za-z0-9_-]+\.driver' "$REPO_ROOT/docs" \
      | grep -v "'%A' '%O' '%B'" || true)"
    if [ -n "$violations" ]; then
      echo "docs/ has merge-driver example(s) missing quoted placeholders:" >&2
      echo "$violations" >&2
      return 1
    fi
  fi
}
