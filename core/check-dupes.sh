#!/bin/bash
# Scan memory files for duplicate content lines left behind by git's
# `union` merge driver.
#
# Invoked from the session-start hook. Emits a one-shot JSON nudge to the
# model via hookSpecificOutput.additionalContext when duplicates exist.
# Silent and exit-0 otherwise.
#
# Adapter-agnostic: uses ADAPTER_DIR and ADAPTER_GLOBAL_MEMORY to locate
# files. Falls back to ~/.claude / CLAUDE.md for backward compat.

set +e

: "${ADAPTER_DIR:=$HOME/.claude}"
: "${ADAPTER_GLOBAL_MEMORY:=$ADAPTER_DIR/CLAUDE.md}"
: "${ADAPTER_EVENT_SESSION_START:=SessionStart}"

has_dupes() {
  local f="$1"
  [ -f "$f" ] || return 1
  awk '
    NF && length($0) >= 20 \
      && !/^[[:space:]]*#/ \
      && !/^[[:space:]]*[-=*_]{3,}[[:space:]]*$/ \
      && !/^[[:space:]]*`{3,}/ {
      if (seen[$0]++) { dups++ }
    }
    END { exit dups ? 0 : 1 }
  ' "$f"
}

flagged=()
[ -f "$ADAPTER_GLOBAL_MEMORY" ] && has_dupes "$ADAPTER_GLOBAL_MEMORY" \
  && flagged+=("${ADAPTER_GLOBAL_MEMORY/#$HOME/~}")

while IFS= read -r -d '' f; do
  has_dupes "$f" && flagged+=("${f#$HOME/}")
done < <(find "$ADAPTER_DIR/projects" -type f -name '*.md' -print0 2>/dev/null)

if [ ${#flagged[@]} -gt 0 ]; then
  list="$(printf '%s, ' "${flagged[@]}" | sed 's/, $//')"
  msg="Apparent duplicate lines detected in: ${list}. These were likely introduced by git's union merge driver when a cross-machine memory sync merged the same bullet from both sides. If you edit any of these files this session, dedupe while you're in there."
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg m "$msg" --arg e "$ADAPTER_EVENT_SESSION_START" \
      '{hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
  fi
fi

exit 0
