#!/usr/bin/env bats
# Tests for core/marker-nudge.sh — the PostToolUse hook that nudges the
# agent to recall the hive-mind skill after editing a hive-mind-synced
# file. Reads hook JSON from stdin, emits JSON to stdout when the edit
# targets a file under $ADAPTER_DIR (default $HOME/.claude).

SCRIPT="$BATS_TEST_DIRNAME/../core/marker-nudge.sh"

setup() {
  command -v jq >/dev/null || skip "jq not on PATH"
  HOME="$(mktemp -d)"
  export HOME
}

teardown() {
  rm -rf "$HOME"
}

run_nudge() {
  bash "$SCRIPT"
}

# Tests ---------------------------------------------------------------------

@test "edit to CLAUDE.md emits the nudge" {
  payload="$(jq -cn --arg p "$HOME/.claude/CLAUDE.md" '{tool_input:{file_path:$p}}')"
  run bash -c "printf '%s' '$payload' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "PostToolUse" ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')" = "hive-mind edit — recall hive-mind skill" ]
}

@test "edit to skills/<X>/SKILL.md emits the nudge" {
  payload="$(jq -cn --arg p "$HOME/.claude/skills/copilot-review/SKILL.md" '{tool_input:{file_path:$p}}')"
  run bash -c "printf '%s' '$payload' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s' "$output" | grep -Fq "hive-mind edit"
}

@test "edit to projects/<variant>/memory/<X>.md emits the nudge" {
  payload="$(jq -cn --arg p "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/note.md" '{tool_input:{file_path:$p}}')"
  run bash -c "printf '%s' '$payload' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "edit outside ~/.claude/ is ignored — silent, exit 0" {
  payload='{"tool_input":{"file_path":"/tmp/unrelated.md"}}'
  run bash -c "printf '%s' '$payload' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing file_path in payload is tolerated — silent, exit 0" {
  payload='{"tool_input":{}}'
  run bash -c "printf '%s' '$payload' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing tool_input entirely is tolerated — silent, exit 0" {
  payload='{}'
  run bash -c "printf '%s' '$payload' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "malformed JSON input is tolerated — silent, exit 0" {
  run bash -c "printf 'not json{{' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

