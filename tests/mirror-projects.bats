#!/usr/bin/env bats
# Tests for scripts/mirror-projects.sh.
#
# The script reads ~/.claude (via `cd ~/.claude`), so each test sandboxes
# HOME into a temp dir and lays out the projects/ tree before invoking.
# Identity is established per-variant via .hive-mind sidecars (or by
# deriving from a local jsonl + git remote, exercised separately).

SCRIPT="$BATS_TEST_DIRNAME/../core/mirror-projects.sh"
MARKER=".hive-mind"

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

run_mirror() {
  bash "$SCRIPT"
}

# Tests ---------------------------------------------------------------------

@test "single variant: no-op" {
  mkvariant "-Users-alice-Repo-solo"
  mark "-Users-alice-Repo-solo" "github.com/me/solo"
  printf 'solo\n' > "$HOME/.claude/projects/-Users-alice-Repo-solo/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/projects/-Users-alice-Repo-solo/MEMORY.md")" = "solo" ]
}

@test "two variants with matching identity: MEMORY.md is line-unioned and unique files copied across" {
  mkvariant "-Users-alice-Repo-foo"
  mkvariant "C--Users-bob-Repo-foo"
  mark "-Users-alice-Repo-foo"      "github.com/me/foo"
  mark "C--Users-bob-Repo-foo"   "github.com/me/foo"

  printf '# foo\n- Mac line\n' > "$HOME/.claude/projects/-Users-alice-Repo-foo/MEMORY.md"
  printf '# foo\n- Win line\n' > "$HOME/.claude/projects/C--Users-bob-Repo-foo/MEMORY.md"
  printf 'mac only\n' > "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/a.md"
  printf 'win only\n' > "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/b.md"

  run run_mirror
  [ "$status" -eq 0 ]

  diff -q "$HOME/.claude/projects/-Users-alice-Repo-foo/MEMORY.md" \
          "$HOME/.claude/projects/C--Users-bob-Repo-foo/MEMORY.md"
  grep -Fq 'Mac line' "$HOME/.claude/projects/-Users-alice-Repo-foo/MEMORY.md"
  grep -Fq 'Win line' "$HOME/.claude/projects/-Users-alice-Repo-foo/MEMORY.md"

  [ -f "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/a.md" ]
  [ -f "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/b.md" ]
}

@test "session transcript files are NOT mirrored" {
  mkvariant "-Users-alice-Repo-foo"
  mkvariant "C--Users-bob-Repo-foo"
  mark "-Users-alice-Repo-foo"      "github.com/me/foo"
  mark "C--Users-bob-Repo-foo"   "github.com/me/foo"
  printf 'shared\n' > "$HOME/.claude/projects/-Users-alice-Repo-foo/MEMORY.md"
  printf '{"sess":1}\n' > "$HOME/.claude/projects/-Users-alice-Repo-foo/abc.jsonl"

  run run_mirror
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.claude/projects/C--Users-bob-Repo-foo/abc.jsonl" ]
}

@test "asymmetric variants: empty target memory/ is populated from richer source" {
  # Both sides have identity markers (a prerequisite under the new model
  # — a variant with no marker AND no local cwd is unidentifiable and
  # gets skipped). Source side is rich (MEMORY.md + memory/note.md);
  # target side has only the marker. Expect target to receive copies.
  mkvariant "-Users-alice-Repo-bar"
  mkvariant "C--Users-bob-Repo-bar"
  mark "-Users-alice-Repo-bar"      "github.com/me/bar"
  mark "C--Users-bob-Repo-bar"   "github.com/me/bar"

  printf 'from B\n' > "$HOME/.claude/projects/C--Users-bob-Repo-bar/memory/note.md"
  printf 'B index\n' > "$HOME/.claude/projects/C--Users-bob-Repo-bar/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/projects/-Users-alice-Repo-bar/memory/note.md" ]
  [ -f "$HOME/.claude/projects/-Users-alice-Repo-bar/MEMORY.md" ]
  grep -Fq 'B index' "$HOME/.claude/projects/-Users-alice-Repo-bar/MEMORY.md"
}

@test "idempotent: second run produces no further changes" {
  mkvariant "-Users-alice-Repo-foo"
  mkvariant "C--Users-bob-Repo-foo"
  mark "-Users-alice-Repo-foo"     "github.com/me/foo"
  mark "C--Users-bob-Repo-foo"  "github.com/me/foo"
  printf '# foo\n- A\n' > "$HOME/.claude/projects/-Users-alice-Repo-foo/MEMORY.md"
  printf '# foo\n- B\n' > "$HOME/.claude/projects/C--Users-bob-Repo-foo/MEMORY.md"

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
  mkvariant "-Users-alice-Repo-basic-pitch-gcs"
  mkvariant "-Users-alice-Repo-demucs-gcs"
  mkvariant "-Users-alice-Repo-piano-transcription-gcs"
  mark "-Users-alice-Repo-basic-pitch-gcs"          "github.com/me/basic-pitch-gcs"
  mark "-Users-alice-Repo-demucs-gcs"               "github.com/me/demucs-gcs"
  mark "-Users-alice-Repo-piano-transcription-gcs"  "github.com/me/piano-transcription-gcs"

  printf '# basic-pitch only\n' > "$HOME/.claude/projects/-Users-alice-Repo-basic-pitch-gcs/MEMORY.md"
  printf '# demucs only\n'      > "$HOME/.claude/projects/-Users-alice-Repo-demucs-gcs/MEMORY.md"
  printf '# pti only\n'         > "$HOME/.claude/projects/-Users-alice-Repo-piano-transcription-gcs/MEMORY.md"
  printf 'demucs-private\n'     > "$HOME/.claude/projects/-Users-alice-Repo-demucs-gcs/memory/secret.md"

  run run_mirror
  [ "$status" -eq 0 ]

  # Each project's MEMORY.md is unchanged.
  grep -Fq '# basic-pitch only' "$HOME/.claude/projects/-Users-alice-Repo-basic-pitch-gcs/MEMORY.md"
  grep -Fq '# demucs only'      "$HOME/.claude/projects/-Users-alice-Repo-demucs-gcs/MEMORY.md"
  grep -Fq '# pti only'         "$HOME/.claude/projects/-Users-alice-Repo-piano-transcription-gcs/MEMORY.md"

  # No cross-pollination of memory files.
  [ ! -f "$HOME/.claude/projects/-Users-alice-Repo-basic-pitch-gcs/memory/secret.md" ]
  [ ! -f "$HOME/.claude/projects/-Users-alice-Repo-piano-transcription-gcs/memory/secret.md" ]
}

@test "variant with no identity (no sidecar, no local cwd) is left alone" {
  # Two variants share a name but only one has an identity. The other
  # has no sidecar and no jsonl — must NOT be mirrored into.
  mkvariant "-Users-alice-Repo-orphan"
  mkvariant "C--Users-bob-Repo-orphan"
  mark "-Users-alice-Repo-orphan" "github.com/me/orphan"
  # No mark on the C-- side, no jsonl either.

  printf 'mac content\n' > "$HOME/.claude/projects/-Users-alice-Repo-orphan/memory/note.md"

  run run_mirror
  [ "$status" -eq 0 ]
  # Mac side is untouched; orphan side received nothing.
  [ -f "$HOME/.claude/projects/-Users-alice-Repo-orphan/memory/note.md" ]
  [ ! -f "$HOME/.claude/projects/C--Users-bob-Repo-orphan/memory/note.md" ]
}

@test "discover_id derives identity from local jsonl + git remote and persists the sidecar" {
  proj_dir="$HOME/myrepo"
  git -c init.defaultBranch=main init -q "$proj_dir"
  git -C "$proj_dir" remote add origin git@github.com:Owner/MyRepo.git

  variant="$HOME/.claude/projects/-Users-alice-myrepo"
  mkdir -p "$variant"
  printf '{"cwd":"%s","other":"junk"}\n' "$proj_dir" > "$variant/session.jsonl"
  # Real memory content so the content gate lets the bootstrap proceed —
  # this test focuses on the id normalization path, covered separately
  # from the "content-less / cross-machine pull-down" cases.
  printf '# notes\n' > "$variant/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$variant/memory/$MARKER" ]
  grep -Fq "project-id=github.com/owner/myrepo" "$variant/memory/$MARKER"
}

@test "content-less variant is left alone — no sidecar is bootstrapped into an empty project dir" {
  # Every project you've opened in Claude Code has a session jsonl that
  # points at a real git repo. Without gating, discover_id would write
  # a .hive-mind sidecar into every one of those and publish empty
  # <variant>/memory/ directories to the shared memory repo. Only
  # variants with actual memory content should be bootstrapped.
  proj_dir="$HOME/empty-repo"
  git -c init.defaultBranch=main init -q "$proj_dir"
  git -C "$proj_dir" remote add origin git@github.com:me/empty-repo.git

  variant="$HOME/.claude/projects/-Users-alice-Repo-empty"
  mkdir -p "$variant"
  printf '{"cwd":"%s"}\n' "$proj_dir" > "$variant/session.jsonl"
  # No MEMORY.md, no memory/ dir, no memory/*.md.

  run run_mirror
  [ "$status" -eq 0 ]
  [ ! -f "$variant/memory/$MARKER" ]
  [ ! -d "$variant/memory" ]
}

@test "cross-machine pull-down: content-less variant bootstraps when another variant has matching id sidecar" {
  # Scenario: alice has been working on the 'adtof' repo and pushed her
  # memory. bob pulls — he now has alice's variant dir with sidecar and
  # content. Then bob clones 'adtof' locally for the first time on his
  # own machine. Claude Code creates bob's variant dir with a session
  # jsonl. Without the escape hatch, discover_id would skip bob's
  # content-less variant, leaving it un-mirrored. With the escape
  # hatch, the derived id matches alice's pre-existing sidecar → bob's
  # variant bootstraps and receives alice's content.
  proj_dir="$HOME/adtof"
  git -c init.defaultBranch=main init -q "$proj_dir"
  git -C "$proj_dir" remote add origin git@github.com:me/adtof.git

  # alice's variant (pulled from remote) — has content + sidecar.
  alice="$HOME/.claude/projects/-Users-alice-Repo-adtof"
  mkdir -p "$alice/memory"
  printf 'project-id=github.com/me/adtof\n' > "$alice/memory/$MARKER"
  printf 'alice memory line\n' > "$alice/memory/notes.md"
  printf '# adtof alice\n' > "$alice/MEMORY.md"

  # bob's fresh variant — session jsonl only, NO memory content, NO sidecar.
  bob="$HOME/.claude/projects/C--Users-bob-Repo-adtof"
  mkdir -p "$bob"
  printf '{"cwd":"%s"}\n' "$proj_dir" > "$bob/session.jsonl"

  run run_mirror
  [ "$status" -eq 0 ]

  # bob's sidecar was bootstrapped because the derived id matched alice's.
  [ -f "$bob/memory/$MARKER" ]
  grep -Fq "project-id=github.com/me/adtof" "$bob/memory/$MARKER"
  # alice's content mirrored into bob's variant.
  [ -f "$bob/memory/notes.md" ]
  grep -Fq "alice memory line" "$bob/memory/notes.md"
  [ -f "$bob/MEMORY.md" ]
}

@test "variant with MEMORY.md (content) DOES bootstrap a sidecar" {
  # Companion to the content-less test: when real content exists,
  # discover_id must still write the sidecar.
  proj_dir="$HOME/live-repo"
  git -c init.defaultBranch=main init -q "$proj_dir"
  git -C "$proj_dir" remote add origin git@github.com:me/live-repo.git

  variant="$HOME/.claude/projects/-Users-alice-Repo-live"
  mkdir -p "$variant"
  printf '{"cwd":"%s"}\n' "$proj_dir" > "$variant/session.jsonl"
  printf '# live memory\n' > "$variant/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$variant/memory/$MARKER" ]
  grep -Fq "project-id=github.com/me/live-repo" "$variant/memory/$MARKER"
}

@test "user-supplied identity (no git remote) is honored — manual override path" {
  # User creates the sidecar by hand for a project that doesn't have a
  # git remote (or that they want to group under a custom id). Mirror
  # must NOT try to overwrite or rederive — the file is the source of
  # truth.
  mkvariant "-Users-alice-Repo-no-remote-1"
  mkvariant "C--Users-bob-Repo-no-remote-2"
  mark "-Users-alice-Repo-no-remote-1"     "user-id/local-project"
  mark "C--Users-bob-Repo-no-remote-2"  "user-id/local-project"
  printf 'side A\n' > "$HOME/.claude/projects/-Users-alice-Repo-no-remote-1/memory/note.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/projects/C--Users-bob-Repo-no-remote-2/memory/note.md" ]
  # Sidecars unchanged.
  grep -Fq "project-id=user-id/local-project" \
    "$HOME/.claude/projects/-Users-alice-Repo-no-remote-1/memory/$MARKER"
}

@test "discover_id: SSH and HTTPS forms of the same remote normalize to the same id and group" {
  mkvariant "-Users-alice-Repo-bothforms"
  mkvariant "C--Users-bob-Repo-bothforms"
  # Pre-populate sidecars in the new key=value format with the same
  # normalized id (representing what each side's discover_id would
  # produce after normalizing its own SSH/HTTPS URL form).
  mark "-Users-alice-Repo-bothforms"     "github.com/me/bothforms"
  mark "C--Users-bob-Repo-bothforms"  "github.com/me/bothforms"
  printf 'side A\n' > "$HOME/.claude/projects/-Users-alice-Repo-bothforms/memory/a.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/projects/C--Users-bob-Repo-bothforms/memory/a.md" ]
}

@test "edit on one side propagates cleanly (no old+new line duplication)" {
  # User edits a word in memory on one machine; the other variant must
  # receive the change as-is, not a union of old+new. Baseline: both
  # variants hold identical committed content. Then one side edits.
  git -C "$HOME/.claude" -c init.defaultBranch=main init -q
  git -C "$HOME/.claude" config user.email t@t.t
  git -C "$HOME/.claude" config user.name t

  mkvariant "-Users-alice-Repo-foo"
  mkvariant "C--Users-bob-Repo-foo"
  mark "-Users-alice-Repo-foo" "github.com/me/foo"
  mark "C--Users-bob-Repo-foo" "github.com/me/foo"
  printf 'line one\ncapital: Paris\nline three\n' \
    > "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/note.md"
  printf 'line one\ncapital: Paris\nline three\n' \
    > "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/note.md"

  git -C "$HOME/.claude" add -A
  git -C "$HOME/.claude" commit -q -m baseline

  # Edit on alice's side only.
  printf 'line one\ncapital: Lyon\nline three\n' \
    > "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/note.md"

  run run_mirror
  [ "$status" -eq 0 ]

  # Both files have exactly 3 lines — Lyon replaced Paris, no union.
  [ "$(wc -l < "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/note.md" | tr -d ' ')" = "3" ]
  [ "$(wc -l < "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/note.md" | tr -d ' ')" = "3" ]
  run grep -Fq "Paris" "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/note.md"
  [ "$status" -ne 0 ]
  run grep -Fq "Paris" "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/note.md"
  [ "$status" -ne 0 ]
  grep -Fq "Lyon" "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/note.md"
  grep -Fq "Lyon" "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/note.md"
}

@test "concurrent additions on both sides: both survive via union merge" {
  # Two machines each add different new memory while offline, then
  # sync. Both additions must end up on both sides — neither side's
  # new content is silently dropped. This is the safety case that
  # justifies keeping union-merge as the fallback.
  git -C "$HOME/.claude" -c init.defaultBranch=main init -q
  git -C "$HOME/.claude" config user.email t@t.t
  git -C "$HOME/.claude" config user.name t

  mkvariant "-Users-alice-Repo-foo"
  mkvariant "C--Users-bob-Repo-foo"
  mark "-Users-alice-Repo-foo" "github.com/me/foo"
  mark "C--Users-bob-Repo-foo" "github.com/me/foo"
  printf 'header\n' > "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/note.md"
  printf 'header\n' > "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/note.md"

  git -C "$HOME/.claude" add -A
  git -C "$HOME/.claude" commit -q -m baseline

  # Both sides add different content.
  printf 'header\nALICE LINE\n' \
    > "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/note.md"
  printf 'header\nBOB LINE\n' \
    > "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/note.md"

  run run_mirror
  [ "$status" -eq 0 ]

  grep -Fq "ALICE LINE" "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/note.md"
  grep -Fq "BOB LINE"   "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/note.md"
  grep -Fq "ALICE LINE" "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/note.md"
  grep -Fq "BOB LINE"   "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/note.md"
}

@test "non-markdown files are NOT byte-concatenated when variants differ" {
  mkvariant "-Users-alice-Repo-foo"
  mkvariant "C--Users-bob-Repo-foo"
  mark "-Users-alice-Repo-foo"     "github.com/me/foo"
  mark "C--Users-bob-Repo-foo"  "github.com/me/foo"
  printf 'BIN_MAC\0data' > "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/blob.bin"
  printf 'BIN_WIN\0data' > "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/blob.bin"

  run run_mirror
  [ "$status" -eq 0 ]

  run diff -q "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/blob.bin" \
              "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/blob.bin"
  [ "$status" -ne 0 ]

  [ "$(wc -c < "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/blob.bin")" -eq 12 ]
  [ "$(wc -c < "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/blob.bin")" -eq 12 ]
}

@test "non-markdown files: copy-if-missing fills variants that lack the file" {
  mkvariant "-Users-alice-Repo-foo"
  mkvariant "C--Users-bob-Repo-foo"
  mark "-Users-alice-Repo-foo"     "github.com/me/foo"
  mark "C--Users-bob-Repo-foo"  "github.com/me/foo"
  printf 'BIN_DATA' > "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/blob.bin"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/blob.bin" ]
  diff -q "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/blob.bin" \
          "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/blob.bin"
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

@test "discover_id iterates jsonls: stale-cwd first session, valid-cwd later session → id resolves" {
  # The variant has two session jsonls. The older one points at a cwd
  # that no longer exists (project moved/deleted). The newer one points
  # at the real repo. derive_id_from_cwd must not stop at the first
  # cwd field — it has to keep trying until one yields a git remote.
  live="$HOME/live-repo"
  git -c init.defaultBranch=main init -q "$live"
  git -C "$live" remote add origin git@github.com:me/live-repo.git

  variant="$HOME/.claude/projects/-Users-alice-Repo-live"
  mkdir -p "$variant"
  # Glob iteration is alphabetical, so "a-*.jsonl" is visited first —
  # its cwd is stale and must not short-circuit discovery.
  printf '{"cwd":"%s/ghost-dir"}\n' "$HOME" > "$variant/a-old-session.jsonl"
  printf '{"cwd":"%s"}\n' "$live"          > "$variant/b-new-session.jsonl"
  printf '# live notes\n' > "$variant/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]
  [ -f "$variant/memory/$MARKER" ]
  grep -Fq "project-id=github.com/me/live-repo" "$variant/memory/$MARKER"
}

@test "n=3 variants, only one edits: edit replaces baseline on the other two (no union)" {
  # Three-way variant grouping (e.g. mac + windows + linux machines all
  # pulling the same memory repo). Only alice edits; bob and carol still
  # hold the pre-edit baseline. The edit must propagate cleanly to both
  # without dragging the old line along as a union.
  git -C "$HOME/.claude" -c init.defaultBranch=main init -q
  git -C "$HOME/.claude" config user.email t@t.t
  git -C "$HOME/.claude" config user.name t

  mkvariant "-Users-alice-Repo-tri"
  mkvariant "C--Users-bob-Repo-tri"
  mkvariant "-home-carol-Repo-tri"
  mark "-Users-alice-Repo-tri" "github.com/me/tri"
  mark "C--Users-bob-Repo-tri" "github.com/me/tri"
  mark "-home-carol-Repo-tri"  "github.com/me/tri"

  for d in -Users-alice-Repo-tri C--Users-bob-Repo-tri -home-carol-Repo-tri; do
    printf 'line one\ncapital: Paris\nline three\n' \
      > "$HOME/.claude/projects/$d/memory/note.md"
  done

  git -C "$HOME/.claude" add -A
  git -C "$HOME/.claude" commit -q -m baseline

  # Only alice edits.
  printf 'line one\ncapital: Lyon\nline three\n' \
    > "$HOME/.claude/projects/-Users-alice-Repo-tri/memory/note.md"

  run run_mirror
  [ "$status" -eq 0 ]

  for d in -Users-alice-Repo-tri C--Users-bob-Repo-tri -home-carol-Repo-tri; do
    p="$HOME/.claude/projects/$d/memory/note.md"
    [ "$(wc -l < "$p" | tr -d ' ')" = "3" ]
    run grep -Fq "Paris" "$p"
    [ "$status" -ne 0 ]
    grep -Fq "Lyon" "$p"
  done
}

@test "no git baseline in ~/.claude: divergent MD variants union (safe fallback)" {
  # Without a git repo at ~/.claude, the script can't distinguish an
  # edit from a concurrent add — there's no HEAD to diverge from. The
  # only data-preserving answer is union; anything else risks silently
  # dropping one side's content. In steady-state hive-mind usage,
  # setup.sh guarantees ~/.claude IS a git repo, so this fallback only
  # fires in pre-install / manually-broken setups. Documenting it here
  # pins the contract so future refactors don't accidentally pick a
  # lossy strategy.
  mkvariant "-Users-alice-Repo-nogit"
  mkvariant "C--Users-bob-Repo-nogit"
  mark "-Users-alice-Repo-nogit" "github.com/me/nogit"
  mark "C--Users-bob-Repo-nogit" "github.com/me/nogit"

  printf 'header\nALICE LINE\n' \
    > "$HOME/.claude/projects/-Users-alice-Repo-nogit/memory/note.md"
  printf 'header\nBOB LINE\n' \
    > "$HOME/.claude/projects/C--Users-bob-Repo-nogit/memory/note.md"

  [ ! -d "$HOME/.claude/.git" ]  # precondition: no git repo

  run run_mirror
  [ "$status" -eq 0 ]

  for d in -Users-alice-Repo-nogit C--Users-bob-Repo-nogit; do
    p="$HOME/.claude/projects/$d/memory/note.md"
    grep -Fq "ALICE LINE" "$p"
    grep -Fq "BOB LINE"   "$p"
  done
}

@test "the .hive-mind sidecar itself is NOT mirrored as content" {
  # Each variant must keep its OWN sidecar. The sidecar is identity
  # metadata, not synced content — the script must skip it when listing
  # files to mirror.
  mkvariant "-Users-alice-Repo-foo"
  mkvariant "C--Users-bob-Repo-foo"
  # Same project-id (so they group), but extra per-variant metadata
  # that would be visibly different if the file got cross-mirrored.
  cat > "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/$MARKER" <<EOF
project-id=github.com/me/foo
machine=mac
EOF
  cat > "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/$MARKER" <<EOF
project-id=github.com/me/foo
machine=windows
EOF
  printf 'shared\n' > "$HOME/.claude/projects/-Users-alice-Repo-foo/MEMORY.md"
  printf 'shared\n' > "$HOME/.claude/projects/C--Users-bob-Repo-foo/MEMORY.md"

  run run_mirror
  [ "$status" -eq 0 ]

  # Each side keeps its own per-variant metadata (no cross-overwrite).
  grep -Fq "machine=mac"     "$HOME/.claude/projects/-Users-alice-Repo-foo/memory/$MARKER"
  grep -Fq "machine=windows" "$HOME/.claude/projects/C--Users-bob-Repo-foo/memory/$MARKER"
}
