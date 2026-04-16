#!/bin/bash
# DEPRECATED: forwarding shim. Use core/mirror-projects.sh directly.
SENTINEL="${ADAPTER_DIR:-$HOME/.claude}/.hive-mind-state/shim-deprecated-mirror-projects"
if [ ! -f "$SENTINEL" ]; then
  mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null
  printf '%s WARN mirror-projects: scripts/mirror-projects.sh is deprecated, use core/mirror-projects.sh (logged once)\n' \
    "$(date -u +%FT%TZ)" >> "${ADAPTER_DIR:-$HOME/.claude}/.sync-error.log" 2>/dev/null
  : > "$SENTINEL" 2>/dev/null
fi
exec "$(dirname "$0")/../core/mirror-projects.sh" "$@"
