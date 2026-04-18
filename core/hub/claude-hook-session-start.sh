#!/bin/bash
# Claude SessionStart-hook wrapper. Runs hub sync first so Claude sees
# fresh cross-machine memory, then invokes check-dupes against the
# adapter's memory files. Any hook-specific JSON emitted by check-dupes
# passes through unchanged to Claude.
set +e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
HUB_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
adapter_dir="${1:-$HOME/.claude}"
adapter_global_memory="$adapter_dir/CLAUDE.md"

"$HUB_DIR/bin/sync" >/dev/null 2>>"$HUB_DIR/.sync-error.log"

ADAPTER_DIR="$adapter_dir" \
ADAPTER_GLOBAL_MEMORY="$adapter_global_memory" \
"$HUB_DIR/hive-mind/core/check-dupes.sh" \
2>>"$adapter_dir/.sync-error.log"
