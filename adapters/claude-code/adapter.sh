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
# Files setup.sh backs up on first attach. Scope deliberately narrow:
# Claude Code has `shell-snapshots/`, `file-history/`, `ide/`, and lock
# files open at runtime; `cp -a` of the whole dir triggers "Device or
# resource busy" on those live files. Only list paths the adapter
# actually modifies — setup.sh falls back to a full-dir copy if this
# var is empty.
ADAPTER_BACKUP_PATHS="settings.json CLAUDE.md skills"
# --- C. Lifecycle touchpoints ----------------------------------------------
ADAPTER_HAS_HOOK_SYSTEM=true
ADAPTER_EVENT_SESSION_START="SessionStart"
ADAPTER_EVENT_TURN_END="Stop"
ADAPTER_EVENT_POST_EDIT="PostToolUse"

_claude_hook_binary_suffix() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) printf '.exe' ;;
    *)                    printf '' ;;
  esac
}

_claude_hook_binary_path() {
  printf '%s' "${HIVE_MIND_HUB_DIR:-$HOME/.hive-mind}/bin/hivemind-hook$(_claude_hook_binary_suffix)"
}

_claude_managed_hook_regex() {
  printf '%s' 'hivemind-hook(\.exe)?|\.hive-mind/bin/sync|hive-mind/core/check-dupes\.sh|hive-mind/core/marker-nudge\.sh|\.claude/hive-mind/(core|scripts)/(sync|check-dupes|marker-nudge)\.sh'
}

_claude_strip_managed_hooks_file() {
  local source="$1" dest="$2" regex
  regex="$(_claude_managed_hook_regex)"

  jq --arg re "$regex" '
    if .hooks then
      .hooks |= with_entries(
        .value |= map(
          if .hooks then
            .hooks |= map(
              select(((.command // "") | test($re)) | not)
            )
          else . end
          | select((.hooks // []) | length > 0)
        )
      )
      | .hooks |= with_entries(select((.value | length) > 0))
      | if (.hooks | keys | length) == 0 then del(.hooks) else . end
    else . end
  ' "$source" > "$dest" 2>/dev/null
}

adapter_install_hooks() {
  local settings="$ADAPTER_DIR/settings.json"
  local template="${ADAPTER_ROOT}/settings.json"
  local rendered hook_path hook_abs adapter_dir_abs stripped tmp
  [ -f "$template" ] || return 1

  mkdir -p "$ADAPTER_DIR"

  hook_path="$(_claude_hook_binary_path)"
  if command -v cygpath >/dev/null 2>&1; then
    hook_abs="$(cygpath -m "$hook_path" 2>/dev/null || printf '%s' "$hook_path")"
    adapter_dir_abs="$(cygpath -m "$ADAPTER_DIR" 2>/dev/null || printf '%s' "$ADAPTER_DIR")"
  else
    hook_abs="$hook_path"
    adapter_dir_abs="$ADAPTER_DIR"
  fi

  rendered="$(mktemp)"
  jq --arg hookcmd "\"$hook_abs\"" \
     --arg adir "\"$adapter_dir_abs\"" \
     'walk(if type == "string" then
       gsub("[$]HIVE_MIND_HOOK"; $hookcmd)
       | gsub("[$]ADAPTER_DIR_ARG"; $adir)
     else . end)' \
     "$template" > "$rendered"

  if [ ! -f "$settings" ]; then
    mv "$rendered" "$settings"
    return 0
  fi

  stripped="$(mktemp)"
  if ! _claude_strip_managed_hooks_file "$settings" "$stripped"; then
    rm -f "$stripped" "$rendered"
    return 1
  fi

  tmp="$(mktemp)"
  # Concatenate hook event arrays instead of replacing them -- jq's `*`
  # operator overwrites arrays, which would drop user-defined hooks on
  # the same event (e.g. a user's custom Stop hook). For each event we
  # know about, append the template's entries only if they aren't
  # already present (match by command string so re-running is a no-op).
  if jq -s '
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
  ' "$stripped" "$rendered" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$settings"
    rm -f "$rendered" "$stripped"
  else
    rm -f "$tmp" "$rendered" "$stripped"
    return 1
  fi
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
  if _claude_strip_managed_hooks_file "$settings" "$tmp"; then
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
ADAPTER_SETTINGS_MERGE_BINDINGS=""

# Optional: per-driver env vars to inject when registering merge drivers
# in the local .git/config. Newline-separated lines of the form
# "<driver>:<KEY=val KEY2=val2>". setup.sh prepends the env-prefix to
# the registered driver command. Example for a TOML adapter (Codex):
#   ADAPTER_MERGE_DRIVER_ENV=$'tomlmerge:TOMLMERGE_UNION_KEYS=permissions.allow,permissions.deny'
# Claude keeps settings.json local-only, so no merge-driver env is needed.
ADAPTER_MERGE_DRIVER_ENV=""

# --- F. User education -----------------------------------------------------
adapter_activation_instructions() {
  echo "Open /hooks in Claude Code once (or start a fresh session) so the"
  echo "settings watcher picks up the SessionStart + Stop hooks."
}

adapter_disable_instructions() {
  local hub="${HIVE_MIND_HUB_DIR:-$HOME/.hive-mind}"
  echo "To temporarily disable hive-mind sync, remove the hook entries from"
  echo "${ADAPTER_DIR}/settings.json. To fully disconnect Claude Code from"
  echo "the hub, edit"
  echo "  ${hub}/.install-state/attached-adapters"
  echo "and remove only the line:"
  echo "  claude-code"
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
# CLAUDE.md uses the [*] wildcard selector so Claude sees every tier of
# the hub's memory without having to enumerate section ids. When a future
# adapter introduces a new tier (section 2, 3, ...) Claude picks it up on
# the next sync — no adapter update needed.
#
# Fan-out with [*] writes section 0 plain + each non-zero section wrapped
# in `<!-- hive-mind:section=N START/END -->` markers (ascending order).
# Harvest parses the same markers back into their respective sections, so
# a Claude-side edit to any tagged block propagates to the owning adapter
# on the next cycle. Content outside any marker block defaults to section
# 0, which makes blind EOF-appends land in the shared tier without needing
# skill discipline.
#
# Claude's settings.json stays machine-local: adapter_install_hooks manages
# hive-mind's hook entries directly and user permissions remain local state.
ADAPTER_HUB_MAP=$'content.md[*]\tCLAUDE.md'

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
# No-op. hive-mind has no released users yet, so the Claude Code adapter
# doesn't carry cross-version migration logic. The function exists
# because the adapter contract (and setup.sh's invocation) expect it.
adapter_migrate() { :; }
