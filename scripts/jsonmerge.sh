#!/bin/bash
# Git merge driver for JSON config files (primarily ~/.claude/settings.json).
#
# Registered locally via:
#   git config merge.jsonmerge.driver '~/.claude/sync/scripts/jsonmerge.sh %A %O %B'
# Referenced per-file in .gitattributes:
#   settings.json merge=jsonmerge
#
# Called by git as: jsonmerge.sh <ours> <base> <theirs>
# Must write the merged result to <ours> and exit 0 on success.
# Exit non-zero → git falls back to its default merge (conflict markers).
#
# Merge semantics:
#   - jq's `*` operator deep-merges objects (theirs wins on key collision,
#     which is fine because remote is "the truth of the shared fleet").
#   - Known array fields get unioned + deduped: permissions.allow/deny/ask,
#     permissions.additionalDirectories. User content on each side is kept
#     without silent drops.
#   - Unknown arrays fall back to jq's default (theirs wins). If this hurts
#     in practice we can extend the union list.

set -e

OURS="$1"
# BASE="$2"  # common ancestor path (unused — we don't need 3-way here)
THEIRS="$3"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

union='(($ours[0] // []) + ($theirs[0] // [])) | unique'

if jq -s --argjson emptyA '[]' '
    .[0] as $ours | .[1] as $theirs
    | ($ours * $theirs)
    | if ($ours.permissions.allow or $theirs.permissions.allow) then
        .permissions.allow = ((($ours.permissions.allow // []) + ($theirs.permissions.allow // [])) | unique)
      else . end
    | if ($ours.permissions.deny or $theirs.permissions.deny) then
        .permissions.deny = ((($ours.permissions.deny // []) + ($theirs.permissions.deny // [])) | unique)
      else . end
    | if ($ours.permissions.ask or $theirs.permissions.ask) then
        .permissions.ask = ((($ours.permissions.ask // []) + ($theirs.permissions.ask // [])) | unique)
      else . end
    | if ($ours.permissions.additionalDirectories or $theirs.permissions.additionalDirectories) then
        .permissions.additionalDirectories = ((($ours.permissions.additionalDirectories // []) + ($theirs.permissions.additionalDirectories // [])) | unique)
      else . end
' "$OURS" "$THEIRS" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$OURS"
    exit 0
fi

# jq couldn't parse or merge (malformed JSON on one side?) — let git's
# default machinery handle it (will leave conflict markers, surfacing the
# issue). Better than silently discarding data.
exit 1
