#!/bin/bash
# DEPRECATED: forwarding shim. Use core/check-dupes.sh directly.
SENTINEL="${ADAPTER_DIR:-$HOME/.claude}/hive-mind/.shim-deprecated-check-dupes"
if [ ! -f "$SENTINEL" ]; then
  mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null
  printf '%s WARN check-dupes: scripts/check-dupes.sh is deprecated, use core/check-dupes.sh (logged once)\n' \
    "$(date -u +%FT%TZ)" >> "${ADAPTER_DIR:-$HOME/.claude}/.sync-error.log" 2>/dev/null
  : > "$SENTINEL" 2>/dev/null
fi
exec "$(dirname "$0")/../core/check-dupes.sh" "$@"
