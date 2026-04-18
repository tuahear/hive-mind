#!/usr/bin/env bats
# Codex adapter-specific tests. Pins the current upstream Codex surface:
# hooks.json + config.toml feature flag + AGENTS.override.md as the active
# global memory layer.

REPO_ROOT="$BATS_TEST_DIRNAME/../../.."
LOADER="$REPO_ROOT/core/adapter-loader.sh"
HARVEST_FANOUT="$REPO_ROOT/core/hub/harvest-fanout.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  source "$LOADER"
  load_adapter "codex"
}

teardown() {
  rm -rf "$HOME"
}

# === ADAPTER_DIR override ==================================================

@test "ADAPTER_DIR pre-set by the caller is preserved on adapter load" {
  custom="$HOME/alt-codex-dir"
  mkdir -p "$custom"
  (
    ADAPTER_DIR="$custom"
    export ADAPTER_DIR
    source "$LOADER"
    load_adapter "codex"
    [ "$ADAPTER_DIR" = "$custom" ]
    [ "$ADAPTER_GLOBAL_MEMORY" = "$custom/AGENTS.override.md" ]
    [ "$ADAPTER_LOG_PATH" = "$custom/.sync-error.log" ]
    [ "$ADAPTER_SKILL_ROOT" = "$HOME/.agents/skills" ]
  )
}

# === Template shape ========================================================

@test "hooks.json template has SessionStart hook" {
  template="$ADAPTER_ROOT/hooks.json"
  [ "$(jq '.hooks.SessionStart | length' "$template")" -gt 0 ]
}

@test "hooks.json template has Stop hook" {
  template="$ADAPTER_ROOT/hooks.json"
  [ "$(jq '.hooks.Stop | length' "$template")" -gt 0 ]
}

@test "hooks.json template does not install a PostToolUse hook" {
  template="$ADAPTER_ROOT/hooks.json"
  run jq -e '.hooks.PostToolUse | length > 0' "$template"
  [ "$status" -ne 0 ]
}

@test "SessionStart hook invokes hub sync before check-dupes with Codex-specific env" {
  template="$ADAPTER_ROOT/hooks.json"
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$template")"
  [[ "$cmd" == *'.hive-mind/bin/sync'* ]]
  [[ "$cmd" == *'hive-mind/core/check-dupes.sh'* ]]
  [[ "$cmd" == *'ADAPTER_DIR="$HOME/.codex"'* ]]
  [[ "$cmd" == *'ADAPTER_GLOBAL_MEMORY="$HOME/.codex/AGENTS.override.md"'* ]]
  sync_pos="$(awk -v s="$cmd" -v t='.hive-mind/bin/sync' 'BEGIN{print index(s,t)}')"
  dupes_pos="$(awk -v s="$cmd" -v t='hive-mind/core/check-dupes.sh' 'BEGIN{print index(s,t)}')"
  [ "$sync_pos" -gt 0 ]
  [ "$dupes_pos" -gt 0 ]
  [ "$sync_pos" -lt "$dupes_pos" ]
}

@test "hooks.json commands use quoted \$HOME paths" {
  template="$ADAPTER_ROOT/hooks.json"
  while IFS= read -r cmd; do
    [[ "$cmd" = *'"$HOME/.hive-mind'* ]] || {
      echo "command missing quoted \$HOME/.hive-mind: $cmd" >&2
      return 1
    }
  done < <(jq -r '.hooks | .[] | .[].hooks[] | .command' "$template")

  run grep -E '~/\.hive-mind|~/\.codex' "$template"
  [ "$status" -ne 0 ]
}

# === Paths =================================================================

@test "ADAPTER_DIR is ~/.codex" {
  [ "$ADAPTER_DIR" = "$HOME/.codex" ]
}

@test "ADAPTER_GLOBAL_MEMORY is ~/.codex/AGENTS.override.md" {
  [ "$ADAPTER_GLOBAL_MEMORY" = "$HOME/.codex/AGENTS.override.md" ]
}

@test "ADAPTER_SKILL_ROOT is ~/.agents/skills" {
  [ "$ADAPTER_SKILL_ROOT" = "$HOME/.agents/skills" ]
}

@test "declared ADAPTER_EVENT_* vars match hooks actually installed in hooks.json" {
  # Contract invariant: an ADAPTER_EVENT_<PHASE> declaration signals that
  # the adapter installs a hook for that phase. If an event var is set
  # but no corresponding hook exists in the template, downstream code
  # (like core/marker-nudge.sh gating on ADAPTER_EVENT_POST_EDIT) runs
  # against a phantom surface — misleading for any reader trying to
  # figure out what this adapter actually supports.
  #
  # Enumerate the declared-events space vs. the hooks.json template:
  local template="$ADAPTER_ROOT/hooks.json"
  [ -f "$template" ]

  # ADAPTER_EVENT_SESSION_START and ADAPTER_EVENT_TURN_END are declared,
  # so the template MUST install those hooks.
  [ -n "$ADAPTER_EVENT_SESSION_START" ]
  [ "$(jq ".hooks.\"$ADAPTER_EVENT_SESSION_START\" | length" "$template")" -gt 0 ]

  [ -n "$ADAPTER_EVENT_TURN_END" ]
  [ "$(jq ".hooks.\"$ADAPTER_EVENT_TURN_END\" | length" "$template")" -gt 0 ]

  # ADAPTER_EVENT_POST_EDIT must NOT be declared — Codex doesn't install
  # a PostToolUse-style hook. Declaring it while leaving the hook
  # uninstalled would falsely imply support.
  [ -z "${ADAPTER_EVENT_POST_EDIT:-}" ]
  [ "$(jq '.hooks.PostToolUse // [] | length' "$template")" -eq 0 ]
}

# === Skill format ==========================================================

@test "bundled hive-mind skill has YAML frontmatter and Codex paths" {
  skill="$ADAPTER_ROOT/skills/hive-mind-codex/content.md"
  [ -f "$skill" ]
  head -1 "$skill" | grep -q '^---$'
  grep -q '\.codex/AGENTS\.override\.md' "$skill"
  grep -q '\.agents/skills' "$skill"
}

# === install_hooks =========================================================

@test "install_hooks creates hooks.json and enables codex_hooks in config.toml" {
  mkdir -p "$ADAPTER_DIR"

  adapter_install_hooks

  [ -f "$ADAPTER_DIR/hooks.json" ]
  [ -f "$ADAPTER_DIR/config.toml" ]
  [ "$(jq '.hooks.Stop | length' "$ADAPTER_DIR/hooks.json")" -gt 0 ]
  grep -q '^codex_hooks = true$' "$ADAPTER_DIR/config.toml"
}

@test "install_hooks does not create AGENTS.override.md (no more one-time seed)" {
  # Pre-sectioned content.md design: AGENTS.md and AGENTS.override.md both
  # round-trip through the hub every sync cycle via section selectors, so
  # the one-time seed that used to copy AGENTS.md → AGENTS.override.md is
  # gone. install_hooks must leave the tool dir's memory files untouched.
  mkdir -p "$ADAPTER_DIR"
  printf '# existing memory\n' > "$ADAPTER_DIR/AGENTS.md"

  adapter_install_hooks

  [ -f "$ADAPTER_DIR/AGENTS.md" ]
  grep -q '# existing memory' "$ADAPTER_DIR/AGENTS.md"
  # AGENTS.override.md stays absent; the next sync cycle's fan-out
  # creates it from hub section 1 if (and only if) the hub has any.
  [ ! -e "$ADAPTER_DIR/AGENTS.override.md" ]
}

@test "install_hooks merges into existing hooks.json and preserves user keys" {
  mkdir -p "$ADAPTER_DIR"
  cat > "$ADAPTER_DIR/hooks.json" <<'EOF'
{
  "version": 1,
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo user-stop"
          }
        ]
      }
    ]
  }
}
EOF
  printf 'model = "gpt-5.4"\n' > "$ADAPTER_DIR/config.toml"

  adapter_install_hooks

  [ "$(jq -r '.version' "$ADAPTER_DIR/hooks.json")" = "1" ]
  jq -e '.hooks.Stop | map(.hooks[0].command) | index("echo user-stop")' "$ADAPTER_DIR/hooks.json" >/dev/null
  [ "$(jq '.hooks.SessionStart | length' "$ADAPTER_DIR/hooks.json")" -gt 0 ]
  grep -q '^model = "gpt-5.4"$' "$ADAPTER_DIR/config.toml"
  grep -q '^codex_hooks = true$' "$ADAPTER_DIR/config.toml"
}

@test "install_hooks idempotency probe tolerates non-command hook entries" {
  mkdir -p "$ADAPTER_DIR"
  cat > "$ADAPTER_DIR/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/.hive-mind/bin/sync\" 2>>\"$HOME/.hive-mind/.sync-error.log\" || true; ADAPTER_DIR=\"$HOME/.codex\" ADAPTER_GLOBAL_MEMORY=\"$HOME/.codex/AGENTS.override.md\" \"$HOME/.hive-mind/hive-mind/core/check-dupes.sh\" 2>>\"$HOME/.codex/.sync-error.log\" || true",
            "timeout": 30
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "prompt"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/.hive-mind/bin/sync\"",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
EOF
  printf '[features]\ncodex_hooks = true\n' > "$ADAPTER_DIR/config.toml"

  before="$(cat "$ADAPTER_DIR/hooks.json")"
  adapter_install_hooks
  after="$(cat "$ADAPTER_DIR/hooks.json")"

  [ "$before" = "$after" ]
  jq -e '.hooks.SessionStart[] | select(.hooks[0].type == "prompt")' "$ADAPTER_DIR/hooks.json" >/dev/null
}

# === uninstall_hooks =======================================================

@test "uninstall_hooks removes hive-mind hooks and restores a missing config state" {
  mkdir -p "$ADAPTER_DIR"

  adapter_install_hooks
  adapter_uninstall_hooks

  [ ! -f "$ADAPTER_DIR/hooks.json" ]
  [ ! -f "$ADAPTER_DIR/config.toml" ]
  [ ! -f "$ADAPTER_DIR/.hive-mind-codex-hooks.state" ]
}

@test "install_hooks renders ADAPTER_DIR into hooks.json for custom install path" {
  custom="$HOME/alt-codex-dir"
  ADAPTER_DIR="$custom"
  ADAPTER_GLOBAL_MEMORY="$custom/AGENTS.override.md"
  mkdir -p "$custom"

  adapter_install_hooks

  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$custom/hooks.json")"
  [[ "$cmd" == *"ADAPTER_DIR=\"$custom\""* ]]
  [[ "$cmd" == *"ADAPTER_GLOBAL_MEMORY=\"$custom/AGENTS.override.md\""* ]]
  [[ "$cmd" != *'$HOME/.codex'* ]]
}

@test "install_hooks renders ADAPTER_DIR into hooks.json when merging into existing file" {
  custom="$HOME/alt-codex-dir"
  ADAPTER_DIR="$custom"
  ADAPTER_GLOBAL_MEMORY="$custom/AGENTS.override.md"
  mkdir -p "$custom"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user"}]}]}}\n' \
    > "$custom/hooks.json"

  adapter_install_hooks

  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$custom/hooks.json")"
  [[ "$cmd" == *"ADAPTER_DIR=\"$custom\""* ]]
  [[ "$cmd" != *'$HOME/.codex'* ]]
}

@test "uninstall_hooks preserves user hooks and restores codex_hooks=false" {
  mkdir -p "$ADAPTER_DIR"
  cat > "$ADAPTER_DIR/hooks.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo user-stop"
          }
        ]
      }
    ]
  }
}
EOF
  cat > "$ADAPTER_DIR/config.toml" <<'EOF'
model = "gpt-5.4"
[features]
codex_hooks = false
EOF

  adapter_install_hooks
  adapter_uninstall_hooks

  [ -f "$ADAPTER_DIR/hooks.json" ]
  jq -e '.hooks.Stop | map(.hooks[0].command) | index("echo user-stop")' "$ADAPTER_DIR/hooks.json" >/dev/null
  run grep -q '\.hive-mind/bin/sync' "$ADAPTER_DIR/hooks.json"
  [ "$status" -ne 0 ]
  grep -q '^model = "gpt-5.4"$' "$ADAPTER_DIR/config.toml"
  grep -q '^codex_hooks = false$' "$ADAPTER_DIR/config.toml"
}

@test "uninstall_hooks preserves comment-only [features] section" {
  mkdir -p "$ADAPTER_DIR"
  printf '[features]\n# user comment\n' > "$ADAPTER_DIR/config.toml"

  adapter_install_hooks
  adapter_uninstall_hooks

  grep -q '# user comment' "$ADAPTER_DIR/config.toml"
}

# === instructions ==========================================================

@test "activation_instructions renders both AGENTS.md and AGENTS.override.md under override" {
  custom="$HOME/alt-codex-dir"
  ADAPTER_DIR="$custom"
  ADAPTER_GLOBAL_MEMORY="$custom/AGENTS.override.md"

  out="$(adapter_activation_instructions)"
  # Both synced files mentioned so the user knows the full memory surface.
  [[ "$out" == *"$custom/AGENTS.md"* ]]
  [[ "$out" == *"$custom/AGENTS.override.md"* ]]
  [[ "$out" != *'~/.codex'* ]]
}

@test "disable_instructions renders ADAPTER_DIR paths under override" {
  custom="$HOME/alt-codex-dir"
  ADAPTER_DIR="$custom"
  ADAPTER_GLOBAL_MEMORY="$custom/AGENTS.override.md"

  out="$(adapter_disable_instructions)"
  [[ "$out" == *"$custom/hooks.json"* ]]
  [[ "$out" == *"$custom/config.toml"* ]]
  [[ "$out" != *'~/.codex'* ]]
}

# === round-trip mapping ====================================================

@test "hub mapping: AGENTS.md round-trips through content.md section 0" {
  TOOL="$HOME/tool"
  HUB="$HOME/hub"
  mkdir -p "$TOOL" "$HUB"

  ADAPTER_DIR="$TOOL"
  export ADAPTER_DIR
  source "$LOADER"
  load_adapter "codex"
  # shellcheck source=/dev/null
  source "$HARVEST_FANOUT"

  printf 'shared line\n' > "$TOOL/AGENTS.md"
  hub_harvest "$TOOL" "$HUB"

  run _hub_content_read_section "$HUB/content.md" 0
  [ "$output" = 'shared line' ]

  # Fan-out back to a clean tool dir → AGENTS.md reappears plain.
  rm -f "$TOOL/AGENTS.md"
  hub_fan_out "$HUB" "$TOOL"
  [ -f "$TOOL/AGENTS.md" ]
  run cat "$TOOL/AGENTS.md"
  [ "$output" = 'shared line' ]
}

@test "hub mapping: AGENTS.override.md round-trips through content.md section 1" {
  TOOL="$HOME/tool"
  HUB="$HOME/hub"
  mkdir -p "$TOOL" "$HUB"

  ADAPTER_DIR="$TOOL"
  export ADAPTER_DIR
  source "$LOADER"
  load_adapter "codex"
  # shellcheck source=/dev/null
  source "$HARVEST_FANOUT"

  printf 'override line\n' > "$TOOL/AGENTS.override.md"
  hub_harvest "$TOOL" "$HUB"

  run _hub_content_read_section "$HUB/content.md" 1
  [ "$output" = 'override line' ]

  rm -f "$TOOL/AGENTS.override.md"
  hub_fan_out "$HUB" "$TOOL"
  [ -f "$TOOL/AGENTS.override.md" ]
  run cat "$TOOL/AGENTS.override.md"
  [ "$output" = 'override line' ]
}

@test "hub mapping: both AGENTS.md and AGENTS.override.md coexist in content.md" {
  TOOL="$HOME/tool"
  HUB="$HOME/hub"
  mkdir -p "$TOOL" "$HUB"

  ADAPTER_DIR="$TOOL"
  export ADAPTER_DIR
  source "$LOADER"
  load_adapter "codex"
  # shellcheck source=/dev/null
  source "$HARVEST_FANOUT"

  printf 'agents md content\n' > "$TOOL/AGENTS.md"
  printf 'override content\n' > "$TOOL/AGENTS.override.md"

  hub_harvest "$TOOL" "$HUB"

  run _hub_content_markers_ok "$HUB/content.md"
  [ "$status" -eq 0 ]
  run _hub_content_read_section "$HUB/content.md" 0
  [ "$output" = 'agents md content' ]
  run _hub_content_read_section "$HUB/content.md" 1
  [ "$output" = 'override content' ]
}

@test "hub mapping: hooks.json#hooks still round-trips alongside section mappings" {
  TOOL="$HOME/tool"
  HUB="$HOME/hub"
  mkdir -p "$TOOL" "$HUB"

  ADAPTER_DIR="$TOOL"
  export ADAPTER_DIR
  source "$LOADER"
  load_adapter "codex"
  # shellcheck source=/dev/null
  source "$HARVEST_FANOUT"

  cat > "$TOOL/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo session",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo stop",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF

  hub_harvest "$TOOL" "$HUB"
  rm -f "$TOOL/hooks.json"
  hub_fan_out "$HUB" "$TOOL"

  jq -e '.hooks.SessionStart[0].hooks[0].command == "echo session"' "$TOOL/hooks.json" >/dev/null
  jq -e '.hooks.Stop[0].hooks[0].command == "echo stop"' "$TOOL/hooks.json" >/dev/null
}
