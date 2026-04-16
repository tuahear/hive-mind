#!/usr/bin/env bats
# Tests for core/tomlmerge.sh -- the git merge driver for TOML config files.
#
# The driver parses each side into a flat key=value representation, merges,
# then rebuilds TOML output. That approach can silently drop formatting
# (comments, blank lines), mis-handle quoted strings, or corrupt arrays if
# any edge case sneaks past the validators. Each test below pins one of
# those edges down: conservative input acceptance (reject anything we
# can't round-trip) and precise array semantics (preserve empty elements,
# reject commas inside quoted strings).

SCRIPT="$BATS_TEST_DIRNAME/../core/tomlmerge.sh"

setup() {
  WORK="$(mktemp -d)"
  OURS="$WORK/ours.toml"
  BASE="$WORK/base.toml"
  THEIRS="$WORK/theirs.toml"
  printf '' > "$BASE"
}

teardown() {
  rm -rf "$WORK"
}

run_merge() {
  # shellcheck disable=SC2086
  bash "$SCRIPT" "$OURS" "$BASE" "$THEIRS" $@
}

# === scalar merge =========================================================

@test "scalar key: theirs wins on collision" {
  printf '[section]\nkey = "a"\n' > "$OURS"
  printf '[section]\nkey = "b"\n' > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  grep -q 'key = "b"' "$OURS"
}

@test "non-overlapping sections: both sides preserved" {
  printf '[a]\nkey = "x"\n' > "$OURS"
  printf '[b]\nkey = "y"\n' > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  grep -q 'key = "x"' "$OURS"
  grep -q 'key = "y"' "$OURS"
}

# === REJECTION: fall through to git's default 3-way merge =================

@test "rejects inline comment after array close (e.g. allow = [\"a\"] # note)" {
  # The downstream split is naive on comma, so trailing-comment tokens
  # would end up inside array values. Validator rejects the shape.
  printf '[permissions]\nallow = ["a"] # note\n' > "$OURS"
  printf '[permissions]\nallow = ["b"]\n' > "$THEIRS"
  export TOMLMERGE_UNION_KEYS="permissions.allow"

  run run_merge
  [ "$status" -ne 0 ]
}

@test "rejects single-quoted array elements" {
  # parse_array's sed strips only double quotes; single-quoted elements
  # would round-trip as literal 'a' wrapped in double quotes.
  printf "[permissions]\nallow = ['a', 'b']\n" > "$OURS"
  printf '[permissions]\nallow = ["c"]\n' > "$THEIRS"
  export TOMLMERGE_UNION_KEYS="permissions.allow"

  run run_merge
  [ "$status" -ne 0 ]
}

@test "rejects comma inside quoted string element" {
  # ["a,b"] would split naively on comma into ["a", "b"] and silently
  # corrupt the file on write-back. Regex element class [^\",] forbids
  # commas inside values so this shape fails validation.
  printf '[permissions]\nallow = ["a,b"]\n' > "$OURS"
  printf '[permissions]\nallow = ["c"]\n' > "$THEIRS"
  export TOMLMERGE_UNION_KEYS="permissions.allow"

  run run_merge
  [ "$status" -ne 0 ]
}

@test "rejects input containing a comment line (parse-rebuild would drop it)" {
  # Comments carry user intent (documentation, defaults, rationale)
  # that the parse-and-rebuild flow has no way to preserve. Safer to
  # hand the conflict back to git's default merge driver, which
  # surfaces conflict markers for manual resolution.
  printf '# Top-level comment\n[section]\nkey = "x"\n' > "$OURS"
  printf '[section]\nkey = "y"\n' > "$THEIRS"

  run run_merge
  [ "$status" -ne 0 ]
}

@test "rejects post-content blank line (visual grouping would be lost)" {
  # Blank lines between content groups in TOML typically separate
  # logical sections -- same reason as comments, the rebuild can't
  # recreate them.
  printf '[a]\nk1 = "x"\n\n[b]\nk2 = "y"\n' > "$OURS"
  printf '[a]\nk1 = "x"\n' > "$THEIRS"

  run run_merge
  [ "$status" -ne 0 ]
}

@test "leading blank lines are tolerated (no content yet)" {
  # File-leading whitespace before the first section/key is harmless
  # -- no content to group, so the rebuild can't lose anything.
  printf '\n\n[section]\nkey = "a"\n' > "$OURS"
  printf '[section]\nkey = "b"\n' > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
}

@test "rejects inline tables" {
  # Inline tables { a = \"x\" } aren't in the flat representation;
  # rebuild would emit them as a scalar string and corrupt the file.
  printf '[section]\ntbl = { a = "x" }\n' > "$OURS"
  printf '[section]\ntbl = { a = "y" }\n' > "$THEIRS"

  run run_merge
  [ "$status" -ne 0 ]
}

@test "rejects array-of-tables [[arr]]" {
  # Array-of-tables syntax has no flat-key analogue.
  printf '[[arr]]\nkey = "x"\n' > "$OURS"
  printf '[[arr]]\nkey = "y"\n' > "$THEIRS"

  run run_merge
  [ "$status" -ne 0 ]
}

# === UNION MERGE (happy path) =============================================

@test "union merge: keys from both sides are combined and deduped" {
  printf '[permissions]\nallow = ["a", "b"]\n' > "$OURS"
  printf '[permissions]\nallow = ["b", "c"]\n' > "$THEIRS"
  export TOMLMERGE_UNION_KEYS="permissions.allow"

  run run_merge
  [ "$status" -eq 0 ]
  grep -qE 'allow = \[.*"a".*\]' "$OURS"
  grep -qE 'allow = \[.*"b".*\]' "$OURS"
  grep -qE 'allow = \[.*"c".*\]' "$OURS"
}

@test "union preserves an empty-string element across both sides" {
  # Both sides have a single empty-string element. Naive command
  # substitution strips the trailing newline and collapses this to
  # []; the temp-file pipeline preserves exact line counts so the
  # [""] round-trips intact.
  printf '[permissions]\nallow = [""]\n' > "$OURS"
  printf '[permissions]\nallow = [""]\n' > "$THEIRS"
  export TOMLMERGE_UNION_KEYS="permissions.allow"

  run run_merge
  [ "$status" -eq 0 ]
  grep -q 'allow = \[""\]' "$OURS"
}

@test "union preserves an empty-string element alongside distinct elements" {
  # The empty string is a legitimate TOML array value; it must survive
  # the dedup + rebuild steps and not get confused with "no element".
  printf '[permissions]\nallow = ["", "x"]\n' > "$OURS"
  printf '[permissions]\nallow = ["", "y"]\n' > "$THEIRS"
  export TOMLMERGE_UNION_KEYS="permissions.allow"

  run run_merge
  [ "$status" -eq 0 ]
  grep -q '""' "$OURS"
  grep -q '"x"' "$OURS"
  grep -q '"y"' "$OURS"
}

@test "TOMLMERGE_UNION_KEYS accepts comma-separated key list" {
  # The env-injection format declared in ADAPTER_MERGE_DRIVER_ENV uses
  # commas because newlines don't survive single-line git config
  # values. Both forms should work.
  printf '[permissions]\nallow = ["a"]\ndeny = ["x"]\n' > "$OURS"
  printf '[permissions]\nallow = ["b"]\ndeny = ["y"]\n' > "$THEIRS"
  export TOMLMERGE_UNION_KEYS="permissions.allow,permissions.deny"

  run run_merge
  [ "$status" -eq 0 ]
  grep -qE 'allow = \[.*"a".*"b".*\]' "$OURS"
  grep -qE 'deny = \[.*"x".*"y".*\]' "$OURS"
}

@test "non-union array: theirs wins, no merge (union list gates the behavior)" {
  # Only keys listed in TOMLMERGE_UNION_KEYS get the union treatment.
  # Other arrays take the "theirs wins" scalar-collision rule.
  printf '[other]\nlist = ["a", "b"]\n' > "$OURS"
  printf '[other]\nlist = ["c"]\n' > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  grep -q 'list = \["c"\]' "$OURS"
  run grep '"a"' "$OURS"
  [ "$status" -ne 0 ]
}
