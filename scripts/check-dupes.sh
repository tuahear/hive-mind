#!/bin/bash
# DEPRECATED: forwarding shim. Use core/check-dupes.sh directly.
_HM_AD="${ADAPTER_DIR:-$HOME/.claude}"
_HM_LOG="${ADAPTER_LOG_PATH:-$_HM_AD/.sync-error.log}"
SENTINEL="$_HM_AD/.hive-mind-state/shim-deprecated-check-dupes"
if [ ! -f "$SENTINEL" ]; then
  mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null
  printf '%s WARN check-dupes: scripts/check-dupes.sh is deprecated, use core/check-dupes.sh (logged once)\n' \
    "$(date -u +%FT%TZ)" >> "$_HM_LOG" 2>/dev/null
  : > "$SENTINEL" 2>/dev/null
fi
exec "$(dirname "$0")/../core/check-dupes.sh" "$@"
