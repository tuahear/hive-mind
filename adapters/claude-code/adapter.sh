#!/usr/bin/env bash
# Claude Code adapter for hive-mind.
# Implements the full capability surface defined in the adapter shell contract.

set -euo pipefail

# --- A. Identity & location ------------------------------------------------
ADAPTER_API_VERSION="1.0.0"
ADAPTER_VERSION="0.1.0"
ADAPTER_NAME="claude-code"
ADAPTER_DIR="${HOME}/.claude"
ADAPTER_MEMORY_MODEL="flat"
ADAPTER_GLOBAL_MEMORY="${ADAPTER_DIR}/CLAUDE.md"
ADAPTER_PROJECT_MEMORY_DIR="${ADAPTER_DIR}/projects/{encoded_cwd}/memory"

adapter_list_memory_files() { :; }  # flat model — unused

# --- B. Files & sync rules -------------------------------------------------
ADAPTER_GITIGNORE_TEMPLATE="${ADAPTER_ROOT}/gitignore"
ADAPTER_GITATTRIBUTES_TEMPLATE="${ADAPTER_ROOT}/gitattributes"
ADAPTER_SECRET_FILES=""
ADAPTER_MARKER_TARGETS=$'CLAUDE.md\nprojects/*/memory/*\nprojects/*/MEMORY.md\nskills/*\nskills/**/*.md'

# --- C. Lifecycle touchpoints ----------------------------------------------
ADAPTER_HAS_HOOK_SYSTEM=true
ADAPTER_EVENT_SESSION_START="SessionStart"
ADAPTER_EVENT_TURN_END="Stop"
ADAPTER_EVENT_POST_EDIT="PostToolUse"

adapter_install_hooks() {
  local settings="$ADAPTER_DIR/settings.json"
  local template="${ADAPTER_ROOT}/settings.json"
  [ -f "$template" ] || return 1

  mkdir -p "$ADAPTER_DIR"

  if [ ! -f "$settings" ]; then
    cp "$template" "$settings"
    return 0
  fi

  # Idempotent: check whether every required hook event is already
  # present with a hive-mind/core/ command. If any are missing, merge
  # the template so partial installs (e.g. user manually deleted the
  # Stop hook) get repaired on re-run.
  local all_present=1
  local event
  for event in SessionStart Stop PostToolUse; do
    if ! jq -e --arg e "$event" '
      (.hooks[$e] // []) | map(.hooks[]? | select(.command | test("hive-mind/core/"))) | length > 0
    ' "$settings" >/dev/null 2>&1; then
      all_present=0
      break
    fi
  done
  if [ "$all_present" -eq 1 ]; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  # Concatenate hook event arrays instead of replacing them -- jq's `*`
  # operator overwrites arrays, which would drop user-defined hooks on
  # the same event (e.g. a user's custom Stop hook). For each event we
  # know about, append the template's entries only if they aren't
  # already present (match by command string so re-running is a no-op).
  jq -s '
    .[0] as $user | .[1] as $new
    # Scalar / object keys: deep-merge, new wins.
    | ($user * $new) as $base
    # Rebuild hooks by walking every template event and concatenating.
    | . = $base
    | .hooks = (($user.hooks // {}) as $uh | ($new.hooks // {}) as $nh |
        ($uh | keys) + ($nh | keys) | unique
        | map({(.): (
            ($uh[.] // []) as $ue | ($nh[.] // []) as $ne
            # For each new entry, only append if no existing matcher/command combo matches.
            | $ue + ($ne | map(
                . as $newEntry
                | if any($ue[]; (.matcher // "") == ($newEntry.matcher // "") and
                                ((.hooks // []) | map(.command // "") | any(. as $c | $newEntry.hooks[]? | .command == $c)))
                  then empty else $newEntry end
              ))
          )}) | add)
    # Only union permissions.allow when at least one side actually has
    # an allow list -- otherwise we would write an empty permissions.allow
    # array into a user settings.json that previously had no permissions
    # block at all (drift the user did not ask for).
    | if ($user.permissions.allow // $new.permissions.allow) != null then
        .permissions.allow = (
          (($user.permissions.allow // []) + ($new.permissions.allow // [])) | unique
        )
      else . end
  ' "$settings" "$template" > "$tmp" 2>/dev/null && mv "$tmp" "$settings"
}

adapter_uninstall_hooks() {
  local settings="$ADAPTER_DIR/settings.json"
  [ -f "$settings" ] || return 0

  # Remove hive-mind hook entries by filtering out commands that reference
  # the specific hive-mind install path. Narrower than a plain "hive-mind"
  # substring match so user-defined hooks that happen to reference a
  # different hive-mind (a repo path, for instance) aren't removed.
  local tmp
  tmp="$(mktemp)"
  if jq '
    if .hooks then
      .hooks |= with_entries(
        .value |= map(
          if .hooks then
            # Guard against hook entries missing a `.command` field (prompt
            # hooks, agent hooks, or any other non-command schema). Treat
            # missing/null command as a non-match -- we only want to
            # remove hive-mind command hooks, nothing else.
            .hooks |= map(select((.command // "") | test("(~/\\.claude|\\$HOME/\\.claude)/hive-mind/(core|scripts)/") | not))
          else . end
          | select((.hooks // []) | length > 0)
        )
      )
      | if (.hooks | keys | length) == 0 then del(.hooks) else . end
    else . end
  ' "$settings" > "$tmp" 2>/dev/null; then
    # If only empty hooks remain (no user content), remove the file.
    local remaining
    remaining="$(jq 'del(.hooks) | length' "$tmp" 2>/dev/null)"
    local hook_count
    hook_count="$(jq '[.hooks // {} | .[] | .[]] | length' "$tmp" 2>/dev/null)"
    if [ "${remaining:-0}" = "0" ] && [ "${hook_count:-0}" = "0" ]; then
      rm -f "$tmp" "$settings"
    else
      mv "$tmp" "$settings"
    fi
  else
    rm -f "$tmp"
  fi
}

# --- D. Skills (optional) --------------------------------------------------
ADAPTER_SKILL_ROOT="${ADAPTER_DIR}/skills"
ADAPTER_SKILL_FORMAT="markdown-frontmatter"

# --- E. Settings merge -----------------------------------------------------
ADAPTER_SETTINGS_MERGE_BINDINGS=$'settings.json jsonmerge'

# Optional: per-driver env vars to inject when registering merge drivers
# in the local .git/config. Newline-separated lines of the form
# "<driver>:<KEY=val KEY2=val2>". setup.sh prepends the env-prefix to
# the registered driver command. Example for a TOML adapter (Codex):
#   ADAPTER_MERGE_DRIVER_ENV=$'tomlmerge:TOMLMERGE_UNION_KEYS=permissions.allow,permissions.deny'
# Claude Code uses jsonmerge which has its union list baked into the
# script, so no env is needed here.
ADAPTER_MERGE_DRIVER_ENV=""

# --- F. User education -----------------------------------------------------
adapter_activation_instructions() {
  echo "Open /hooks in Claude Code once (or start a fresh session) so the"
  echo "settings watcher picks up the SessionStart + Stop hooks."
}

adapter_disable_instructions() {
  echo "To temporarily disable hive-mind sync, remove the hook entries from"
  echo "~/.claude/settings.json, or disconnect the git remote:"
  echo "  cd ~/.claude && git remote remove origin"
}

# --- G. Fallback -----------------------------------------------------------
ADAPTER_FALLBACK_STRATEGY=""  # not needed — Claude Code has hooks

# --- H. Logging ------------------------------------------------------------
ADAPTER_LOG_PATH="${ADAPTER_DIR}/.sync-error.log"

# --- Healthcheck -----------------------------------------------------------
adapter_healthcheck() {
  # Require the `claude` binary on PATH OR a populated Claude install
  # (settings.json or CLAUDE.md present — means Claude has been run
  # here at least once, even if uninstalled since). A bare empty
  # ~/.claude dir alone is not enough — that catches leftover state
  # from an uninstalled tool, which detect_adapters would otherwise
  # misreport as "claude-code is available".
  if command -v claude >/dev/null 2>&1; then
    return 0
  fi
  [ -f "$ADAPTER_DIR/settings.json" ] || [ -f "$ADAPTER_DIR/CLAUDE.md" ]
}

# --- Migration (optional) --------------------------------------------------
# Migrate from pre-refactor layout. Rewrites hook command strings that
# reference the old scripts/ paths to use the new core/ paths.
adapter_migrate() {
  local from_version="${1:-}"
  local settings="$ADAPTER_DIR/settings.json"
  [ -f "$settings" ] || return 0

  # Rewrite old hook command paths:
  # 1) scripts/<file>.sh -> core/<file>.sh        (refactor move)
  # 2) ~/.claude/hive-mind/core/<file>.sh ->
  #    \"\$HOME/.claude/hive-mind/core/<file>.sh\" (space-safe quoting)
  # The literal \\\" in the sed replacement emits a backslash-escaped
  # double quote into the JSON string, preserving JSON validity.
  # Both regexes are idempotent: a settings.json already on the new
  # form is unchanged (substitutions don't find their old patterns).
  local tmp
  tmp="$(mktemp)"
  if sed \
    -e 's|hive-mind/scripts/sync\.sh|hive-mind/core/sync.sh|g' \
    -e 's|hive-mind/scripts/check-dupes\.sh|hive-mind/core/check-dupes.sh|g' \
    -e 's|hive-mind/scripts/marker-nudge\.sh|hive-mind/core/marker-nudge.sh|g' \
    -e 's|hive-mind/scripts/jsonmerge\.sh|hive-mind/core/jsonmerge.sh|g' \
    -e 's|hive-mind/scripts/mirror-projects\.sh|hive-mind/core/mirror-projects.sh|g' \
    -e 's|cd ~/\.claude |cd \\"$HOME/.claude\\" |g' \
    -e 's|~/\.claude/hive-mind/core/sync\.sh|\\"$HOME/.claude/hive-mind/core/sync.sh\\"|g' \
    -e 's|~/\.claude/hive-mind/core/check-dupes\.sh|\\"$HOME/.claude/hive-mind/core/check-dupes.sh\\"|g' \
    -e 's|~/\.claude/hive-mind/core/marker-nudge\.sh|\\"$HOME/.claude/hive-mind/core/marker-nudge.sh\\"|g' \
    -e 's|~/\.claude/hive-mind/core/mirror-projects\.sh|\\"$HOME/.claude/hive-mind/core/mirror-projects.sh\\"|g' \
    "$settings" > "$tmp"; then
    if ! cmp -s "$settings" "$tmp"; then
      mv "$tmp" "$settings"
    else
      rm -f "$tmp"
    fi
  else
    rm -f "$tmp"
  fi
}
