#!/bin/bash
# DEPRECATED: forwarding shim. Use core/mirror-projects.sh directly.
_HM_AD="${ADAPTER_DIR:-$HOME/.claude}"
_HM_LOG="${ADAPTER_LOG_PATH:-$_HM_AD/.sync-error.log}"
SENTINEL="$_HM_AD/.hive-mind-state/shim-deprecated-mirror-projects"
if [ ! -f "$SENTINEL" ]; then
  mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null
  printf '%s WARN mirror-projects: scripts/mirror-projects.sh is deprecated, use core/mirror-projects.sh (logged once)\n' \
    "$(date -u +%FT%TZ)" >> "$_HM_LOG" 2>/dev/null
  : > "$SENTINEL" 2>/dev/null
fi
exec "$(dirname "$0")/../core/mirror-projects.sh" "$@"
