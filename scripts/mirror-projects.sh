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
#   - Each variant carries a metadata sidecar at
#     <variant>/memory/.hive-mind, a key=value text file. Project
#     identity is the value of the `project-id` key, normally the
#     normalized git remote URL but a user may set it manually for
#     projects without a git remote.
#   - If the sidecar isn't there yet, scan local *.jsonl session files
#     for a `cwd` field, run `git -C $cwd remote get-url origin`,
#     normalize, and persist as `project-id=…`. The sidecar IS synced,
#     so other machines see it after the next pull.
#   - Variants whose project-id matches byte-for-byte are treated as
#     the same project and unified.
#   - A variant with no sidecar AND no usable local cwd+git remote is
#     left alone — never grouped, never overwritten.
#
# The sidecar is intentionally a flat text key=value file so future
# metadata (machine origin, last-mirrored timestamp, etc.) can be added
# without changing tooling, and so reading is jq-free.
#
# Union strategy: only `.md` files are line-merged via `git merge-file
# --union` (matches the gitattributes union driver). Other files under
# `memory/` are copy-if-missing only — never byte-concatenated, so binary
# or structured non-text content can't be corrupted.
#
# Only `MEMORY.md` and files under `memory/` are mirrored — session
# transcripts and other local state are left alone. The sidecar is
# excluded from content sync; each variant maintains its own.

set +e
cd ~/.claude || exit 0
[ -d projects ] || exit 0

MARKER_FILE=".hive-mind"

# Read a key from a key=value sidecar. Echoes the value (or nothing).
read_meta() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  awk -F= -v k="$key" '
    /^[[:space:]]*#/ { next }
    $1 == k { sub(/^[^=]*=/, ""); print; exit }
  ' "$file"
}

# Normalize a git remote URL to a stable host/path form so SSH and HTTPS
# variants of the same repo group together.
#   git@github.com:user/repo.git  →  github.com/user/repo
#   https://github.com/user/repo  →  github.com/user/repo
# Does $1 (a path relative to ~/.claude) match its last committed
# version in HEAD? Non-zero for any modification, new-file, or untracked
# state. Used to distinguish an edit (one side diverged from HEAD) from
# concurrent additions (multiple sides diverged independently).
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

# Derive a project id from a variant's session jsonl + git remote.
# Echoes the normalized id on success; returns non-zero otherwise.
#
# Iterates every *.jsonl — earlier sessions may point to a path the user
# has since moved or deleted, so stopping at the first cwd leaves later,
# still-valid sessions unused and misclassifies the variant as
# unidentifiable.
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

# Determine the project identity for a variant dir. Echoes the id on
# success, returns non-zero on no-id-available. $2 is a newline-
# separated list of project-ids already observed in other variants'
# sidecars — used as the escape hatch for bootstrapping a content-less
# variant that's actually a cross-machine peer of an existing project.
discover_id() {
  local pdir="$1"
  local known="$2"
  local meta="$pdir/memory/$MARKER_FILE"
  local id=""

  # Sidecar already present → use it verbatim.
  if [ -f "$meta" ]; then
    id="$(read_meta "$meta" "project-id" | tr -d '\r\n')"
    if [ -n "$id" ]; then
      printf '%s' "$id"
      return 0
    fi
  fi

  # No sidecar — derive from cwd+remote; a variant with no jsonl or no
  # git remote is unidentifiable and must be skipped.
  id="$(derive_id_from_cwd "$pdir")" || return 1
  [ -z "$id" ] && return 1

  # Gate the bootstrap: only create a sidecar when either
  #  (a) this variant has real memory content, OR
  #  (b) the derived id matches a project-id already present in another
  #      variant's sidecar (cross-machine pull-down — an existing peer
  #      lets mirror replicate content INTO this fresh variant).
  # Both conditions must fail before we skip; without them, every
  # empty project Claude Code has ever opened gets published.
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

# Pass 1: collect every project-id already persisted to a sidecar.
# discover_id uses this set as the escape hatch that lets a content-
# less variant still bootstrap (and thus receive mirrored content)
# when it's a known peer — the cross-machine pull-down case.
known_ids=""
for d in projects/*/; do
  [ -d "$d" ] || continue
  pdir="${d%/}"
  meta="$pdir/memory/$MARKER_FILE"
  [ -f "$meta" ] || continue
  id="$(read_meta "$meta" "project-id" | tr -d '\r\n')"
  [ -n "$id" ] && known_ids="$known_ids$id"$'\n'
done

# Pass 2: build the manifest (id<TAB>variant_dir, one line per variant
# that resolves to an id).
manifest=""
for d in projects/*/; do
  [ -d "$d" ] || continue
  pdir="${d%/}"
  id="$(discover_id "$pdir" "$known_ids" 2>/dev/null)" || continue
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
    # `find -name` excludes the sidecar by literal basename; avoids the
    # regex-metachar pitfall of filtering via `grep "$MARKER_FILE"` where
    # the `.` would match any char.
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
      # Distinguish an EDIT (exactly one side diverged from the last
      # committed version) from CONCURRENT ADDITIONS (multiple sides
      # diverged independently). For an edit, take the diverged side
      # whole so old lines are replaced cleanly — the "edit a word
      # and both copies show the word changed" UX. For concurrent
      # adds, union-merge so neither side's new content is lost.
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
        # Zero modified = all pristine (cmp short-circuit handles the
        # no-op). Two-or-more = true concurrent divergence → union.
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
