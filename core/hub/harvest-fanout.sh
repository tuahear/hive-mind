#!/usr/bin/env bash
# Hub topology (v0.3.0): bidirectional mapper between a tool's native
# config dir and the hub's provider-agnostic schema.
#
# Public entry points:
#   hub_harvest <tool-dir> <hub-dir>          tool → hub
#   hub_fan_out <hub-dir>  <tool-dir>         hub → tool
#   hub_is_machine_local <command-string>     0 if cmd references a
#                                             machine-specific path prefix
#   hub_parse_map <MAP-string>                emits valid entries, one per line
#   hub_parse_project_rules <RULES-string>    same shape as hub_parse_map
#
# Consumed from the environment:
#   ADAPTER_HUB_MAP                newline, TAB-delimited `<hub>\t<tool>` pairs
#   ADAPTER_PROJECT_CONTENT_RULES  newline, TAB-delimited `<hub-rel>\t<tool-rel>`
#                                  pairs applied under projects/<id>/
#   ADAPTER_LOG_PATH               (optional) where skip-logs go
#
# Sourced by core/hub/sync.sh. Never executed directly. Caller owns its
# own strict-mode choice; this file avoids `set -e` so partial map
# entries don't abort an entire sync cycle.

# Guard against double-sourcing. Re-sourcing wipes the machine-local
# pattern list (heredoc runs twice fine, but a caller that re-sources in
# an unstrict-mode script could hit an ordering issue).
if [ -n "${_HUB_HARVEST_FANOUT_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_HUB_HARVEST_FANOUT_LOADED=1

# Path prefixes that identify machine-local content. Hook command strings
# containing any of these are skipped during harvest (they'd make no sense
# on other machines). Deliberately conservative: common system paths on
# macOS/Linux/Windows. Users can opt into syncing a machine-local command
# only by pointing it through a stable indirection.
_HUB_MACHINE_LOCAL_PATTERNS='/Applications/
/opt/homebrew/
/usr/local/Cellar/
/usr/local/opt/
/System/
/Library/
~/Library/
/private/var/folders/
/tmp/
C:\
D:\
/mnt/c/'

# Route log lines to (in order of preference):
#   HIVE_MIND_HUB_LOG — set by core/hub/sync.sh to the hub's own log so
#                       machine-local-skip events surface where an
#                       operator grepping for "why didn't X reach the
#                       hub" would actually look.
#   ADAPTER_LOG_PATH — set by setup.sh and by single-adapter callers.
#   stderr — nothing else configured (unit tests pick this up via `run`).
_hub_log() {
  local msg="$*"
  local ts
  ts="$(date -u +%FT%TZ 2>/dev/null)"
  if [ -n "${HIVE_MIND_HUB_LOG:-}" ]; then
    printf '%s hub: %s\n' "$ts" "$msg" >>"$HIVE_MIND_HUB_LOG" 2>/dev/null
  elif [ -n "${ADAPTER_LOG_PATH:-}" ]; then
    printf '%s hub: %s\n' "$ts" "$msg" >>"$ADAPTER_LOG_PATH" 2>/dev/null
  else
    printf '%s hub: %s\n' "$ts" "$msg" >&2
  fi
}

hub_is_machine_local() {
  local cmd="$1"
  [ -n "$cmd" ] || return 1
  local pattern
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    case "$cmd" in
      *"$pattern"*) return 0 ;;
    esac
  done <<< "$_HUB_MACHINE_LOCAL_PATTERNS"
  return 1
}

# Emit valid `<hub>\t<tool>` entries from a map string. Drops blanks and
# malformed lines silently — the adapter contract requires `\t` delimiter.
hub_parse_map() {
  local map="$1"
  [ -z "$map" ] && return 0
  printf '%s\n' "$map" | awk -F'\t' '
    /^[[:space:]]*$/ { next }
    NF==2 && $1 != "" && $2 != "" { print $1 "\t" $2 }
  '
}

hub_parse_project_rules() {
  hub_parse_map "$1"
}

# --- internal helpers ------------------------------------------------------

# Derive a human-readable slug from a hook entry's first command.
# E.g. `"$HOME/.hive-mind/bin/sync"` → `sync`.
# Falls back to a content hash if no command is found.
_hub_entry_slug() {
  local entry_json="$1"
  local cmd
  cmd="$(jq -r '.. | objects | .command? // empty' <<<"$entry_json" 2>/dev/null | head -1)"
  if [ -n "$cmd" ]; then
    # Extract the FIRST path-like token from the command. Compound
    # commands (e.g. `"$HOME/.hive-mind/bin/sync" 2>>... || true;
    # "$HOME/.hive-mind/hive-mind/core/check-dupes.sh" ...`) have
    # multiple paths; we want the first one's basename as the slug.
    # Split on whitespace/semicolons/pipes, take the first token that
    # contains a `/`, then extract its basename.
    local first_path
    first_path="$(printf '%s' "$cmd" | tr ';|' ' ' | awk '{for(i=1;i<=NF;i++) if($i ~ /\//) {print $i; exit}}')"
    [ -z "$first_path" ] && first_path="$cmd"
    local slug="${first_path##*/}"
    # Strip quotes and extensions.
    slug="${slug%%\"*}"
    slug="${slug%%.sh}"
    slug="${slug%%.*}"
    # Sanitize: keep only alphanum + dash + underscore.
    slug="$(printf '%s' "$slug" | tr -cd 'a-zA-Z0-9_-')"
    [ -n "$slug" ] && { printf '%s' "$slug"; return 0; }
  fi
  # Fallback: generic name (no content hash — keep filenames readable).
  printf 'hook'
}

# File-like if the last path component has a '.'.
_hub_is_filelike() {
  local base="${1##*/}"
  case "$base" in
    *.*) return 0 ;;
    *)   return 1 ;;
  esac
}

# --- Fan-out snapshots (cross-provider harvest-stomp guard) ---------------
# Prior shipped behavior: harvest unconditionally overwrote hub content
# from a tool file, even when the tool file was identical to what the
# previous sync fanned out. In a two-adapter install that's a silent
# "last writer wins" stomp — the second adapter's harvest reverts the
# first adapter's edits on every cycle because the second tool file,
# unchanged since last fan-out, rewrites the hub section the first
# adapter just updated.
#
# Fix: after every write to a tool file (fan-out or post-harvest), drop
# a byte-for-byte snapshot under .hive-mind-state/fanout-snapshots/
# keyed by <tool-dir-basename>/<tool-rel-path>. On the next harvest, if
# the tool file is byte-identical to its snapshot, skip the harvest —
# the user didn't edit it, so there's nothing to contribute to the hub.
#
# Only applies to file-like (content.md / content.md[...]) entries. JSON
# subkey and directory entries keep their existing semantics (subkey
# writes are already narrow; dir mirroring has its own diff behavior).

_hub_snapshot_path() {
  local tool_dir="$1" rel="$2"
  # Strip trailing slash before extracting the basename — a caller that
  # passed "/path/to/.codex/" would otherwise yield base="" and collapse
  # every adapter's snapshots under fanout-snapshots// with cross-adapter
  # collisions. Matches the `${X%/}` idiom every glob-loop site in this
  # file already applies.
  local normalized="${tool_dir%/}"
  local base="${normalized##*/}"
  printf '%s/.hive-mind-state/fanout-snapshots/%s/%s' \
    "${HIVE_MIND_HUB_DIR:-$HOME/.hive-mind}" "$base" "$rel"
}

# Return 0 (match) iff the tool file and its snapshot both exist and are
# byte-identical. Any other case (missing file, missing snapshot,
# content differs) returns non-zero so harvest proceeds as usual.
_hub_tool_file_unchanged() {
  local tool_file="$1" snap="$2"
  [ -f "$tool_file" ] || return 1
  [ -f "$snap" ] || return 1
  cmp -s "$tool_file" "$snap"
}

# Record the current tool file as the "last-synced" snapshot. Creates
# parent dirs as needed. If the tool file is missing (e.g. fan-out was
# skipped for an absent section), leave any existing snapshot untouched
# — the old snapshot still reflects the last state we actually synced.
_hub_snapshot_write() {
  local tool_file="$1" snap="$2"
  [ -f "$tool_file" ] || return 0
  mkdir -p "$(dirname "$snap")" 2>/dev/null
  cp "$tool_file" "$snap"
}

# Split `<file>#<jsonpath>` into two fields on stdout (TAB-delimited).
# Returns non-zero if no '#' is present.
_hub_split_subkey() {
  local spec="$1"
  case "$spec" in
    *'#'*) printf '%s\t%s' "${spec%%#*}" "${spec#*#}" ;;
    *) return 1 ;;
  esac
}

# -- Sectioned content.md helpers ------------------------------------------
# A "sectioned" file uses paired HTML-comment markers to delimit sections
# inside a single file:
#
#     shared content (section 0, default bucket)
#     <!-- hive-mind:section=1 START -->
#     section 1 content
#     <!-- hive-mind:section=1 END -->
#
# Section 0 = every line OUTSIDE any START/END block. Section N>0 = content
# inside that block's markers. Blocks must not nest and must balance.
# Consumed by hub_harvest and hub_fan_out whenever an ADAPTER_HUB_MAP entry
# carries a bracket selector (see _hub_split_sections).

# Split `<path>[<selector>]` into path + selector on stdout, TAB-delim.
# Selector grammar (equivalent to `^(\*|[0-9]+(,[0-9]+)*)$`):
#   - "*" — expands at harvest/fan-out time to every section the file
#     actually contains (forward-compat for adapters that want to
#     round-trip any future tier without an adapter update).
#   - a CSV of one or more integer section ids with no empty elements
#     (e.g. "0", "1", "0,1"). Rejects "0,", ",0", "0,,1", etc. so typos
#     in ADAPTER_HUB_MAP fail when hub_harvest / hub_fan_out parse the
#     entry, instead of being silently normalized by the downstream
#     `tr ',' '\n' | awk 'NF'` pipeline in _hub_expand_sections.
#     (The adapter loader does not validate selectors — validation is
#     deferred to harvest/fan-out dispatch.)
# Returns 1 if no `[...]` selector is present or the grammar doesn't match.
_hub_split_sections() {
  local spec="$1"
  case "$spec" in
    *'['*']')
      local path="${spec%\[*}"
      local rest="${spec#*[}"
      local sel="${rest%]}"
      case "$sel" in
        '*') : ;;
        '' | *[!0-9,]* | ,* | *, | *,,*) return 1 ;;
      esac
      printf '%s\t%s' "$path" "$sel"
      ;;
    *) return 1 ;;
  esac
}

# Emit every section id present in a sectioned file, sorted ascending.
# Section 0 is included iff any content exists outside tagged blocks
# (non-blank outside line) OR the file has no markers at all.
# Non-zero ids come from the unique set of `<!-- hive-mind:section=N START
# -->` markers found. Empty file → no ids.
_hub_content_present_sections() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    BEGIN { in_block = 0; has_zero = 0; has_any_marker = 0 }
    /^<!-- hive-mind:section=[0-9]+ START -->$/ {
      match($0, /[0-9]+/)
      n = substr($0, RSTART, RLENGTH) + 0
      ids[n] = 1
      in_block = 1
      has_any_marker = 1
      next
    }
    /^<!-- hive-mind:section=[0-9]+ END -->$/ {
      in_block = 0
      has_any_marker = 1
      next
    }
    {
      if (!in_block && NF) has_zero = 1
    }
    END {
      # A file with NO markers at all is section 0 as a whole — report 0
      # even if every line is blank (empty file stays empty).
      if (!has_any_marker && NR > 0) has_zero = 1
      if (has_zero) ids[0] = 1
      n = 0
      for (k in ids) out[n++] = k
      # awk sort: insertion sort on small arrays is fine here.
      for (i = 1; i < n; i++) {
        v = out[i]; j = i - 1
        while (j >= 0 && out[j] > v) { out[j+1] = out[j]; j-- }
        out[j+1] = v
      }
      for (i = 0; i < n; i++) print out[i]
    }
  ' "$file"
}

# Expand a selector CSV (or "*") against a source file, emitting one
# integer id per line. When selector is "*", expand to every section
# present in the source. When selector is numeric, just normalize the CSV
# (sort ascending, dedupe).
_hub_expand_sections() {
  local sel="$1" src="$2"
  if [ "$sel" = '*' ]; then
    _hub_content_present_sections "$src"
  else
    printf '%s\n' "$sel" | tr ',' '\n' | awk 'NF' | sort -u -n
  fi
}

# Exit 0 if the file's section markers balance cleanly (every START has a
# matching END for the same id, no nesting), non-zero otherwise. Missing
# file exits 0 (nothing to validate).
_hub_content_markers_ok() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    BEGIN { open = 0; cur = -1; bad = 0 }
    /^<!-- hive-mind:section=[0-9]+ START -->$/ {
      if (open) { bad = 1; exit }
      match($0, /[0-9]+/)
      cur = substr($0, RSTART, RLENGTH) + 0
      open = 1
      next
    }
    /^<!-- hive-mind:section=[0-9]+ END -->$/ {
      if (!open) { bad = 1; exit }
      match($0, /[0-9]+/)
      n = substr($0, RSTART, RLENGTH) + 0
      if (n != cur) { bad = 1; exit }
      open = 0
      cur = -1
      next
    }
    { next }
    END { if (open) bad = 1; exit bad }
  ' "$file"
}

# Emit section `want` to stdout. want=0 returns everything outside blocks;
# want>0 returns the block body (markers stripped). Missing file and
# missing sections emit nothing.
_hub_content_read_section() {
  local file="$1" want="$2"
  [ -f "$file" ] || return 0
  awk -v want="$want" '
    BEGIN { in_block = 0; cur = -1 }
    /^<!-- hive-mind:section=[0-9]+ START -->$/ {
      match($0, /[0-9]+/)
      cur = substr($0, RSTART, RLENGTH) + 0
      in_block = 1
      next
    }
    /^<!-- hive-mind:section=[0-9]+ END -->$/ {
      if (in_block) {
        match($0, /[0-9]+/)
        n = substr($0, RSTART, RLENGTH) + 0
        if (n == cur) { in_block = 0; cur = -1; next }
      }
    }
    {
      if (!in_block && want == 0) print
      else if (in_block && cur == want) print
    }
  ' "$file"
}

# Rewrite `file` so that section `sid`'s content becomes the contents of
# `new`. Other sections' contents are preserved, and their order relative
# to each other is preserved, but the output is canonicalized: all
# section-0 (outside-block) content first, then every tagged block in
# the order they appeared. The original physical interleaving of blocks
# with outside content is NOT preserved. When sid>0 and the file has no
# matching block, the new block is appended at EOF. When sid=0 and `new`
# is empty, section 0 becomes empty (blocks retained). A fresh (non-
# existent) file is created with just the requested section.
_hub_content_replace_section() {
  local file="$1" sid="$2" new="$3"
  [ -n "$file" ] || return 1
  [ -n "$sid" ] || return 1
  [ -f "$new" ] || return 1

  local tmp outside blocks
  tmp="$(mktemp)" || return 1
  outside="$(mktemp)" || { rm -f "$tmp"; return 1; }
  blocks="$(mktemp)" || { rm -f "$tmp" "$outside"; return 1; }

  if [ -f "$file" ]; then
    awk -v outside="$outside" -v blocks="$blocks" '
      BEGIN { in_block = 0; cur = -1 }
      /^<!-- hive-mind:section=[0-9]+ START -->$/ {
        match($0, /[0-9]+/)
        cur = substr($0, RSTART, RLENGTH) + 0
        in_block = 1
        print > blocks
        next
      }
      /^<!-- hive-mind:section=[0-9]+ END -->$/ {
        if (in_block) {
          match($0, /[0-9]+/)
          n = substr($0, RSTART, RLENGTH) + 0
          if (n == cur) {
            print > blocks
            in_block = 0
            cur = -1
            next
          }
        }
      }
      {
        if (in_block) print > blocks
        else print > outside
      }
    ' "$file"
  else
    : > "$outside"
    : > "$blocks"
  fi

  if [ "$sid" -eq 0 ]; then
    cat "$new" > "$tmp"
    cat "$blocks" >> "$tmp"
  else
    cat "$outside" > "$tmp"
    awk -v sid="$sid" -v new="$new" '
      BEGIN { replaced = 0; skip = 0 }
      /^<!-- hive-mind:section=[0-9]+ START -->$/ {
        match($0, /[0-9]+/)
        n = substr($0, RSTART, RLENGTH) + 0
        if (n == sid) {
          printf "<!-- hive-mind:section=%d START -->\n", sid
          while ((getline line < new) > 0) print line
          close(new)
          printf "<!-- hive-mind:section=%d END -->\n", sid
          skip = 1
          replaced = 1
          next
        }
        print
        next
      }
      /^<!-- hive-mind:section=[0-9]+ END -->$/ {
        if (skip) {
          match($0, /[0-9]+/)
          n = substr($0, RSTART, RLENGTH) + 0
          if (n == sid) { skip = 0; next }
        }
        print
        next
      }
      {
        if (skip) next
        print
      }
      END {
        if (!replaced) {
          printf "<!-- hive-mind:section=%d START -->\n", sid
          while ((getline line < new) > 0) print line
          close(new)
          printf "<!-- hive-mind:section=%d END -->\n", sid
        }
      }
    ' "$blocks" >> "$tmp"
  fi

  mv "$tmp" "$file"
  rm -f "$outside" "$blocks"
}

# Fan-out: write selected sections from a hub content file to a tool file.
# sel: CSV of section ids, or "*" (every section present in src). Semantics:
#   - single id: write that section's body plain (markers stripped).
#   - multiple ids (or "*" expanding to >1 id): write section 0 plain (if
#     selected), then each non-zero section wrapped in its own START/END
#     markers in ascending-id order.
#   - "*" expanding to a single id: treated like that single id.
# `_hub_content_read_section` emits via awk's `print`, so every line already
# ends in \n and successive blocks separate cleanly without manual fixups.
_hub_content_fanout_to_file() {
  local src="$1" sel="$2" dst="$3"
  [ -f "$src" ] || return 0

  # Marker-integrity check for selectors that drive a marker-based parse
  # ("*" or explicit multi-id CSV). Symmetric with the harvest-side
  # validation — if content.md has damaged markers, fan-out could
  # silently mis-route content; skip + log and leave dst untouched.
  # Single-id selectors read one whole section without parsing other
  # markers, so they tolerate marker damage elsewhere in the file.
  case "$sel" in
    \*|*,*)
      if ! _hub_content_markers_ok "$src"; then
        _hub_log "fan-out: skipping sectioned fanout for $src (marker imbalance)"
        return 0
      fi
      ;;
  esac

  local ids count
  ids="$(_hub_expand_sections "$sel" "$src")"
  count="$(printf '%s\n' "$ids" | awk 'NF' | wc -l | tr -d ' ')"

  # Handle "src exists but expands to zero sections". A missing src
  # already returned above; for an existing-but-empty src the semantics
  # split by selector:
  #   - Wildcard '*': "present but empty" — cross-machine 'clear all
  #     memory' edits must propagate, so select section 0 and let the
  #     empty body overwrite dst.
  #   - Anything else (single non-zero id, explicit CSV): the user asked
  #     for specific sections that aren't in src; leave dst untouched.
  if [ "$count" = "0" ]; then
    case "$sel" in
      \*)
        ids="0"
        count="1"
        ;;
      *)
        return 0
        ;;
    esac
  fi

  # Single-id skip-on-absent check: if the requested non-zero section
  # isn't in src, leave dst untouched. Two intentional exceptions:
  # - Section 0 is the default bucket (everything outside any block)
  #   and is always "present as a concept" when the hub file exists —
  #   _hub_content_present_sections only reports 0 when outside content
  #   or markerless content exists, so a blocks-only hub legitimately
  #   wants to write an empty dst to clear the shared tier.
  # - "Present but empty body" (START + END with nothing between) still
  #   counts as present via present_sections, so that case writes an
  #   empty dst — distinct from true absence.
  if [ "$count" = "1" ] && [ "$ids" != "0" ] \
     && ! _hub_content_present_sections "$src" | grep -Fxq "$ids"; then
    _hub_log "fan-out: skipping $dst (section $ids absent from $src)"
    return 0
  fi

  mkdir -p "$(dirname "$dst")" 2>/dev/null
  local tmp
  tmp="$(mktemp)"

  if [ "$count" = "1" ]; then
    # Wildcard intent: when sel='*' expands to a single non-zero id (the
    # hub is blocks-only), the tool file must keep the section markers
    # so the next harvest cycle round-trips the content back to that
    # section. Without markers, the next harvest would reclassify the
    # tool-side content as section 0 (markerless → shared tier) — a
    # silent privacy downgrade. Explicit single-id selectors (like [1])
    # still want plain output — that's the whole point of selecting one
    # specific tier as the tool's surface.
    if [ "$sel" = '*' ] && [ "$ids" != "0" ]; then
      {
        printf '<!-- hive-mind:section=%s START -->\n' "$ids"
        _hub_content_read_section "$src" "$ids"
        printf '<!-- hive-mind:section=%s END -->\n' "$ids"
      } > "$tmp"
    else
      _hub_content_read_section "$src" "$ids" > "$tmp"
    fi
  else
    {
      local id
      if printf '%s\n' "$ids" | grep -qx '0'; then
        _hub_content_read_section "$src" 0
      fi
      while IFS= read -r id; do
        [ -z "$id" ] && continue
        [ "$id" = "0" ] && continue
        printf '<!-- hive-mind:section=%s START -->\n' "$id"
        _hub_content_read_section "$src" "$id"
        printf '<!-- hive-mind:section=%s END -->\n' "$id"
      done <<EOF
$ids
EOF
    } > "$tmp"
  fi

  mv "$tmp" "$dst"
}

# Harvest: replace selected sections in a hub content file from a tool file.
# sel: CSV of section ids, or "*" (every section present in src).
#   - Single id (numeric OR "*" expanding to one id): whole tool file
#     becomes that section.
#   - Multiple ids (or "*" expanding to >1 ids): parse tool file by markers,
#     extract each selected section, replace in hub.
# Unbalanced markers in the tool file → log + skip, hub preserved.
_hub_content_harvest_from_file() {
  local src="$1" sel="$2" dst="$3"
  [ -f "$src" ] || return 0
  mkdir -p "$(dirname "$dst")" 2>/dev/null

  # Validate markers up front only for selectors that drive a marker-
  # based parse: a literal "*" (wildcard, expands from the tool file's
  # actual section list) or any explicit multi-id CSV (contains a
  # comma). Single-id selectors like "0" / "1" treat the tool file as
  # plain content for that section and must not be blocked by unrelated
  # marker imbalance elsewhere in the file.
  local needs_valid_markers=0
  case "$sel" in
    \*|*,*) needs_valid_markers=1 ;;
  esac
  if [ "$needs_valid_markers" -eq 1 ] && ! _hub_content_markers_ok "$src"; then
    _hub_log "harvest: skipping sectioned harvest for $src (marker imbalance)"
    return 0
  fi

  local ids count
  ids="$(_hub_expand_sections "$sel" "$src")"
  count="$(printf '%s\n' "$ids" | awk 'NF' | wc -l | tr -d ' ')"

  if [ "$count" = "0" ]; then
    return 0
  fi
  if [ "$count" = "1" ]; then
    # Symmetric with fan-out's wildcard-single-non-zero branch: fan-out
    # wraps the section body in START/END markers so the tool file
    # round-trips cleanly. Harvest must parse those markers back out —
    # passing the whole tool file through _hub_content_replace_section
    # would nest the markers inside the hub's section body and leak
    # stray END lines into section 0 on the next read.
    # Explicit single-id selectors like [1] take the plain whole-file
    # path — the adapter declared that tier as its sole surface.
    if [ "$sel" = '*' ] && [ "$ids" != "0" ]; then
      local tmp_body
      tmp_body="$(mktemp)"
      _hub_content_read_section "$src" "$ids" > "$tmp_body"
      _hub_content_replace_section "$dst" "$ids" "$tmp_body"
      rm -f "$tmp_body"
    else
      _hub_content_replace_section "$dst" "$ids" "$src"
    fi
    return 0
  fi

  local id tmp
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    tmp="$(mktemp)"
    _hub_content_read_section "$src" "$id" > "$tmp"
    _hub_content_replace_section "$dst" "$id" "$tmp"
    rm -f "$tmp"
  done <<EOF
$ids
EOF
}

# Dedupe non-trivial lines within each section independently (stdin/stdout
# variant for testability; callers typically wrap a file in <).
# Uses the same "non-trivial" heuristic as core/check-dupes.sh: length >= 20,
# skip blanks, comments, rule-like separators, and fenced-code fences.
# Markers partition the scan so a line appearing in section 0 and section 1
# is never deduped across the boundary.
_hub_dedupe_sections() {
  awk '
    function reset_seen() { for (k in seen) delete seen[k] }
    /^<!-- hive-mind:section=[0-9]+ START -->$/ { reset_seen(); print; next }
    /^<!-- hive-mind:section=[0-9]+ END -->$/   { reset_seen(); print; next }
    NF && length($0) >= 20 \
      && !/^[[:space:]]*#/ \
      && !/^[[:space:]]*[-=*_]{3,}[[:space:]]*$/ \
      && !/^[[:space:]]*`{3,}/ {
      if (seen[$0]++) next
    }
    { print }
  '
}

# Canonicalize an adapter-declared dotted jsonpath to the bare key list
# (no leading dot) — jq's getpath/setpath take an array of keys, and
# `split(".")` on ".permissions.allow" produces a spurious empty-string
# segment that breaks lookup. Strip the leading dot; caller already
# re-adds it where jq's filter syntax needs it.
_hub_jsonpath_to_jq() {
  local p="$1"
  printf '%s' "${p#.}"
}

# Mirror a single file: create parents, cp src → dst. If src is absent,
# DO NOT touch dst — an absent tool-side file is ambiguous ("user
# deleted it" vs "user never had this one yet"), and blindly deleting
# would wipe legitimate content in multi-adapter setups where only one
# adapter has the file while others harvest in parallel against the
# same hub path. Deletions that users do want to propagate can be
# applied by editing the hub file's content or removing it directly.
#
# Marker preservation: if dst already contains a commit marker and src
# doesn't, skip the overwrite. This prevents a sibling variant's
# marker-stripped copy from overwriting the source variant's marker-
# containing copy during multi-variant harvest. The marker needs to
# survive in the hub until the commit phase's marker-extract reads it.
_hub_sync_file() {
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0

  # Marker preservation: don't overwrite a marker-containing dst with
  # a marker-free src (prevents fan-out from erasing source markers).
  if [ -f "$dst" ] \
     && grep -q '<!--[[:space:]]*commit:' "$dst" 2>/dev/null \
     && ! grep -q '<!--[[:space:]]*commit:' "$src" 2>/dev/null; then
    return 0
  fi

  mkdir -p "$(dirname "$dst")" 2>/dev/null
  cp "$src" "$dst"
}

# Mirror a directory tree src → dst. When src_dir EXISTS, files present
# in src overwrite dst and files in dst with no counterpart in src are
# removed — the user's intent within an active tree is unambiguous.
# When src_dir is ABSENT, leave dst alone: same rationale as
# _hub_sync_file above (multi-adapter setups where only some adapters
# populate this subtree). Top-level dst is preserved even if empty.
_hub_sync_dir() {
  local src_dir="$1" dst_dir="$2"
  if [ ! -d "$src_dir" ]; then
    return 0
  fi
  mkdir -p "$dst_dir"
  # src → dst
  (cd "$src_dir" && find . -type f -print0 2>/dev/null) \
    | while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        mkdir -p "$dst_dir/$(dirname "$rel")" 2>/dev/null
        cp "$src_dir/$rel" "$dst_dir/$rel"
      done
  # Remove dst files not in src.
  (cd "$dst_dir" && find . -type f -print0 2>/dev/null) \
    | while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        [ -f "$src_dir/$rel" ] || rm -f "$dst_dir/$rel"
      done
  # Prune empty subdirs (keep dst_dir itself).
  find "$dst_dir" -mindepth 1 -type d -empty -delete 2>/dev/null
}

# True if any command string inside a hook wrapper entry (outer shape
# {matcher?, hooks: [{command, ...}]}) references a machine-local path.
_hub_entry_has_machine_local() {
  local entry_json="$1"
  local cmd
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    if hub_is_machine_local "$cmd"; then
      return 0
    fi
  done < <(jq -r '.. | objects | .command? // empty' <<<"$entry_json" 2>/dev/null)
  return 1
}

# Harvest: split `.hooks[event]` arrays in the tool-side JSON into
# per-event/<id>.json files under the hub dir, filtering machine-local.
# Nukes and rewrites each event dir so deletions propagate. Leaves other
# event dirs (written by other adapters) untouched.
_hub_harvest_hooks_dir() {
  local tool_file="$1" jsonpath="$2" hub_dir="$3"
  [ -f "$tool_file" ] || return 0
  mkdir -p "$hub_dir"

  local events
  events="$(jq -r --arg jp "$jsonpath" '
    getpath($jp | split(".")) // {} | keys[]?
  ' "$tool_file" 2>/dev/null)"
  [ -z "$events" ] && return 0

  local event entries_json entry canon id
  while IFS= read -r event; do
    event="${event%$'\r'}"
    [ -z "$event" ] && continue
    entries_json="$(jq -c --arg jp "$jsonpath" --arg e "$event" '
      (getpath($jp | split(".")) // {})[$e] // [] | .[]
    ' "$tool_file" 2>/dev/null)"

    # Build fresh set of this machine's non-local entries for this event.
    local event_dir="$hub_dir/$event"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      if _hub_entry_has_machine_local "$entry"; then
        _hub_log "harvest: skipped machine-local hook in $event: $(printf '%s' "$entry" | head -c 80)"
        continue
      fi
      canon="$(jq -cS . <<<"$entry" 2>/dev/null)"
      [ -z "$canon" ] && continue
      local slug
      slug="$(_hub_entry_slug "$canon")"
      [ -z "$slug" ] && continue
      # Dedup: if two entries produce the same slug (e.g. two hooks
      # whose command basename is identical), append a counter.
      if [ -f "$tmp_dir/$slug.json" ]; then
        local n=2
        while [ -f "$tmp_dir/${slug}-${n}.json" ]; do n=$((n + 1)); done
        slug="${slug}-${n}"
      fi
      printf '%s\n' "$canon" > "$tmp_dir/$slug.json"
    done <<<"$entries_json"

    # Replace event dir atomically-ish: nuke, then move contents.
    rm -rf "$event_dir"
    mkdir -p "$event_dir"
    # Moves only if any files were written — otherwise leave an empty dir.
    if [ -n "$(ls -A "$tmp_dir" 2>/dev/null)" ]; then
      mv "$tmp_dir"/*.json "$event_dir/"
    fi
    rm -rf "$tmp_dir"
  done <<<"$events"
}

# Fan-out: reconstruct `.hooks` subtree from hub's per-event dirs,
# preserve any machine-local entries already in the tool file, and merge
# back in. Event names not represented in hub are left untouched.
_hub_fan_out_hooks_dir() {
  local hub_dir="$1" tool_file="$2" jsonpath="$3"
  [ -d "$hub_dir" ] || return 0
  mkdir -p "$(dirname "$tool_file")" 2>/dev/null
  [ -f "$tool_file" ] || printf '{}\n' > "$tool_file"

  local event_path event_dir event entries_json
  for event_path in "$hub_dir"/*/; do
    [ -d "$event_path" ] || continue
    event_dir="${event_path%/}"
    event="${event_dir##*/}"
    event="${event%$'\r'}"

    # Concatenate all hub entries for this event into a JSON array.
    # Skip empty event dirs (no .json files) — the glob would fail.
    local json_files
    json_files="$(find "$event_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)"
    if [ -z "$json_files" ]; then
      entries_json="[]"
    else
      entries_json="$(find "$event_dir" -maxdepth 1 -name '*.json' -type f -print0 | xargs -0 jq -cs . 2>/dev/null)"
      [ -z "$entries_json" ] && entries_json="[]"
    fi

    # Merge into tool file: keep machine-local tool entries for this
    # event, add hub entries. jq handles the de-machine-local split via
    # a walker that scans each wrapper's command strings against the
    # adapter-supplied pattern list (passed as a newline string).
    local tmp
    tmp="$(mktemp)"
    if jq \
      --arg jp "$jsonpath" \
      --arg event "$event" \
      --argjson hub "$entries_json" \
      --arg patterns "$_HUB_MACHINE_LOCAL_PATTERNS" '
        def is_machine_local:
          . as $cmd
          | ($patterns | split("\n") | map(select(length > 0)))
          | any(. as $p | $cmd | contains($p));
        def wrapper_is_machine_local:
          [.. | objects | .command? // empty]
          | any(is_machine_local);

        # Read current tool entries for this event, keep only machine-local ones.
        (getpath($jp | split(".")) // {}) as $hooks
        | ($hooks[$event] // []) as $existing
        | ($existing | map(select(wrapper_is_machine_local))) as $local_only
        | setpath(($jp | split(".")) + [$event]; ($local_only + $hub))
      ' "$tool_file" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$tool_file"
    else
      rm -f "$tmp"
      _hub_log "fan-out: jq merge failed for $tool_file#$jsonpath.$event"
    fi
  done
}

# Harvest a JSON array field into a text file, one entry per line.
_hub_harvest_text_list() {
  local tool_file="$1" jsonpath="$2" hub_file="$3"
  [ -f "$tool_file" ] || return 0
  mkdir -p "$(dirname "$hub_file")" 2>/dev/null
  local arr
  arr="$(jq -r --arg jp "$jsonpath" '
    getpath($jp | split(".")) // [] | .[]?
  ' "$tool_file" 2>/dev/null)"
  # Always emit a file so an emptied list is observable downstream.
  printf '%s' "$arr" > "$hub_file"
  if [ -n "$arr" ]; then
    printf '\n' >> "$hub_file"
  fi
}

# Fan out a newline-separated text list into a JSON array field.
_hub_fan_out_text_list() {
  local hub_file="$1" tool_file="$2" jsonpath="$3"
  [ -f "$hub_file" ] || return 0
  mkdir -p "$(dirname "$tool_file")" 2>/dev/null
  [ -f "$tool_file" ] || printf '{}\n' > "$tool_file"
  local tmp
  tmp="$(mktemp)"
  if jq \
    --arg jp "$jsonpath" \
    --rawfile raw "$hub_file" '
      setpath($jp | split(".");
        ($raw | split("\n") | map(select(length > 0))))
    ' "$tool_file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$tool_file"
  else
    rm -f "$tmp"
    _hub_log "fan-out: jq set failed for $tool_file#$jsonpath"
  fi
}

# --- entry: per-project content --------------------------------------------

# Read project-id from a variant's sidecar. Checks two locations:
#   1. $variant/.hive-mind (new canonical location — variant root)
#   2. $variant/memory/.hive-mind (legacy location, pre-root-migration)
# Always exits 0 so callers under `set -e` don't abort on missing sidecars.
_hub_read_project_id() {
  local variant="$1"
  local sidecar=""
  if [ -f "$variant/.hive-mind" ]; then
    sidecar="$variant/.hive-mind"
  elif [ -f "$variant/memory/.hive-mind" ]; then
    sidecar="$variant/memory/.hive-mind"
  else
    return 0
  fi
  awk -F= '
    /^[[:space:]]*#/ { next }
    $1 == "project-id" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; exit }
  ' "$sidecar"
}

# Apply ADAPTER_PROJECT_CONTENT_RULES between a single tool variant and a
# single hub project dir. Rules map hub-rel → tool-rel; direction param
# is "harvest" (tool→hub) or "fanout" (hub→tool).
#
# Special rule: if hub_rel is `*`, it's a catch-all: every file in the
# hub project dir NOT matched by an explicit rule above gets synced
# to/from tool_variant/<tool-rel>/ (the tool_rel for `*` is a subdir
# name). This supports the flattened hub project layout where the hub
# stores all per-project subfiles at the project root while the tool
# keeps them in a subdirectory (e.g. Claude's `memory/`).
_hub_apply_project_rules() {
  local direction="$1" tool_variant="$2" hub_proj="$3"
  local rules="${ADAPTER_PROJECT_CONTENT_RULES:-}"
  [ -n "$rules" ] || return 0

  # Two-pass processing: dir rules first, file rules second.
  local hub_rel tool_rel src dst

  # Pass 1: directory rules.
  # HARVEST direction uses add-only (no delete from dst). Multiple
  # tool-side variants can share the same hub project-id; if the last
  # variant to harvest lacks a file that an earlier variant added, the
  # dir-sync's delete-absent logic would remove it. Add-only means
  # every variant's files accumulate in the hub. Fan-out (hub→tool)
  # still deletes, since the hub is authoritative.
  while IFS=$'\t' read -r hub_rel tool_rel; do
    [ -z "$hub_rel" ] && continue
    [ -z "$tool_rel" ] && continue
    _hub_is_filelike "$hub_rel" && continue
    if [ "$direction" = "harvest" ]; then
      # Add-only: copy src→dst, skip the delete-absent pass.
      local s="$tool_variant/$tool_rel" d="$hub_proj/$hub_rel"
      if [ -d "$s" ]; then
        mkdir -p "$d"
        (cd "$s" && find . -type f -print0 2>/dev/null) \
          | while IFS= read -r -d '' rel; do
              rel="${rel#./}"
              _hub_sync_file "$s/$rel" "$d/$rel"
            done
      fi
    else
      _hub_sync_dir "$hub_proj/$hub_rel" "$tool_variant/$tool_rel"
    fi
  done < <(hub_parse_project_rules "$rules")

  # Pass 2: file rules (overwrite anything the dir-sync deleted/placed).
  while IFS=$'\t' read -r hub_rel tool_rel; do
    [ -z "$hub_rel" ] && continue
    [ -z "$tool_rel" ] && continue
    _hub_is_filelike "$hub_rel" || continue
    if [ "$direction" = "harvest" ]; then
      _hub_sync_file "$tool_variant/$tool_rel" "$hub_proj/$hub_rel"
    else
      _hub_sync_file "$hub_proj/$hub_rel" "$tool_variant/$tool_rel"
    fi
  done < <(hub_parse_project_rules "$rules")
}

# --- entry: skills with content-file rename --------------------------------

# Sync skills between tool and hub with the content-file rename:
# tool's SKILL.md ↔ hub's content.md. All other files and subdirs
# in each skill folder pass through unchanged — skills are folders
# specifically to allow helper scripts, configs, and assets alongside
# the content file.
_hub_sync_skills() {
  local direction="$1" src_root="$2" dst_root="$3"
  [ -d "$src_root" ] || return 0
  mkdir -p "$dst_root" 2>/dev/null
  local skill_src skill_name skill_dst
  for skill_src in "$src_root"/*/; do
    [ -d "$skill_src" ] || continue
    skill_name="${skill_src%/}"
    skill_name="${skill_name##*/}"
    skill_dst="$dst_root/$skill_name"
    mkdir -p "$skill_dst" 2>/dev/null
    # Recursive copy: walk all files in the skill tree.
    while IFS= read -r -d '' f; do
      local rel="${f#"$skill_src"}"
      local dst_name="$rel"
      # Rename only the root content file.
      if [ "$direction" = "harvest" ] && [ "$rel" = "SKILL.md" ]; then
        dst_name="content.md"
      elif [ "$direction" = "fanout" ] && [ "$rel" = "content.md" ]; then
        dst_name="SKILL.md"
      fi
      mkdir -p "$(dirname "$skill_dst/$dst_name")" 2>/dev/null
      cp "$f" "$skill_dst/$dst_name"
    done < <(find "$skill_src" -type f -print0 2>/dev/null)
    # Prune dst files not in src — fan-out only.
    if [ "$direction" = "fanout" ]; then
      while IFS= read -r -d '' f; do
        local rel="${f#"$skill_dst/"}"
        local src_name="$rel"
        if [ "$rel" = "SKILL.md" ]; then
          src_name="content.md"
        fi
        [ -f "$skill_src/$src_name" ] || rm -f "$f"
      done < <(find "$skill_dst" -type f -print0 2>/dev/null)
      # Remove empty subdirs left by pruning.
      find "$skill_dst" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    fi
  done
  # Remove dst skill dirs not in src — fan-out only.
  if [ "$direction" = "fanout" ]; then
    for skill_dst in "$dst_root"/*/; do
      [ -d "$skill_dst" ] || continue
      skill_name="${skill_dst%/}"
      skill_name="${skill_name##*/}"
      [ -d "$src_root/$skill_name" ] || rm -rf "$skill_dst"
    done
  fi
}

# --- main entry points -----------------------------------------------------

# Harvest: tool → hub. Applies every entry in ADAPTER_HUB_MAP, then walks
# per-project variants to apply ADAPTER_PROJECT_CONTENT_RULES.
hub_harvest() {
  local tool_dir="$1" hub_dir="$2"
  [ -d "$tool_dir" ] || return 0
  mkdir -p "$hub_dir" 2>/dev/null

  local hub_rel tool_spec file_part jsonpath_part pair sec_pair
  while IFS=$'\t' read -r hub_rel tool_spec; do
    [ -z "$hub_rel" ] && continue
    [ -z "$tool_spec" ] && continue

    if pair="$(_hub_split_subkey "$tool_spec")"; then
      file_part="${pair%%$'\t'*}"
      jsonpath_part="${pair#*$'\t'}"
      local tool_json="$tool_dir/$file_part"
      local jq_path
      jq_path="$(_hub_jsonpath_to_jq "$jsonpath_part")"

      if _hub_is_filelike "$hub_rel"; then
        _hub_harvest_text_list "$tool_json" "$jq_path" "$hub_dir/$hub_rel"
      else
        _hub_harvest_hooks_dir "$tool_json" "$jq_path" "$hub_dir/$hub_rel"
      fi
    elif sec_pair="$(_hub_split_sections "$hub_rel")"; then
      local hub_file sel snap
      hub_file="${sec_pair%%$'\t'*}"
      sel="${sec_pair#*$'\t'}"
      snap="$(_hub_snapshot_path "$tool_dir" "$tool_spec")"
      # Skip harvest when the tool file is byte-identical to its last
      # fan-out snapshot — the user didn't edit this adapter's surface
      # since the previous sync, so there's nothing to contribute. This
      # is the guard against the cross-provider harvest-stomp: without
      # it, the second adapter's unchanged tool file would blindly
      # overwrite the hub section the first adapter just updated.
      if ! _hub_tool_file_unchanged "$tool_dir/$tool_spec" "$snap"; then
        _hub_content_harvest_from_file \
          "$tool_dir/$tool_spec" "$sel" "$hub_dir/$hub_file"
        _hub_snapshot_write "$tool_dir/$tool_spec" "$snap"
      fi
    elif case "$hub_rel" in *'['*|*']'*) true ;; *) false ;; esac; then
      # Bracket-bearing hub path that failed selector validation. Covers
      # every typo shape where _hub_split_sections's strict `*'['*']'`
      # glob doesn't match: trailing-comma (`content.md[0,]`), missing
      # close bracket (`content.md[0`), missing open bracket
      # (`content.md0]`), reversed brackets (`content.md][`), standalone
      # bracket (`content.md[`). Without this guard the entry falls
      # through to _hub_sync_file and creates a literal file with the
      # broken-bracket name in the hub, silently masking the typo.
      _hub_log "harvest: skipping entry with malformed section selector: $hub_rel"
    else
      local src="$tool_dir/$tool_spec"
      local dst="$hub_dir/$hub_rel"
      if _hub_is_filelike "$hub_rel"; then
        local snap
        snap="$(_hub_snapshot_path "$tool_dir" "$tool_spec")"
        # Same harvest-stomp guard as the sectioned path — skip when
        # the tool file matches its last fan-out snapshot.
        if ! _hub_tool_file_unchanged "$src" "$snap"; then
          _hub_sync_file "$src" "$dst"
          _hub_snapshot_write "$src" "$snap"
        fi
      else
        _hub_sync_dir "$src" "$dst"
      fi
    fi
  done < <(hub_parse_map "${ADAPTER_HUB_MAP:-}")

  # Skills: content-file rename (SKILL.md ↔ content.md). Handled here
  # instead of via an ADAPTER_HUB_MAP dir-mirror entry because the
  # generic _hub_sync_dir has no rename support.
  local tool_skills="${ADAPTER_SKILL_ROOT:-$tool_dir/skills}"
  _hub_sync_skills harvest "$tool_skills" "$hub_dir/skills"

  # Per-project content. Claude uses projects/<encoded-cwd>/; the sidecar
  # at <variant>/memory/.hive-mind exposes project-id. Skip variants that
  # have no sidecar — they're unbootstrapped (mirror-projects handles the
  # bootstrap before this runs).
  local proj_root="$tool_dir/projects"
  [ -d "$proj_root" ] || return 0
  local variant id variant_name
  for variant in "$proj_root"/*/; do
    [ -d "$variant" ] || continue
    variant="${variant%/}"
    id="$(_hub_read_project_id "$variant" 2>/dev/null || true)"
    [ -z "$id" ] && continue
    variant_name="${variant##*/}"
    local hub_proj="$hub_dir/projects/$id"
    mkdir -p "$hub_proj"
    _hub_apply_project_rules harvest "$variant" "$hub_proj"
    # Persist project-id in the hub sidecar. No `path=` key — the
    # encoded-cwd folder name is machine-specific (different machines
    # have different checkout paths) so a single path value would be
    # wrong/misleading on every machine except the one that wrote it.
    printf 'project-id=%s\n' "$id" > "$hub_proj/.hive-mind"
    # Migrate tool-side sidecar from legacy memory/.hive-mind to the
    # variant root. The root is the correct location — the sidecar is
    # metadata about the variant, not memory content.
    if [ -f "$variant/memory/.hive-mind" ] && [ ! -f "$variant/.hive-mind" ]; then
      mv "$variant/memory/.hive-mind" "$variant/.hive-mind"
    elif [ -f "$variant/memory/.hive-mind" ] && [ -f "$variant/.hive-mind" ]; then
      rm -f "$variant/memory/.hive-mind"
    fi
  done
}

# Fan-out: hub → tool. Mirror of hub_harvest, including project walk.
# For JSON-subkey entries, preserves tool-side machine-local entries
# and any fields outside the jsonpath.
hub_fan_out() {
  local hub_dir="$1" tool_dir="$2"
  [ -d "$hub_dir" ] || return 0
  mkdir -p "$tool_dir" 2>/dev/null

  local hub_rel tool_spec file_part jsonpath_part pair sec_pair
  while IFS=$'\t' read -r hub_rel tool_spec; do
    [ -z "$hub_rel" ] && continue
    [ -z "$tool_spec" ] && continue

    if pair="$(_hub_split_subkey "$tool_spec")"; then
      file_part="${pair%%$'\t'*}"
      jsonpath_part="${pair#*$'\t'}"
      local tool_json="$tool_dir/$file_part"
      local jq_path
      jq_path="$(_hub_jsonpath_to_jq "$jsonpath_part")"

      if _hub_is_filelike "$hub_rel"; then
        _hub_fan_out_text_list "$hub_dir/$hub_rel" "$tool_json" "$jq_path"
      else
        _hub_fan_out_hooks_dir "$hub_dir/$hub_rel" "$tool_json" "$jq_path"
      fi
    elif sec_pair="$(_hub_split_sections "$hub_rel")"; then
      local hub_file sel
      hub_file="${sec_pair%%$'\t'*}"
      sel="${sec_pair#*$'\t'}"
      _hub_content_fanout_to_file \
        "$hub_dir/$hub_file" "$sel" "$tool_dir/$tool_spec"
      # Update the snapshot so the next harvest can tell whether the
      # user edited this file between cycles (unchanged = skip harvest,
      # preventing the cross-provider stomp). If the fan-out skipped
      # because the section was absent, the tool file wasn't written
      # and _hub_snapshot_write's [ -f ] guard leaves the old snapshot
      # in place — still reflects the last actually-synced state.
      _hub_snapshot_write "$tool_dir/$tool_spec" \
        "$(_hub_snapshot_path "$tool_dir" "$tool_spec")"
    elif case "$hub_rel" in *'['*|*']'*) true ;; *) false ;; esac; then
      # Same malformed-selector guard as the harvest phase — any entry
      # containing `[` or `]` that failed _hub_split_sections validation
      # must be skipped + logged, not routed to the plain-file path.
      # Covers trailing-comma, missing-bracket, reversed-bracket, and
      # standalone-bracket typo shapes that all land here.
      _hub_log "fan-out: skipping entry with malformed section selector: $hub_rel"
    else
      local src="$hub_dir/$hub_rel"
      local dst="$tool_dir/$tool_spec"
      if _hub_is_filelike "$hub_rel"; then
        _hub_sync_file "$src" "$dst"
        # Same snapshot update as the sectioned path — the next harvest
        # needs to know what was written here to detect real edits.
        _hub_snapshot_write "$dst" \
          "$(_hub_snapshot_path "$tool_dir" "$tool_spec")"
      else
        _hub_sync_dir "$src" "$dst"
      fi
    fi
  done < <(hub_parse_map "${ADAPTER_HUB_MAP:-}")

  # Skills: content-file rename (content.md → SKILL.md on fan-out).
  local tool_skills="${ADAPTER_SKILL_ROOT:-$tool_dir/skills}"
  _hub_sync_skills fanout "$hub_dir/skills" "$tool_skills"

  # Per-project: walk the tool's variants. Each variant's sidecar
  # (at variant root or legacy memory/.hive-mind) maps it to a hub
  # project-id; look up the hub dir and apply rules. Variant dirs are
  # created by the tool itself when the user opens a project — fan-out
  # can't create them because the encoded-cwd folder name is machine-
  # specific and not stored in the hub.
  local tool_proj_root="$tool_dir/projects"
  [ -d "$tool_proj_root" ] || return 0

  local variant id hub_proj
  for variant in "$tool_proj_root"/*/; do
    [ -d "$variant" ] || continue
    variant="${variant%/}"
    id="$(_hub_read_project_id "$variant" 2>/dev/null || true)"
    [ -z "$id" ] && continue
    hub_proj="$hub_dir/projects/$id"
    [ -d "$hub_proj" ] || continue
    _hub_apply_project_rules fanout "$variant" "$hub_proj"
  done
}
