#!/bin/bash
# DEPRECATED: forwarding shim. Use core/marker-nudge.sh directly.
printf '%s WARN marker-nudge: scripts/marker-nudge.sh is deprecated, use core/marker-nudge.sh\n' \
  "$(date -u +%FT%TZ)" >> "${ADAPTER_DIR:-$HOME/.claude}/.sync-error.log" 2>/dev/null
exec "$(dirname "$0")/../core/marker-nudge.sh" "$@"
