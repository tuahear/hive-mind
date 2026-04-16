#!/bin/bash
# DEPRECATED: forwarding shim. Use core/sync.sh directly.
# This shim exists for one release cycle to avoid breaking existing hook
# commands that reference ~/.claude/hive-mind/scripts/sync.sh.
_HM_AD="${ADAPTER_DIR:-$HOME/.claude}"
_HM_LOG="${ADAPTER_LOG_PATH:-$_HM_AD/.sync-error.log}"
SENTINEL="$_HM_AD/.hive-mind-state/shim-deprecated-sync"
if [ ! -f "$SENTINEL" ]; then
  mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null
  printf '%s WARN sync: scripts/sync.sh is deprecated, use core/sync.sh (this warning logged once)\n' \
    "$(date -u +%FT%TZ)" >> "$_HM_LOG" 2>/dev/null
  : > "$SENTINEL" 2>/dev/null
fi

# Pre-refactor hooks never set ADAPTER_* vars; core/sync.sh's fallback
# only covers *.md files, which misses the Claude whitelist of skill
# assets and nested memory files. Load the claude-code adapter here so
# core/sync.sh sees ADAPTER_MARKER_TARGETS et al. populated exactly as
# the pre-refactor script did. The shim is inherently Claude-specific
# (it lives under the old scripts/ layout that only Claude installs
# ever referenced) so loading the Claude adapter is appropriate.
_HM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$_HM_ROOT/core/adapter-loader.sh" ] \
   && [ -f "$_HM_ROOT/adapters/claude-code/adapter.sh" ]; then
  ADAPTER_ROOT="$_HM_ROOT/adapters/claude-code"
  export ADAPTER_ROOT
  # shellcheck disable=SC1091
  . "$_HM_ROOT/core/adapter-loader.sh"
  if load_adapter claude-code >/dev/null 2>>"$_HM_LOG"; then
    # Adapters set ADAPTER_* as shell variables, not environment
    # exports. exec() passes environment only, so without this loop
    # core/sync.sh would see ADAPTER_MARKER_TARGETS unset and fall
    # back to the generic *.md pattern — defeating the whole point
    # of loading the adapter from the shim.
    for _v in $(compgen -v ADAPTER_ 2>/dev/null); do
      export "$_v"
    done
    unset _v
  fi
fi

exec "$_HM_ROOT/core/sync.sh" "$@"
