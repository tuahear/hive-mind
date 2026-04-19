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

@test "core/hub/sync.sh: push-retry log lines compute timestamp at emission, not reuse \$TS" {
  # The outer $TS in core/hub/sync.sh is captured once near the top of
  # the script. Retry-log lines inside the push backoff loop can fire
  # tens of seconds later (backoff caps at 30s per iteration, 5
  # iterations = up to ~62s of skew), so reusing $TS produces
  # misleading correlations with server-side push logs. Assert the
  # retry/error lines compute the time inline with `date`.
  sync="$REPO_ROOT/core/hub/sync.sh"
  [ -f "$sync" ]
  # Extract the push-retry loop region (from `for (( _attempt=` up to
  # the closing `done`) and assert no `echo "$TS` remains inside it.
  loop="$(awk '/for[[:space:]]*\(\([[:space:]]*_attempt=/,/^[[:space:]]*done$/' "$sync")"
  [ -n "$loop" ]
  if printf '%s\n' "$loop" | grep -qE 'echo[[:space:]]+"\$TS'; then
    echo "core/hub/sync.sh retry loop still reuses \$TS for log lines:" >&2
    printf '%s\n' "$loop" >&2
    return 1
  fi
  # And assert the retry/error log lines call date(1) inline.
  if ! printf '%s\n' "$loop" | grep -qE 'date -u \+%FT%TZ.*push failed'; then
    echo "core/hub/sync.sh retry loop does not recompute timestamp at emission" >&2
    return 1
  fi
}

@test "setup.sh runs the hub's bin/sync with HIVE_MIND_FORCE_PUSH=1 at the end" {
  # v0.3.0 upgrade-path regression: when setup.sh finishes, it must run
  # one sync cycle so whatever it staged (refreshed .gitignore, migrated
  # settings.json, re-installed hooks, new bundled skills, harvested
  # existing tool content) reaches the remote immediately. The old
  # per-adapter `already_synced` branch is gone — the unified hub flow
  # has a single `[6/6]` verify step that must force-push. Pin that so
  # a refactor doesn't silently drop it.
  setup="$BATS_TEST_DIRNAME/../setup.sh"
  [ -f "$setup" ]
  # Anywhere in setup.sh, the hub's bin/sync is invoked with
  # HIVE_MIND_FORCE_PUSH=1 set in the environment.
  grep -qE 'HIVE_MIND_FORCE_PUSH=1' "$setup"
  grep -qE 'bin/sync' "$setup"
}

@test "setup.sh tolerates missing origin remote on the hub under set -euo pipefail" {
  # Regression: command substitution with `git remote get-url origin`
  # fails under `set -euo pipefail` if origin isn't configured, which
  # silently exits setup.sh (stderr is muted by 2>/dev/null). The
  # memory-repo resolution path must include `|| true` on the get-url
  # call so setup.sh prompts the user instead of exiting blank.
  setup="$REPO_ROOT/setup.sh"
  [ -f "$setup" ]
  # At least one `git -C ... remote get-url origin` call must carry
  # `|| true` (or an equivalent tolerant form). Find every such line
  # and require each to be guarded.
  violations="$(grep -nE 'git[[:space:]]+-C.*remote[[:space:]]+get-url[[:space:]]+origin' "$setup" \
    | grep -v '|| true' || true)"
  if [ -n "$violations" ]; then
    echo "git remote get-url origin not guarded by || true in setup.sh:" >&2
    echo "$violations" >&2
    return 1
  fi
}

@test "every git add / rm / checkout / restore of a shell variable uses the '--' separator" {
  # Defense against dash-prefixed paths being mis-parsed as options.
  # Any invocation like `git add "$f"` must be `git add -- "$f"` so a
  # filename starting with `-` cannot be interpreted as a flag. Scan
  # all shell files in the repo (core/, setup.sh, scripts/, adapters/)
  # and fail if any violation is found.
  violations=""
  while IFS= read -r file; do
    # shellcheck disable=SC2016
    bad="$(grep -nE 'git[[:space:]]+(add|rm|checkout|restore)[^|]*"\$[A-Za-z_]' "$file" | grep -v -- ' -- "' || true)"
    if [ -n "$bad" ]; then
      violations="$violations$file:
$bad
"
    fi
  done < <(find "$REPO_ROOT" -type f -name '*.sh' \
             -not -path '*/tests/*' \
             -not -path '*/.git/*')
  if [ -n "$violations" ]; then
    echo "git add/rm/checkout/restore of a shell variable without '--':" >&2
    printf '%s\n' "$violations" >&2
    return 1
  fi
}

@test "setup.sh hub sync invocation does not leak an empty ADAPTER_DIR under set -u" {
  # Regression (rewritten for v0.3.0 hub topology): setup.sh runs under
  # `set -euo pipefail`. The verify step at the end runs
  # $HIVE_MIND_HUB_DIR/bin/sync, which sources each attached adapter
  # itself — it does NOT need setup.sh to forward ADAPTER_DIR. If a
  # future refactor re-introduces an ADAPTER_DIR forward on that line
  # without a ${:-} fallback, a partial / failed adapter load earlier in
  # the script would crash the installer. Assert either: no ADAPTER_DIR
  # forward on the sync line, OR any ADAPTER_DIR forward uses a fallback.
  setup="$BATS_TEST_DIRNAME/../setup.sh"
  [ -f "$setup" ]
  # Isolate the verify-step block. setup.sh switched to a dynamic
  # `step()` helper (step-index is computed at runtime, not hard-coded
  # in the source) so the old `log "[6/6]"` literal no longer exists.
  # Match on the step label instead — it's the stable contract.
  block="$(awk '/^step "running hub sync/,/^fi$/' "$setup")"
  [ -n "$block" ]
  # bin/sync is what the block invokes.
  printf '%s\n' "$block" | grep -Fq 'bin/sync'
  # No bare ADAPTER_DIR="$ADAPTER_DIR" backslash-line in this block.
  if printf '%s\n' "$block" | grep -qE '^[[:space:]]*ADAPTER_DIR="\$ADAPTER_DIR"[[:space:]]*\\?$'; then
    echo "bare \$ADAPTER_DIR (no :- fallback) in hub sync invocation" >&2
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
