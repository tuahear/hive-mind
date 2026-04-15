#!/bin/bash
# Mirror per-project memory across path-variant directories.
#
# Claude Code stores project memory at projects/<encoded-cwd>/ where the
# encoding depends on the host's absolute path (Mac vs Windows, username,
# etc.). The same repo cloned on two machines maps to two different
# variant dirs, so per-project memory written on one machine is invisible
# on the other. This script groups variants by the apparent project name
# (trailing dash-segment after the last encoded path separator) and
# unifies their content so every variant holds the same memory.
#
# Union strategy: `git merge-file --union` line-merges differing copies
# of the same file, matching the gitattributes union driver used on pull.
# Duplicates that result are left for check-dupes.sh to surface.
#
# Only `MEMORY.md` and files under `memory/` are mirrored — session
# transcripts and other local state are left alone.

set +e
cd ~/.claude || exit 0
[ -d projects ] || exit 0

# Emit "<group-key>\t<variant-dir>" for each candidate variant.
keyed="$(
  for d in projects/*/; do
    [ -d "$d" ] || continue
    name="${d#projects/}"; name="${name%/}"
    # Group key = last dash-separated segment (the apparent project basename).
    # Collisions between genuinely unrelated projects sharing a basename are
    # the documented edge case; fence with a marker file if it ever matters.
    key="${name##*-}"
    [ -z "$key" ] && continue
    printf '%s\t%s\n' "$key" "$d"
  done
)"

[ -z "$keyed" ] && exit 0

# Keys present in 2+ variants — these are the cross-machine mirror groups.
keys="$(printf '%s\n' "$keyed" | awk -F'\t' 'NF==2 {c[$1]++} END {for (k in c) if (c[k]>1) print k}')"

[ -z "$keys" ] && exit 0

list_rels() {
  local v="$1"
  [ -f "$v/MEMORY.md" ] && printf 'MEMORY.md\n'
  if [ -d "$v/memory" ]; then
    (cd "$v" && find memory -type f 2>/dev/null)
  fi
}

while IFS= read -r key; do
  [ -z "$key" ] && continue

  variants="$(printf '%s\n' "$keyed" | awk -F'\t' -v k="$key" '$1==k {print $2}')"

  # Union set of relative paths present in any variant.
  all_rels="$(
    while IFS= read -r v; do
      [ -z "$v" ] && continue
      list_rels "$v"
    done <<<"$variants" | sort -u
  )"

  [ -z "$all_rels" ] && continue

  while IFS= read -r rel; do
    [ -z "$rel" ] && continue

    existing="$(
      while IFS= read -r v; do
        [ -z "$v" ] && continue
        [ -f "$v$rel" ] && printf '%s\n' "$v$rel"
      done <<<"$variants"
    )"

    n="$(printf '%s\n' "$existing" | awk 'NF' | wc -l | tr -d ' ')"
    [ "$n" -eq 0 ] && continue

    merged="$(mktemp)"

    if [ "$n" -eq 1 ]; then
      cp "$(printf '%s' "$existing")" "$merged"
    else
      # Line-union all copies, pairwise with an empty base.
      first=1
      while IFS= read -r src; do
        [ -z "$src" ] && continue
        if [ "$first" -eq 1 ]; then
          cp "$src" "$merged"
          first=0
          continue
        fi
        if cmp -s "$merged" "$src"; then
          continue
        fi
        tmp="$(mktemp)"
        if git merge-file --union -p "$merged" /dev/null "$src" > "$tmp" 2>/dev/null; then
          mv "$tmp" "$merged"
        else
          cat "$src" >> "$merged"
          rm -f "$tmp"
        fi
      done <<<"$existing"
    fi

    # Write the merged content back to every variant.
    while IFS= read -r v; do
      [ -z "$v" ] && continue
      dst="$v$rel"
      if [ -f "$dst" ] && cmp -s "$dst" "$merged"; then
        continue
      fi
      mkdir -p "$(dirname "$dst")"
      cp "$merged" "$dst"
    done <<<"$variants"

    rm -f "$merged"
  done <<<"$all_rels"

done <<<"$keys"

exit 0
