#!/bin/bash
# DEPRECATED: forwarding shim. Use core/jsonmerge.sh directly.
SENTINEL="${ADAPTER_DIR:-$HOME/.claude}/hive-mind/.shim-deprecated-jsonmerge"
if [ ! -f "$SENTINEL" ]; then
  mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null
  printf '%s WARN jsonmerge: scripts/jsonmerge.sh is deprecated, use core/jsonmerge.sh (logged once)\n' \
    "$(date -u +%FT%TZ)" >> "${ADAPTER_DIR:-$HOME/.claude}/.sync-error.log" 2>/dev/null
  : > "$SENTINEL" 2>/dev/null
fi
exec "$(dirname "$0")/../core/jsonmerge.sh" "$@"
