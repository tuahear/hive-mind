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
  export ADAPTER_PROJECT_CONTENT_RULES=$'content.md\tMEMORY.md\ncontent.md\tmemory/MEMORY.md\nmemory\tmemory'
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

@test "harvest removes hub skill dirs whose tool counterpart was deleted" {
  mkdir -p "$TOOL/skills/foo"
  echo "A" > "$TOOL/skills/foo/SKILL.md"
  hub_harvest "$TOOL" "$HUB"
  [ -f "$HUB/skills/foo/content.md" ]

  rm -rf "$TOOL/skills/foo"
  hub_harvest "$TOOL" "$HUB"

  [ ! -d "$HUB/skills/foo" ]
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

@test "harvest splits settings.json#hooks into per-event/<id>.json files" {
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
    > "$HUB/config/hooks/Stop/abcdef.json"

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
  printf 'project-id=github.com/alice/proj\n' > "$variant/memory/.hive-mind"
  printf '# project memory\n' > "$variant/MEMORY.md"
  printf 'note\n' > "$variant/memory/note.md"

  hub_harvest "$TOOL" "$HUB"

  hub_proj="$HUB/projects/github.com/alice/proj"
  [ -f "$hub_proj/content.md" ]
  grep -q '# project memory' "$hub_proj/content.md"
  [ -f "$hub_proj/memory/note.md" ]
  grep -q '^note$' "$hub_proj/memory/note.md"
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
  # Precondition: tool already has the variant identified by sidecar.
  variant="$TOOL/projects/-Users-alice-proj"
  mkdir -p "$variant/memory"
  printf 'project-id=github.com/alice/proj\n' > "$variant/memory/.hive-mind"

  # Hub has project content from another machine.
  hub_proj="$HUB/projects/github.com/alice/proj"
  mkdir -p "$hub_proj/memory"
  printf '# fresh\n' > "$hub_proj/content.md"
  printf 'a\n' > "$hub_proj/memory/a.md"

  hub_fan_out "$HUB" "$TOOL"

  [ -f "$variant/MEMORY.md" ]
  grep -q '# fresh' "$variant/MEMORY.md"
  [ -f "$variant/memory/a.md" ]
}
