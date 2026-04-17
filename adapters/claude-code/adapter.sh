#!/usr/bin/env bash
# Claude Code adapter for hive-mind.
# Implements the full capability surface defined in the adapter shell contract.

set -euo pipefail

# --- A. Identity & location ------------------------------------------------
ADAPTER_API_VERSION="1.0.0"
ADAPTER_VERSION="0.1.0"
ADAPTER_NAME="claude-code"
# Honor a caller-provided ADAPTER_DIR (tests, alternative installs, or
# setup.sh running with a non-default tool dir). Hardcoding would
# overwrite it, routing sync to the default location even when the
# caller meant another.
ADAPTER_DIR="${ADAPTER_DIR:-$HOME/.claude}"
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
  # present with a hive-mind command. The hub topology (v0.3.0+) routes
  # Stop through `$HOME/.hive-mind/bin/sync` and the others through
  # `$HOME/.hive-mind/hive-mind/core/...`; pre-0.3.0 installs used
  # `$HOME/.claude/hive-mind/core/...`. Match either so a partial or
  # pre-refactor install still triggers the merge-template path and
  # gets repaired on re-run.
  local all_present=1
  local event
  # The `select` uses `(.command // "")` rather than `.command` because
  # a user's settings.json can legitimately contain non-command hook
  # entries (prompt hooks, agent hooks, http hooks — none of which
  # carry a `.command` field). With a bare `.command | test(...)` jq
  # errors on the first such entry and the probe misreports "this
  # event has no hive-mind hook" for an event that does — the merge
  # branch below then runs on every invocation, wasting work on an
  # already-installed hook set.
  for event in SessionStart Stop PostToolUse; do
    if ! jq -e --arg e "$event" '
      (.hooks[$e] // []) | map(.hooks[]? | select((.command // "") | test("(\\.hive-mind/(bin/sync|hive-mind/core/)|\\.claude/hive-mind/(core|scripts)/)"))) | length > 0
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
            .hooks |= map(select((.command // "") | test("((~/\\.claude|\\$HOME/\\.claude)/hive-mind/(core|scripts)/|(~/\\.hive-mind|\\$HOME/\\.hive-mind)/(bin/sync|hive-mind/core/))") | not))
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
  echo "~/.claude/settings.json. To fully disconnect from the hub:"
  echo "  rm ~/.hive-mind/.install-state/attached-adapters"
}

# --- G. Fallback -----------------------------------------------------------
ADAPTER_FALLBACK_STRATEGY=""  # not needed — Claude Code has hooks

# --- I. Hub mapping (v0.3.0 hub topology) ---------------------------------
# Declares how the hub's provider-agnostic schema maps to Claude's
# tool-native layout. The hub sync engine reads this bidirectionally:
# harvest (tool → hub) and fan-out (hub → tool). Entries are
# newline-separated TAB-delimited pairs `<hub-path>\t<tool-rel-path>`.
# Tool paths are relative to ADAPTER_DIR ($HOME/.claude).
#
# Consumed by core/hub/harvest-fanout.sh during every sync cycle
# (harvest reads tool → hub; fan-out reads hub → tool).
ADAPTER_HUB_MAP=$'content.md\tCLAUDE.md
config/hooks\tsettings.json#hooks
config/permissions/allow.txt\tsettings.json#permissions.allow
config/permissions/deny.txt\tsettings.json#permissions.deny
config/permissions/ask.txt\tsettings.json#permissions.ask'

# Rules for hub's `projects/<id>/` subtree ↔ Claude's per-project
# layout. Hub mirrors the tool's memory/ subdir as-is; only the main
# memory file gets renamed to content.md. Two explicit rules for
# content.md because Claude stores MEMORY.md at EITHER the variant
# root or inside memory/ depending on version. ORDER MATTERS: file
# rules are last-writer-wins. The subdir rule runs first (fallback);
# the root rule runs second and overwrites when root MEMORY.md exists
# — so root content is never lost when both locations are populated.
# Fan-out writes content.md to BOTH locations.
ADAPTER_PROJECT_CONTENT_RULES=$'content.md\tmemory/MEMORY.md
content.md\tMEMORY.md
memory\tmemory'

# --- H. File harvest rules -------------------------------------------------
# Glob patterns (relative to ADAPTER_DIR) declaring which files this
# adapter syncs. Not consumed by the engine yet — reserved for future
# user-extensible sync (e.g., custom skill assets). Declared now so
# the adapter contract is complete.
ADAPTER_FILE_HARVEST_RULES=$'CLAUDE.md\nskills/**/*.md\nprojects/**/*.md'

# Project-specific subset: globs relative to ADAPTER_DIR that match
# synced per-project files. Used by variant GC to verify content is
# in the hub before deleting an orphaned variant.
ADAPTER_PROJECT_CONTENT_GLOBS=$'projects/**/*.md'

# --- I. Logging ------------------------------------------------------------
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
# Migrate hook command strings across the v0.1.x → v0.2.x → v0.3.x
# topology shifts. Idempotent: each sed substitution targets patterns
# that don't exist on the new form, so a settings.json already on the
# latest shape passes through unchanged.
#
#   v0.1 scripts/<file>.sh       -> core/<file>.sh                (refactor move)
#   v0.2 ~/.claude/hive-mind/... -> "$HOME/.claude/hive-mind/..." (space-safe quoting)
#   v0.3 ~/.claude/hive-mind/core/sync.sh -> "$HOME/.hive-mind/bin/sync"
#        (Stop hook promoted to the hub's shared entry point)
#   v0.3 ~/.claude/hive-mind/core/<other>.sh -> "$HOME/.hive-mind/hive-mind/core/<other>.sh"
#        (hive-mind source relocated under the hub)
adapter_migrate() {
  local from_version="${1:-}"
  local settings="$ADAPTER_DIR/settings.json"
  [ -f "$settings" ] || return 0

  local tmp
  tmp="$(mktemp)"
  if sed \
    -e 's|hive-mind/scripts/sync\.sh|hive-mind/core/sync.sh|g' \
    -e 's|hive-mind/scripts/check-dupes\.sh|hive-mind/core/check-dupes.sh|g' \
    -e 's|hive-mind/scripts/marker-nudge\.sh|hive-mind/core/marker-nudge.sh|g' \
    -e 's|hive-mind/scripts/jsonmerge\.sh|hive-mind/core/jsonmerge.sh|g' \
    -e 's|hive-mind/scripts/mirror-projects\.sh|hive-mind/core/mirror-projects.sh|g' \
    -e 's|cd ~/\.claude |cd \\"$HOME/.claude\\" |g' \
    -e 's|~/\.claude/hive-mind/core/sync\.sh|\\"$HOME/.hive-mind/bin/sync\\"|g' \
    -e 's|\\"\$HOME/\.claude/hive-mind/core/sync\.sh\\"|\\"$HOME/.hive-mind/bin/sync\\"|g' \
    -e 's|~/\.claude/hive-mind/core/check-dupes\.sh|\\"$HOME/.hive-mind/hive-mind/core/check-dupes.sh\\"|g' \
    -e 's|\\"\$HOME/\.claude/hive-mind/core/check-dupes\.sh\\"|\\"$HOME/.hive-mind/hive-mind/core/check-dupes.sh\\"|g' \
    -e 's|~/\.claude/hive-mind/core/marker-nudge\.sh|\\"$HOME/.hive-mind/hive-mind/core/marker-nudge.sh\\"|g' \
    -e 's|\\"\$HOME/\.claude/hive-mind/core/marker-nudge\.sh\\"|\\"$HOME/.hive-mind/hive-mind/core/marker-nudge.sh\\"|g' \
    -e 's|~/\.claude/hive-mind/core/mirror-projects\.sh|\\"$HOME/.hive-mind/hive-mind/core/mirror-projects.sh\\"|g' \
    -e 's|\\"\$HOME/\.claude/hive-mind/core/mirror-projects\.sh\\"|\\"$HOME/.hive-mind/hive-mind/core/mirror-projects.sh\\"|g' \
    "$settings" > "$tmp"; then
    if ! cmp -s "$settings" "$tmp"; then
      mv "$tmp" "$settings"
    else
      rm -f "$tmp"
    fi
  else
    rm -f "$tmp"
  fi

  # SessionStart hook needs bin/sync prefix. Pre-0.3 installs that
  # made it through the path rewrites above still carry the original
  # check-dupes-only form — no pull, no fan-out, so new sessions on a
  # second machine don't see cross-machine memory until the first Stop
  # hook fires mid-session. README promises "pulled when your AI
  # starts a session"; honor that promise on upgrade by prepending a
  # bin/sync call to any SessionStart command that references the
  # hub's check-dupes path but not bin/sync.
  #
  # Gated behind a detection pass (jq -e returns 0 only if at least
  # one command matches) so the transformation pass is skipped when
  # nothing needs promotion. jq's pretty-printing otherwise rewrites
  # the file on every invocation, violating idempotency.
  if jq -e '
      (.hooks.SessionStart // []) | any(
        .hooks[]? |
          ((.command // "") | test("hive-mind/hive-mind/core/check-dupes\\.sh"))
          and
          ((.command // "") | test("hive-mind/bin/sync") | not)
      )
    ' "$settings" >/dev/null 2>&1; then
    local jq_tmp
    jq_tmp="$(mktemp)"
    if jq '
        .hooks.SessionStart |= map(
          .hooks |= map(
            ((.command // "") | test("hive-mind/hive-mind/core/check-dupes\\.sh")) as $has_checkdupes |
            ((.command // "") | test("hive-mind/bin/sync") | not) as $missing_sync |
            if $has_checkdupes and $missing_sync then
              .command = "\"$HOME/.hive-mind/bin/sync\" 2>>\"$HOME/.hive-mind/.sync-error.log\" || true; \"$HOME/.hive-mind/hive-mind/core/check-dupes.sh\" 2>>\"$HOME/.claude/.sync-error.log\" || true"
              | .timeout = 30
            else . end
          )
        )
      ' "$settings" > "$jq_tmp" 2>/dev/null; then
      mv "$jq_tmp" "$settings"
    else
      rm -f "$jq_tmp"
    fi
  fi
}
