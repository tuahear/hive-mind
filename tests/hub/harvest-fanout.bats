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

  # Claude-shaped hub map (the only adapter shipping one today). The
  # helpers are adapter-agnostic; using Claude's here keeps the test
  # shape identical to what production hits.
  export ADAPTER_HUB_MAP=$'content.md\tCLAUDE.md\nconfig/hooks\tsettings.json#hooks\nconfig/permissions/allow.txt\tsettings.json#permissions.allow'
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

# === JSON subkey — text list (permissions.allow) ===========================

@test "harvest extracts permissions.allow to a newline-per-entry text file" {
  cat > "$TOOL/settings.json" <<'EOF'
{"permissions":{"allow":["Bash(npm *)","Edit","Read"]}}
EOF
  hub_harvest "$TOOL" "$HUB"
  [ -f "$HUB/config/permissions/allow.txt" ]
  run cat "$HUB/config/permissions/allow.txt"
  [[ "$output" == *'Bash(npm *)'* ]]
  [[ "$output" == *'Edit'* ]]
  [[ "$output" == *'Read'* ]]
}

@test "fanout writes hub allow.txt back into settings.json .permissions.allow" {
  mkdir -p "$HUB/config/permissions"
  printf 'Bash(git *)\nRead\n' > "$HUB/config/permissions/allow.txt"
  echo '{"model":"opus"}' > "$TOOL/settings.json"

  hub_fan_out "$HUB" "$TOOL"

  # Array reconstructed with all entries, model preserved.
  [ "$(jq -r '.model' "$TOOL/settings.json")" = "opus" ]
  jq -e '.permissions.allow | index("Bash(git *)")' "$TOOL/settings.json" >/dev/null
  jq -e '.permissions.allow | index("Read")' "$TOOL/settings.json" >/dev/null
  [ "$(jq '.permissions.allow | length' "$TOOL/settings.json")" = "2" ]
}

# === JSON subkey — hooks directory split ===================================

@test "harvest splits settings.json#hooks into per-event/<slug>.json files" {
  cat > "$TOOL/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$HOME/.hive-mind/bin/sync" } ] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write", "hooks": [ { "type": "command", "command": "echo" } ] }
    ]
  }
}
EOF
  hub_harvest "$TOOL" "$HUB"

  [ -d "$HUB/config/hooks/Stop" ]
  [ -d "$HUB/config/hooks/PostToolUse" ]
  # One wrapper per event → one file per event.
  [ "$(find "$HUB/config/hooks/Stop" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
  [ "$(find "$HUB/config/hooks/PostToolUse" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
  # Stop entry's command survived verbatim.
  jq -e '.hooks[0].command == "$HOME/.hive-mind/bin/sync"' "$HUB/config/hooks/Stop"/*.json >/dev/null
  # Filenames are human-readable command slugs (not content hashes).
  [ -f "$HUB/config/hooks/Stop/sync.json" ]
  [ -f "$HUB/config/hooks/PostToolUse/echo.json" ]
}

@test "harvest filters out hooks whose command references a machine-local path" {
  cat > "$TOOL/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "/Applications/LocalTool.app/foo" } ] },
      { "hooks": [ { "type": "command", "command": "echo hello" } ] }
    ]
  }
}
EOF
  hub_harvest "$TOOL" "$HUB"

  # Only the non-machine-local entry should be harvested.
  [ "$(find "$HUB/config/hooks/SessionStart" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
  grep -q 'echo hello' "$HUB/config/hooks/SessionStart"/*.json
  # Skip was logged.
  grep -Fq 'skipped machine-local hook' "$ADAPTER_LOG_PATH"
}

@test "fanout rebuilds settings.json .hooks from hub and preserves tool-side machine-local entries" {
  # Hub has one Stop entry.
  mkdir -p "$HUB/config/hooks/Stop"
  printf '{"hooks":[{"type":"command","command":"$HOME/.hive-mind/bin/sync"}]}\n' \
    > "$HUB/config/hooks/Stop/sync.json"

  # Tool already has a machine-local Stop entry (fan-out must keep it).
  cat > "$TOOL/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/Applications/LocalApp.app/notify" } ] }
    ]
  },
  "ui": { "theme": "dark" }
}
EOF

  hub_fan_out "$HUB" "$TOOL"

  # Both entries present.
  [ "$(jq '.hooks.Stop | length' "$TOOL/settings.json")" = "2" ]
  # Machine-local one retained.
  jq -e '.hooks.Stop | map(.hooks[0].command) | index("/Applications/LocalApp.app/notify")' "$TOOL/settings.json" >/dev/null
  # Hub one added.
  jq -e '.hooks.Stop | map(.hooks[0].command) | index("$HOME/.hive-mind/bin/sync")' "$TOOL/settings.json" >/dev/null
  # Fields outside the map untouched.
  [ "$(jq -r '.ui.theme' "$TOOL/settings.json")" = "dark" ]
}

@test "harvest rewrites stale hub hooks for an event when the tool changes" {
  # First pass: one Stop entry.
  cat > "$TOOL/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"cmd-one"}]}]}}
EOF
  hub_harvest "$TOOL" "$HUB"
  first_id="$(basename "$(find "$HUB/config/hooks/Stop" -name '*.json' | head -1)" .json)"
  [ -n "$first_id" ]

  # User removes the first entry, adds a different one. Harvest must
  # nuke the old file under Stop/ and write the new one — otherwise
  # the hub would accumulate ghost hooks forever.
  cat > "$TOOL/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"cmd-two"}]}]}}
EOF
  hub_harvest "$TOOL" "$HUB"

  [ "$(find "$HUB/config/hooks/Stop" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
  [ ! -f "$HUB/config/hooks/Stop/$first_id.json" ]
  grep -q 'cmd-two' "$HUB/config/hooks/Stop"/*.json
  run grep -q 'cmd-one' "$HUB/config/hooks/Stop"/*.json
  [ "$status" -ne 0 ]
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
