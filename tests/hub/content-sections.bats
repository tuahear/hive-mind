#!/usr/bin/env bats
# Unit tests for the sectioned content.md helpers in harvest-fanout.sh:
#   _hub_split_sections        — parse `path[csv]` selector
#   _hub_content_markers_ok    — balance check
#   _hub_content_read_section  — extract section N
#   _hub_content_replace_section — rewrite section N
#   _hub_dedupe_sections       — per-section dedupe
#
# These tests exercise the section helpers directly. Harvest/fan-out
# wiring through ADAPTER_HUB_MAP selectors is covered separately in
# tests/hub/harvest-fanout.bats.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
HARVEST_FANOUT="$REPO_ROOT/core/hub/harvest-fanout.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  WORK="$HOME/work"
  mkdir -p "$WORK"
  export ADAPTER_LOG_PATH="$HOME/hub.log"
  # shellcheck source=/dev/null
  source "$HARVEST_FANOUT"
}

teardown() {
  rm -rf "$HOME"
}

# --- _hub_split_sections --------------------------------------------------

@test "split_sections parses single-section selector" {
  run _hub_split_sections 'content.md[0]'
  [ "$status" -eq 0 ]
  [ "$output" = $'content.md\t0' ]
}

@test "split_sections parses multi-section selector" {
  run _hub_split_sections 'content.md[0,1]'
  [ "$status" -eq 0 ]
  [ "$output" = $'content.md\t0,1' ]
}

@test "split_sections parses nested subdir path with selector" {
  run _hub_split_sections 'projects/X/content.md[1]'
  [ "$status" -eq 0 ]
  [ "$output" = $'projects/X/content.md\t1' ]
}

@test "split_sections rejects missing selector" {
  run _hub_split_sections 'content.md'
  [ "$status" -ne 0 ]
}

@test "split_sections rejects empty selector" {
  run _hub_split_sections 'content.md[]'
  [ "$status" -ne 0 ]
}

@test "split_sections rejects non-digit selector" {
  run _hub_split_sections 'content.md[a]'
  [ "$status" -ne 0 ]
}

@test "split_sections rejects selector with trailing text" {
  run _hub_split_sections 'content.md[0]extra'
  [ "$status" -ne 0 ]
}

@test "split_sections parses wildcard selector" {
  run _hub_split_sections 'content.md[*]'
  [ "$status" -eq 0 ]
  [ "$output" = $'content.md\t*' ]
}

@test "split_sections rejects malformed CSV selectors (empty elements)" {
  # Structural typos in a CSV selector must be rejected by _hub_split_sections
  # (which is called during harvest/fan-out dispatch), rather than being
  # silently normalized by the downstream `tr ',' '\n' | awk 'NF'`
  # pipeline in _hub_expand_sections (which would accept all of these
  # as "just 0,1"). Cover every placement of empty elements — leading,
  # trailing, doubled, standalone comma. The dispatch-level malformed-
  # selector guard in hub_harvest/hub_fan_out then logs + skips rather
  # than falling through to the plain-file path.
  local bad
  for bad in 'content.md[0,]' 'content.md[,0]' 'content.md[0,,1]' 'content.md[,]' 'content.md[,,]'; do
    run _hub_split_sections "$bad"
    [ "$status" -ne 0 ] || { echo "should have rejected: $bad"; return 1; }
  done
}

@test "adapter loader does not invoke _hub_split_sections (validation is deferred to harvest/fan-out dispatch)" {
  # Pin the contract described in the _hub_split_sections header: the
  # adapter loader (core/adapter-loader.sh) sources + validates the
  # contract surface but does NOT parse ADAPTER_HUB_MAP section
  # selectors. Selectors are parsed/rejected when hub_harvest and
  # hub_fan_out iterate the map.
  #
  # If a future change wires selector validation into load-time, the
  # comment block above _hub_split_sections must move with it — this
  # assertion catches silent drift between the doc and the wiring.
  ! grep -q '_hub_split_sections' "$REPO_ROOT/core/adapter-loader.sh"
}

@test "split_sections still accepts well-formed multi-element CSVs" {
  # Regression guard paired with the rejection test above: the tightening
  # must not false-positive on legitimate CSVs (single id, two ids,
  # non-adjacent ids, multi-digit ids).
  local good
  for good in 'content.md[0]' 'content.md[0,1]' 'content.md[0,2,5]' 'content.md[10,20]'; do
    run _hub_split_sections "$good"
    [ "$status" -eq 0 ] || { echo "should have accepted: $good"; return 1; }
  done
}

# --- present_sections + expand --------------------------------------------

@test "present_sections: empty file → no ids" {
  : > "$WORK/empty.md"
  run _hub_content_present_sections "$WORK/empty.md"
  [ -z "$output" ]
}

@test "present_sections: plain file → only 0" {
  printf 'foo\n' > "$WORK/plain.md"
  run _hub_content_present_sections "$WORK/plain.md"
  [ "$output" = '0' ]
}

@test "present_sections: blocks-only file → no 0 (section 0 empty)" {
  cat > "$WORK/f.md" <<'EOF'
<!-- hive-mind:section=1 START -->
x
<!-- hive-mind:section=1 END -->
EOF
  run _hub_content_present_sections "$WORK/f.md"
  [ "$output" = '1' ]
}

@test "present_sections: mixed → 0 and block ids, ascending" {
  cat > "$WORK/f.md" <<'EOF'
shared
<!-- hive-mind:section=2 START -->
two
<!-- hive-mind:section=2 END -->
<!-- hive-mind:section=1 START -->
one
<!-- hive-mind:section=1 END -->
EOF
  run _hub_content_present_sections "$WORK/f.md"
  [ "$output" = $'0\n1\n2' ]
}

@test "expand_sections: wildcard pulls ids from src" {
  cat > "$WORK/f.md" <<'EOF'
shared
<!-- hive-mind:section=1 START -->
s1
<!-- hive-mind:section=1 END -->
EOF
  run _hub_expand_sections '*' "$WORK/f.md"
  [ "$output" = $'0\n1' ]
}

@test "expand_sections: numeric csv passes through (sorted, deduped)" {
  run _hub_expand_sections '2,0,1,0' "$WORK/any.md"
  [ "$output" = $'0\n1\n2' ]
}

# --- _hub_content_markers_ok ----------------------------------------------

@test "markers_ok passes on empty file" {
  : > "$WORK/empty.md"
  run _hub_content_markers_ok "$WORK/empty.md"
  [ "$status" -eq 0 ]
}

@test "markers_ok passes on unsectioned file" {
  printf 'just some content\nacross a few lines\n' > "$WORK/plain.md"
  run _hub_content_markers_ok "$WORK/plain.md"
  [ "$status" -eq 0 ]
}

@test "markers_ok passes on single balanced block" {
  cat > "$WORK/one.md" <<'EOF'
shared stuff
<!-- hive-mind:section=1 START -->
s1 body
<!-- hive-mind:section=1 END -->
trailing shared
EOF
  run _hub_content_markers_ok "$WORK/one.md"
  [ "$status" -eq 0 ]
}

@test "markers_ok passes on two consecutive balanced blocks" {
  cat > "$WORK/two.md" <<'EOF'
<!-- hive-mind:section=1 START -->
a
<!-- hive-mind:section=1 END -->
<!-- hive-mind:section=2 START -->
b
<!-- hive-mind:section=2 END -->
EOF
  run _hub_content_markers_ok "$WORK/two.md"
  [ "$status" -eq 0 ]
}

@test "markers_ok rejects START without END" {
  cat > "$WORK/bad.md" <<'EOF'
shared
<!-- hive-mind:section=1 START -->
dangling body
EOF
  run _hub_content_markers_ok "$WORK/bad.md"
  [ "$status" -ne 0 ]
}

@test "markers_ok rejects END without START" {
  cat > "$WORK/bad.md" <<'EOF'
shared
<!-- hive-mind:section=1 END -->
EOF
  run _hub_content_markers_ok "$WORK/bad.md"
  [ "$status" -ne 0 ]
}

@test "markers_ok rejects nested START" {
  cat > "$WORK/bad.md" <<'EOF'
<!-- hive-mind:section=1 START -->
<!-- hive-mind:section=2 START -->
nested
<!-- hive-mind:section=2 END -->
<!-- hive-mind:section=1 END -->
EOF
  run _hub_content_markers_ok "$WORK/bad.md"
  [ "$status" -ne 0 ]
}

@test "markers_ok rejects mismatched END id" {
  cat > "$WORK/bad.md" <<'EOF'
<!-- hive-mind:section=1 START -->
body
<!-- hive-mind:section=2 END -->
EOF
  run _hub_content_markers_ok "$WORK/bad.md"
  [ "$status" -ne 0 ]
}

# --- _hub_content_read_section --------------------------------------------

@test "read_section: unsectioned file — section 0 is whole file" {
  printf 'line a\nline b\n' > "$WORK/plain.md"
  run _hub_content_read_section "$WORK/plain.md" 0
  [ "$status" -eq 0 ]
  [ "$output" = $'line a\nline b' ]
}

@test "read_section: unsectioned file — section 1 is empty" {
  printf 'line a\nline b\n' > "$WORK/plain.md"
  run _hub_content_read_section "$WORK/plain.md" 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "read_section: section 0 excludes block content" {
  cat > "$WORK/f.md" <<'EOF'
outside a
<!-- hive-mind:section=1 START -->
inside 1
<!-- hive-mind:section=1 END -->
outside b
EOF
  run _hub_content_read_section "$WORK/f.md" 0
  [ "$status" -eq 0 ]
  [ "$output" = $'outside a\noutside b' ]
}

@test "read_section: section 1 returns body without markers" {
  cat > "$WORK/f.md" <<'EOF'
outside a
<!-- hive-mind:section=1 START -->
inside 1a
inside 1b
<!-- hive-mind:section=1 END -->
outside b
EOF
  run _hub_content_read_section "$WORK/f.md" 1
  [ "$status" -eq 0 ]
  [ "$output" = $'inside 1a\ninside 1b' ]
}

@test "read_section: missing section returns empty" {
  cat > "$WORK/f.md" <<'EOF'
shared
<!-- hive-mind:section=1 START -->
body
<!-- hive-mind:section=1 END -->
EOF
  run _hub_content_read_section "$WORK/f.md" 2
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "read_section: missing file returns empty" {
  run _hub_content_read_section "$WORK/nope.md" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- _hub_content_replace_section -----------------------------------------

@test "replace_section: fresh file with section 0 content" {
  printf 'new shared\n' > "$WORK/new.txt"
  _hub_content_replace_section "$WORK/f.md" 0 "$WORK/new.txt"
  [ -f "$WORK/f.md" ]
  run cat "$WORK/f.md"
  [ "$output" = 'new shared' ]
}

@test "replace_section: fresh file with section 1 adds markers" {
  printf 'codex stuff\n' > "$WORK/new.txt"
  _hub_content_replace_section "$WORK/f.md" 1 "$WORK/new.txt"
  [ -f "$WORK/f.md" ]
  run cat "$WORK/f.md"
  [[ "$output" == *'<!-- hive-mind:section=1 START -->'* ]]
  [[ "$output" == *'codex stuff'* ]]
  [[ "$output" == *'<!-- hive-mind:section=1 END -->'* ]]
}

@test "replace_section: section 0 preserves existing blocks" {
  cat > "$WORK/f.md" <<'EOF'
old shared
<!-- hive-mind:section=1 START -->
keep this
<!-- hive-mind:section=1 END -->
EOF
  printf 'new shared\n' > "$WORK/new.txt"
  _hub_content_replace_section "$WORK/f.md" 0 "$WORK/new.txt"

  run _hub_content_read_section "$WORK/f.md" 0
  [ "$output" = 'new shared' ]

  run _hub_content_read_section "$WORK/f.md" 1
  [ "$output" = 'keep this' ]
}

@test "replace_section: existing section N replaced in place" {
  cat > "$WORK/f.md" <<'EOF'
shared
<!-- hive-mind:section=1 START -->
old body
<!-- hive-mind:section=1 END -->
more shared
EOF
  printf 'new body\n' > "$WORK/new.txt"
  _hub_content_replace_section "$WORK/f.md" 1 "$WORK/new.txt"

  run _hub_content_read_section "$WORK/f.md" 0
  [ "$output" = $'shared\nmore shared' ]

  run _hub_content_read_section "$WORK/f.md" 1
  [ "$output" = 'new body' ]
}

@test "replace_section: missing section N appended at EOF" {
  cat > "$WORK/f.md" <<'EOF'
shared line
EOF
  printf 'new s1\n' > "$WORK/new.txt"
  _hub_content_replace_section "$WORK/f.md" 1 "$WORK/new.txt"

  run _hub_content_read_section "$WORK/f.md" 0
  [ "$output" = 'shared line' ]

  run _hub_content_read_section "$WORK/f.md" 1
  [ "$output" = 'new s1' ]
}

@test "replace_section: canonicalizes layout — outside content first, blocks after" {
  # Pins the contract the docstring describes: replace_section rebuilds
  # the file with all outside (section-0) content up top and every tagged
  # block afterwards in the order they originally appeared. The original
  # physical interleaving of blocks with outside lines is NOT preserved.
  # If a future refactor starts preserving interleaving, the docstring
  # must change together with this test.
  cat > "$WORK/f.md" <<'EOF'
outside-before
<!-- hive-mind:section=1 START -->
one
<!-- hive-mind:section=1 END -->
outside-middle
<!-- hive-mind:section=2 START -->
two
<!-- hive-mind:section=2 END -->
outside-after
EOF
  printf 'replaced-two\n' > "$WORK/new.txt"
  _hub_content_replace_section "$WORK/f.md" 2 "$WORK/new.txt"

  # Every line of outside content must appear before the first block
  # marker in the rewritten file.
  local first_marker_line outside_before_line outside_middle_line outside_after_line
  first_marker_line="$(grep -n 'hive-mind:section=' "$WORK/f.md" | head -1 | cut -d: -f1)"
  outside_before_line="$(grep -n '^outside-before$' "$WORK/f.md" | cut -d: -f1)"
  outside_middle_line="$(grep -n '^outside-middle$' "$WORK/f.md" | cut -d: -f1)"
  outside_after_line="$(grep -n '^outside-after$' "$WORK/f.md" | cut -d: -f1)"
  [ "$outside_before_line" -lt "$first_marker_line" ]
  [ "$outside_middle_line" -lt "$first_marker_line" ]
  [ "$outside_after_line"  -lt "$first_marker_line" ]

  # Block order among themselves is preserved (section 1 before section 2).
  local s1_line s2_line
  s1_line="$(grep -n '^<!-- hive-mind:section=1 START -->$' "$WORK/f.md" | cut -d: -f1)"
  s2_line="$(grep -n '^<!-- hive-mind:section=2 START -->$' "$WORK/f.md" | cut -d: -f1)"
  [ "$s1_line" -lt "$s2_line" ]
}

@test "replace_section: round-trip preserves other blocks unchanged" {
  cat > "$WORK/f.md" <<'EOF'
top
<!-- hive-mind:section=1 START -->
one
<!-- hive-mind:section=1 END -->
<!-- hive-mind:section=2 START -->
two
<!-- hive-mind:section=2 END -->
bottom
EOF
  printf 'replaced one\n' > "$WORK/new.txt"
  _hub_content_replace_section "$WORK/f.md" 1 "$WORK/new.txt"

  run _hub_content_markers_ok "$WORK/f.md"
  [ "$status" -eq 0 ]

  run _hub_content_read_section "$WORK/f.md" 0
  [ "$output" = $'top\nbottom' ]

  run _hub_content_read_section "$WORK/f.md" 1
  [ "$output" = 'replaced one' ]

  run _hub_content_read_section "$WORK/f.md" 2
  [ "$output" = 'two' ]
}

@test "replace_section: empty section 0 rewrite clears outside content" {
  cat > "$WORK/f.md" <<'EOF'
A
B
<!-- hive-mind:section=1 START -->
keep
<!-- hive-mind:section=1 END -->
C
EOF
  : > "$WORK/empty.txt"
  _hub_content_replace_section "$WORK/f.md" 0 "$WORK/empty.txt"

  run _hub_content_read_section "$WORK/f.md" 0
  [ -z "$output" ]

  run _hub_content_read_section "$WORK/f.md" 1
  [ "$output" = 'keep' ]
}

# --- _hub_dedupe_sections -------------------------------------------------

@test "dedupe_sections: collapses repeated long lines in section 0" {
  printf 'this is a long repeated line\nthis is a long repeated line\nshort\nshort\n' > "$WORK/in.txt"
  output="$(_hub_dedupe_sections < "$WORK/in.txt")"
  # Long-line duplicate collapses to one; short lines preserved.
  [[ "$output" == *'this is a long repeated line'* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'this is a long repeated line')" = '1' ]
  # 'short' doesn't hit the ≥20-char heuristic, so both copies survive.
  [ "$(printf '%s\n' "$output" | grep -c '^short$')" = '2' ]
}

@test "dedupe_sections: does not dedupe across section boundary" {
  cat > "$WORK/in.txt" <<'EOF'
aaaaaaaaaaaaaaaaaaaaaaaaaa
<!-- hive-mind:section=1 START -->
aaaaaaaaaaaaaaaaaaaaaaaaaa
<!-- hive-mind:section=1 END -->
EOF
  output="$(_hub_dedupe_sections < "$WORK/in.txt")"
  # Both copies of the long line survive — each in its own section.
  [ "$(printf '%s\n' "$output" | grep -c 'aaaaaaaaaaaaaaaaaaaaaaaaaa')" = '2' ]
}
