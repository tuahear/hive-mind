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

@test "self-round-trip: tomlmerge's output is re-mergeable without fallback" {
  # The reconstruction step must not emit blank lines between sections
  # because toml_flatten rejects blank lines after content. If it did,
  # merging once would produce output that parses-fail on the second
  # merge, and every subsequent merge on the file would silently fall
  # back to git's default 3-way merger — defeating the point of
  # registering the driver at all.
  #
  # Scenario: first merge, feed the result back in as OURS of a new
  # merge against an unrelated THEIRS. Both merges must succeed.
  printf '[alpha]\nk = "1"\n[beta]\nk = "2"\n' > "$OURS"
  printf '[alpha]\nk = "1"\n[beta]\nk = "2b"\n' > "$THEIRS"
  run run_merge
  [ "$status" -eq 0 ]

  # Sanity: output contains both sections.
  grep -q '^\[alpha\]$' "$OURS"
  grep -q '^\[beta\]$' "$OURS"

  # Second merge uses the first merge's output as OURS.
  printf '[alpha]\nk = "1"\n[beta]\nk = "2c"\n[gamma]\nk = "3"\n' > "$THEIRS"
  run run_merge
  [ "$status" -eq 0 ]
  grep -q 'k = "2c"' "$OURS"
  grep -q '^\[gamma\]$' "$OURS"
}

@test "rejects scalar line with inline comment (key = \"x\" # note)" {
  # The header promises comment-containing inputs exit non-zero so git
  # falls back to its default 3-way merger. Previously only full-line
  # comments were rejected; inline comments on scalar lines were
  # silently absorbed into the flattened value, producing spurious
  # "theirs-wins" conflicts when one side had the comment and the
  # other did not. Drop into fallback instead.
  printf '[section]\nkey = "x" # inline note\n' > "$OURS"
  printf '[section]\nkey = "y"\n' > "$THEIRS"

  run run_merge
  [ "$status" -ne 0 ]
}

@test "rejects inline comment on bare-value scalar (key = 42 # note)" {
  # Same failure mode for non-string scalars. A user annotating a
  # numeric config value with a trailing comment must not corrupt
  # the merged output.
  printf '[section]\ncount = 42 # annotation\n' > "$OURS"
  printf '[section]\ncount = 42\n' > "$THEIRS"

  run run_merge
  [ "$status" -ne 0 ]
}

@test "root-level keys stay root after merging a file with mixed root + section keys" {
  # Classic TOML gotcha: a root-level key emitted AFTER a [section]
  # header gets silently reassigned to that section by the parser
  # (`rootkey = "x"` after `[section]` parses as `section.rootkey`).
  # The old single-pass emitter relied on input order; merging doesn't
  # guarantee it. Reconstruction must always emit root keys BEFORE any
  # [section] header.
  printf 'rootkey = "a"\n[section]\nskey = "1"\n' > "$OURS"
  printf 'rootkey = "b"\n[section]\nskey = "1"\n' > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]

  # Root key wins theirs (scalar collision) and is emitted BEFORE the
  # [section] header, not after it.
  root_line="$(grep -n '^rootkey' "$OURS" | head -1 | cut -d: -f1)"
  header_line="$(grep -n '^\[section\]' "$OURS" | head -1 | cut -d: -f1)"
  [ -n "$root_line" ]
  [ -n "$header_line" ]
  [ "$root_line" -lt "$header_line" ]
  grep -q 'rootkey = "b"' "$OURS"
  grep -q '^\[section\]$' "$OURS"
  grep -q 'skey = "1"' "$OURS"
}

@test "multiple root keys + multiple sections reconstruct without root-key absorption" {
  # Broader variant: many root keys interleaved with many sections
  # across both sides. After merge the output must still have every
  # root key above any [header]. Pin the invariant directly: every
  # original root key appears before the first [header]. Can't check
  # the inverse ("no root key after a header") from the output alone
  # because inside a section, `key = value` is a valid section-key
  # syntax indistinguishable from an absorbed root key.
  printf 'a = "1"\nb = "2"\n[s1]\nk = "x"\n[s2]\nm = "y"\n' > "$OURS"
  printf 'c = "3"\n[s1]\nk = "xx"\n[s3]\nz = "q"\n' > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]

  first_header="$(grep -n '^\[' "$OURS" | head -1 | cut -d: -f1)"
  [ -n "$first_header" ]
  pre_header="$(head -n "$((first_header - 1))" "$OURS")"
  # Every root key from the inputs survives above the first header.
  printf '%s\n' "$pre_header" | grep -q '^a = '
  printf '%s\n' "$pre_header" | grep -q '^b = '
  printf '%s\n' "$pre_header" | grep -q '^c = '
  # And three distinct section headers are present in the output.
  grep -q '^\[s1\]$' "$OURS"
  grep -q '^\[s2\]$' "$OURS"
  grep -q '^\[s3\]$' "$OURS"
}

@test "plain quoted scalars (no inline comment) still merge normally" {
  # Negative control: the new inline-comment reject must not break
  # the common case where neither side has comments. This is the
  # "simple TOML" case the driver exists to handle.
  printf '[section]\nkey = "x"\n' > "$OURS"
  printf '[section]\nkey = "y"\n' > "$THEIRS"

  run run_merge
  [ "$status" -eq 0 ]
  grep -q 'key = "y"' "$OURS"
}

@test "reconstruction emits no blank lines between sections" {
  # Explicit pin: the output of a merge must contain zero fully-blank
  # lines. This is the exact invariant the self-round-trip test above
  # depends on, asserted directly so a regression shows up with a
  # clearer error than "the second merge fell back".
  printf '[a]\nk = "1"\n[b]\nk = "2"\n' > "$OURS"
  printf '[a]\nk = "1x"\n[b]\nk = "2"\n' > "$THEIRS"
  run run_merge
  [ "$status" -eq 0 ]
  run grep -cE '^$' "$OURS"
  [ "$output" = "0" ]
}
