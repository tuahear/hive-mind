#!/bin/bash
# Mirror per-project memory across path-variant directories.
#
# Claude Code stores project memory at projects/<encoded-cwd>/ where the
# encoding depends on the host's absolute path (Mac vs Windows, username,
# etc.). The same repo cloned on two machines maps to two different
# variant dirs, so per-project memory written on one machine is invisible
# on the other. This script groups variants by the *longest shared trailing
# dash-separated suffix* (so `-Users-nick-Repo-my-project` and
# `C--Users-thiti-Repo-my-project` group under `Repo-my-project`, not the
# lossy `project`) and unifies their content so every variant holds the
# same memory.
#
# Union strategy: only `.md` files are line-merged via `git merge-file
# --union` (matches the gitattributes union driver). Other files under
# `memory/` are copy-if-missing only — never byte-concatenated, so binary
# or structured non-text content can't be corrupted. If variants disagree
# on a non-markdown file, each variant keeps its own copy until the user
# resolves it.
#
# Only `MEMORY.md` and files under `memory/` are mirrored — session
# transcripts and other local state are left alone.

set +e
cd ~/.claude || exit 0
[ -d projects ] || exit 0

candidates="$(
  for d in projects/*/; do
    [ -d "$d" ] || continue
    name="${d#projects/}"; name="${name%/}"
    [ -n "$name" ] && printf '%s\n' "$name"
  done
)"

[ -z "$candidates" ] && exit 0

# For each candidate, emit every trailing dash-bounded suffix paired with the
# candidate's full name. Then pick the longest suffix per candidate that is
# shared by ≥2 distinct candidates; that becomes the group key.
suffixes="$(
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    rest="$name"
    while [ -n "$rest" ]; do
      printf '%s\t%s\n' "$rest" "$name"
      next="${rest#*-}"
      [ "$next" = "$rest" ] && break
      rest="$next"
    done
  done <<<"$candidates"
)"

group_keys="$(
  printf '%s\n' "$suffixes" | awk -F'\t' '
    { seen[$1 FS $2] = 1 }
    END {
      for (k in seen) { split(k, a, FS); uniq[a[1]]++ }
      for (k in seen) {
        split(k, a, FS); suf = a[1]; name = a[2]
        if (uniq[suf] < 2) continue
        if (length(suf) > length(best[name])) best[name] = suf
      }
      for (name in best) print best[name] "\t" name
    }
  '
)"

[ -z "$group_keys" ] && exit 0

keys="$(printf '%s\n' "$group_keys" | awk -F'\t' 'NF==2 {print $1}' | sort -u)"

list_rels() {
  local v="$1"
  [ -f "$v/MEMORY.md" ] && printf 'MEMORY.md\n'
  if [ -d "$v/memory" ]; then
    (cd "$v" && find memory -type f 2>/dev/null)
  fi
}

while IFS= read -r key; do
  [ -z "$key" ] && continue

  variants="$(
    printf '%s\n' "$group_keys" | awk -F'\t' -v k="$key" '$1==k {print "projects/" $2 "/"}'
  )"

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

    # Is this a markdown file? Only markdown participates in union merging.
    case "$rel" in
      *.md|MEMORY.md) is_md=1 ;;
      *)              is_md=0 ;;
    esac

    merged="$(mktemp)"

    if [ "$n" -eq 1 ]; then
      cp "$(printf '%s' "$existing" | awk 'NF' | head -n1)" "$merged"
    elif [ "$is_md" -eq 1 ]; then
      # Line-union all markdown copies, pairwise with an empty base.
      first=1
      while IFS= read -r src; do
        [ -z "$src" ] && continue
        if [ "$first" -eq 1 ]; then
          cp "$src" "$merged"
          first=0
          continue
        fi
        cmp -s "$merged" "$src" && continue
        tmp="$(mktemp)"
        if git merge-file --union -p "$merged" /dev/null "$src" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
          mv "$tmp" "$merged"
        else
          # Merge failed or produced empty output — keep running state;
          # never byte-concat (would corrupt on non-text & worsen text).
          rm -f "$tmp"
        fi
      done <<<"$existing"
    else
      # Non-markdown, multiple copies: seed from first existing. Variants
      # with differing content are preserved below (not overwritten).
      cp "$(printf '%s' "$existing" | awk 'NF' | head -n1)" "$merged"
    fi

    # Safety gate: never overwrite with an empty merged result when any
    # source was non-empty (catches silent cp/merge failures).
    any_nonempty=0
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      [ -s "$src" ] && any_nonempty=1
    done <<<"$existing"
    if [ ! -s "$merged" ] && [ "$any_nonempty" -eq 1 ]; then
      rm -f "$merged"
      continue
    fi

    # Write back. For non-markdown, never clobber an existing differing
    # copy in a variant — preserve whatever local content is there.
    while IFS= read -r v; do
      [ -z "$v" ] && continue
      dst="$v$rel"
      if [ -f "$dst" ]; then
        cmp -s "$dst" "$merged" && continue
        [ "$is_md" -eq 0 ] && continue
      fi
      mkdir -p "$(dirname "$dst")"
      cp "$merged" "$dst"
    done <<<"$variants"

    rm -f "$merged"
  done <<<"$all_rels"

done <<<"$keys"

exit 0
