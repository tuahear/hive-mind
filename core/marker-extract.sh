#!/usr/bin/env bash
# Extract <!-- commit: ... --> markers from a file and strip them from disk.
#
# Fence-aware: markers inside ``` code fences are preserved (SKILL.md docs
# contain illustrative examples that would otherwise be picked up).
#
# Usage:
#   core/marker-extract.sh <file>
#
# Writes extracted messages (one per line) to stdout. Modifies <file>
# in-place (strips markers + trims trailing blanks). Exits 0 always.

set -euo pipefail

FILE="$1"
[ -f "$FILE" ] || exit 0
grep -q '<!--[[:space:]]*commit:' "$FILE" || exit 0

tmp="$(mktemp)"
msg_file="$(mktemp)"
trap 'rm -f "$tmp" "$msg_file" "$tmp.trim"' EXIT

awk -v msgfile="$msg_file" '
  BEGIN { fence = 0 }
  /^[[:space:]]*```/ { fence = 1 - fence; print; next }
  fence == 1 { print; next }
  {
    line = $0
    # Full-line marker: drop entirely.
    if (match(line, /^[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*[^>]+-->[[:space:]]*$/)) {
      msg = line
      sub(/^[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*/, "", msg)
      sub(/[[:space:]]*-->[[:space:]]*$/, "", msg)
      print msg >> msgfile
      next
    }
    # Inline marker: strip from line, keep remaining text.
    if (match(line, /<!--[[:space:]]*commit:[[:space:]]*[^>]+-->/)) {
      m = substr(line, RSTART, RLENGTH)
      msg = m
      sub(/^<!--[[:space:]]*commit:[[:space:]]*/, "", msg)
      sub(/[[:space:]]*-->$/, "", msg)
      print msg >> msgfile
      gsub(/[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*[^>]+-->/, "", line)
    }
    print line
  }
  END { close(msgfile) }
' "$FILE" > "$tmp"

# Trim trailing blank lines.
awk '{ lines[NR]=$0; last=NR }
     END {
       while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
       for (i=1; i<=last; i++) print lines[i]
     }' "$tmp" > "$tmp.trim" && mv "$tmp.trim" "$tmp"

# Update file only if changed.
if ! cmp -s "$FILE" "$tmp"; then
  mv "$tmp" "$FILE"
else
  rm -f "$tmp"
fi

# Output extracted messages.
if [ -s "$msg_file" ]; then
  cat "$msg_file"
fi
