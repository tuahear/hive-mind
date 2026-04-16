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
