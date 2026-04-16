#!/bin/bash
# DEPRECATED: forwarding shim. Use core/mirror-projects.sh directly.
printf '%s WARN mirror-projects: scripts/mirror-projects.sh is deprecated, use core/mirror-projects.sh\n' \
  "$(date -u +%FT%TZ)" >> "${ADAPTER_DIR:-$HOME/.claude}/.sync-error.log" 2>/dev/null
exec "$(dirname "$0")/../core/mirror-projects.sh" "$@"
