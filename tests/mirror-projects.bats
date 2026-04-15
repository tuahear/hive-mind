#!/usr/bin/env bats
# Tests for scripts/mirror-projects.sh.
#
# The script reads ~/.claude (via `cd ~/.claude`), so each test sandboxes
# HOME into a temp dir and lays out the projects/ tree before invoking.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/mirror-projects.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  mkdir -p "$HOME/.claude"
}

teardown() {
  rm -rf "$HOME"
}

# Helpers -------------------------------------------------------------------

mkvariant() {
  mkdir -p "$HOME/.claude/projects/$1/memory"
}

run_mirror() {
  bash "$SCRIPT"
}

# Tests ---------------------------------------------------------------------

@test "single variant: no-op" {
  mkvariant "-Users-nick-Repo-solo"
  printf 'solo\n' > "$HOME/.claude/projects/-Users-nick-Repo-solo/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/projects/-Users-nick-Repo-solo/MEMORY.md")" = "solo" ]
}

@test "two variants: MEMORY.md is line-unioned and unique files copied across" {
  mkvariant "-Users-nick-Repo-foo"
  mkvariant "C--Users-thiti-Repo-foo"

  printf '# foo\n- Mac line\n' > "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md"
  printf '# foo\n- Win line\n' > "$HOME/.claude/projects/C--Users-thiti-Repo-foo/MEMORY.md"
  printf 'mac only\n' > "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/a.md"
  printf 'win only\n' > "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/b.md"

  run run_mirror
  [ "$status" -eq 0 ]

  diff -r "$HOME/.claude/projects/-Users-nick-Repo-foo/memory" \
          "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory"
  diff -q "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md" \
          "$HOME/.claude/projects/C--Users-thiti-Repo-foo/MEMORY.md"

  grep -q 'Mac line' "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md"
  grep -q 'Win line' "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md"
}

@test "session transcript files are NOT mirrored" {
  mkvariant "-Users-nick-Repo-foo"
  mkvariant "C--Users-thiti-Repo-foo"
  printf 'shared\n' > "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md"
  printf '{"sess":1}\n' > "$HOME/.claude/projects/-Users-nick-Repo-foo/abc.jsonl"

  run run_mirror
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.claude/projects/C--Users-thiti-Repo-foo/abc.jsonl" ]
}

@test "asymmetric variants: missing memory/ dir is created and populated" {
  mkdir -p "$HOME/.claude/projects/-Users-nick-Repo-bar"
  mkvariant "C--Users-thiti-Repo-bar"
  printf 'from B\n' > "$HOME/.claude/projects/C--Users-thiti-Repo-bar/memory/note.md"
  printf 'B index\n' > "$HOME/.claude/projects/C--Users-thiti-Repo-bar/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/projects/-Users-nick-Repo-bar/memory/note.md" ]
  [ -f "$HOME/.claude/projects/-Users-nick-Repo-bar/MEMORY.md" ]
}

@test "idempotent: second run produces no further changes" {
  mkvariant "-Users-nick-Repo-foo"
  mkvariant "C--Users-thiti-Repo-foo"
  printf '# foo\n- A\n' > "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md"
  printf '# foo\n- B\n' > "$HOME/.claude/projects/C--Users-thiti-Repo-foo/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]
  snapshot="$(find "$HOME/.claude/projects" -type f -exec md5sum {} + 2>/dev/null \
              || find "$HOME/.claude/projects" -type f -exec md5 {} +)"

  run run_mirror
  [ "$status" -eq 0 ]
  snapshot2="$(find "$HOME/.claude/projects" -type f -exec md5sum {} + 2>/dev/null \
               || find "$HOME/.claude/projects" -type f -exec md5 {} +)"
  [ "$snapshot" = "$snapshot2" ]
}

@test "dashed repo names group via longest shared trailing suffix" {
  # Two variants of the same project named "my-project" across OSes.
  mkvariant "-Users-nick-Repo-my-project"
  mkvariant "C--Users-thiti-Repo-my-project"
  # An unrelated project that *also* ends with "-project" — must not merge.
  mkvariant "-Users-nick-Code-other-project"

  printf '# my\n- A\n' > "$HOME/.claude/projects/-Users-nick-Repo-my-project/MEMORY.md"
  printf '# my\n- B\n' > "$HOME/.claude/projects/C--Users-thiti-Repo-my-project/MEMORY.md"
  printf '# other\n- unrelated\n' > "$HOME/.claude/projects/-Users-nick-Code-other-project/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]

  # my-project variants converge.
  diff -q "$HOME/.claude/projects/-Users-nick-Repo-my-project/MEMORY.md" \
          "$HOME/.claude/projects/C--Users-thiti-Repo-my-project/MEMORY.md"
  grep -q '^- A' "$HOME/.claude/projects/-Users-nick-Repo-my-project/MEMORY.md"
  grep -q '^- B' "$HOME/.claude/projects/-Users-nick-Repo-my-project/MEMORY.md"

  # other-project untouched (no "- A" or "- B" leaked in).
  ! grep -q '^- A' "$HOME/.claude/projects/-Users-nick-Code-other-project/MEMORY.md"
  ! grep -q '^- B' "$HOME/.claude/projects/-Users-nick-Code-other-project/MEMORY.md"
  grep -q 'unrelated' "$HOME/.claude/projects/-Users-nick-Code-other-project/MEMORY.md"
}

@test "non-markdown files are NOT byte-concatenated when variants differ" {
  mkvariant "-Users-nick-Repo-foo"
  mkvariant "C--Users-thiti-Repo-foo"
  printf 'BIN_MAC\0data' > "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/blob.bin"
  printf 'BIN_WIN\0data' > "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/blob.bin"

  run run_mirror
  [ "$status" -eq 0 ]

  # Both files still exist with their original distinct content — neither
  # was overwritten with a byte-concatenated frankenfile.
  run diff -q "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/blob.bin" \
              "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/blob.bin"
  [ "$status" -ne 0 ]

  # And the originals are intact (not concatenated against the other side).
  [ "$(wc -c < "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/blob.bin")" -eq 12 ]
  [ "$(wc -c < "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/blob.bin")" -eq 12 ]
}

@test "non-markdown files: copy-if-missing fills variants that lack the file" {
  mkvariant "-Users-nick-Repo-foo"
  mkvariant "C--Users-thiti-Repo-foo"
  printf 'BIN_DATA' > "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/blob.bin"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/blob.bin" ]
  diff -q "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/blob.bin" \
          "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/blob.bin"
}

@test "missing projects/ dir: clean exit, no error" {
  rm -rf "$HOME/.claude/projects"
  run run_mirror
  [ "$status" -eq 0 ]
}

@test "empty projects/ dir: clean exit, no error" {
  mkdir -p "$HOME/.claude/projects"
  run run_mirror
  [ "$status" -eq 0 ]
}
