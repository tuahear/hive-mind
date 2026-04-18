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

@test "SessionStart hook template dispatches via the native hivemind-hook launcher" {
  # The template now exposes a single native-launcher entrypoint. The
  # launcher owns the shell hop internally; hooks.json itself stays free
  # of direct bash/script-path dispatch details.
  template="$ADAPTER_ROOT/hooks.json"
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$template")"
  [ "$cmd" = '$HIVE_MIND_HOOK session-start $ADAPTER_DIR_ARG' ]
}

@test "session-start wrapper script itself invokes sync before check-dupes with Codex env" {
  script="$REPO_ROOT/core/hub/codex-hook-session-start.sh"
  [ -f "$script" ]
  body="$(cat "$script")"
  [[ "$body" == *'HUB_DIR/bin/sync'* ]]
  [[ "$body" == *'hive-mind/core/check-dupes.sh'* ]]
  [[ "$body" == *'ADAPTER_DIR='* ]]
  [[ "$body" == *'ADAPTER_GLOBAL_MEMORY='* ]]
  sync_pos="$(awk -v s="$body" -v t='HUB_DIR/bin/sync' 'BEGIN{print index(s,t)}')"
  dupes_pos="$(awk -v s="$body" -v t='hive-mind/core/check-dupes.sh' 'BEGIN{print index(s,t)}')"
  [ "$sync_pos" -gt 0 ]
  [ "$dupes_pos" -gt 0 ]
  [ "$sync_pos" -lt "$dupes_pos" ]
}

@test "stop wrapper script runs sync and emits JSON" {
  script="$REPO_ROOT/core/hub/codex-hook-stop.sh"
  [ -f "$script" ]
  body="$(cat "$script")"
  [[ "$body" == *'HUB_DIR/bin/sync'* ]]
  [[ "$body" == *"printf '{}'"* ]]
}

@test "install_hooks renders an absolute hivemind-hook path" {
  # install_hooks renders a concrete hivemind-hook path into hooks.json
  # so Codex never has to expand env vars or PATH-dependent launcher
  # names at hook-dispatch time.
  mkdir -p "$ADAPTER_DIR"
  adapter_install_hooks

  local cmd
  cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$ADAPTER_DIR/hooks.json")"

  # Must start with a quoted hivemind-hook executable path.
  [[ "$cmd" =~ ^\"[^\"]*hivemind-hook(\.exe)?\"[[:space:]]stop$ ]] || {
    echo "installed hooks.json Stop command must begin with a quoted hivemind-hook executable, got: $cmd" >&2
    return 1
  }

  # On Windows the rendered launcher path should be drive-qualified.
  if command -v cygpath >/dev/null 2>&1; then
    [[ "$cmd" =~ ^\"[A-Za-z]:/ ]] || {
      echo "on Windows, installed hooks.json Stop command must use an absolute path (drive letter), got: $cmd" >&2
      return 1
    }
  fi
}

@test "hooks.json template dispatches only through hivemind-hook (no inline shell)" {
  # Earlier designs embedded full shell logic (sync + check-dupes +
  # JSON-emit) inline in each hooks.json command string. That failed
  # repeatedly on Windows because Codex's hook runner + PowerShell
  # strip or mangle inner quotes before bash sees them. The current
  # design keeps hooks.json down to a single launcher token plus argv.
  # No inline shell syntax, no direct wrapper-script references, no
  # quoting lottery downstream.
  template="$ADAPTER_ROOT/hooks.json"
  while IFS= read -r cmd; do
    [[ "$cmd" == '$HIVE_MIND_HOOK '* ]] || {
      echo "hook command must start with the \$HIVE_MIND_HOOK token: $cmd" >&2
      return 1
    }
    [[ "$cmd" != *'bash '* ]] || {
      echo "hook command must not dispatch bash directly: $cmd" >&2
      return 1
    }
    [[ "$cmd" != *'codex-hook-'*'.sh'* ]] || {
      echo "hook command must not mention wrapper scripts directly: $cmd" >&2
      return 1
    }
    # Guard against regression to inline shell syntax — the whole point
    # of the wrapper-script indirection is that NONE of these appear in
    # the template-level command.
    [[ "$cmd" != *'||'* ]] || { echo "command must not contain '||' — move to wrapper: $cmd" >&2; return 1; }
    [[ "$cmd" != *';'* ]]  || { echo "command must not contain ';' — move to wrapper: $cmd" >&2; return 1; }
    [[ "$cmd" != *'\"'* ]] || { echo "command must not embed \\\" — PowerShell strips inner quotes: $cmd" >&2; return 1; }
    [[ "$cmd" != *'printf'* ]] || { echo "command must not call printf directly — move to wrapper: $cmd" >&2; return 1; }
  done < <(jq -r '.hooks | .[] | .[].hooks[] | .command' "$template")
}

@test "hooks.json template references launcher and adapter-dir tokens" {
  # install_hooks substitutes the launcher path and custom adapter dir at
  # render time. The template must use those tokens rather than bare
  # $HOME references, whose expansion depends on Codex's dispatcher.
  template="$ADAPTER_ROOT/hooks.json"
  session_cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$template")"
  stop_cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$template")"
  while IFS= read -r cmd; do
    [[ "$cmd" == *'$HIVE_MIND_HOOK'* ]] || {
      echo "command must reference \$HIVE_MIND_HOOK (not bare \$HOME): $cmd" >&2
      return 1
    }
    [[ "$cmd" != *'$HOME'* ]] || {
      echo "command must not reference bare \$HOME — use tokens substituted at install time: $cmd" >&2
      return 1
    }
  done < <(jq -r '.hooks | .[] | .[].hooks[] | .command' "$template")
  [[ "$session_cmd" == *'$ADAPTER_DIR_ARG'* ]]
  [[ "$stop_cmd" == '$HIVE_MIND_HOOK stop' ]]

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

@test "install_hooks replaces legacy hive-mind commands and preserves non-command hook entries" {
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

  [ "$before" != "$after" ]
  run grep -q 'hivemind-hook' "$ADAPTER_DIR/hooks.json"
  [ "$status" -eq 0 ]
  run grep -q '\.hive-mind/bin/sync' "$ADAPTER_DIR/hooks.json"
  [ "$status" -ne 0 ]
  jq -e '.hooks.SessionStart[] | select(.hooks[0].type == "prompt")' "$ADAPTER_DIR/hooks.json" >/dev/null
}

@test "install_hooks is idempotent once hivemind-hook commands are present" {
  mkdir -p "$ADAPTER_DIR"

  adapter_install_hooks
  before="$(cat "$ADAPTER_DIR/hooks.json")"
  adapter_install_hooks
  after="$(cat "$ADAPTER_DIR/hooks.json")"

  [ "$before" = "$after" ]
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

  if command -v cygpath >/dev/null 2>&1; then
    custom_expected="$(cygpath -m "$custom")"
  else
    custom_expected="$custom"
  fi
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$custom/hooks.json")"
  [[ "$cmd" == *"session-start \"$custom_expected\""* ]]
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

  if command -v cygpath >/dev/null 2>&1; then
    custom_expected="$(cygpath -m "$custom")"
  else
    custom_expected="$custom"
  fi
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$custom/hooks.json")"
  [[ "$cmd" == *"session-start \"$custom_expected\""* ]]
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
  run grep -q 'hivemind-hook' "$ADAPTER_DIR/hooks.json"
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

@test "hub mapping: codex hooks.json is NOT in ADAPTER_HUB_MAP (avoid cross-shell contamination)" {
  # The hub's `config/hooks/` bucket is the same directory every adapter
  # that has `config/hooks\t...` in its map writes into AND reads out of.
  # If Codex mapped its hooks.json through that bucket, Claude's
  # Bash-syntax hook commands (PostToolUse / Notification / ...) would
  # end up in Codex's hooks.json on every fan-out, where Codex executes
  # them under PowerShell on Windows and they fail to parse.
  #
  # Contract: Codex manages its own hooks.json locally via
  # adapter_install_hooks. hooks.json must NOT appear as a tool target
  # in ADAPTER_HUB_MAP.
  ! printf '%s\n' "$ADAPTER_HUB_MAP" | grep -Fq 'hooks.json'
  ! printf '%s\n' "$ADAPTER_HUB_MAP" | grep -Fq 'config/hooks'
}

@test "hub mapping: fan-out never populates codex hooks.json with foreign-adapter events" {
  # Direct regression guard for the cross-shell contamination the
  # previous test encodes as a contract: simulate a hub that already
  # contains Claude-style events (e.g. PostToolUse) under
  # config/hooks/, then fan-out for codex and confirm none of those
  # leak into ~/.codex/hooks.json.
  TOOL="$HOME/tool"
  HUB="$HOME/hub"
  mkdir -p "$TOOL" "$HUB"

  ADAPTER_DIR="$TOOL"
  export ADAPTER_DIR
  source "$LOADER"
  load_adapter "codex"
  # shellcheck source=/dev/null
  source "$HARVEST_FANOUT"

  # Seed the hub with Claude-style hook entries in config/hooks/.
  mkdir -p "$HUB/config/hooks/PostToolUse" "$HUB/config/hooks/Notification"
  printf '{"hooks":[{"type":"command","command":"bash-syntax && would-fail-in-powershell"}]}' \
    > "$HUB/config/hooks/PostToolUse/entry.json"
  printf '{"hooks":[{"type":"command","command":"echo notif"}]}' \
    > "$HUB/config/hooks/Notification/entry.json"

  # Seed Codex's own hooks.json with the expected SessionStart + Stop.
  cat > "$TOOL/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "codex-session-cmd"}]}],
    "Stop":         [{"hooks": [{"type": "command", "command": "codex-stop-cmd"}]}]
  }
}
EOF

  hub_fan_out "$HUB" "$TOOL"

  # Fan-out must not have injected the hub's Claude events into Codex's file.
  run jq -e '.hooks | has("PostToolUse") or has("Notification")' "$TOOL/hooks.json"
  [ "$status" -ne 0 ]

  # Codex's own hooks survive unchanged.
  jq -e '.hooks.SessionStart[0].hooks[0].command == "codex-session-cmd"' "$TOOL/hooks.json" >/dev/null
  jq -e '.hooks.Stop[0].hooks[0].command == "codex-stop-cmd"' "$TOOL/hooks.json" >/dev/null
}
