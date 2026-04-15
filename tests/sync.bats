#!/usr/bin/env bats
# Tests for scripts/sync.sh — the Stop-hook sync driver.
#
# sync.sh runs `cd ~/.claude` and assumes that directory is a git checkout
# with an upstream. Each test sandboxes HOME and sets up:
#   $HOME/remote.git    — bare git remote
#   $HOME/.claude       — clone of the bare remote, tracking origin/main
# The sandbox also skips the mirror-projects.sh invocation (no such file
# exists under $HOME/.claude/hive-mind in the sandbox).

SCRIPT="$BATS_TEST_DIRNAME/../scripts/sync.sh"

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
