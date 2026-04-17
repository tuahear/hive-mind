#!/usr/bin/env bats
# Tests for core/check-dupes.sh — the SessionStart duplicate-line scanner.
#
# The script reads $HOME/.claude/CLAUDE.md and $HOME/.claude/projects/**/*.md,
# so each test sandboxes HOME into a temp dir. jq must be on PATH (script
# emits the nudge via jq; missing jq means silent no-op).

SCRIPT="$BATS_TEST_DIRNAME/../core/check-dupes.sh"

setup() {
  command -v jq >/dev/null || skip "jq not on PATH"
  HOME="$(mktemp -d)"
  export HOME
  mkdir -p "$HOME/.claude"
}

teardown() {
  rm -rf "$HOME"
}

run_check() {
  bash "$SCRIPT"
}

# A line that's >=20 chars and isn't structural — safe to use as a duplicate.
LONG_LINE='This is a reasonably long duplicate content line for testing.'

# Tests ---------------------------------------------------------------------

@test "no duplicates: no output, exit 0" {
  printf '# Heading\n\n%s\n' "$LONG_LINE" > "$HOME/.claude/CLAUDE.md"

  run run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "duplicate in CLAUDE.md: emits JSON naming the file" {
  printf '%s\n%s\n' "$LONG_LINE" "$LONG_LINE" > "$HOME/.claude/CLAUDE.md"

  run run_check
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  printf '%s' "$ctx" | grep -Fq '~/.claude/CLAUDE.md'
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "SessionStart" ]
}

@test "short duplicate (<20 chars) is NOT flagged" {
  printf 'short line\nshort line\n' > "$HOME/.claude/CLAUDE.md"

  run run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "repeated headings are NOT flagged" {
  printf '# Section with a long-enough heading title here\n# Section with a long-enough heading title here\n' \
    > "$HOME/.claude/CLAUDE.md"

  run run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "repeated separator lines are NOT flagged" {
  printf -- '---\n---\n***\n***\n' > "$HOME/.claude/CLAUDE.md"

  run run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "repeated code-fence lines are NOT flagged" {
  printf '```\nalpha\n```\n```\nbeta\n```\n' > "$HOME/.claude/CLAUDE.md"

  run run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "duplicate in a projects/<variant>/memory file emits JSON" {
  mkdir -p "$HOME/.claude/projects/-Users-alice-Repo-foo/memory"
  printf '%s\n%s\n' "$LONG_LINE" "$LONG_LINE" \
    > "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/note.md"

  run run_check
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  printf '%s' "$ctx" | grep -Fq '.claude/projects/-Users-alice-Repo-foo/memory/note.md'
}

@test "multiple flagged files: listed comma-separated in the message" {
  mkdir -p "$HOME/.claude/projects/v1/memory"
  printf '%s\n%s\n' "$LONG_LINE" "$LONG_LINE" > "$HOME/.claude/CLAUDE.md"
  printf '%s\n%s\n' "$LONG_LINE" "$LONG_LINE" \
    > "$HOME/.claude/projects/v1/memory/note.md"

  run run_check
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  printf '%s' "$ctx" | grep -Fq '~/.claude/CLAUDE.md'
  printf '%s' "$ctx" | grep -Fq 'projects/v1/memory/note.md'
  printf '%s' "$ctx" | grep -Fq ', '
}

@test "missing CLAUDE.md: projects still scanned, exit 0" {
  mkdir -p "$HOME/.claude/projects/v1/memory"
  printf '%s\n%s\n' "$LONG_LINE" "$LONG_LINE" \
    > "$HOME/.claude/projects/v1/memory/note.md"

  run run_check
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  printf '%s' "$ctx" | grep -Fq 'projects/v1/memory/note.md'
}

@test "missing projects/ directory: exit 0, no output" {
  printf '# clean\nnothing duplicated here at all\n' > "$HOME/.claude/CLAUDE.md"

  run run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
