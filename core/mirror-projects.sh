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
# the hub. For those adapters this script is a clean no-op: it exits
# when `projects/` is absent.
#
# Uses ADAPTER_DIR to locate the tool's config dir (e.g. ~/.claude);
# falls back to ~/.claude for backward compat.
#
# Identity model:
#   - Each variant carries a metadata sidecar at the variant root
#     (<variant>/.hive-mind), a key=value text file. Legacy installs
#     may still have it at <variant>/memory/.hive-mind — discover_id
#     checks both and migrates to root on first access.
#   - If the sidecar isn't there yet, derive from local session jsonl
#     + git remote, normalize, and persist at <variant>/.hive-mind.
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

# NOTE: under hub topology ADAPTER_DIR is not necessarily a git repo.
# When outside a repo, `git status` errors silently (stderr suppressed)
# and this returns true (empty output = "matches"), causing the
# single-editor optimization to degrade to union-merge. Acceptable
# for now — union-merge is the safe fallback. A content-based
# heuristic (compare file contents across variants) would be more
# robust but is deferred.
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

# Decode a Claude-encoded variant dirname back to a real filesystem
# path. The encoding (claude-code) replaces /, \, and : with `-`, which
# is lossy when a path component itself contains `-` (e.g. `my-project`
# and `my/project` encode to the same dirname). Enumerate every path
# that resolves on disk; succeed only if exactly one does.
#
# Input:  "c--Users-alice-Repo-my-project"  or  "-Users-alice-Repo-my-project"
# Output: "C:/Users/alice/Repo/my-project"  or  "/Users/alice/Repo/my-project"
#
# Returns empty on: no matching directory, ambiguous match (two or more
# distinct full paths resolve), or encoding that doesn't start with a
# recognized root prefix. Silence over guessing: a wrong decoding would
# write a wrong project-id into the sidecar.
_decode_variant_dirname() {
  local name="$1"
  local root rest results count

  if [[ "$name" =~ ^([a-zA-Z])--(.*)$ ]]; then
    # Windows: `c--Users-...` → root `C:/`, rest `Users-...`
    local drive
    drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
    root="${drive}:/"
    rest="${BASH_REMATCH[2]}"
  elif [[ "$name" == -* ]]; then
    # Unix: `-Users-...` → root `/`, rest `Users-...`
    root="/"
    rest="${name#-}"
  else
    return 1
  fi

  # Enumerate every full-path decoding that resolves on disk. Dedup,
  # then require exactly one — anything else is ambiguous and must not
  # silently pick a decoding.
  results="$(_decode_walk "$root" "$rest" | awk 'NF' | sort -u)"
  count="$(printf '%s\n' "$results" | awk 'NF' | wc -l | tr -d ' ')"
  if [ "$count" = "1" ]; then
    printf '%s' "$results"
    return 0
  fi
  return 1
}

# Walk from $current down through the `-`-split tokens of $remaining,
# emitting every full-path decoding that resolves on disk (one per
# line). Explores all split points at each level, not just the greedy
# longest — the caller decides whether >1 distinct result means the
# encoding is ambiguous.
_decode_walk() {
  local current="$1" remaining="$2"

  if [ -z "$remaining" ]; then
    [ -d "$current" ] && printf '%s\n' "${current%/}"
    return
  fi

  # Split remaining on '-' into an array.
  local IFS='-'
  # shellcheck disable=SC2206
  local parts=($remaining)
  unset IFS
  local n=${#parts[@]}
  [ "$n" -eq 0 ] && return

  local i j segment tail candidate sep
  # Iteration order (longest-first) is not load-bearing — every split
  # point is explored. Ambiguity is detected by emitting all resolved
  # paths and letting the caller count distinct results.
  for (( i = n; i >= 1; i-- )); do
    segment=""
    for (( j = 0; j < i; j++ )); do
      if [ -z "$segment" ]; then
        segment="${parts[j]}"
      else
        segment="${segment}-${parts[j]}"
      fi
    done
    sep="/"
    case "$current" in */) sep="" ;; esac
    candidate="${current}${sep}${segment}"
    [ -d "$candidate" ] || continue

    if [ "$i" -eq "$n" ]; then
      printf '%s\n' "${candidate%/}"
      continue
    fi

    tail=""
    for (( j = i; j < n; j++ )); do
      if [ -z "$tail" ]; then
        tail="${parts[j]}"
      else
        tail="${tail}-${parts[j]}"
      fi
    done
    _decode_walk "$candidate" "$tail"
  done
}

# Fallback identity path when no session jsonl is available. Decode the
# variant's directory name to a real path, then resolve the git remote
# the same way derive_id_from_cwd does. Keeps behaviour narrow: returns
# empty unless the decode is unambiguous AND the path is a git checkout
# with a usable `origin`.
derive_id_from_dirname() {
  local pdir="$1"
  local variant_name cwd remote id
  variant_name="${pdir##*/}"
  [ -n "$variant_name" ] || return 1

  cwd="$(_decode_variant_dirname "$variant_name")"
  [ -z "$cwd" ] && return 1
  [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ] || return 1

  remote="$(git -C "$cwd" remote get-url origin 2>/dev/null)"
  [ -z "$remote" ] && return 1
  id="$(normalize_remote "$remote")"
  [ -z "$id" ] && return 1
  printf '%s' "$id"
  return 0
}

discover_id() {
  local pdir="$1"
  local known="$2"
  # Check for sidecar at variant root (canonical) then legacy memory/ location.
  local meta=""
  if [ -f "$pdir/$MARKER_FILE" ]; then
    meta="$pdir/$MARKER_FILE"
  elif [ -f "$pdir/memory/$MARKER_FILE" ]; then
    meta="$pdir/memory/$MARKER_FILE"
  fi
  local id=""

  if [ -n "$meta" ] && [ -f "$meta" ]; then
    id="$(read_meta "$meta" "project-id" | tr -d '\r\n')"
    if [ -n "$id" ]; then
      # Migrate legacy sidecar to variant root if needed.
      if [ "$meta" = "$pdir/memory/$MARKER_FILE" ] && [ ! -f "$pdir/$MARKER_FILE" ]; then
        mv "$meta" "$pdir/$MARKER_FILE"
      elif [ "$meta" = "$pdir/memory/$MARKER_FILE" ] && [ -f "$pdir/$MARKER_FILE" ]; then
        rm -f "$meta"
      fi
      printf '%s' "$id"
      return 0
    fi
  fi

  id="$(derive_id_from_cwd "$pdir")"
  if [ -z "$id" ]; then
    # No jsonl-based identity — common when sessions have been
    # trimmed/cleared but memory files remain. Fall back to decoding
    # the variant's encoded-cwd directory name. Only kicks in when
    # jsonl discovery produced nothing; jsonl is authoritative.
    id="$(derive_id_from_dirname "$pdir")" || return 1
  fi
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
    # Check sibling variants' known ids first, then fall back to the
    # hub — a variant may be empty on this machine but the hub already
    # has content for this project-id from another machine.
    local id_known=0
    printf '%s\n' "$known" | grep -Fxq "$id" && id_known=1
    if [ "$id_known" -eq 0 ] && [ -n "${HIVE_MIND_HUB_DIR:-}" ] \
       && [ -d "$HIVE_MIND_HUB_DIR/projects/$id" ]; then
      id_known=1
    fi
    [ "$id_known" -eq 0 ] && return 1
  fi

  # Write sidecar at variant root (not inside memory/).
  printf 'project-id=%s\n' "$id" > "$pdir/$MARKER_FILE"
  printf '%s' "$id"
  return 0
}

# Pass 1: collect known project-ids from sidecars.
known_ids=""
for d in projects/*/; do
  [ -d "$d" ] || continue
  pdir="${d%/}"
  # Check variant root first (canonical), then legacy memory/ location.
  meta=""
  if [ -f "$pdir/$MARKER_FILE" ]; then
    meta="$pdir/$MARKER_FILE"
  elif [ -f "$pdir/memory/$MARKER_FILE" ]; then
    meta="$pdir/memory/$MARKER_FILE"
  fi
  [ -n "$meta" ] || continue
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
        # Git Bash / MSYS can't stat /dev/null (mapped to NUL), so
        # `git merge-file --union -p A /dev/null B` exits 255 silently
        # and leaves the merge unpopulated. Use a real empty tempfile
        # as the union base instead — portable across every shell.
        empty_base="$(mktemp)"
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
          if git merge-file --union -p "$merged" "$empty_base" "$src" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
            mv "$tmp" "$merged"
          else
            rm -f "$tmp"
          fi
        done <<<"$existing"
        rm -f "$empty_base"
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

    # Prepare a marker-stripped version for SIBLING copies. The source
    # variant keeps its markers so the hub sync's marker-extract can
    # read them and use them as the commit subject. Only siblings get
    # the stripped copy — without this, markers leak to every sibling
    # and get re-committed as stale subjects on the next sync cycle.
    merged_stripped=""
    if [ "$is_md" -eq 1 ] && grep -q '<!--[[:space:]]*commit:' "$merged" 2>/dev/null; then
      merged_stripped="$(mktemp)"
      awk '
        BEGIN { fence = 0 }
        /^[[:space:]]*```/ { fence = 1 - fence; print; next }
        fence == 1 { print; next }
        /^[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*[^>]+-->[[:space:]]*$/ { next }
        { gsub(/[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*[^>]+-->/, ""); print }
      ' "$merged" > "$merged_stripped"
    fi

    while IFS= read -r v; do
      [ -z "$v" ] && continue
      dst="$v/$rel"
      # Pick source: if the destination already has a commit marker,
      # DON'T overwrite it with the stripped version — that's the
      # source variant whose marker must survive for hub sync's
      # marker-extract. Every other destination gets the stripped copy.
      copy_src="$merged"
      if [ -n "$merged_stripped" ]; then
        if [ -f "$dst" ] && grep -q '<!--[[:space:]]*commit:' "$dst" 2>/dev/null; then
          copy_src="$merged"
        else
          copy_src="$merged_stripped"
        fi
      fi
      if [ -f "$dst" ]; then
        cmp -s "$dst" "$copy_src" && continue
        [ "$is_md" -eq 0 ] && continue
      fi
      mkdir -p "$(dirname "$dst")"
      cp "$copy_src" "$dst"
    done <<<"$variants"
    [ -n "$merged_stripped" ] && rm -f "$merged_stripped"

    rm -f "$merged"
  done <<<"$all_rels"

done <<<"$keys"

exit 0
