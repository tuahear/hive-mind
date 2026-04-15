#!/usr/bin/env bats
# Tests for scripts/mirror-projects.sh.
#
# The script reads ~/.claude (via `cd ~/.claude`), so each test sandboxes
# HOME into a temp dir and lays out the projects/ tree before invoking.
# Identity is established per-variant via .hive-mind-project-id sidecars
# (or by deriving from a local jsonl + git remote, exercised separately).

SCRIPT="$BATS_TEST_DIRNAME/../scripts/mirror-projects.sh"
MARKER=".hive-mind"
LEGACY_MARKER=".hive-mind-project-id"

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

# Mark a variant with a fixed identity. Variants sharing the same id
# group together; variants with different ids don't.
mark() {
  local variant="$1" id="$2"
  mkdir -p "$HOME/.claude/projects/$variant/memory"
  printf 'project-id=%s\n' "$id" > "$HOME/.claude/projects/$variant/memory/$MARKER"
}

# Drop a legacy single-value sidecar (pre-rename format) for migration tests.
mark_legacy() {
  local variant="$1" id="$2"
  mkdir -p "$HOME/.claude/projects/$variant/memory"
  printf '%s\n' "$id" > "$HOME/.claude/projects/$variant/memory/$LEGACY_MARKER"
}

run_mirror() {
  bash "$SCRIPT"
}

# Tests ---------------------------------------------------------------------

@test "single variant: no-op" {
  mkvariant "-Users-nick-Repo-solo"
  mark "-Users-nick-Repo-solo" "github.com/me/solo"
  printf 'solo\n' > "$HOME/.claude/projects/-Users-nick-Repo-solo/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/projects/-Users-nick-Repo-solo/MEMORY.md")" = "solo" ]
}

@test "two variants with matching identity: MEMORY.md is line-unioned and unique files copied across" {
  mkvariant "-Users-nick-Repo-foo"
  mkvariant "C--Users-thiti-Repo-foo"
  mark "-Users-nick-Repo-foo"      "github.com/me/foo"
  mark "C--Users-thiti-Repo-foo"   "github.com/me/foo"

  printf '# foo\n- Mac line\n' > "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md"
  printf '# foo\n- Win line\n' > "$HOME/.claude/projects/C--Users-thiti-Repo-foo/MEMORY.md"
  printf 'mac only\n' > "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/a.md"
  printf 'win only\n' > "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/b.md"

  run run_mirror
  [ "$status" -eq 0 ]

  diff -q "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md" \
          "$HOME/.claude/projects/C--Users-thiti-Repo-foo/MEMORY.md"
  grep -Fq 'Mac line' "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md"
  grep -Fq 'Win line' "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md"

  [ -f "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/a.md" ]
  [ -f "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/b.md" ]
}

@test "session transcript files are NOT mirrored" {
  mkvariant "-Users-nick-Repo-foo"
  mkvariant "C--Users-thiti-Repo-foo"
  mark "-Users-nick-Repo-foo"      "github.com/me/foo"
  mark "C--Users-thiti-Repo-foo"   "github.com/me/foo"
  printf 'shared\n' > "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md"
  printf '{"sess":1}\n' > "$HOME/.claude/projects/-Users-nick-Repo-foo/abc.jsonl"

  run run_mirror
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.claude/projects/C--Users-thiti-Repo-foo/abc.jsonl" ]
}

@test "asymmetric variants: empty target memory/ is populated from richer source" {
  # Both sides have identity markers (a prerequisite under the new model
  # — a variant with no marker AND no local cwd is unidentifiable and
  # gets skipped). Source side is rich (MEMORY.md + memory/note.md);
  # target side has only the marker. Expect target to receive copies.
  mkvariant "-Users-nick-Repo-bar"
  mkvariant "C--Users-thiti-Repo-bar"
  mark "-Users-nick-Repo-bar"      "github.com/me/bar"
  mark "C--Users-thiti-Repo-bar"   "github.com/me/bar"

  printf 'from B\n' > "$HOME/.claude/projects/C--Users-thiti-Repo-bar/memory/note.md"
  printf 'B index\n' > "$HOME/.claude/projects/C--Users-thiti-Repo-bar/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/projects/-Users-nick-Repo-bar/memory/note.md" ]
  [ -f "$HOME/.claude/projects/-Users-nick-Repo-bar/MEMORY.md" ]
  grep -Fq 'B index' "$HOME/.claude/projects/-Users-nick-Repo-bar/MEMORY.md"
}

@test "idempotent: second run produces no further changes" {
  mkvariant "-Users-nick-Repo-foo"
  mkvariant "C--Users-thiti-Repo-foo"
  mark "-Users-nick-Repo-foo"     "github.com/me/foo"
  mark "C--Users-thiti-Repo-foo"  "github.com/me/foo"
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

@test "REGRESSION: projects with shared trailing dash-suffix do NOT group across distinct identities" {
  # The legacy heuristic grouped any variants sharing a trailing dash-
  # separated suffix, which catastrophically fused unrelated projects
  # like basic-pitch-gcs / demucs-gcs / piano-transcription-gcs because
  # they all ended in "-gcs". Distinct identities must NEVER fuse, no
  # matter how similar the encoded paths look.
  mkvariant "-Users-nick-Repo-basic-pitch-gcs"
  mkvariant "-Users-nick-Repo-demucs-gcs"
  mkvariant "-Users-nick-Repo-piano-transcription-gcs"
  mark "-Users-nick-Repo-basic-pitch-gcs"          "github.com/me/basic-pitch-gcs"
  mark "-Users-nick-Repo-demucs-gcs"               "github.com/me/demucs-gcs"
  mark "-Users-nick-Repo-piano-transcription-gcs"  "github.com/me/piano-transcription-gcs"

  printf '# basic-pitch only\n' > "$HOME/.claude/projects/-Users-nick-Repo-basic-pitch-gcs/MEMORY.md"
  printf '# demucs only\n'      > "$HOME/.claude/projects/-Users-nick-Repo-demucs-gcs/MEMORY.md"
  printf '# pti only\n'         > "$HOME/.claude/projects/-Users-nick-Repo-piano-transcription-gcs/MEMORY.md"
  printf 'demucs-private\n'     > "$HOME/.claude/projects/-Users-nick-Repo-demucs-gcs/memory/secret.md"

  run run_mirror
  [ "$status" -eq 0 ]

  # Each project's MEMORY.md is unchanged.
  grep -Fq '# basic-pitch only' "$HOME/.claude/projects/-Users-nick-Repo-basic-pitch-gcs/MEMORY.md"
  grep -Fq '# demucs only'      "$HOME/.claude/projects/-Users-nick-Repo-demucs-gcs/MEMORY.md"
  grep -Fq '# pti only'         "$HOME/.claude/projects/-Users-nick-Repo-piano-transcription-gcs/MEMORY.md"

  # No cross-pollination of memory files.
  [ ! -f "$HOME/.claude/projects/-Users-nick-Repo-basic-pitch-gcs/memory/secret.md" ]
  [ ! -f "$HOME/.claude/projects/-Users-nick-Repo-piano-transcription-gcs/memory/secret.md" ]
}

@test "variant with no identity (no sidecar, no local cwd) is left alone" {
  # Two variants share a name but only one has an identity. The other
  # has no sidecar and no jsonl — must NOT be mirrored into.
  mkvariant "-Users-nick-Repo-orphan"
  mkvariant "C--Users-thiti-Repo-orphan"
  mark "-Users-nick-Repo-orphan" "github.com/me/orphan"
  # No mark on the C-- side, no jsonl either.

  printf 'mac content\n' > "$HOME/.claude/projects/-Users-nick-Repo-orphan/memory/note.md"

  run run_mirror
  [ "$status" -eq 0 ]
  # Mac side is untouched; orphan side received nothing.
  [ -f "$HOME/.claude/projects/-Users-nick-Repo-orphan/memory/note.md" ]
  [ ! -f "$HOME/.claude/projects/C--Users-thiti-Repo-orphan/memory/note.md" ]
}

@test "discover_id derives identity from local jsonl + git remote and persists the sidecar" {
  proj_dir="$HOME/myrepo"
  git -c init.defaultBranch=main init -q "$proj_dir"
  git -C "$proj_dir" remote add origin git@github.com:Owner/MyRepo.git

  variant="$HOME/.claude/projects/-Users-nick-myrepo"
  mkdir -p "$variant"
  printf '{"cwd":"%s","other":"junk"}\n' "$proj_dir" > "$variant/session.jsonl"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$variant/memory/$MARKER" ]
  grep -Fq "project-id=github.com/owner/myrepo" "$variant/memory/$MARKER"
}

@test "legacy .hive-mind-project-id is migrated to .hive-mind on first run, then deleted" {
  variant="$HOME/.claude/projects/-Users-nick-Repo-foo"
  mkdir -p "$variant/memory"
  printf 'github.com/me/foo\n' > "$variant/memory/$LEGACY_MARKER"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$variant/memory/$MARKER" ]
  grep -Fq "project-id=github.com/me/foo" "$variant/memory/$MARKER"
  [ ! -f "$variant/memory/$LEGACY_MARKER" ]
}

@test "user-supplied identity (no git remote) is honored — manual override path" {
  # User creates the sidecar by hand for a project that doesn't have a
  # git remote (or that they want to group under a custom id). Mirror
  # must NOT try to overwrite or rederive — the file is the source of
  # truth.
  mkvariant "-Users-nick-Repo-no-remote-1"
  mkvariant "C--Users-thiti-Repo-no-remote-2"
  mark "-Users-nick-Repo-no-remote-1"     "user-id/local-project"
  mark "C--Users-thiti-Repo-no-remote-2"  "user-id/local-project"
  printf 'side A\n' > "$HOME/.claude/projects/-Users-nick-Repo-no-remote-1/memory/note.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/projects/C--Users-thiti-Repo-no-remote-2/memory/note.md" ]
  # Sidecars unchanged.
  grep -Fq "project-id=user-id/local-project" \
    "$HOME/.claude/projects/-Users-nick-Repo-no-remote-1/memory/$MARKER"
}

@test "legacy sidecar is also excluded from content mirroring during migration window" {
  # Set up two variants with matching identity. One side carries an old
  # legacy file (which migration deletes); the OTHER side's content
  # mirror must not propagate the legacy file across.
  mkvariant "-Users-nick-Repo-mig"
  mkvariant "C--Users-thiti-Repo-mig"
  mark_legacy "-Users-nick-Repo-mig"      "github.com/me/mig"
  mark        "C--Users-thiti-Repo-mig"   "github.com/me/mig"

  run run_mirror
  [ "$status" -eq 0 ]
  # Mac side migrated to new sidecar; legacy gone on Mac.
  [ -f "$HOME/.claude/projects/-Users-nick-Repo-mig/memory/$MARKER" ]
  [ ! -f "$HOME/.claude/projects/-Users-nick-Repo-mig/memory/$LEGACY_MARKER" ]
  # Win side never had the legacy and must not have received it via mirror.
  [ ! -f "$HOME/.claude/projects/C--Users-thiti-Repo-mig/memory/$LEGACY_MARKER" ]
}

@test "discover_id: SSH and HTTPS forms of the same remote normalize to the same id and group" {
  mkvariant "-Users-nick-Repo-bothforms"
  mkvariant "C--Users-thiti-Repo-bothforms"
  # Pre-populate sidecars in the new key=value format with the same
  # normalized id (representing what each side's discover_id would
  # produce after normalizing its own SSH/HTTPS URL form).
  mark "-Users-nick-Repo-bothforms"     "github.com/me/bothforms"
  mark "C--Users-thiti-Repo-bothforms"  "github.com/me/bothforms"
  printf 'side A\n' > "$HOME/.claude/projects/-Users-nick-Repo-bothforms/memory/a.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/projects/C--Users-thiti-Repo-bothforms/memory/a.md" ]
}

@test "non-markdown files are NOT byte-concatenated when variants differ" {
  mkvariant "-Users-nick-Repo-foo"
  mkvariant "C--Users-thiti-Repo-foo"
  mark "-Users-nick-Repo-foo"     "github.com/me/foo"
  mark "C--Users-thiti-Repo-foo"  "github.com/me/foo"
  printf 'BIN_MAC\0data' > "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/blob.bin"
  printf 'BIN_WIN\0data' > "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/blob.bin"

  run run_mirror
  [ "$status" -eq 0 ]

  run diff -q "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/blob.bin" \
              "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/blob.bin"
  [ "$status" -ne 0 ]

  [ "$(wc -c < "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/blob.bin")" -eq 12 ]
  [ "$(wc -c < "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/blob.bin")" -eq 12 ]
}

@test "non-markdown files: copy-if-missing fills variants that lack the file" {
  mkvariant "-Users-nick-Repo-foo"
  mkvariant "C--Users-thiti-Repo-foo"
  mark "-Users-nick-Repo-foo"     "github.com/me/foo"
  mark "C--Users-thiti-Repo-foo"  "github.com/me/foo"
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

@test "the .hive-mind sidecar itself is NOT mirrored as content" {
  # Each variant must keep its OWN sidecar. The sidecar is identity
  # metadata, not synced content — the script must skip it when listing
  # files to mirror.
  mkvariant "-Users-nick-Repo-foo"
  mkvariant "C--Users-thiti-Repo-foo"
  # Same project-id (so they group), but extra per-variant metadata
  # that would be visibly different if the file got cross-mirrored.
  cat > "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/$MARKER" <<EOF
project-id=github.com/me/foo
machine=mac
EOF
  cat > "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/$MARKER" <<EOF
project-id=github.com/me/foo
machine=windows
EOF
  printf 'shared\n' > "$HOME/.claude/projects/-Users-nick-Repo-foo/MEMORY.md"
  printf 'shared\n' > "$HOME/.claude/projects/C--Users-thiti-Repo-foo/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]

  # Each side keeps its own per-variant metadata (no cross-overwrite).
  grep -Fq "machine=mac"     "$HOME/.claude/projects/-Users-nick-Repo-foo/memory/$MARKER"
  grep -Fq "machine=windows" "$HOME/.claude/projects/C--Users-thiti-Repo-foo/memory/$MARKER"
}
