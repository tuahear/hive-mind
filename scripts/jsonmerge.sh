#!/bin/bash
# DEPRECATED: forwarding shim. Use core/jsonmerge.sh directly.
printf '%s WARN jsonmerge: scripts/jsonmerge.sh is deprecated, use core/jsonmerge.sh\n' \
  "$(date -u +%FT%TZ)" >> "${ADAPTER_DIR:-$HOME/.claude}/.sync-error.log" 2>/dev/null
exec "$(dirname "$0")/../core/jsonmerge.sh" "$@"
