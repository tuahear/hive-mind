#!/bin/bash
# Mirror per-project memory across path-variant directories.
#
# Claude Code stores project memory at projects/<encoded-cwd>/ where the
# encoding depends on the host's absolute path (Mac vs Windows, username,
# etc.). The same repo cloned on two machines maps to two different
# variant dirs, so per-project memory written on one machine is invisible
# on the other.
#
# Identity model:
#   - For each variant dir, read its identity from
#     <variant>/memory/.hive-mind-project-id (one line: a normalized git
#     remote URL).
#   - If the sidecar isn't there yet, scan local *.jsonl session files
#     for a `cwd` field, run `git -C $cwd remote get-url origin`,
#     normalize, and persist to the sidecar so the *next* sync (and
#     other machines, after they pull) can match without local cwd.
#   - Variants whose identity matches byte-for-byte are treated as the
#     same project and unified.
#   - A variant with no sidecar AND no usable local cwd+git remote is
#     left alone — never grouped, never overwritten.
#
# Union strategy: only `.md` files are line-merged via `git merge-file
# --union` (matches the gitattributes union driver). Other files under
# `memory/` are copy-if-missing only — never byte-concatenated, so binary
# or structured non-text content can't be corrupted.
#
# Only `MEMORY.md` and files under `memory/` are mirrored — session
# transcripts and other local state are left alone. The sidecar identity
# file is excluded from content sync; each variant maintains its own.

set +e
cd ~/.claude || exit 0
[ -d projects ] || exit 0

MARKER_FILE=".hive-mind-project-id"

# Normalize a git remote URL to a stable host/path form so SSH and HTTPS
# variants of the same repo group together.
#   git@github.com:user/repo.git  →  github.com/user/repo
#   https://github.com/user/repo  →  github.com/user/repo
normalize_remote() {
  local u="$1"
  u="${u#git@}"
  u="${u#ssh://}"
  u="${u#git://}"
  u="${u#https://}"
  u="${u#http://}"
  u="${u/://}"
  u="${u%.git}"
  u="${u%/}"
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}

# Determine the project identity for a variant dir. Echoes the id on
# success, returns non-zero on no-id-available.
discover_id() {
  local pdir="$1"
  local idfile="$pdir/memory/$MARKER_FILE"

  if [ -s "$idfile" ]; then
    head -n 1 "$idfile" | tr -d '\r\n'
    return 0
  fi

  # No sidecar — try to derive from a local session jsonl in this dir.
  local cwd="" f
  for f in "$pdir"/*.jsonl; do
    [ -f "$f" ] || continue
    cwd="$(grep -m1 -oE '"cwd":"[^"]+"' "$f" 2>/dev/null \
             | sed -e 's/^"cwd":"//' -e 's/"$//' )"
    [ -n "$cwd" ] && break
  done
  [ -z "$cwd" ] && return 1
  [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ] || return 1

  local remote
  remote="$(git -C "$cwd" remote get-url origin 2>/dev/null)"
  [ -z "$remote" ] && return 1

  local id
  id="$(normalize_remote "$remote")"
  [ -z "$id" ] && return 1

  # Persist for next time + cross-machine matching.
  mkdir -p "$pdir/memory"
  printf '%s\n' "$id" > "$idfile"
  printf '%s' "$id"
  return 0
}

# Build a manifest: id<TAB>variant_dir, one line per variant with an id.
manifest=""
for d in projects/*/; do
  [ -d "$d" ] || continue
  pdir="${d%/}"
  id="$(discover_id "$pdir" 2>/dev/null)" || continue
  [ -z "$id" ] && continue
  manifest="$manifest$id"$'\t'"$pdir"$'\n'
done

[ -z "$manifest" ] && exit 0

# Keep only ids with ≥2 variants — the only ones worth mirroring.
keys="$(printf '%s' "$manifest" | awk -F'\t' 'NF==2 {c[$1]++} END{for(k in c) if(c[k]>=2) print k}')"
[ -z "$keys" ] && exit 0

list_rels() {
  local v="$1"
  [ -f "$v/MEMORY.md" ] && printf 'MEMORY.md\n'
  if [ -d "$v/memory" ]; then
    (cd "$v" && find memory -type f 2>/dev/null) \
      | grep -v "^memory/$MARKER_FILE\$"
  fi
}

while IFS= read -r key; do
  [ -z "$key" ] && continue

  variants="$(printf '%s' "$manifest" | awk -F'\t' -v k="$key" '$1==k {print $2}')"

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
        [ -f "$v/$rel" ] && printf '%s\n' "$v/$rel"
      done <<<"$variants"
    )"

    n="$(printf '%s\n' "$existing" | awk 'NF' | wc -l | tr -d ' ')"
    [ "$n" -eq 0 ] && continue

    case "$rel" in
      *.md|MEMORY.md) is_md=1 ;;
      *)              is_md=0 ;;
    esac

    merged="$(mktemp)"

    if [ "$n" -eq 1 ]; then
      cp "$(printf '%s' "$existing" | awk 'NF' | head -n1)" "$merged"
    elif [ "$is_md" -eq 1 ]; then
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
          rm -f "$tmp"
        fi
      done <<<"$existing"
    else
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
      dst="$v/$rel"
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
