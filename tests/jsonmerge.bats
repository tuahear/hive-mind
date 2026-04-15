#!/usr/bin/env bats
# Tests for scripts/jsonmerge.sh — the git merge driver for settings.json.
#
# Invoked by git as: jsonmerge.sh <ours> <base> <theirs>
# Writes merged JSON to <ours>; exits non-zero on failure so git falls back
# to its default merge driver.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/jsonmerge.sh"

setup() {
  command -v jq >/dev/null || skip "jq not on PATH"
  WORK="$(mktemp -d)"
  OURS="$WORK/ours.json"
  BASE="$WORK/base.json"
  THEIRS="$WORK/theirs.json"
  printf '{}\n' > "$BASE"
}

teardown() {
  rm -rf "$WORK"
}

run_merge() {
  bash "$SCRIPT" "$OURS" "$BASE" "$THEIRS"
}

# Tests ---------------------------------------------------------------------

@test "scalar key: theirs wins" {
  printf '{"model":"A"}\n'  > "$OURS"
  printf '{"model":"B"}\n'  > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  [ "$(jq -r '.model' "$OURS")" = "B" ]
}

@test "nested scalar: deep merge keeps both sides" {
  printf '{"a":{"x":1}}\n' > "$OURS"
  printf '{"a":{"y":2}}\n' > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  [ "$(jq -r '.a.x' "$OURS")" = "1" ]
  [ "$(jq -r '.a.y' "$OURS")" = "2" ]
}

@test "permissions.allow is unioned and deduped" {
  printf '{"permissions":{"allow":["A","B"]}}\n' > "$OURS"
  printf '{"permissions":{"allow":["B","C"]}}\n' > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  result="$(jq -c '.permissions.allow' "$OURS")"
  [ "$result" = '["A","B","C"]' ]
}

@test "permissions.deny is unioned and deduped" {
  printf '{"permissions":{"deny":["X","Y"]}}\n'  > "$OURS"
  printf '{"permissions":{"deny":["Y","Z"]}}\n'  > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  [ "$(jq -c '.permissions.deny' "$OURS")" = '["X","Y","Z"]' ]
}

@test "permissions.ask is unioned and deduped" {
  printf '{"permissions":{"ask":["P","Q"]}}\n' > "$OURS"
  printf '{"permissions":{"ask":["Q","R"]}}\n' > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  [ "$(jq -c '.permissions.ask' "$OURS")" = '["P","Q","R"]' ]
}

@test "permissions.additionalDirectories is unioned and deduped" {
  printf '{"permissions":{"additionalDirectories":["/a","/b"]}}\n' > "$OURS"
  printf '{"permissions":{"additionalDirectories":["/b","/c"]}}\n' > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  [ "$(jq -c '.permissions.additionalDirectories' "$OURS")" = '["/a","/b","/c"]' ]
}

@test "unknown array field: theirs wins, no union" {
  printf '{"customArr":["A","B"]}\n' > "$OURS"
  printf '{"customArr":["C"]}\n'     > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  [ "$(jq -c '.customArr' "$OURS")" = '["C"]' ]
}

@test "missing permissions on ours: theirs block preserved intact" {
  printf '{"model":"A"}\n'                              > "$OURS"
  printf '{"permissions":{"allow":["X","Y"]}}\n'         > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  [ "$(jq -c '.permissions.allow' "$OURS")" = '["X","Y"]' ]
  [ "$(jq -r '.model' "$OURS")" = "A" ]
}

@test "missing permissions on theirs: ours block preserved intact" {
  printf '{"permissions":{"allow":["X","Y"]}}\n'   > "$OURS"
  printf '{"model":"B"}\n'                          > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  [ "$(jq -c '.permissions.allow' "$OURS")" = '["X","Y"]' ]
  [ "$(jq -r '.model' "$OURS")" = "B" ]
}

@test "malformed JSON on ours: exit non-zero" {
  printf 'not json{{\n'    > "$OURS"
  printf '{"model":"B"}\n' > "$THEIRS"

  run run_merge
  [ "$status" -ne 0 ]
}

@test "malformed JSON on theirs: exit non-zero" {
  printf '{"model":"A"}\n' > "$OURS"
  printf 'not json{{\n'    > "$THEIRS"

  run run_merge
  [ "$status" -ne 0 ]
}
