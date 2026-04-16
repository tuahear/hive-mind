#!/bin/bash
# DEPRECATED: forwarding shim. Use core/check-dupes.sh directly.
printf '%s WARN check-dupes: scripts/check-dupes.sh is deprecated, use core/check-dupes.sh\n' \
  "$(date -u +%FT%TZ)" >> "${ADAPTER_DIR:-$HOME/.claude}/.sync-error.log" 2>/dev/null
exec "$(dirname "$0")/../core/check-dupes.sh" "$@"
