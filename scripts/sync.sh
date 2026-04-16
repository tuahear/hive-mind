#!/bin/bash
# DEPRECATED: forwarding shim. Use core/sync.sh directly.
# This shim exists for one release cycle to avoid breaking existing hook
# commands that reference ~/.claude/hive-mind/scripts/sync.sh.
SENTINEL="${ADAPTER_DIR:-$HOME/.claude}/hive-mind/.shim-deprecated-sync"
if [ ! -f "$SENTINEL" ]; then
  mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null
  printf '%s WARN sync: scripts/sync.sh is deprecated, use core/sync.sh (this warning logged once)\n' \
    "$(date -u +%FT%TZ)" >> "${ADAPTER_DIR:-$HOME/.claude}/.sync-error.log" 2>/dev/null
  : > "$SENTINEL" 2>/dev/null
fi
exec "$(dirname "$0")/../core/sync.sh" "$@"
