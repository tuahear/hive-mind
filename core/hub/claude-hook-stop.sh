#!/bin/bash
# Claude Stop-hook wrapper. Runs the hub sync entry point and otherwise
# stays silent so Claude's turn-end hook behaves the same as the
# previous direct-sync command.
set +e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
HUB_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"

"$HUB_DIR/bin/sync" >/dev/null 2>>"$HUB_DIR/.sync-error.log"
