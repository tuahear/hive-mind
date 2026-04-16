#!/bin/bash
# DEPRECATED: forwarding shim. Use core/marker-nudge.sh directly.
SENTINEL="${ADAPTER_DIR:-$HOME/.claude}/.hive-mind-state/shim-deprecated-marker-nudge"
if [ ! -f "$SENTINEL" ]; then
  mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null
  printf '%s WARN marker-nudge: scripts/marker-nudge.sh is deprecated, use core/marker-nudge.sh (logged once)\n' \
    "$(date -u +%FT%TZ)" >> "${ADAPTER_DIR:-$HOME/.claude}/.sync-error.log" 2>/dev/null
  : > "$SENTINEL" 2>/dev/null
fi
exec "$(dirname "$0")/../core/marker-nudge.sh" "$@"
