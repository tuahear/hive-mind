#!/usr/bin/env bats
# Claude-code adapter-specific tests. Tests Claude-specific behavior that
# doesn't generalize to other adapters (settings.json schema, Claude event
# names, marker-nudge prompt content, skill format).

REPO_ROOT="$BATS_TEST_DIRNAME/../../.."
LOADER="$REPO_ROOT/core/adapter-loader.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  source "$LOADER"
  load_adapter "claude-code"
}

teardown() {
  rm -rf "$HOME"
}

# === settings.json schema ==================================================

@test "settings.json template has SessionStart hook" {
  local template="${ADAPTER_ROOT}/settings.json"
  [ "$(jq '.hooks.SessionStart | length' "$template")" -gt 0 ]
}

@test "settings.json template has Stop hook" {
  local template="${ADAPTER_ROOT}/settings.json"
  [ "$(jq '.hooks.Stop | length' "$template")" -gt 0 ]
}

@test "settings.json template has PostToolUse hook with Edit|Write|NotebookEdit matcher" {
  local template="${ADAPTER_ROOT}/settings.json"
  matcher="$(jq -r '.hooks.PostToolUse[0].matcher' "$template")"
  [ "$matcher" = "Edit|Write|NotebookEdit" ]
}

@test "settings.json hook commands reference core/ not scripts/" {
  local template="${ADAPTER_ROOT}/settings.json"
  run grep -c 'hive-mind/scripts/' "$template"
  [ "$output" = "0" ]
  grep -q 'hive-mind/core/' "$template"
}

# === Claude-specific event names ===========================================

@test "ADAPTER_EVENT_SESSION_START is SessionStart" {
  [ "$ADAPTER_EVENT_SESSION_START" = "SessionStart" ]
}

@test "ADAPTER_EVENT_TURN_END is Stop" {
  [ "$ADAPTER_EVENT_TURN_END" = "Stop" ]
}

@test "ADAPTER_EVENT_POST_EDIT is PostToolUse" {
  [ "$ADAPTER_EVENT_POST_EDIT" = "PostToolUse" ]
}

# === Paths =================================================================

@test "ADAPTER_DIR is ~/.claude" {
  [ "$ADAPTER_DIR" = "$HOME/.claude" ]
}

@test "ADAPTER_GLOBAL_MEMORY is ~/.claude/CLAUDE.md" {
  [ "$ADAPTER_GLOBAL_MEMORY" = "$HOME/.claude/CLAUDE.md" ]
}

@test "ADAPTER_SKILL_ROOT is ~/.claude/skills" {
  [ "$ADAPTER_SKILL_ROOT" = "$HOME/.claude/skills" ]
}

# === Skill format ==========================================================

@test "bundled hive-mind skill has YAML frontmatter" {
  local skill="${ADAPTER_ROOT}/skills/hive-mind/SKILL.md"
  [ -f "$skill" ]
  head -1 "$skill" | grep -q '^---$'
}

# === Migration =============================================================

@test "adapter_migrate rewrites old scripts/ paths in settings.json" {
  mkdir -p "$ADAPTER_DIR"
  cat > "$ADAPTER_DIR/settings.json" <<'SETTINGS'
{
  "hooks": {
    "Stop": [{"hooks": [{"command": "~/.claude/hive-mind/scripts/sync.sh"}]}],
    "SessionStart": [{"hooks": [{"command": "cd ~/.claude && { ~/.claude/hive-mind/scripts/check-dupes.sh; }"}]}]
  }
}
SETTINGS

  adapter_migrate "0.1.0"

  run grep 'hive-mind/scripts/' "$ADAPTER_DIR/settings.json"
  [ "$status" -ne 0 ]
  grep -q 'hive-mind/core/sync.sh' "$ADAPTER_DIR/settings.json"
  grep -q 'hive-mind/core/check-dupes.sh' "$ADAPTER_DIR/settings.json"
}

@test "adapter_migrate is idempotent" {
  mkdir -p "$ADAPTER_DIR"
  cat > "$ADAPTER_DIR/settings.json" <<'SETTINGS'
{
  "hooks": {
    "Stop": [{"hooks": [{"command": "~/.claude/hive-mind/core/sync.sh"}]}]
  }
}
SETTINGS

  local before
  before="$(cat "$ADAPTER_DIR/settings.json")"

  adapter_migrate "0.1.0"

  [ "$(cat "$ADAPTER_DIR/settings.json")" = "$before" ]
}

# === install_hooks =========================================================

@test "install_hooks creates settings.json with hook entries" {
  mkdir -p "$ADAPTER_DIR"

  adapter_install_hooks

  [ -f "$ADAPTER_DIR/settings.json" ]
  [ "$(jq '.hooks.Stop | length' "$ADAPTER_DIR/settings.json")" -gt 0 ]
}

@test "install_hooks merges into existing settings.json preserving user keys" {
  mkdir -p "$ADAPTER_DIR"
  echo '{"model":"opus","permissions":{"allow":["Bash(npm test)"]}}' > "$ADAPTER_DIR/settings.json"

  adapter_install_hooks

  [ "$(jq -r '.model' "$ADAPTER_DIR/settings.json")" = "opus" ]
  jq -e '.permissions.allow | index("Bash(npm test)")' "$ADAPTER_DIR/settings.json" >/dev/null
  [ "$(jq '.hooks.Stop | length' "$ADAPTER_DIR/settings.json")" -gt 0 ]
}

# === uninstall_hooks =======================================================

@test "uninstall_hooks removes hive-mind entries from settings.json" {
  mkdir -p "$ADAPTER_DIR"

  adapter_install_hooks
  adapter_uninstall_hooks

  # When settings.json only had hive-mind hooks, uninstall removes the file.
  [ ! -f "$ADAPTER_DIR/settings.json" ]
}

@test "uninstall_hooks preserves user content in settings.json" {
  mkdir -p "$ADAPTER_DIR"
  echo '{"model":"opus"}' > "$ADAPTER_DIR/settings.json"

  adapter_install_hooks
  adapter_uninstall_hooks

  # User's model key still present.
  [ -f "$ADAPTER_DIR/settings.json" ]
  [ "$(jq -r '.model' "$ADAPTER_DIR/settings.json")" = "opus" ]
}
