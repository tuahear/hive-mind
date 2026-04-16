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
exec "$(dirname "$0")/../core/sync.sh" "$@"
