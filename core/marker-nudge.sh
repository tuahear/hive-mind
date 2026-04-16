#!/bin/bash
# Post-edit hook -- when an edit targets a file under the adapter's sync
# root (excluding the hive-mind install dir), emit a one-line nudge
# telling the agent to recall the hive-mind skill.
#
# Adapter-agnostic: uses ADAPTER_DIR to locate the sync root.
# Falls back to ~/.claude for backward compat.

set +e

: "${ADAPTER_DIR:=$HOME/.claude}"
: "${ADAPTER_EVENT_POST_EDIT:=PostToolUse}"

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"

case "$file_path" in
  "$ADAPTER_DIR/hive-mind/"*) exit 0 ;;
  "$ADAPTER_DIR/"*) ;;
  *) exit 0 ;;
esac

jq -cn --arg e "$ADAPTER_EVENT_POST_EDIT" \
  '{hookSpecificOutput: {hookEventName: $e, additionalContext: "hive-mind edit \u2014 recall hive-mind skill"}}'
exit 0
