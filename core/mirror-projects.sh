#!/bin/bash
# Mirror per-project memory across path-variant directories.
#
# Scope: handles the FLAT-layout `projects/<encoded-cwd>/` tree that
# Claude-style adapters use. Tools encode the cwd path into the
# directory name, so the same repo cloned on two machines maps to
# two different variant dirs; per-project memory written on one
# machine is invisible on the other until this script unifies them.
#
# Hierarchical-model adapters (Codex, Qwen, Kimi, …) do NOT use this
# layout — their per-project memory (e.g. tree-walked AGENTS.md) lives
# inside user project checkouts, versioned by the user's own repo, not
# in the hive-mind memory repo. For those adapters this script is a
# clean no-op: it exits at line ~27 when `projects/` is absent.
#
# Uses ADAPTER_DIR to locate the memory repo; falls back to ~/.claude
# for backward compat with pre-adapter-contract installs.
#
# Identity model:
#   - Each variant carries a metadata sidecar at
#     <variant>/memory/.hive-mind, a key=value text file.
#   - If the sidecar isn't there yet, derive from local session jsonl
#     + git remote, normalize, and persist.
#   - Variants whose project-id matches are treated as the same project.
#
# Union strategy: only `.md` files are line-merged via `git merge-file
# --union`. Other files are copy-if-missing only.

set +e

: "${ADAPTER_DIR:=$HOME/.claude}"
cd "$ADAPTER_DIR" || exit 0
[ -d projects ] || exit 0

MARKER_FILE=".hive-mind"

read_meta() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  awk -F= -v k="$key" '
    /^[[:space:]]*#/ { next }
    $1 == k { sub(/^[^=]*=/, ""); print; exit }
  ' "$file"
}

file_matches_head() {
  local path="$1"
  [ -z "$(git status --porcelain -- "$path" 2>/dev/null)" ]
}

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

derive_id_from_cwd() {
  local pdir="$1"
  local f cwd remote id
  for f in "$pdir"/*.jsonl; do
    [ -f "$f" ] || continue
    cwd="$(grep -m1 -oE '"cwd":"[^"]+"' "$f" 2>/dev/null \
             | sed -e 's/^"cwd":"//' -e 's/"$//' )"
    [ -z "$cwd" ] && continue
    [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ] || continue
    remote="$(git -C "$cwd" remote get-url origin 2>/dev/null)"
    [ -z "$remote" ] && continue
    id="$(normalize_remote "$remote")"
    [ -z "$id" ] && continue
    printf '%s' "$id"
    return 0
  done
  return 1
}

discover_id() {
  local pdir="$1"
  local known="$2"
  local meta="$pdir/memory/$MARKER_FILE"
  local id=""

  if [ -f "$meta" ]; then
    id="$(read_meta "$meta" "project-id" | tr -d '\r\n')"
    if [ -n "$id" ]; then
      printf '%s' "$id"
      return 0
    fi
  fi

  id="$(derive_id_from_cwd "$pdir")" || return 1
  [ -z "$id" ] && return 1

  local has_content=0
  [ -f "$pdir/MEMORY.md" ] && has_content=1
  if [ "$has_content" -eq 0 ] && [ -d "$pdir/memory" ]; then
    if find "$pdir/memory" -type f ! -name "$MARKER_FILE" 2>/dev/null \
         | head -n 1 | grep -q .; then
      has_content=1
    fi
  fi

  if [ "$has_content" -eq 0 ]; then
    if ! printf '%s\n' "$known" | grep -Fxq "$id"; then
      return 1
    fi
  fi

  mkdir -p "$pdir/memory"
  printf 'project-id=%s\n' "$id" > "$meta"
  printf '%s' "$id"
  return 0
}

# Pass 1: collect known project-ids from sidecars.
known_ids=""
for d in projects/*/; do
  [ -d "$d" ] || continue
  pdir="${d%/}"
  meta="$pdir/memory/$MARKER_FILE"
  [ -f "$meta" ] || continue
  id="$(read_meta "$meta" "project-id" | tr -d '\r\n')"
  [ -n "$id" ] && known_ids="$known_ids$id"$'\n'
done

# Pass 2: build manifest.
manifest=""
for d in projects/*/; do
  [ -d "$d" ] || continue
  pdir="${d%/}"
  id="$(discover_id "$pdir" "$known_ids" 2>/dev/null)" || continue
  [ -z "$id" ] && continue
  manifest="$manifest$id"$'\t'"$pdir"$'\n'
done

[ -z "$manifest" ] && exit 0

keys="$(printf '%s' "$manifest" | awk -F'\t' 'NF==2 {c[$1]++} END{for(k in c) if(c[k]>=2) print k}')"
[ -z "$keys" ] && exit 0

list_rels() {
  local v="$1"
  [ -f "$v/MEMORY.md" ] && printf 'MEMORY.md\n'
  if [ -d "$v/memory" ]; then
    (cd "$v" && find memory -type f ! -name "$MARKER_FILE" 2>/dev/null)
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
      modified_srcs=""
      while IFS= read -r src; do
        [ -z "$src" ] && continue
        if ! file_matches_head "$src"; then
          modified_srcs="$modified_srcs$src"$'\n'
        fi
      done <<<"$existing"
      modified_count="$(printf '%s\n' "$modified_srcs" | awk 'NF' | wc -l | tr -d ' ')"

      if [ "$modified_count" -eq 1 ]; then
        cp "$(printf '%s' "$modified_srcs" | awk 'NF' | head -n1)" "$merged"
      else
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
      fi
    else
      cp "$(printf '%s' "$existing" | awk 'NF' | head -n1)" "$merged"
    fi

    any_nonempty=0
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      [ -s "$src" ] && any_nonempty=1
    done <<<"$existing"
    if [ ! -s "$merged" ] && [ "$any_nonempty" -eq 1 ]; then
      rm -f "$merged"
      continue
    fi

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
