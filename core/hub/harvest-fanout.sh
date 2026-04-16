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

# Deterministic short id from stdin. git hash-object is always available
# (git is a hard dep) and emits stable sha1 regardless of platform.
_hub_entry_id() {
  git hash-object --stdin 2>/dev/null | cut -c1-12
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
      id="$(printf '%s' "$canon" | _hub_entry_id)"
      [ -z "$id" ] && continue
      printf '%s\n' "$canon" > "$tmp_dir/$id.json"
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
    entries_json="$(
      jq -cs . "$event_dir"/*.json 2>/dev/null
    )"
    [ -z "$entries_json" ] && entries_json="[]"

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

# Read project-id from a variant's sidecar at <variant>/memory/.hive-mind.
# Always exits 0 — an absent sidecar emits nothing, not a non-zero status,
# so a caller's `id="$(...)"` under `set -e` won't abort when the variant
# hasn't been bootstrapped by mirror-projects yet.
_hub_read_project_id() {
  local variant="$1"
  local sidecar="$variant/memory/.hive-mind"
  [ -f "$sidecar" ] || return 0
  awk -F= '
    /^[[:space:]]*#/ { next }
    $1 == "project-id" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; exit }
  ' "$sidecar"
}

# Apply ADAPTER_PROJECT_CONTENT_RULES between a single tool variant and a
# single hub project dir. Rules map hub-rel → tool-rel; direction param
# is "harvest" (tool→hub) or "fanout" (hub→tool).
_hub_apply_project_rules() {
  local direction="$1" tool_variant="$2" hub_proj="$3"
  local rules="${ADAPTER_PROJECT_CONTENT_RULES:-}"
  [ -n "$rules" ] || return 0

  local pair hub_rel tool_rel src dst
  while IFS=$'\t' read -r hub_rel tool_rel; do
    [ -z "$hub_rel" ] && continue
    [ -z "$tool_rel" ] && continue
    if [ "$direction" = "harvest" ]; then
      src="$tool_variant/$tool_rel"
      dst="$hub_proj/$hub_rel"
    else
      src="$hub_proj/$hub_rel"
      dst="$tool_variant/$tool_rel"
    fi

    if _hub_is_filelike "$hub_rel"; then
      _hub_sync_file "$src" "$dst"
    else
      _hub_sync_dir "$src" "$dst"
    fi
  done < <(hub_parse_project_rules "$rules")
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

  # Per-project content. Claude uses projects/<encoded-cwd>/; the sidecar
  # at <variant>/memory/.hive-mind exposes project-id. Skip variants that
  # have no sidecar — they're unbootstrapped (mirror-projects handles the
  # bootstrap before this runs).
  local proj_root="$tool_dir/projects"
  [ -d "$proj_root" ] || return 0
  local variant id
  for variant in "$proj_root"/*/; do
    [ -d "$variant" ] || continue
    variant="${variant%/}"
    id="$(_hub_read_project_id "$variant" 2>/dev/null || true)"
    [ -z "$id" ] && continue
    local hub_proj="$hub_dir/projects/$id"
    mkdir -p "$hub_proj"
    _hub_apply_project_rules harvest "$variant" "$hub_proj"
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

  # Per-project: walk the tool's variants (not the hub's `projects/<id>/`
  # tree) — project-id contains slashes like `github.com/alice/proj`, so
  # iterating the hub's top-level `*/` would only see a URL host segment.
  # Each variant's sidecar maps it to a hub id; look up the hub path
  # directly. Missing hub dirs are skipped — this machine has the variant
  # but the hub (or other machines) haven't pushed content for that
  # project yet. Missing tool variants stay absent until the user opens
  # the project and Claude writes a session jsonl (mirror-projects
  # discovers the id on the next sync cycle).
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
