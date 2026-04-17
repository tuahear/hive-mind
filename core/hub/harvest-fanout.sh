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

# Split `<file>#<jsonpath>` into two fields on stdout (TAB-delimited).
# Returns non-zero if no '#' is present.
_hub_split_subkey() {
  local spec="$1"
  case "$spec" in
    *'#'*) printf '%s\t%s' "${spec%%#*}" "${spec#*#}" ;;
    *) return 1 ;;
  esac
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
_hub_sync_file() {
  local src="$1" dst="$2"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")" 2>/dev/null
    cp "$src" "$dst"
  fi
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

  # Two-pass processing: dir rules first, file rules second. This
  # prevents the dir-sync's "delete absent files" logic from wiping a
  # file that an explicit file rule places inside the synced dir. For
  # example: `memory\tmemory` dir-syncs the whole memory/ subdir, then
  # `content.md\tmemory/MEMORY.md` writes MEMORY.md into memory/ — if
  # we ran the file rule first, the dir-sync would delete MEMORY.md
  # because it's not present in the hub's memory/ source.
  local hub_rel tool_rel src dst

  # Pass 1: directory rules.
  while IFS=$'\t' read -r hub_rel tool_rel; do
    [ -z "$hub_rel" ] && continue
    [ -z "$tool_rel" ] && continue
    _hub_is_filelike "$hub_rel" && continue
    if [ "$direction" = "harvest" ]; then
      _hub_sync_dir "$tool_variant/$tool_rel" "$hub_proj/$hub_rel"
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
# tool's SKILL.md ↔ hub's content.md. Other files in each skill dir
# pass through unchanged. Replaces the generic dir-mirror that the
# removed `skills\tskills` ADAPTER_HUB_MAP entry used to trigger.
_hub_sync_skills() {
  local direction="$1" src_root="$2" dst_root="$3"
  [ -d "$src_root" ] || return 0
  mkdir -p "$dst_root" 2>/dev/null
  local skill_src skill_name skill_dst f fname dst_name
  for skill_src in "$src_root"/*/; do
    [ -d "$skill_src" ] || continue
    skill_name="${skill_src%/}"
    skill_name="${skill_name##*/}"
    skill_dst="$dst_root/$skill_name"
    mkdir -p "$skill_dst" 2>/dev/null
    # Copy with rename for the content file.
    for f in "$skill_src"/*; do
      [ -f "$f" ] || continue
      fname="${f##*/}"
      dst_name="$fname"
      if [ "$direction" = "harvest" ] && [ "$fname" = "SKILL.md" ]; then
        dst_name="content.md"
      elif [ "$direction" = "fanout" ] && [ "$fname" = "content.md" ]; then
        dst_name="SKILL.md"
      fi
      cp "$f" "$skill_dst/$dst_name"
    done
    # Remove dst files not in src (with rename awareness).
    for f in "$skill_dst"/*; do
      [ -f "$f" ] || continue
      fname="${f##*/}"
      local src_name="$fname"
      if [ "$direction" = "harvest" ] && [ "$fname" = "content.md" ]; then
        src_name="SKILL.md"
      elif [ "$direction" = "fanout" ] && [ "$fname" = "SKILL.md" ]; then
        src_name="content.md"
      fi
      [ -f "$skill_src/$src_name" ] || rm -f "$f"
    done
  done
  # Remove dst skill dirs not in src.
  for skill_dst in "$dst_root"/*/; do
    [ -d "$skill_dst" ] || continue
    skill_name="${skill_dst%/}"
    skill_name="${skill_name##*/}"
    [ -d "$src_root/$skill_name" ] || rm -rf "$skill_dst"
  done
}

# --- main entry points -----------------------------------------------------

# Harvest: tool → hub. Applies every entry in ADAPTER_HUB_MAP, then walks
# per-project variants to apply ADAPTER_PROJECT_CONTENT_RULES.
hub_harvest() {
  local tool_dir="$1" hub_dir="$2"
  [ -d "$tool_dir" ] || return 0
  mkdir -p "$hub_dir" 2>/dev/null

  local hub_rel tool_spec file_part jsonpath_part
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
    else
      local src="$tool_dir/$tool_spec"
      local dst="$hub_dir/$hub_rel"
      if _hub_is_filelike "$hub_rel"; then
        _hub_sync_file "$src" "$dst"
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

  local hub_rel tool_spec file_part jsonpath_part
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
    else
      local src="$hub_dir/$hub_rel"
      local dst="$tool_dir/$tool_spec"
      if _hub_is_filelike "$hub_rel"; then
        _hub_sync_file "$src" "$dst"
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
