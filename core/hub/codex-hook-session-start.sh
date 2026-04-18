#!/bin/bash
# Codex SessionStart-hook wrapper. Runs hub sync (silent — errors
# go to the usual log), then invokes check-dupes against the
# synced memory. Emits check-dupes' JSON payload when duplicates
# are detected, or `{}` as the default fallback. Codex's hook
# runner requires valid JSON on stdout — an empty or malformed
# body makes the whole session start fail with "hook exited with
# code 1".
#
# Arg 1 (optional): ADAPTER_DIR. Defaults to $HOME/.codex. Passed
# explicitly from hooks.json so a custom-install ADAPTER_DIR still
# routes check-dupes correctly.
#
# See adapters/codex/adapter.sh for why this logic lives on disk
# rather than inline in hooks.json.
set +e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
HUB_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
adapter_dir="${1:-$HOME/.codex}"
adapter_global_memory="$adapter_dir/AGENTS.override.md"

"$HUB_DIR/bin/sync" >/dev/null 2>>"$HUB_DIR/.sync-error.log"

out="$(ADAPTER_DIR="$adapter_dir" \
       ADAPTER_GLOBAL_MEMORY="$adapter_global_memory" \
       "$HUB_DIR/hive-mind/core/check-dupes.sh" \
       2>>"$adapter_dir/.sync-error.log")"

if [ -n "$out" ]; then
  printf '%s' "$out"
else
  printf '{}'
fi
