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

  # Idempotent: if hooks already contain hive-mind entries, skip merge.
  if grep -q 'hive-mind/core/' "$settings" 2>/dev/null; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  jq -s '
    .[0] as $user | .[1] as $new
    | ($user * $new)
    | .permissions.allow = (
        (($user.permissions.allow // []) + ($new.permissions.allow // [])) | unique
      )
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
            .hooks |= map(select(.command | test("(~/\\.claude|\\$HOME/\\.claude)/hive-mind/(core|scripts)/") | not))
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
  command -v claude >/dev/null 2>&1 || [ -d "$ADAPTER_DIR" ] || mkdir -p "$ADAPTER_DIR" 2>/dev/null
}

# --- Migration (optional) --------------------------------------------------
# Migrate from pre-refactor layout. Rewrites hook command strings that
# reference the old scripts/ paths to use the new core/ paths.
adapter_migrate() {
  local from_version="${1:-}"
  local settings="$ADAPTER_DIR/settings.json"
  [ -f "$settings" ] || return 0

  # Rewrite old hook command paths: scripts/sync.sh → core/sync.sh, etc.
  local tmp
  tmp="$(mktemp)"
  if sed \
    -e 's|hive-mind/scripts/sync\.sh|hive-mind/core/sync.sh|g' \
    -e 's|hive-mind/scripts/check-dupes\.sh|hive-mind/core/check-dupes.sh|g' \
    -e 's|hive-mind/scripts/marker-nudge\.sh|hive-mind/core/marker-nudge.sh|g' \
    -e 's|hive-mind/scripts/jsonmerge\.sh|hive-mind/core/jsonmerge.sh|g' \
    -e 's|hive-mind/scripts/mirror-projects\.sh|hive-mind/core/mirror-projects.sh|g' \
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
