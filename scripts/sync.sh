#!/bin/bash
# DEPRECATED: forwarding shim. Use core/sync.sh directly.
# This shim exists for one release cycle to avoid breaking existing hook
# commands that reference ~/.claude/hive-mind/scripts/sync.sh.
printf '%s WARN sync: scripts/sync.sh is deprecated, use core/sync.sh\n' \
  "$(date -u +%FT%TZ)" >> "${ADAPTER_DIR:-$HOME/.claude}/.sync-error.log" 2>/dev/null
exec "$(dirname "$0")/../core/sync.sh" "$@"
