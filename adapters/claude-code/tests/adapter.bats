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

@test "settings.json SessionStart hook invokes the hub sync before check-dupes (pulls fresh memory at session start)" {
  # README.md promises "Quietly pulled when your AI starts a session."
  # That's a deliberate UX guarantee: on a second machine, a new
  # Claude session must see cross-machine memory from the hub remote
  # immediately, not only after the first Stop hook fires mid-session.
  # Pin that the SessionStart hook runs the hub entry point (which
  # pulls + fans out) BEFORE check-dupes so the tool dir is fresh
  # when check-dupes scans it, and before the user's first turn reads
  # memory. If a future refactor drops bin/sync from SessionStart, the
  # promise silently regresses.
  local template="${ADAPTER_ROOT}/settings.json"
  local cmd
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$template")"
  [[ "$cmd" == *'.hive-mind/bin/sync'* ]]
  [[ "$cmd" == *'hive-mind/core/check-dupes.sh'* ]]
  # bin/sync runs FIRST (position in the command string — before
  # check-dupes). A reversed order would run check-dupes against
  # stale memory, then pull, then the user sees stale content in
  # their first turn.
  local sync_pos dupes_pos
  sync_pos="$(awk -v s="$cmd" -v t='.hive-mind/bin/sync' 'BEGIN{print index(s,t)}')"
  dupes_pos="$(awk -v s="$cmd" -v t='hive-mind/core/check-dupes.sh' 'BEGIN{print index(s,t)}')"
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

@test "settings.json hook commands reference the hub bin/sync and hive-mind/core/ helpers" {
  # v0.3.0 hub topology: Stop hook fires the single hub entry
  # ($HIVE_MIND_HUB_DIR/bin/sync); SessionStart and PostToolUse still
  # run per-adapter helpers that now live under the hub at
  # $HIVE_MIND_HUB_DIR/hive-mind/core/. The pre-0.3 `hive-mind/scripts/`
  # form and the 0.2 `~/.claude/hive-mind/core/sync.sh` form are both
  # dead in templates — adapter_migrate rewrites any such hook on
  # upgrade, so the template itself must never carry them.
  local template="${ADAPTER_ROOT}/settings.json"
  run grep -c 'hive-mind/scripts/' "$template"
  [ "$output" = "0" ]
  run grep -c '\.claude/hive-mind/core/' "$template"
  [ "$output" = "0" ]
  grep -q '\.hive-mind/bin/sync' "$template"
  grep -q '\.hive-mind/hive-mind/core/' "$template"
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

@test "settings.json template uses quoted \$HOME form (survives spaces in home dir)" {
  # A home directory containing spaces (e.g. /c/Users/Jane Doe on Windows
  # Git Bash) would word-split an unquoted ~/.hive-mind path at shell
  # parse time and break hook execution. Every command string in the
  # template must use "\$HOME/.hive-mind/..." with quotes.
  local template="${ADAPTER_ROOT}/settings.json"
  while IFS= read -r cmd; do
    [[ "$cmd" = *'"$HOME/.hive-mind'* ]] || {
      echo "command missing quoted \$HOME/.hive-mind: $cmd" >&2
      return 1
    }
  done < <(jq -r '.hooks | .[] | .[].hooks[] | .command' "$template")

  # And NO unquoted tilde form anywhere in the template.
  run grep -E '~/\.hive-mind' "$template"
  [ "$status" -ne 0 ]
}

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

# === install_hooks preserves user settings ==================================

@test "install_hooks does not add empty permissions.allow when neither side has one" {
  # Writing permissions.allow=[] into a user's settings.json that had
  # no permissions block at all is silent drift the user didn't ask
  # for. The jq merge guards the union behind a check that at least
  # one side has a non-null allow list.
  mkdir -p "$ADAPTER_DIR"
  echo '{"model":"opus"}' > "$ADAPTER_DIR/settings.json"

  adapter_install_hooks

  # The .permissions key should be ABSENT (neither user nor template had one).
  run jq -e 'has("permissions")' "$ADAPTER_DIR/settings.json"
  [ "$status" -ne 0 ]
}

@test "install_hooks preserves user's permissions.allow when present" {
  mkdir -p "$ADAPTER_DIR"
  echo '{"permissions":{"allow":["Bash(npm test)"]}}' > "$ADAPTER_DIR/settings.json"

  adapter_install_hooks

  jq -e '.permissions.allow | index("Bash(npm test)")' "$ADAPTER_DIR/settings.json" >/dev/null
}

@test "install_hooks idempotency probe tolerates non-command hook entries (prompt / agent / http)" {
  # Regression: the presence check previously used `.command | test(...)`
  # on every hook entry. A user's settings.json can legitimately carry
  # non-command hooks — type=="prompt", type=="agent", type=="http" —
  # none of which have a `.command` field. Under jq, `null | test(...)`
  # errors out and the probe treats the event as missing, so
  # install_hooks runs the merge branch every invocation instead of
  # short-circuiting. Pin the `(.command // "")` guard.
  mkdir -p "$ADAPTER_DIR"
  # Pre-seed a settings.json that has the canonical hive-mind hooks
  # AND a user-added prompt-type hook on one of the same events.
  # After install_hooks runs, the prompt hook must survive AND the
  # idempotency check must NOT have silently re-merged the template
  # (detectable: re-running install_hooks on a prompt-hook-containing
  # config that already has all hive-mind hooks should leave the file
  # byte-identical).
  cat > "$ADAPTER_DIR/settings.json" <<'SETTINGS'
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type":"command","command":"\"$HOME/.hive-mind/hive-mind/core/check-dupes.sh\""}]},
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
  # Idempotent: all hive-mind hooks were already present, so the
  # probe must have short-circuited and NOT rewritten the file. A
  # bare `.command | test(...)` would jq-error on the prompt entry,
  # return false for the event, and fall into the merge branch.
  [ "$before" = "$after" ]
  # Prompt-type hook survived.
  jq -e '.hooks.SessionStart[] | select(.hooks[0].type == "prompt")' "$ADAPTER_DIR/settings.json" >/dev/null
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
