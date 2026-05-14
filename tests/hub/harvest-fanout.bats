#!/usr/bin/env bats
# Unit tests for core/hub/harvest-fanout.sh — the bidirectional mapper
# between a tool's native config dir and the hub's canonical schema.
#
# Tests run against a synthetic tool/ + hub/ pair under $HOME (no git,
# no adapter load overhead). The adapter contract fields the helpers
# consume are set directly in the test's environment.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
HARVEST_FANOUT="$REPO_ROOT/core/hub/harvest-fanout.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  TOOL="$HOME/.tool"
  HUB="$HOME/.hive-mind"
  mkdir -p "$TOOL" "$HUB"
  export ADAPTER_LOG_PATH="$HOME/hub.log"

  # Claude-shaped content/project rules. The helpers are adapter-agnostic;
  # using Claude's current production map keeps the test shape aligned
  # with a real adapter.
  export ADAPTER_HUB_MAP=$'content.md\tCLAUDE.md'
  export ADAPTER_PROJECT_CONTENT_RULES=$'content.md\tmemory/MEMORY.md\ncontent.md\tMEMORY.md\nmemory\tmemory'
  export ADAPTER_SKILL_ROOT="$TOOL/skills"

  # shellcheck source=/dev/null
  source "$HARVEST_FANOUT"
}

teardown() {
  rm -rf "$HOME"
}

# === parser helpers ========================================================

@test "hub_parse_map drops blank lines and malformed entries" {
  run hub_parse_map $'a\tb\n\n  \nlonely\nc\td'
  [ "$status" -eq 0 ]
  # Emits exactly 2 valid pairs.
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]
  # BSD grep lacks -P; match via a literal TAB in the shell's context.
  tab=$'\t'
  printf '%s\n' "$output" | grep -q "^a${tab}b$"
  printf '%s\n' "$output" | grep -q "^c${tab}d$"
}

@test "hub_parse_map accepts an empty map without erroring" {
  run hub_parse_map ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# === machine-local filter ==================================================

@test "hub_is_machine_local flags /Applications/ paths" {
  run hub_is_machine_local "/Applications/Foo.app/bin/bar --arg"
  [ "$status" -eq 0 ]
}

@test "hub_is_machine_local flags /opt/homebrew/ paths" {
  run hub_is_machine_local "cd /opt/homebrew/bin && foo"
  [ "$status" -eq 0 ]
}

@test "hub_is_machine_local flags Windows drive letters" {
  run hub_is_machine_local 'C:\Users\Foo\bin\x.exe'
  [ "$status" -eq 0 ]
}

@test "hub_is_machine_local passes non-local hook commands" {
  run hub_is_machine_local '$HOME/.hive-mind/bin/sync'
  [ "$status" -eq 1 ]
}

@test "hub_is_machine_local handles empty input" {
  run hub_is_machine_local ""
  [ "$status" -eq 1 ]
}

# === direct file-copy mapping (content.md ↔ CLAUDE.md) ======================

@test "harvest copies CLAUDE.md -> hub/content.md" {
  printf '# global\n' > "$TOOL/CLAUDE.md"
  hub_harvest "$TOOL" "$HUB"
  [ -f "$HUB/content.md" ]
  grep -q '# global' "$HUB/content.md"
}

@test "fanout copies hub/content.md -> tool/CLAUDE.md (renamed)" {
  printf '# canonical\n' > "$HUB/content.md"
  hub_fan_out "$HUB" "$TOOL"
  [ -f "$TOOL/CLAUDE.md" ]
  grep -q '# canonical' "$TOOL/CLAUDE.md"
}

@test "harvest + fanout roundtrips CLAUDE.md content" {
  printf 'alpha\nbeta\n' > "$TOOL/CLAUDE.md"
  hub_harvest "$TOOL" "$HUB"
  # Simulate cross-machine receive: nuke tool, fan-out from hub.
  rm -rf "$TOOL"
  mkdir -p "$TOOL"
  hub_fan_out "$HUB" "$TOOL"
  diff <(printf 'alpha\nbeta\n') "$TOOL/CLAUDE.md"
}

# === directory-tree mapping (skills ↔ skills) ==============================

@test "harvest mirrors tool/skills/ tree into hub with SKILL.md → content.md rename" {
  mkdir -p "$TOOL/skills/foo"
  echo "A" > "$TOOL/skills/foo/SKILL.md"
  echo "extra" > "$TOOL/skills/foo/helper.sh"

  hub_harvest "$TOOL" "$HUB"

  # Hub stores the content file as content.md (not SKILL.md).
  [ -f "$HUB/skills/foo/content.md" ]
  [ ! -f "$HUB/skills/foo/SKILL.md" ]
  grep -q '^A$' "$HUB/skills/foo/content.md"
  # Non-content files pass through unchanged.
  [ -f "$HUB/skills/foo/helper.sh" ]
}

@test "fanout renames hub content.md back to SKILL.md in tool skill dirs" {
  mkdir -p "$HUB/skills/bar"
  echo "B" > "$HUB/skills/bar/content.md"

  hub_fan_out "$HUB" "$TOOL"

  [ -f "$TOOL/skills/bar/SKILL.md" ]
  [ ! -f "$TOOL/skills/bar/content.md" ]
  grep -q '^B$' "$TOOL/skills/bar/SKILL.md"
}

@test "harvest syncs nested skill subdirs and files" {
  mkdir -p "$TOOL/skills/my-skill/scripts" "$TOOL/skills/my-skill/config"
  echo "content" > "$TOOL/skills/my-skill/SKILL.md"
  echo "#!/bin/bash" > "$TOOL/skills/my-skill/scripts/setup.sh"
  echo "key=val" > "$TOOL/skills/my-skill/config/defaults.ini"

  hub_harvest "$TOOL" "$HUB"

  [ -f "$HUB/skills/my-skill/content.md" ]
  [ -f "$HUB/skills/my-skill/scripts/setup.sh" ]
  [ -f "$HUB/skills/my-skill/config/defaults.ini" ]
  grep -q '#!/bin/bash' "$HUB/skills/my-skill/scripts/setup.sh"
}

@test "fanout syncs nested skill subdirs and prunes removed files" {
  mkdir -p "$HUB/skills/my-skill/scripts"
  echo "B" > "$HUB/skills/my-skill/content.md"
  echo "helper" > "$HUB/skills/my-skill/scripts/run.sh"
  # Pre-populate tool with an extra file that hub doesn't have.
  mkdir -p "$TOOL/skills/my-skill/old"
  echo "stale" > "$TOOL/skills/my-skill/old/legacy.sh"

  hub_fan_out "$HUB" "$TOOL"

  [ -f "$TOOL/skills/my-skill/SKILL.md" ]
  [ -f "$TOOL/skills/my-skill/scripts/run.sh" ]
  # Stale file not in hub must be pruned.
  [ ! -f "$TOOL/skills/my-skill/old/legacy.sh" ]
}

@test "harvest does not remove hub skill dirs absent from tool (add-only)" {
  mkdir -p "$HUB/skills/existing"
  echo "hub content" > "$HUB/skills/existing/content.md"
  mkdir -p "$TOOL/skills/new-skill"
  echo "A" > "$TOOL/skills/new-skill/SKILL.md"

  hub_harvest "$TOOL" "$HUB"

  [ -f "$HUB/skills/existing/content.md" ]
  [ -f "$HUB/skills/new-skill/content.md" ]
}

@test "fanout removes tool skill dirs absent from hub (prune on fanout only)" {
  mkdir -p "$HUB/skills/keep"
  echo "K" > "$HUB/skills/keep/content.md"
  mkdir -p "$TOOL/skills/keep" "$TOOL/skills/stale"
  echo "K" > "$TOOL/skills/keep/SKILL.md"
  echo "S" > "$TOOL/skills/stale/SKILL.md"

  hub_fan_out "$HUB" "$TOOL"

  [ -f "$TOOL/skills/keep/SKILL.md" ]
  [ ! -d "$TOOL/skills/stale" ]
}

# === per-project content ===================================================

@test "harvest walks tool/projects/<variant>/ and mirrors content under hub/projects/<project-id>/" {
  # Seed a variant with a sidecar (the way mirror-projects writes it).
  variant="$TOOL/projects/-Users-alice-proj"
  mkdir -p "$variant/memory"
  printf 'project-id=github.com/alice/proj\n' > "$variant/.hive-mind"
  printf '# project memory\n' > "$variant/MEMORY.md"
  printf 'note\n' > "$variant/memory/note.md"

  hub_harvest "$TOOL" "$HUB"

  hub_proj="$HUB/projects/github.com/alice/proj"
  [ -f "$hub_proj/content.md" ]
  grep -q '# project memory' "$hub_proj/content.md"
  [ -f "$hub_proj/memory/note.md" ]
  grep -q '^note$' "$hub_proj/memory/note.md"
}

@test "harvest: root MEMORY.md wins over memory/MEMORY.md when both exist" {
  # Critical: if both locations have MEMORY.md with DIFFERENT content,
  # root must win — it's the primary project memory that the user and
  # the tool see. The subdir copy is a mirror-projects artifact. If
  # subdir wins, root content is silently lost and fanned out to other
  # providers with the wrong data.
  variant="$TOOL/projects/-Users-alice-proj"
  mkdir -p "$variant/memory"
  printf 'project-id=github.com/alice/proj\n' > "$variant/.hive-mind"
  printf '# ROOT content — this must win\n' > "$variant/MEMORY.md"
  printf '# SUBDIR content — this must NOT win\n' > "$variant/memory/MEMORY.md"

  hub_harvest "$TOOL" "$HUB"

  hub_proj="$HUB/projects/github.com/alice/proj"
  [ -f "$hub_proj/content.md" ]
  grep -q '# ROOT content — this must win' "$hub_proj/content.md"
  # The subdir version must NOT have overwritten content.md.
  run grep -q '# SUBDIR content' "$hub_proj/content.md"
  [ "$status" -ne 0 ]
}

@test "harvest: falls back to memory/MEMORY.md when root MEMORY.md is absent" {
  # When only memory/MEMORY.md exists (Claude's standard layout for
  # projects that don't have a root-level MEMORY.md), the subdir file
  # must still produce content.md in the hub.
  variant="$TOOL/projects/-Users-bob-proj"
  mkdir -p "$variant/memory"
  printf 'project-id=github.com/bob/proj\n' > "$variant/.hive-mind"
  # NO root MEMORY.md — only subdir.
  printf '# subdir-only content\n' > "$variant/memory/MEMORY.md"

  hub_harvest "$TOOL" "$HUB"

  hub_proj="$HUB/projects/github.com/bob/proj"
  [ -f "$hub_proj/content.md" ]
  grep -q '# subdir-only content' "$hub_proj/content.md"
}

@test "harvest skips project variants without a sidecar (mirror-projects hasn't bootstrapped them)" {
  variant="$TOOL/projects/-Users-bob-proj"
  mkdir -p "$variant/memory"
  # No .hive-mind sidecar → variant identity unknown → skip.
  printf '# content\n' > "$variant/MEMORY.md"

  hub_harvest "$TOOL" "$HUB"

  [ ! -d "$HUB/projects/-Users-bob-proj" ]
  [ ! -e "$HUB/projects/content.md" ]
}

@test "fanout copies hub/projects/<id>/ content back into the matching tool variant" {
  # Precondition: tool-side variant exists with a sidecar at root.
  variant="$TOOL/projects/-Users-alice-proj"
  mkdir -p "$variant/memory"
  printf 'project-id=github.com/alice/proj\n' > "$variant/.hive-mind"

  # Hub has project content from another machine.
  hub_proj="$HUB/projects/github.com/alice/proj"
  mkdir -p "$hub_proj/memory"
  printf 'project-id=github.com/alice/proj\n' > "$hub_proj/.hive-mind"
  printf '# fresh\n' > "$hub_proj/content.md"
  printf 'a\n' > "$hub_proj/memory/a.md"

  hub_fan_out "$HUB" "$TOOL"

  # content.md → MEMORY.md at variant root (first explicit rule).
  [ -f "$variant/MEMORY.md" ]
  grep -q '# fresh' "$variant/MEMORY.md"
  # content.md → memory/MEMORY.md (second explicit rule).
  [ -f "$variant/memory/MEMORY.md" ]
  # Subfiles synced as-is.
  [ -f "$variant/memory/a.md" ]
}

@test "fanout only populates existing tool variants — cannot create new ones without the machine-specific encoded-cwd" {
  # The encoded-cwd folder name is machine-specific (different checkout
  # paths produce different folder names), so the hub can't tell a fresh
  # machine what folder name to use. Fan-out only populates variant dirs
  # that already exist with a sidecar. New variants get created when the
  # user opens the project in Claude (which writes a session jsonl) and
  # mirror-projects bootstraps the sidecar on the next sync.
  hub_proj="$HUB/projects/github.com/bob/newrepo"
  mkdir -p "$hub_proj/memory"
  printf 'project-id=github.com/bob/newrepo\n' > "$hub_proj/.hive-mind"
  printf '# from another machine\n' > "$hub_proj/content.md"

  [ ! -d "$TOOL/projects" ]

  hub_fan_out "$HUB" "$TOOL"

  # No variant created — tool has no encoded-cwd for this project.
  [ ! -d "$TOOL/projects" ]
}

# === section selectors in ADAPTER_HUB_MAP =================================
# A dual-file tool (AGENTS.md + AGENTS.override.md shape) uses section
# selectors to round-trip memory through a single canonical content.md.

@test "harvest: content.md[0]/[1] routes two plain tool files into distinct hub sections" {
  export ADAPTER_HUB_MAP=$'content.md[0]\tAGENTS.md\ncontent.md[1]\tAGENTS.override.md'
  printf 'shared-a\n' > "$TOOL/AGENTS.md"
  printf 'override-a\n' > "$TOOL/AGENTS.override.md"

  hub_harvest "$TOOL" "$HUB"

  run _hub_content_read_section "$HUB/content.md" 0
  [ "$output" = 'shared-a' ]
  run _hub_content_read_section "$HUB/content.md" 1
  [ "$output" = 'override-a' ]
  run _hub_content_markers_ok "$HUB/content.md"
  [ "$status" -eq 0 ]
}

@test "fan-out: content.md[0] writes plain body without markers" {
  export ADAPTER_HUB_MAP=$'content.md[0]\tAGENTS.md'
  cat > "$HUB/content.md" <<'EOF'
shared line
<!-- hive-mind:section=1 START -->
codex only
<!-- hive-mind:section=1 END -->
EOF
  hub_fan_out "$HUB" "$TOOL"

  [ -f "$TOOL/AGENTS.md" ]
  run cat "$TOOL/AGENTS.md"
  [ "$output" = 'shared line' ]
  # Exact-match guard: no marker strings leaked into the plain fan-out.
  ! grep -q 'hive-mind:section' "$TOOL/AGENTS.md"
}

@test "fan-out: content.md[0,1] concatenates section 0 plain then section 1 wrapped in markers" {
  export ADAPTER_HUB_MAP=$'content.md[0,1]\tCLAUDE.md'
  cat > "$HUB/content.md" <<'EOF'
shared stuff
<!-- hive-mind:section=1 START -->
codex-scoped
<!-- hive-mind:section=1 END -->
EOF
  hub_fan_out "$HUB" "$TOOL"

  [ -f "$TOOL/CLAUDE.md" ]
  # Section 0 content appears first, plain.
  grep -q '^shared stuff$' "$TOOL/CLAUDE.md"
  # Section 1 content survives, wrapped in START/END markers.
  grep -q '^<!-- hive-mind:section=1 START -->$' "$TOOL/CLAUDE.md"
  grep -q '^codex-scoped$' "$TOOL/CLAUDE.md"
  grep -q '^<!-- hive-mind:section=1 END -->$' "$TOOL/CLAUDE.md"
}

@test "round-trip: multi-section fan-out, tool edit, harvest — edits land in correct sections" {
  export ADAPTER_HUB_MAP=$'content.md[0,1]\tCLAUDE.md'
  cat > "$HUB/content.md" <<'EOF'
starting shared
<!-- hive-mind:section=1 START -->
starting codex-scoped
<!-- hive-mind:section=1 END -->
EOF
  hub_fan_out "$HUB" "$TOOL"

  # Agent appends a shared-tier line at EOF (outside any block) AND edits
  # the codex-scoped block body in-place.
  awk '
    /<!-- hive-mind:section=1 START -->/ { print; in_block=1; next }
    /<!-- hive-mind:section=1 END -->/   { print "edited codex-scoped"; print; in_block=0; next }
    in_block { next }
    { print }
  ' "$TOOL/CLAUDE.md" > "$TOOL/CLAUDE.md.tmp"
  mv "$TOOL/CLAUDE.md.tmp" "$TOOL/CLAUDE.md"
  printf 'appended shared at EOF\n' >> "$TOOL/CLAUDE.md"

  hub_harvest "$TOOL" "$HUB"

  # Section 0 picked up both the original shared line and the EOF append.
  run _hub_content_read_section "$HUB/content.md" 0
  printf '%s\n' "$output" | grep -Fq 'starting shared'
  printf '%s\n' "$output" | grep -Fq 'appended shared at EOF'
  # Section 1 picked up the in-block edit, not the old body.
  run _hub_content_read_section "$HUB/content.md" 1
  [ "$output" = 'edited codex-scoped' ]
}

@test "harvest: single-id selector ignores marker state in tool file" {
  # Single-id selectors (e.g. content.md[1]\tAGENTS.override.md) treat the
  # whole tool file as plain content for that one section. Marker damage
  # elsewhere in the file must NOT cause harvest to bail — only multi-id
  # / wildcard selectors parse markers. Regression guard for the case
  # pattern that decides whether to invoke _hub_content_markers_ok.
  #
  # Concrete failure mode this pins: if the case pattern were ever widened
  # to match single-id selectors, harvest would short-circuit and the hub
  # file would stay empty (or keep its pre-harvest state).
  export ADAPTER_HUB_MAP=$'content.md[1]\tAGENTS.override.md'
  # Tool file deliberately has an unmatched START marker (damaged).
  cat > "$TOOL/AGENTS.override.md" <<'EOF'
body line
<!-- hive-mind:section=2 START -->
dangling (no END)
EOF
  hub_harvest "$TOOL" "$HUB"

  # Harvest ran: the hub file exists and contains the tool-side body.
  # Raw grep (not _hub_content_read_section) because wrapping the damaged
  # marker inside section 1's block produces nested markers that the
  # section-reader isn't required to untangle — harvest's contract is
  # "don't skip single-id harvests", not "perfectly round-trip damaged
  # markers through the section parser".
  [ -f "$HUB/content.md" ]
  grep -Fq 'body line' "$HUB/content.md"
  grep -Fq 'dangling (no END)' "$HUB/content.md"
}

@test "harvest: every malformed-selector typo shape is skipped, no literal-bracket file created" {
  # Grammar tightening in _hub_split_sections is only half the story —
  # the dispatch cascade in hub_harvest also needs a guard so a
  # bracket-bearing hub path that failed validation doesn't fall through
  # to _hub_sync_file and create a file literally named after the
  # broken selector in the hub.
  #
  # Cover every typo shape that _hub_split_sections rejects:
  #   - trailing comma:       content.md[0,]
  #   - leading comma:        content.md[,0]
  #   - doubled comma:        content.md[0,,1]
  #   - missing close bracket: content.md[0
  #   - missing open bracket:  content.md0]
  #   - reversed brackets:     content.md][
  #   - standalone open:       content.md[
  #   - standalone close:      content.md]
  #
  # For each, confirm: no file with the literal broken name lands in
  # the hub AND the canonical content.md target isn't silently populated
  # as a fallback.
  local bad
  for bad in 'content.md[0,]' 'content.md[,0]' 'content.md[0,,1]' \
             'content.md[0' 'content.md0]' 'content.md][' \
             'content.md[' 'content.md]'; do
    rm -rf "$HUB" "$TOOL"
    mkdir -p "$HUB" "$TOOL"
    export ADAPTER_HUB_MAP="${bad}"$'\tAGENTS.md'
    printf 'tool content\n' > "$TOOL/AGENTS.md"

    hub_harvest "$TOOL" "$HUB"

    if [ -e "$HUB/$bad" ]; then
      echo "harvest leaked literal-bracket file for: $bad"
      return 1
    fi
    if [ -f "$HUB/content.md" ]; then
      echo "harvest silently retargeted to content.md for: $bad"
      return 1
    fi
  done
}

@test "fan-out: every malformed-selector typo shape is skipped, no literal-bracket file created" {
  # Symmetric regression guard on the fan-out side. Same coverage of
  # typo shapes as the harvest test above.
  local bad
  for bad in 'content.md[0,]' 'content.md[,0]' 'content.md[0,,1]' \
             'content.md[0' 'content.md0]' 'content.md][' \
             'content.md[' 'content.md]'; do
    rm -rf "$HUB" "$TOOL"
    mkdir -p "$HUB" "$TOOL"
    export ADAPTER_HUB_MAP="${bad}"$'\tAGENTS.md'
    printf 'hub content\n' > "$HUB/content.md"

    hub_fan_out "$HUB" "$TOOL"

    if [ -e "$TOOL/$bad" ]; then
      echo "fan-out leaked literal-bracket file for: $bad"
      return 1
    fi
    if [ -f "$TOOL/AGENTS.md" ]; then
      echo "fan-out silently retargeted to AGENTS.md for: $bad"
      return 1
    fi
  done
}

@test "fan-out: single-id selector skips when section absent from hub (does not create empty tool file)" {
  # Defense symmetric with harvest's early-return-on-absent-src: if the
  # hub doesn't have the requested section, fan-out must not overwrite
  # the tool's file with an empty one. The tool's existing file is
  # preserved untouched until the hub actually has content to ship.
  export ADAPTER_HUB_MAP=$'content.md[1]\tAGENTS.override.md'
  # Hub has ONLY a section 0 — no section 1 block.
  printf 'shared stuff only\n' > "$HUB/content.md"
  # Tool already had content; must survive the fan-out pass.
  printf 'tool-side pre-existing content\n' > "$TOOL/AGENTS.override.md"

  hub_fan_out "$HUB" "$TOOL"

  [ "$(cat "$TOOL/AGENTS.override.md")" = 'tool-side pre-existing content' ]
}

@test "fan-out: single-id selector writes empty dst when section is present but body empty" {
  # Distinct from absence: if the hub explicitly declares section 1 with
  # markers around an empty body, that IS an intentional signal ("this
  # tier is empty on this machine"). Fan-out should honor it and write
  # an empty file, not skip.
  export ADAPTER_HUB_MAP=$'content.md[1]\tAGENTS.override.md'
  cat > "$HUB/content.md" <<'EOF'
shared stuff
<!-- hive-mind:section=1 START -->
<!-- hive-mind:section=1 END -->
EOF
  printf 'should be cleared by fan-out\n' > "$TOOL/AGENTS.override.md"

  hub_fan_out "$HUB" "$TOOL"

  [ -f "$TOOL/AGENTS.override.md" ]
  [ ! -s "$TOOL/AGENTS.override.md" ]
}

@test "fan-out: [0] on blocks-only hub writes empty dst, does not skip" {
  # Section 0 is the default bucket — 'absent' from present_sections
  # only means 'empty right now', not 'doesn't exist as a concept'.
  # When the hub has only non-zero blocks (shared tier legitimately
  # empty on this machine), content.md[0]\tAGENTS.md must write an
  # empty AGENTS.md, not skip and leave stale content behind.
  export ADAPTER_HUB_MAP=$'content.md[0]\tAGENTS.md'
  cat > "$HUB/content.md" <<'EOF'
<!-- hive-mind:section=1 START -->
codex-scoped content only
<!-- hive-mind:section=1 END -->
EOF
  printf 'stale shared content that must be cleared\n' > "$TOOL/AGENTS.md"

  hub_fan_out "$HUB" "$TOOL"

  [ -f "$TOOL/AGENTS.md" ]
  [ ! -s "$TOOL/AGENTS.md" ]
}

@test "fan-out: [*] with blocks-only hub keeps section markers in tool file" {
  # Wildcard intent is 'round-trip every tier'. When [*] expands to a
  # single non-zero id, the tool file MUST keep the section markers so
  # the next harvest can route the content back to that tier. Writing
  # plain content would make the next harvest classify it as section 0
  # (markerless → shared tier) — a silent privacy downgrade.
  export ADAPTER_HUB_MAP=$'content.md[*]\tCLAUDE.md'
  cat > "$HUB/content.md" <<'EOF'
<!-- hive-mind:section=1 START -->
codex-only content
<!-- hive-mind:section=1 END -->
EOF

  hub_fan_out "$HUB" "$TOOL"

  [ -f "$TOOL/CLAUDE.md" ]
  grep -Fq '<!-- hive-mind:section=1 START -->' "$TOOL/CLAUDE.md"
  grep -Fq 'codex-only content' "$TOOL/CLAUDE.md"
  grep -Fq '<!-- hive-mind:section=1 END -->' "$TOOL/CLAUDE.md"
}

@test "fan-out+harvest round-trip: [*] on blocks-only hub preserves section 1 through a full cycle" {
  # End-to-end guard against the privacy downgrade: if fan-out strips
  # section markers for a wildcard-single-non-zero case, the next
  # harvest reclassifies the content as section 0 and codex-only
  # content starts leaking into the shared tier after just one cycle.
  export ADAPTER_HUB_MAP=$'content.md[*]\tCLAUDE.md'
  cat > "$HUB/content.md" <<'EOF'
<!-- hive-mind:section=1 START -->
codex-only content
<!-- hive-mind:section=1 END -->
EOF

  hub_fan_out "$HUB" "$TOOL"
  # Harvest back without modifying the tool file — simulates a sync
  # cycle where the agent didn't change CLAUDE.md at all.
  hub_harvest "$TOOL" "$HUB"

  # Section 1 still holds the codex-only content; section 0 is still
  # empty (no leakage into the shared tier).
  run _hub_content_read_section "$HUB/content.md" 1
  [ "$output" = 'codex-only content' ]
  run _hub_content_read_section "$HUB/content.md" 0
  [ -z "$output" ]
}

@test "fan-out: damaged markers in hub content.md are skipped for marker-dependent selectors" {
  # Symmetric with harvest-side marker validation. Fan-out with a
  # multi-id or wildcard selector parses markers; if the hub has damage,
  # silent mis-routing is possible. Skip + log and leave the tool file
  # unchanged, matching the harvest robustness contract.
  export ADAPTER_HUB_MAP=$'content.md[*]\tCLAUDE.md'
  cat > "$HUB/content.md" <<'EOF'
top
<!-- hive-mind:section=1 START -->
body (no matching END — damaged)
EOF
  printf 'pre-existing tool content\n' > "$TOOL/CLAUDE.md"

  hub_fan_out "$HUB" "$TOOL"

  # Tool file untouched — fan-out must not emit a corrupted rewrite.
  [ "$(cat "$TOOL/CLAUDE.md")" = 'pre-existing tool content' ]
}

@test "harvest: damaged markers in multi-section tool file are skipped, hub preserved" {
  export ADAPTER_HUB_MAP=$'content.md[0,1]\tCLAUDE.md'
  # Seed hub with a clean two-section file.
  cat > "$HUB/content.md" <<'EOF'
hub shared
<!-- hive-mind:section=1 START -->
hub codex
<!-- hive-mind:section=1 END -->
EOF
  # Tool file has an unmatched START (damage).
  cat > "$TOOL/CLAUDE.md" <<'EOF'
shared
<!-- hive-mind:section=1 START -->
dangling body (no END)
EOF

  hub_harvest "$TOOL" "$HUB"

  # Hub unchanged: still has both sections with the pre-harvest content.
  run _hub_content_read_section "$HUB/content.md" 0
  [ "$output" = 'hub shared' ]
  run _hub_content_read_section "$HUB/content.md" 1
  [ "$output" = 'hub codex' ]
}

# === snapshot path normalization ===========================================

@test "_hub_snapshot_path strips a trailing slash so adapters never collide" {
  # Regression: _hub_snapshot_path used ${tool_dir##*/} without stripping
  # a trailing slash first. A caller-override tool_dir like
  # "/path/to/.codex/" would yield base="" and every adapter's
  # snapshots would collapse under fanout-snapshots// — silent
  # cross-adapter collision risk.
  export HIVE_MIND_HUB_DIR="$HOME/hub-root"
  run _hub_snapshot_path "/path/to/.codex/" "content.md"
  [ "$status" -eq 0 ]
  # Namespace path must reflect the real basename, not an empty segment.
  [[ "$output" == *"fanout-snapshots/.codex/content.md" ]]
  [[ "$output" != *"fanout-snapshots//"* ]]

  # No-trailing-slash form matches the same namespace.
  run _hub_snapshot_path "/path/to/.codex" "content.md"
  [[ "$output" == *"fanout-snapshots/.codex/content.md" ]]
}

# === wildcard empty-hub clear propagation =================================

@test "fan-out: [*] on an existing but empty hub clears the tool file" {
  # Regression: a user on machine A clears CLAUDE.md to empty, which
  # harvests an empty hub content.md. On machine B the fan-out must
  # propagate the clear — otherwise B's stale CLAUDE.md survives the
  # sync cycle and the two machines drift. [*] selector with an empty
  # hub file (zero sections) must write an empty dst, not skip.
  : > "$HUB/content.md"
  printf 'stale content from before the clear\n' > "$TOOL/CLAUDE.md"

  run _hub_content_fanout_to_file "$HUB/content.md" '*' "$TOOL/CLAUDE.md"
  [ "$status" -eq 0 ]

  # CLAUDE.md exists and is empty (the clear propagated).
  [ -f "$TOOL/CLAUDE.md" ]
  [ ! -s "$TOOL/CLAUDE.md" ]
}

@test "fan-out: explicit single-id selector still skips when section is absent from empty hub" {
  # The wildcard fix must NOT change non-wildcard semantics. [1] against
  # an empty hub file still means "section 1 isn't here; leave dst
  # alone" — otherwise any adapter that targets a specific non-zero
  # section would start writing empty files whenever the hub is empty.
  : > "$HUB/content.md"
  printf 'existing body\n' > "$TOOL/AGENTS.override.md"

  run _hub_content_fanout_to_file "$HUB/content.md" '1' "$TOOL/AGENTS.override.md"
  [ "$status" -eq 0 ]

  # Tool file untouched — content preserved.
  run cat "$TOOL/AGENTS.override.md"
  [ "$output" = "existing body" ]
}

# === source-side .gitignore filter in _hub_sync_dir ========================

@test "_hub_gitignore_pattern_match: literal basename" {
  run _hub_gitignore_pattern_match ".env" ".env"
  [ "$status" -eq 0 ]
  run _hub_gitignore_pattern_match "sub/.env" ".env"
  [ "$status" -eq 0 ]
  run _hub_gitignore_pattern_match ".env.example" ".env"
  [ "$status" -ne 0 ]
}

@test "_hub_gitignore_pattern_match: trailing-slash directory pattern" {
  run _hub_gitignore_pattern_match "cache/blob" "cache/"
  [ "$status" -eq 0 ]
  run _hub_gitignore_pattern_match "sub/cache/blob" "cache/"
  [ "$status" -eq 0 ]
  run _hub_gitignore_pattern_match "cached-data" "cache/"
  [ "$status" -ne 0 ]
}

@test "_hub_gitignore_pattern_match: glob extension" {
  run _hub_gitignore_pattern_match "run.log" "*.log"
  [ "$status" -eq 0 ]
  run _hub_gitignore_pattern_match "sub/run.log" "*.log"
  [ "$status" -eq 0 ]
  run _hub_gitignore_pattern_match "run.txt" "*.log"
  [ "$status" -ne 0 ]
}

@test "_hub_sync_dir: harvest skips files matching src/.gitignore" {
  src="$HOME/src" dst="$HOME/dst"
  mkdir -p "$src/cache" "$src/sub"
  cat > "$src/.gitignore" <<'GIT'
.env
cache/
*.log
GIT
  echo "secret" > "$src/.env"
  echo "kept"   > "$src/keep.md"
  echo "trash"  > "$src/cache/blob"
  echo "trash"  > "$src/sub/run.log"

  _hub_sync_dir "$src" "$dst"

  [ -f "$dst/keep.md" ]
  [ -f "$dst/.gitignore" ]
  [ ! -e "$dst/.env" ]
  [ ! -e "$dst/cache/blob" ]
  [ ! -e "$dst/sub/run.log" ]
}

@test "_hub_sync_dir: fanout delete pass preserves dst files matching src/.gitignore" {
  src="$HOME/src" dst="$HOME/dst"
  mkdir -p "$src" "$dst/cache" "$dst/sub"
  cat > "$src/.gitignore" <<'GIT'
.env
cache/
*.log
GIT
  echo "from-src" > "$src/keep.md"
  # Pre-existing dst files that match src/.gitignore. Without the filter
  # the delete pass would wipe them because they aren't in src.
  echo "local"    > "$dst/.env"
  echo "local"    > "$dst/cache/blob"
  echo "local"    > "$dst/sub/build.log"

  _hub_sync_dir "$src" "$dst" fanout

  [ -f "$dst/keep.md" ]
  [ -f "$dst/.env" ]
  [ -f "$dst/cache/blob" ]
  [ -f "$dst/sub/build.log" ]
}

@test "_hub_sync_dir: harvest delete pass cleans stale ignored files from dst" {
  # The asymmetric half of the gitignore filter. Scenario: an earlier
  # sync committed cache/blob to the hub before the .gitignore rule
  # `cache/` was added. On the next harvest, the copy pass already
  # skips cache/blob (src filtered), but the delete pass must STILL
  # remove the stale hub-side copy — otherwise the file lingers in the
  # tracked tree forever, defeating the rule. Symmetric to the fanout
  # test above but with opposite expected behavior.
  src="$HOME/src" dst="$HOME/dst"
  mkdir -p "$src" "$dst/cache" "$dst/sub"
  cat > "$src/.gitignore" <<'GIT'
.env
cache/
*.log
GIT
  echo "from-src" > "$src/keep.md"
  # Pre-existing committed-stale dst files (the hub got them before the
  # gitignore rule landed). Harvest must remove them.
  echo "stale"    > "$dst/.env"
  echo "stale"    > "$dst/cache/blob"
  echo "stale"    > "$dst/sub/build.log"

  _hub_sync_dir "$src" "$dst" harvest

  [ -f "$dst/keep.md" ]
  [ ! -f "$dst/.env" ]
  [ ! -f "$dst/cache/blob" ]
  [ ! -f "$dst/sub/build.log" ]
}

@test "_hub_sync_dir: no .gitignore means original mirror semantics" {
  # Regression guard: claude-code and codex use dir mirrors (e.g.
  # memory/ → memory/) and none of those source dirs carry a .gitignore.
  # The pre-existing strict mirror behavior must hold for them.
  src="$HOME/src" dst="$HOME/dst"
  mkdir -p "$src" "$dst"
  echo "fresh" > "$src/a"
  echo "stale" > "$dst/b"

  _hub_sync_dir "$src" "$dst"

  [ -f "$dst/a" ]
  [ ! -f "$dst/b" ]
}
