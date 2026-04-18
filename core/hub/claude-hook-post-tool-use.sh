#!/bin/bash
# Claude PostToolUse-hook wrapper. Passes the incoming hook payload to
# marker-nudge with the adapter dir wired in so custom installs still
# scope the nudge correctly.
set +e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
HUB_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
adapter_dir="${1:-$HOME/.claude}"

ADAPTER_DIR="$adapter_dir" \
"$HUB_DIR/hive-mind/core/marker-nudge.sh" \
2>>"$adapter_dir/.sync-error.log"
