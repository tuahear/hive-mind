#!/bin/bash
# Scan ~/.claude/CLAUDE.md and projects/**/memory/*.md for duplicate content
# lines left behind by git's `union` merge driver (invoked when two machines
# both added the same content and sync-merged).
#
# Invoked from the SessionStart hook. Emits a one-shot JSON nudge to the
# model via hookSpecificOutput.additionalContext when duplicates exist.
# Silent and exit-0 otherwise, so a clean state injects nothing.
#
# Heuristic: count a line as "duplicate" only if it is >=20 chars, has
# content, and is not a markdown structural line (heading, separator, code
# fence). Short/structural repetition is normal markdown, not a merge bug.

set +e

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
[ -f "$HOME/.claude/CLAUDE.md" ] && has_dupes "$HOME/.claude/CLAUDE.md" \
  && flagged+=("~/.claude/CLAUDE.md")

while IFS= read -r -d '' f; do
  has_dupes "$f" && flagged+=("${f#$HOME/}")
done < <(find "$HOME/.claude/projects" -type f -name '*.md' -print0 2>/dev/null)

if [ ${#flagged[@]} -gt 0 ]; then
  list="$(printf '%s, ' "${flagged[@]}" | sed 's/, $//')"
  msg="Apparent duplicate lines detected in: ${list}. These were likely introduced by git's union merge driver when a cross-machine memory sync merged the same bullet from both sides. If you edit any of these files this session, dedupe while you're in there."
  # jq formats the JSON correctly and escapes the message. If jq isn't
  # available, skip silently — the hint is a nice-to-have, not critical.
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg m "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
  fi
fi

exit 0
