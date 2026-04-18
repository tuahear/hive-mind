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

# === ADAPTER_DIR override =================================================

@test "ADAPTER_DIR pre-set by the caller is preserved on adapter load" {
  # Default path must be ~/.claude, but a caller (tests, alternative
  # installs, or setup.sh running against a non-default tool dir)
  # should be able to override it. Hardcoding `ADAPTER_DIR=$HOME/.claude`
  # without a fallback would overwrite the override; this test pins
  # the ${:-} fallback so a regression fails here instead of silently
  # routing sync to the wrong directory.
  custom="$HOME/alt-claude-dir"
  mkdir -p "$custom"
  (
    ADAPTER_DIR="$custom"
    export ADAPTER_DIR
    source "$LOADER"
    load_adapter "claude-code"
    [ "$ADAPTER_DIR" = "$custom" ]
    # Dependent paths must derive from the override, not the default.
    [ "$ADAPTER_GLOBAL_MEMORY" = "$custom/CLAUDE.md" ]
    [[ "$ADAPTER_PROJECT_MEMORY_DIR" == "$custom/projects/"* ]]
    [ "$ADAPTER_LOG_PATH" = "$custom/.sync-error.log" ]
  )
}

# === settings.json schema ==================================================

@test "settings.json template has SessionStart hook" {
  local template="${ADAPTER_ROOT}/settings.json"
  [ "$(jq '.hooks.SessionStart | length' "$template")" -gt 0 ]
}

@test "settings.json SessionStart hook dispatches via the native hivemind-hook launcher" {
  # Claude keeps the hook entry surface down to one native launcher
  # token plus argv. The launcher owns the shell hop internally.
  local template="${ADAPTER_ROOT}/settings.json"
  local cmd
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$template")"
  [ "$cmd" = '$HIVE_MIND_HOOK claude-code session-start $ADAPTER_DIR_ARG' ]
}

@test "claude session-start wrapper script invokes sync before check-dupes with Claude env" {
  local script="$REPO_ROOT/core/hub/claude-hook-session-start.sh"
  [ -f "$script" ]
  local body
  body="$(cat "$script")"
  [[ "$body" == *'HUB_DIR/bin/sync'* ]]
  [[ "$body" == *'hive-mind/core/check-dupes.sh'* ]]
  [[ "$body" == *'ADAPTER_DIR='* ]]
  [[ "$body" == *'ADAPTER_GLOBAL_MEMORY='* ]]

  local sync_pos dupes_pos
  sync_pos="$(awk -v s="$body" -v t='HUB_DIR/bin/sync' 'BEGIN{print index(s,t)}')"
  dupes_pos="$(awk -v s="$body" -v t='hive-mind/core/check-dupes.sh' 'BEGIN{print index(s,t)}')"
  [ "$sync_pos" -gt 0 ]
  [ "$dupes_pos" -gt 0 ]
  [ "$sync_pos" -lt "$dupes_pos" ]
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

@test "claude stop wrapper script runs sync" {
  local script="$REPO_ROOT/core/hub/claude-hook-stop.sh"
  [ -f "$script" ]
  local body
  body="$(cat "$script")"
  [[ "$body" == *'HUB_DIR/bin/sync'* ]]
}

@test "claude post-tool-use wrapper script invokes marker-nudge with ADAPTER_DIR" {
  local script="$REPO_ROOT/core/hub/claude-hook-post-tool-use.sh"
  [ -f "$script" ]
  local body
  body="$(cat "$script")"
  [[ "$body" == *'hive-mind/core/marker-nudge.sh'* ]]
  [[ "$body" == *'ADAPTER_DIR='* ]]
}

@test "settings.json template dispatches only through hivemind-hook" {
  # The template should stay free of direct sync/check-dupes/marker-nudge
  # shell commands; those details live behind the launcher.
  local template="${ADAPTER_ROOT}/settings.json"
  while IFS= read -r cmd; do
    [[ "$cmd" == '$HIVE_MIND_HOOK '* ]] || {
      echo "hook command must start with the \$HIVE_MIND_HOOK token: $cmd" >&2
      return 1
    }
    [[ "$cmd" != *'bash '* ]] || {
      echo "hook command must not dispatch bash directly: $cmd" >&2
      return 1
    }
    [[ "$cmd" != *'.hive-mind/bin/sync'* ]] || {
      echo "hook command must not reference sync directly: $cmd" >&2
      return 1
    }
    [[ "$cmd" != *'check-dupes.sh'* ]] || {
      echo "hook command must not reference check-dupes directly: $cmd" >&2
      return 1
    }
    [[ "$cmd" != *'marker-nudge.sh'* ]] || {
      echo "hook command must not reference marker-nudge directly: $cmd" >&2
      return 1
    }
  done < <(jq -r '.hooks | .[] | .[].hooks[] | .command' "$template")
}

@test "settings.json template references launcher and adapter-dir tokens" {
  local template="${ADAPTER_ROOT}/settings.json"
  local session_cmd stop_cmd post_cmd
  session_cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$template")"
  stop_cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$template")"
  post_cmd="$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$template")"

  while IFS= read -r cmd; do
    [[ "$cmd" == *'$HIVE_MIND_HOOK'* ]] || {
      echo "command must reference \$HIVE_MIND_HOOK (not bare \$HOME): $cmd" >&2
      return 1
    }
    [[ "$cmd" != *'$HOME'* ]] || {
      echo "command must not reference bare \$HOME in the template: $cmd" >&2
      return 1
    }
  done < <(jq -r '.hooks | .[] | .[].hooks[] | .command' "$template")

  [[ "$session_cmd" == *'$ADAPTER_DIR_ARG'* ]]
  [[ "$post_cmd" == *'$ADAPTER_DIR_ARG'* ]]
  [[ "$stop_cmd" = '$HIVE_MIND_HOOK claude-code stop' ]]
}

@test "install_hooks renders an absolute hivemind-hook path" {
  mkdir -p "$ADAPTER_DIR"

  adapter_install_hooks

  local cmd
  cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$ADAPTER_DIR/settings.json")"

  [[ "$cmd" =~ ^\"[^\"]*hivemind-hook(\.exe)?\"[[:space:]]claude-code[[:space:]]stop$ ]] || {
    echo "installed settings.json Stop command must begin with a quoted hivemind-hook executable, got: $cmd" >&2
    return 1
  }

  if command -v cygpath >/dev/null 2>&1; then
    [[ "$cmd" =~ ^\"[A-Za-z]:/ ]] || {
      echo "on Windows, installed settings.json Stop command must use an absolute path (drive letter), got: $cmd" >&2
      return 1
    }
  fi
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
  local skill="${ADAPTER_ROOT}/skills/hive-mind-claude/content.md"
  [ -f "$skill" ]
  head -1 "$skill" | grep -q '^---$'
}

# === Migration =============================================================

@test "adapter_migrate rewrites old scripts/ and core/ paths to the hub topology" {
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

  # Neither the old scripts/ nor the 0.2 per-adapter core/ form may survive.
  run grep 'hive-mind/scripts/' "$ADAPTER_DIR/settings.json"
  [ "$status" -ne 0 ]
  run grep '\.claude/hive-mind/core/sync\.sh' "$ADAPTER_DIR/settings.json"
  [ "$status" -ne 0 ]
  # Stop promoted to the hub entry point.
  grep -q '\.hive-mind/bin/sync' "$ADAPTER_DIR/settings.json"
  # Helper-script hooks (SessionStart's check-dupes) relocated under the hub.
  grep -q '\.hive-mind/hive-mind/core/check-dupes\.sh' "$ADAPTER_DIR/settings.json"
}

@test "adapter_migrate promotes existing hub-topology SessionStart commands to include bin/sync" {
  # Regression: a v0.3.0-alpha install (say, an early adopter's
  # machine from before this commit landed) already has hub-topology
  # paths for SessionStart — migrate's sed rules no longer fire on
  # them. But the command lacks the bin/sync prefix the README now
  # promises, so a new session on that machine wouldn't pull fresh
  # memory. The jq post-pass in adapter_migrate targets exactly
  # this form: SessionStart command references hub check-dupes but
  # not bin/sync, so it needs the bin/sync prefix added.
  mkdir -p "$ADAPTER_DIR"
  cat > "$ADAPTER_DIR/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type":"command","command":"cd \"$HOME/.claude\" && \"$HOME/.hive-mind/hive-mind/core/check-dupes.sh\" || true","timeout":10}]}],
    "Stop": [{"hooks": [{"type":"command","command":"\"$HOME/.hive-mind/bin/sync\""}]}]
  }
}
EOF

  adapter_migrate "0.3.0"

  # After migrate, SessionStart command now runs bin/sync AND still runs check-dupes,
  # with bin/sync first.
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ADAPTER_DIR/settings.json")"
  [[ "$cmd" == *'.hive-mind/bin/sync'* ]]
  [[ "$cmd" == *'hive-mind/core/check-dupes.sh'* ]]
  # Timeout bumped from 10 to 30 (sync + check-dupes needs more headroom).
  timeout="$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$ADAPTER_DIR/settings.json")"
  [ "$timeout" = "30" ]

  # Stop hook unchanged (no promotion needed, already has bin/sync).
  stop_cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$ADAPTER_DIR/settings.json")"
  [ "$stop_cmd" = '"$HOME/.hive-mind/bin/sync"' ]
}

@test "adapter_migrate is idempotent on the hub-topology form" {
  mkdir -p "$ADAPTER_DIR"
  cat > "$ADAPTER_DIR/settings.json" <<'SETTINGS'
{
  "hooks": {
    "Stop": [{"hooks": [{"command": "\"$HOME/.hive-mind/bin/sync\""}]}]
  }
}
SETTINGS

  local before
  before="$(cat "$ADAPTER_DIR/settings.json")"

  adapter_migrate "0.3.0"

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

@test "install_hooks renders ADAPTER_DIR into launcher args for custom install path" {
  custom="$HOME/alt-claude-dir"
  ADAPTER_DIR="$custom"
  ADAPTER_GLOBAL_MEMORY="$custom/CLAUDE.md"
  mkdir -p "$custom"

  adapter_install_hooks

  if command -v cygpath >/dev/null 2>&1; then
    custom_expected="$(cygpath -m "$custom")"
  else
    custom_expected="$custom"
  fi

  sess_cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$custom/settings.json")"
  post_cmd="$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$custom/settings.json")"
  [[ "$sess_cmd" == *"session-start \"$custom_expected\""* ]]
  [[ "$post_cmd" == *"post-tool-use \"$custom_expected\""* ]]
  [[ "$sess_cmd" != *'$HOME/.claude'* ]]
  [[ "$post_cmd" != *'$HOME/.claude'* ]]
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

# === hook command strings are space-safe ===================================

@test "adapter_migrate upgrades unquoted tilde form to hub-topology paths" {
  # An existing install may carry the earlier unquoted-tilde form in
  # settings.json. Migration must rewrite both the Stop hook command
  # (now the hub's bin/sync) AND the SessionStart cd+chain (helpers
  # now live under the hub) to the quoted-\$HOME form so users on
  # spaces-in-home-dir machines get fixed on the next setup.sh run,
  # not just new installs.
  mkdir -p "$ADAPTER_DIR"
  cat > "$ADAPTER_DIR/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"command": "cd ~/.claude && { ~/.claude/hive-mind/core/check-dupes.sh; }"}]}],
    "Stop": [{"hooks": [{"command": "~/.claude/hive-mind/core/sync.sh"}]}]
  }
}
EOF

  adapter_migrate "0.1.0"

  stop_cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$ADAPTER_DIR/settings.json")"
  [ "$stop_cmd" = '"$HOME/.hive-mind/bin/sync"' ]

  sess_cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ADAPTER_DIR/settings.json")"
  [[ "$sess_cmd" = *'cd "$HOME/.claude"'* ]]
  [[ "$sess_cmd" = *'"$HOME/.hive-mind/hive-mind/core/check-dupes.sh"'* ]]
}

@test "install_hooks replaces legacy direct shell hooks and preserves non-command hook entries" {
  mkdir -p "$ADAPTER_DIR"
  cat > "$ADAPTER_DIR/settings.json" <<'SETTINGS'
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type":"command","command":"\"$HOME/.hive-mind/bin/sync\" 2>>\"$HOME/.hive-mind/.sync-error.log\" || true; \"$HOME/.hive-mind/hive-mind/core/check-dupes.sh\" 2>>\"$HOME/.claude/.sync-error.log\" || true"}]},
      {"hooks": [{"type":"prompt","prompt":"Is this a clean start? $ARGUMENTS"}]}
    ],
    "Stop": [{"hooks": [{"type":"command","command":"\"$HOME/.hive-mind/bin/sync\""}]}],
    "PostToolUse": [
      {"matcher": "Edit|Write|NotebookEdit",
       "hooks": [{"type":"command","command":"\"$HOME/.hive-mind/hive-mind/core/marker-nudge.sh\""}]}
    ]
  }
}
SETTINGS

  before="$(cat "$ADAPTER_DIR/settings.json")"

  adapter_install_hooks

  after="$(cat "$ADAPTER_DIR/settings.json")"
  [ "$before" != "$after" ]
  run grep -q 'hivemind-hook' "$ADAPTER_DIR/settings.json"
  [ "$status" -eq 0 ]
  run grep -q '\.hive-mind/bin/sync' "$ADAPTER_DIR/settings.json"
  [ "$status" -ne 0 ]
  run grep -q 'check-dupes\.sh' "$ADAPTER_DIR/settings.json"
  [ "$status" -ne 0 ]
  run grep -q 'marker-nudge\.sh' "$ADAPTER_DIR/settings.json"
  [ "$status" -ne 0 ]
  # Prompt-type hook survived.
  jq -e '.hooks.SessionStart[] | select(.hooks[0].type == "prompt")' "$ADAPTER_DIR/settings.json" >/dev/null
}

@test "install_hooks is idempotent once hivemind-hook commands are present" {
  mkdir -p "$ADAPTER_DIR"

  adapter_install_hooks
  before="$(cat "$ADAPTER_DIR/settings.json")"
  adapter_install_hooks
  after="$(cat "$ADAPTER_DIR/settings.json")"

  [ "$before" = "$after" ]
}

@test "install_hooks self-heals when a required hook event was deleted" {
  # Upgrade path runs install_hooks on existing settings.json. If the
  # user or a buggy previous install removed one of the hook events
  # (e.g. Stop), re-running install_hooks must put it back -- partial
  # installs are worse than clean ones.
  mkdir -p "$ADAPTER_DIR"
  adapter_install_hooks
  local tmp
  tmp="$(mktemp)"
  jq 'del(.hooks.Stop)' "$ADAPTER_DIR/settings.json" > "$tmp"
  mv "$tmp" "$ADAPTER_DIR/settings.json"

  adapter_install_hooks

  [ "$(jq '.hooks.Stop | length' "$ADAPTER_DIR/settings.json")" -gt 0 ]
}

# === hub mapping ===========================================================

@test "hub mapping keeps Claude hooks and permissions out of ADAPTER_HUB_MAP" {
  ! printf '%s\n' "$ADAPTER_HUB_MAP" | grep -Fq 'settings.json#hooks'
  ! printf '%s\n' "$ADAPTER_HUB_MAP" | grep -Fq 'settings.json#permissions.'
  ! printf '%s\n' "$ADAPTER_HUB_MAP" | grep -Fq 'config/hooks'
  ! printf '%s\n' "$ADAPTER_HUB_MAP" | grep -Fq 'config/permissions'
}
