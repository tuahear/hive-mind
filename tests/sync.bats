#!/usr/bin/env bats
# Tests for scripts/sync.sh — the Stop-hook sync driver.
#
# sync.sh runs `cd ~/.claude` and assumes that directory is a git checkout
# with an upstream. Each test sandboxes HOME and sets up:
#   $HOME/remote.git    — bare git remote
#   $HOME/.claude       — clone of the bare remote, tracking origin/main
# The sandbox also skips the mirror-projects.sh invocation (no such file
# exists under $HOME/.claude/hive-mind in the sandbox).

SCRIPT="$BATS_TEST_DIRNAME/../core/sync.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME

  # Seed a working "remote" with an initial commit on main, then snapshot
  # it into a bare repo that our .claude clone tracks.
  git -c init.defaultBranch=main init -q "$HOME/seed"
  git -C "$HOME/seed" config user.email t@t.t
  git -C "$HOME/seed" config user.name t
  printf 'seed\n' > "$HOME/seed/seed.md"
  git -C "$HOME/seed" add seed.md
  git -C "$HOME/seed" commit -q -m seed
  git clone -q --bare "$HOME/seed" "$HOME/remote.git"

  git clone -q "$HOME/remote.git" "$HOME/.claude"
  git -C "$HOME/.claude" config user.email t@t.t
  git -C "$HOME/.claude" config user.name t

  # Match the real deployment: ~/.claude is a whitelist-only repo so the
  # script's `git add -A` doesn't pick up the script's own .sync-error.log
  # or other stray files outside the synced tree.
  cat > "$HOME/.claude/.gitignore" <<'EOF'
/*
!/.gitignore
!/.gitattributes
!/settings.json
!/CLAUDE.md
!/projects/
/projects/*
!/projects/*/
/projects/*/*
!/projects/*/memory/
!/projects/*/MEMORY.md
!/skills/
!/skills/**
EOF
  git -C "$HOME/.claude" add .gitignore
  git -C "$HOME/.claude" commit -q -m "add whitelist gitignore"
  git -C "$HOME/.claude" push -q
}

teardown() {
  rm -rf "$HOME"
}

run_sync() {
  bash "$SCRIPT"
}

# Construct marker strings dynamically so the literal pattern sync.sh scans
# for never appears as a byte sequence in this test file. Defense-in-depth:
# even though tests/ lives outside the marker-scan whitelist, grepping the
# repo for real markers stays unambiguous.
marker() {
  printf '<!-- commit: %s -->' "$1"
}

# Tests ---------------------------------------------------------------------

@test "early exit: clean tree and no unpushed commits → no-op" {
  before="$(git -C "$HOME/.claude" rev-parse HEAD)"

  run run_sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.claude" rev-parse HEAD)" = "$before" ]
}

@test "mirror runs BEFORE the early-exit gate so a fresh project bootstraps in one sync" {
  # Stage a real git repo to act as a project's cwd, drop a session jsonl
  # pointing at it, and a stub mirror script that — like the real one —
  # writes a sidecar derived from the cwd. With a clean working tree and
  # no unpushed commits, the OLD ordering early-exited before mirror got
  # to run, leaving sidecars unwritten until the user manually triggered
  # something that dirtied the tree. Mirror must run first so that the
  # bootstrap commit happens on the very first sync.
  proj_dir="$HOME/myrepo"
  git -c init.defaultBranch=main init -q "$proj_dir"
  git -C "$proj_dir" remote add origin git@github.com:Owner/MyRepo.git

  variant="$HOME/.claude/projects/-Users-alice-myrepo"
  mkdir -p "$variant"
  printf '{"cwd":"%s"}\n' "$proj_dir" > "$variant/session.jsonl"
  # Real memory content is required for mirror's bootstrap gate to fire
  # (content-less variants are intentionally left alone). The point of
  # this test is ordering — that mirror runs before the early-exit gate —
  # not the content-gate behavior, which is exercised in mirror-projects.bats.
  printf '# notes\n' > "$variant/MEMORY.md"

  # core/sync.sh discovers mirror-projects.sh via CORE_DIR (same directory
  # as the script itself), so no separate install step is needed when
  # running from the repo checkout.

  run run_sync
  [ "$status" -eq 0 ]

  # Sidecar was written by mirror in the new key=value format.
  [ -f "$variant/memory/.hive-mind" ]
  grep -Fq "project-id=github.com/owner/myrepo" "$variant/memory/.hive-mind"

  # And it was committed + pushed (proves we did NOT early-exit).
  msg="$(git -C "$HOME/.claude" log -1 --format=%s)"
  [ "$msg" != "add whitelist gitignore" ]
}

@test "fallback commit message: 1 file → 'update <basename>'" {
  printf 'hello\n' > "$HOME/.claude/CLAUDE.md"

  run run_sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.claude" log -1 --format=%s)" = "update CLAUDE.md" ]
}

@test "fallback commit message: 3 files → 'update a.md, b.md, c.md'" {
  mkdir -p "$HOME/.claude/skills"
  for f in a.md b.md c.md; do printf 'x\n' > "$HOME/.claude/skills/$f"; done

  run run_sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.claude" log -1 --format=%s)" = "update a.md, b.md, c.md" ]
}

@test "fallback commit message: 5 files → first 3 basenames + '+N more'" {
  mkdir -p "$HOME/.claude/skills"
  for f in a.md b.md c.md d.md e.md; do printf 'x\n' > "$HOME/.claude/skills/$f"; done

  run run_sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.claude" log -1 --format=%s)" = "update a.md, b.md, c.md, +2 more" ]
}

@test "marker extraction: full-line marker → commit message is the marker body, marker stripped from file" {
  printf 'hello\n%s\ntail\n' "$(marker 'my message')" > "$HOME/.claude/CLAUDE.md"

  run run_sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.claude" log -1 --format=%s)" = "my message" ]
  run grep -q 'commit:' "$HOME/.claude/CLAUDE.md"
  [ "$status" -ne 0 ]
  grep -q '^hello$' "$HOME/.claude/CLAUDE.md"
  grep -q '^tail$'  "$HOME/.claude/CLAUDE.md"
}

@test "marker extraction: inline marker → message extracted, surrounding text kept, marker stripped" {
  printf 'some content %s tail\n' "$(marker 'msg')" > "$HOME/.claude/CLAUDE.md"

  run run_sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.claude" log -1 --format=%s)" = "msg" ]
  grep -q 'some content' "$HOME/.claude/CLAUDE.md"
  grep -q 'tail'         "$HOME/.claude/CLAUDE.md"
  run grep -q 'commit:' "$HOME/.claude/CLAUDE.md"
  [ "$status" -ne 0 ]
}

@test "marker inside a fenced code block is preserved while a marker outside the fence in the same file IS extracted" {
  # Two markers in one file: one outside a code fence (must be extracted +
  # stripped), one inside (must be preserved as-is). Using both together is
  # the only way to positively prove the fence-aware scan actually ran on
  # this path — if the file were skipped entirely, the fenced marker would
  # also survive but the outside marker would too, which this test rejects.
  mkdir -p "$HOME/.claude/skills/foo"
  printf 'header\n%s\n\n```\n%s\n```\n\nafter\n' \
    "$(marker 'real extract')" "$(marker 'inside fence')" \
    > "$HOME/.claude/skills/foo/SKILL.md"

  run run_sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.claude" log -1 --format=%s)" = "real extract" ]
  # Outside-fence marker is gone (extracted + stripped).
  run grep -Fq 'real extract' "$HOME/.claude/skills/foo/SKILL.md"
  [ "$status" -ne 0 ]
  # Inside-fence marker preserved verbatim.
  grep -Fq 'inside fence' "$HOME/.claude/skills/foo/SKILL.md"
}

@test "multiple markers across files are joined with ' + '" {
  mkdir -p "$HOME/.claude/projects/p1/memory"
  printf 'a\n%s\n' "$(marker 'msg1')" > "$HOME/.claude/CLAUDE.md"
  printf 'b\n%s\n' "$(marker 'msg2')" > "$HOME/.claude/projects/p1/memory/x.md"

  run run_sync
  [ "$status" -eq 0 ]
  msg="$(git -C "$HOME/.claude" log -1 --format=%s)"
  [ "$msg" = "msg1 + msg2" ] || [ "$msg" = "msg2 + msg1" ]
}

@test "identical markers across staged files are deduped (no 'msg + msg')" {
  # mirror-projects.sh copies an edited file — marker and all — into
  # its path-variant peer, so two staged files end up carrying the
  # same marker body. The commit subject must not double it.
  mkdir -p "$HOME/.claude/projects/p1/memory" \
           "$HOME/.claude/projects/p2/memory"
  printf 'shared\n%s\n' "$(marker 'one edit')" \
    > "$HOME/.claude/projects/p1/memory/note.md"
  printf 'shared\n%s\n' "$(marker 'one edit')" \
    > "$HOME/.claude/projects/p2/memory/note.md"

  run run_sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.claude" log -1 --format=%s)" = "one edit" ]
}

@test "trailing blank lines are trimmed after full-line marker at EOF" {
  printf 'content\n%s\n' "$(marker 'eof')" > "$HOME/.claude/CLAUDE.md"

  run run_sync
  [ "$status" -eq 0 ]
  # Expect exactly one line: "content\n" — no dangling blank where the marker was.
  [ "$(wc -l < "$HOME/.claude/CLAUDE.md" | tr -d ' ')" = "1" ]
  grep -q '^content$' "$HOME/.claude/CLAUDE.md"
}

@test "tracked-but-not-marker-whitelisted file: fake marker is not scanned, fallback applies" {
  # settings.json is tracked/synced but lives outside the marker-scan whitelist
  # (CLAUDE.md / projects/*/memory / projects/*/MEMORY.md / skills/*). A stray
  # marker-shaped comment in it must NOT hijack the commit message and must
  # NOT be stripped from the file.
  printf '{"note": "%s"}\n' "$(marker 'fake')" > "$HOME/.claude/settings.json"

  run run_sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.claude" log -1 --format=%s)" = "update settings.json" ]
  grep -q 'fake' "$HOME/.claude/settings.json"
}

@test "marker-scan loop handles a staged filename containing a newline (NUL-delimited read)" {
  # Round-4 regression guard: the marker-scan loop previously read staged
  # paths newline-delimited, so a filename containing \n would be split
  # across two read iterations — the marker inside it would be skipped.
  # With `git diff --cached --name-only -z` + `read -d ''`, the filename
  # passes through intact and the marker is extracted normally.
  mkdir -p "$HOME/.claude/skills"
  weird=$'weird\nname.md'
  printf 'before\n%s\nafter\n' "$(marker 'across newline filename')" \
    > "$HOME/.claude/skills/$weird"

  run run_sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.claude" log -1 --format=%s)" = "across newline filename" ]
  # Marker must be stripped from the file on disk.
  run grep -Fq 'commit:' "$HOME/.claude/skills/$weird"
  [ "$status" -ne 0 ]
}

@test "basename containing spaces survives the fallback join (no xargs word-splitting)" {
  # Round-2 regression guard: the old pipeline (echo | xargs -n1 basename |
  # paste) split on whitespace, so 'two word.md' became three tokens. With
  # the NUL-delimited read + parameter-expansion basename, spaces pass
  # through untouched.
  mkdir -p "$HOME/.claude/skills"
  printf 'x\n' > "$HOME/.claude/skills/a.md"
  printf 'x\n' > "$HOME/.claude/skills/two word.md"

  run run_sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.claude" log -1 --format=%s)" = "update a.md, two word.md" ]
}

@test "basename containing a newline is sanitized so the commit message doesn't split or break" {
  # NUL-delimited read preserves any char in a filename, including \n. The
  # downstream awk join uses \n as record separator — without the cntrl-
  # collapse step, a two-file sync where one name contains a newline would
  # produce three awk records and a mangled commit subject.
  mkdir -p "$HOME/.claude/skills"
  weird=$'weird\nname.md'
  printf 'x\n' > "$HOME/.claude/skills/a.md"
  printf 'x\n' > "$HOME/.claude/skills/$weird"

  run run_sync
  [ "$status" -eq 0 ]
  msg="$(git -C "$HOME/.claude" log -1 --format=%s)"
  [ "$msg" = "update a.md, weird name.md" ]
  # Subject must itself contain no literal newline.
  [[ "$msg" != *$'\n'* ]]
}

@test "pull-rebase conflict: clean abort, exit 0, logged to .sync-error.log, local commit preserved" {
  # Seed the remote with a conflicting commit via a second clone.
  other="$(mktemp -d)"
  git clone -q "$HOME/remote.git" "$other/w"
  git -C "$other/w" config user.email t@t.t
  git -C "$other/w" config user.name t
  printf 'remote side\n' > "$other/w/CLAUDE.md"
  git -C "$other/w" add CLAUDE.md
  git -C "$other/w" commit -q -m "remote change"
  git -C "$other/w" push -q
  rm -rf "$other"

  # Local unpushed commit on the same file, different content.
  printf 'local side\n' > "$HOME/.claude/CLAUDE.md"
  git -C "$HOME/.claude" add CLAUDE.md
  git -C "$HOME/.claude" commit -q -m "local change"
  local_head="$(git -C "$HOME/.claude" rev-parse HEAD)"

  run run_sync
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/.sync-error.log" ]
  grep -q 'pull-rebase failed' "$HOME/.claude/.sync-error.log"

  # Local working tree restored (autostash) and rebase aborted.
  grep -q 'local side' "$HOME/.claude/CLAUDE.md"
  [ "$(git -C "$HOME/.claude" rev-parse HEAD)" = "$local_head" ]
}

# Rate-limit tests ----------------------------------------------------------

@test "rate limit: push is skipped when interval has not elapsed" {
  # Set a very long push interval so the second push is definitely skipped.
  export HIVE_MIND_MIN_PUSH_INTERVAL_SEC=9999

  # First edit + sync — should push.
  printf 'first\n' > "$HOME/.claude/CLAUDE.md"
  run run_sync
  [ "$status" -eq 0 ]
  remote_head1="$(git -C "$HOME/remote.git" rev-parse HEAD)"

  # Second edit + sync — should commit locally but skip push.
  printf 'second\n' > "$HOME/.claude/CLAUDE.md"
  run run_sync
  [ "$status" -eq 0 ]
  remote_head2="$(git -C "$HOME/remote.git" rev-parse HEAD)"

  # Remote should not have advanced.
  [ "$remote_head1" = "$remote_head2" ]
  # But local should have the commit.
  [ "$(git -C "$HOME/.claude" log -1 --format=%s)" = "update CLAUDE.md" ]
}

@test "rate limit: HIVE_MIND_FORCE_PUSH overrides debounce" {
  export HIVE_MIND_MIN_PUSH_INTERVAL_SEC=9999
  export HIVE_MIND_FORCE_PUSH=1

  printf 'first\n' > "$HOME/.claude/CLAUDE.md"
  run run_sync
  [ "$status" -eq 0 ]
  remote_head1="$(git -C "$HOME/remote.git" rev-parse HEAD)"

  printf 'forced\n' > "$HOME/.claude/CLAUDE.md"
  run run_sync
  [ "$status" -eq 0 ]
  remote_head2="$(git -C "$HOME/remote.git" rev-parse HEAD)"

  # Remote DID advance because force-push overrides debounce.
  [ "$remote_head1" != "$remote_head2" ]
}

@test "REGRESSION: a previously-debounced commit gets pushed on the next non-edit sync" {
  # Debounce the second push, then run sync a third time with no new
  # staged changes. The pending local commit must still get pushed (the
  # older impl gated push behind staged-diff and would silently strand
  # the commit on the local branch until another file change triggered it).

  # First edit + sync establishes a baseline (and writes last-push).
  export HIVE_MIND_MIN_PUSH_INTERVAL_SEC=0
  printf 'baseline\n' > "$HOME/.claude/CLAUDE.md"
  run run_sync
  [ "$status" -eq 0 ]
  remote_head_before="$(git -C "$HOME/remote.git" rev-parse HEAD)"

  # Second edit + sync with high min-interval — commit lands locally,
  # push is debounced.
  export HIVE_MIND_MIN_PUSH_INTERVAL_SEC=9999
  printf 'second\n' > "$HOME/.claude/CLAUDE.md"
  run run_sync
  [ "$status" -eq 0 ]
  local_head_after_debounce="$(git -C "$HOME/.claude" rev-parse HEAD)"
  remote_head_after_debounce="$(git -C "$HOME/remote.git" rev-parse HEAD)"
  # Local advanced, remote did not — confirms the debounce fired.
  [ "$local_head_after_debounce" != "$remote_head_after_debounce" ]
  [ "$remote_head_after_debounce" = "$remote_head_before" ]

  # Now relax the rate limit and run sync again with NO file edits.
  # The unpushed local commit must reach the remote.
  export HIVE_MIND_MIN_PUSH_INTERVAL_SEC=0
  run run_sync
  [ "$status" -eq 0 ]
  remote_head_final="$(git -C "$HOME/remote.git" rev-parse HEAD)"
  [ "$remote_head_final" = "$local_head_after_debounce" ]
}

@test "rate limit: last-push state file is written after successful push outside hive-mind git repo" {
  printf 'hello\n' > "$HOME/.claude/CLAUDE.md"
  run run_sync
  [ "$status" -eq 0 ]
  # State lives under $ADAPTER_DIR/.hive-mind-state/ so it never lands
  # inside the hive-mind checkout (which gets `git pull`ed on upgrade).
  [ -f "$HOME/.claude/.hive-mind-state/last-push" ]
  [[ "$(cat "$HOME/.claude/.hive-mind-state/last-push")" =~ ^[0-9]+$ ]]
}

@test "fresh install with empty remote pushes the initial commit and sets upstream" {
  # Scenario: `git init` + `git remote add` pointing at an EMPTY bare
  # remote (no branches yet) and no upstream tracking configured.
  # Naive use of `@{u}` as the "unpushed commits?" check fails here
  # (undefined), leaving the initial commit stranded until another
  # file change triggers another commit. The fix: detect no upstream
  # and run `git push -u origin <branch>` so the first push
  # publishes the branch AND sets tracking for subsequent syncs.
  empty_remote="$HOME/empty-remote.git"
  git -c init.defaultBranch=main init --bare -q "$empty_remote"

  fresh="$HOME/fresh-claude"
  mkdir -p "$fresh"
  git -c init.defaultBranch=main init -q "$fresh"
  git -C "$fresh" config user.email t@t.t
  git -C "$fresh" config user.name t
  git -C "$fresh" remote add origin "$empty_remote"
  # No `git fetch`, no `git branch -u` — upstream is unset AND the
  # remote has no branches yet. This is exactly the fresh-init case.

  cat > "$fresh/.gitignore" <<'EOF'
/*
!/.gitignore
!/CLAUDE.md
EOF
  printf 'first content\n' > "$fresh/CLAUDE.md"

  run bash -c "ADAPTER_DIR='$fresh' bash '$SCRIPT'"
  [ "$status" -eq 0 ]

  # The initial commit reached the remote.
  git -C "$empty_remote" log --oneline --all | grep -q .
  # Upstream tracking got configured by the `-u` flag.
  git -C "$fresh" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1
}

@test "release_lock does not remove the lock dir after another process reclaimed it" {
  # Race guarded: legitimate sync A runs long (>STALE_AGE_SEC); sync B
  # deems A's lock stale, removes it, and acquires a fresh lock. A's
  # EXIT trap must NOT delete B's lock — doing so would let a third
  # process C acquire a concurrent lock while B is still running.
  # Exercises the owner-PID check in release_lock().
  tmp="$(mktemp -d)"
  lock_dir="$tmp/sync.lock"

  # Extract acquire_lock + release_lock from core/sync.sh and run them
  # against a local LOCK_DIR. The functions are self-contained (they
  # only depend on LOCK_DIR and the local shell's PID), so this is a
  # clean unit test.
  LOCK_DIR="$lock_dir"
  # shellcheck disable=SC2030
  eval "$(awk '/^acquire_lock\(\)/,/^}/' "$BATS_TEST_DIRNAME/../core/sync.sh")"
  # shellcheck disable=SC2030
  eval "$(awk '/^release_lock\(\)/,/^}/' "$BATS_TEST_DIRNAME/../core/sync.sh")"

  # Simulate: process A acquires.
  acquire_lock
  [ -d "$lock_dir" ]
  [ "$(cat "$lock_dir/owner-pid")" = "$$" ]

  # Simulate: process B reclaims after deeming A stale. It wipes the
  # dir and writes its own PID (a sentinel different from $$).
  rm -rf "$lock_dir"
  mkdir "$lock_dir"
  printf 'not-our-pid\n' > "$lock_dir/owner-pid"

  # Process A's EXIT trap fires release_lock now. With the owner check,
  # the lock must remain intact because the PID no longer matches.
  release_lock
  [ -d "$lock_dir" ]
  [ "$(cat "$lock_dir/owner-pid")" = "not-our-pid" ]
}

@test "acquire_lock's own process can release the lock it acquired" {
  # Pairing test: the owner-PID check must not over-correct and leave
  # the lock dir around after a legitimate release. Otherwise the next
  # sync invocation finds a stale-looking lock forever.
  tmp="$(mktemp -d)"
  lock_dir="$tmp/sync.lock"
  LOCK_DIR="$lock_dir"
  eval "$(awk '/^acquire_lock\(\)/,/^}/' "$BATS_TEST_DIRNAME/../core/sync.sh")"
  eval "$(awk '/^release_lock\(\)/,/^}/' "$BATS_TEST_DIRNAME/../core/sync.sh")"

  acquire_lock
  [ -d "$lock_dir" ]
  release_lock
  [ ! -d "$lock_dir" ]
}

@test "fresh install sets upstream for a branch name with unusual-but-valid characters" {
  # Pins the push invocation's handling of arbitrary branch names.
  # If push_args ever regresses to unquoted word-splitting, a branch
  # name like `feat/with.dots+plus-dash` still pushes fine here, but
  # the test guarantees the upstream-set path stays exercised for
  # non-trivial refspecs so a future refactor that e.g. sanitizes the
  # branch name through a regex gets caught.
  empty_remote="$HOME/unusual-remote.git"
  git -c init.defaultBranch=main init --bare -q "$empty_remote"

  fresh="$HOME/fresh-unusual"
  mkdir -p "$fresh"
  git -c init.defaultBranch=main init -q "$fresh"
  git -C "$fresh" config user.email test@example.com
  git -C "$fresh" config user.name test
  git -C "$fresh" remote add origin "$empty_remote"
  git -C "$fresh" checkout -q -b 'feat/with.dots+plus-dash'

  cat > "$fresh/.gitignore" <<'EOF'
/*
!/.gitignore
!/CLAUDE.md
EOF
  printf 'unusual branch\n' > "$fresh/CLAUDE.md"

  run bash -c "ADAPTER_DIR='$fresh' bash '$SCRIPT'"
  [ "$status" -eq 0 ]

  git -C "$empty_remote" log --oneline --all | grep -q .
  [ "$(git -C "$fresh" rev-parse --abbrev-ref '@{u}')" = "origin/feat/with.dots+plus-dash" ]
}
