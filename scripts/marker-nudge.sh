#!/bin/bash
# PostToolUse hook — when an Edit/Write/NotebookEdit targets a file under
# ~/.claude (excluding ~/.claude/hive-mind itself, which is a separate repo
# governed by hive-mind-dev, not the marker rule), emit a one-line nudge
# telling the agent to recall the hive-mind skill. Deliberately terse to
# avoid polluting the transcript on bursts of edits.

set +e

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"

case "$file_path" in
  "$HOME/.claude/hive-mind/"*) exit 0 ;;
  "$HOME/.claude/"*) ;;
  *) exit 0 ;;
esac

jq -cn '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: "hive-mind edit — recall hive-mind skill"}}'
exit 0
