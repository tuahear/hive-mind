#!/usr/bin/env bats
# Unit tests for the sectioned content.md helpers in harvest-fanout.sh:
#   _hub_split_sections        — parse `path[csv]` selector
#   _hub_content_markers_ok    — balance check
#   _hub_content_read_section  — extract section N
#   _hub_content_replace_section — rewrite section N
#   _hub_dedupe_sections       — per-section dedupe
#
# Pure library tests. No harvest/fan-out wiring yet.

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
