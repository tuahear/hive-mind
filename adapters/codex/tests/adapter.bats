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

# === Skill format ==========================================================

@test "bundled hive-mind skill has YAML frontmatter and Codex paths" {
  skill="$ADAPTER_ROOT/skills/hive-mind/content.md"
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

@test "install_hooks seeds AGENTS.override.md from an existing AGENTS.md" {
  mkdir -p "$ADAPTER_DIR"
  printf '# legacy memory\n' > "$ADAPTER_DIR/AGENTS.md"

  adapter_install_hooks

  [ -f "$ADAPTER_DIR/AGENTS.override.md" ]
  grep -q '# legacy memory' "$ADAPTER_DIR/AGENTS.override.md"
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

# === round-trip mapping ====================================================

@test "hub mapping round-trips AGENTS.override.md and hooks.json#hooks" {
  TOOL="$HOME/tool"
  HUB="$HOME/hub"
  mkdir -p "$TOOL" "$HUB"

  ADAPTER_DIR="$TOOL"
  export ADAPTER_DIR
  source "$LOADER"
  load_adapter "codex"
  # shellcheck source=/dev/null
  source "$HARVEST_FANOUT"

  printf 'alpha\nbeta\n' > "$TOOL/AGENTS.override.md"
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
  rm -rf "$TOOL"
  mkdir -p "$TOOL"
  hub_fan_out "$HUB" "$TOOL"

  diff <(printf 'alpha\nbeta\n') "$TOOL/AGENTS.override.md"
  jq -e '.hooks.SessionStart[0].hooks[0].command == "echo session"' "$TOOL/hooks.json" >/dev/null
  jq -e '.hooks.Stop[0].hooks[0].command == "echo stop"' "$TOOL/hooks.json" >/dev/null
}
