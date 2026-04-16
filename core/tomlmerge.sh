#!/usr/bin/env bash
# Git merge driver for TOML config files.
#
# Registered locally via:
#   git config merge.tomlmerge.driver 'core/tomlmerge.sh %A %O %B'
# Referenced per-file in .gitattributes:
#   config.toml merge=tomlmerge
#
# Called by git as: tomlmerge.sh <ours> <base> <theirs>
# Must write the merged result to <ours> and exit 0 on success.
# Exit non-zero -> git falls back to its default merge (conflict markers).
#
# Merge semantics (pure POSIX awk, no external deps beyond awk/sort):
#   - Scalar keys: theirs wins on collision (remote is fleet truth).
#   - Tables (sections): deep-merge by combining keys from both sides.
#   - Array-of-strings values on known union keys: union + dedup + sort.
#     Adapter declares which keys get union treatment via env var
#     TOMLMERGE_UNION_KEYS (newline-separated dotted paths, e.g.
#     "permissions.allow\npermissions.deny").
#   - Unknown arrays: theirs wins.
#
# Limitations (acceptable for config files):
#   - Inline tables and nested arrays-of-tables are NOT supported.
#   - Multi-line basic strings are NOT supported.
#   - Only handles simple key = "value" / key = [array] / [table] forms.

set -e

OURS="$1"
# BASE="$2"  # unused — 2-way merge is sufficient for config files
THEIRS="$3"

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.ours" "$tmp.theirs" "$tmp.merged"' EXIT

# --- Parse TOML into a flat key=value representation ----------------------
# Output: section.key<TAB>value (one per line, arrays expanded per-element)
toml_flatten() {
  awk '
    BEGIN { section = "" }
    /^[[:space:]]*#/  { next }
    /^[[:space:]]*$/  { next }
    /^\[([^\]]+)\][[:space:]]*$/ {
      s = $0
      gsub(/^[[:space:]]*\[/, "", s)
      gsub(/\][[:space:]]*$/, "", s)
      section = s
      next
    }
    {
      line = $0
      # Match key = value
      if (match(line, /^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*=/, arr)) {
        key = line
        sub(/[[:space:]]*=.*/, "", key)
        gsub(/^[[:space:]]+/, "", key)
        val = line
        sub(/^[^=]+=/, "", val)
        gsub(/^[[:space:]]+/, "", val)
        gsub(/[[:space:]]+$/, "", val)
        fullkey = (section != "" ? section "." : "") key
        print fullkey "\t" val
      }
    }
  ' "$1"
}

# --- Check if a key is in the union list ----------------------------------
is_union_key() {
  local key="$1"
  local union_keys="${TOMLMERGE_UNION_KEYS:-}"
  [ -z "$union_keys" ] && return 1
  printf '%s\n' "$union_keys" | grep -Fxq "$key"
}

# --- Parse array value into lines of elements -----------------------------
parse_array() {
  local val="$1"
  # Strip outer brackets
  val="${val#\[}"
  val="${val%\]}"
  # Split on comma, strip quotes and whitespace
  printf '%s' "$val" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' | grep -v '^$'
}

# --- Rebuild array from lines of elements ---------------------------------
rebuild_array() {
  local elements
  elements="$(sort -u)"
  local first=1
  printf '['
  while IFS= read -r elem; do
    [ -z "$elem" ] && continue
    [ "$first" -eq 1 ] || printf ', '
    printf '"%s"' "$elem"
    first=0
  done <<< "$elements"
  printf ']'
}

# --- Main merge logic -----------------------------------------------------

toml_flatten "$OURS" > "$tmp.ours"
toml_flatten "$THEIRS" > "$tmp.theirs"

# Build merged flat representation. Theirs wins on scalar collision.
# For union keys, merge array elements.
{
  # All keys from both sides
  cut -f1 "$tmp.ours" "$tmp.theirs" | sort -u
} | while IFS= read -r key; do
  [ -z "$key" ] && continue
  ours_val="$(grep -m1 "^${key}	" "$tmp.ours" 2>/dev/null | cut -f2- || true)"
  theirs_val="$(grep -m1 "^${key}	" "$tmp.theirs" 2>/dev/null | cut -f2- || true)"

  if [ -n "$theirs_val" ] && [ -n "$ours_val" ]; then
    # Both sides have this key
    if is_union_key "$key" && [[ "$ours_val" == \[* ]] && [[ "$theirs_val" == \[* ]]; then
      # Union arrays
      merged_val="$( { parse_array "$ours_val"; parse_array "$theirs_val"; } | rebuild_array )"
      printf '%s\t%s\n' "$key" "$merged_val"
    else
      # Theirs wins
      printf '%s\t%s\n' "$key" "$theirs_val"
    fi
  elif [ -n "$theirs_val" ]; then
    printf '%s\t%s\n' "$key" "$theirs_val"
  else
    printf '%s\t%s\n' "$key" "$ours_val"
  fi
done > "$tmp.merged"

# --- Reconstruct TOML from flat representation ----------------------------
awk -F'\t' '
  BEGIN { section = "" }
  {
    key = $1
    val = $2
    # Split dotted key into section + local key
    n = split(key, parts, ".")
    if (n >= 2) {
      sec = parts[1]
      for (i = 2; i < n; i++) sec = sec "." parts[i]
      local_key = parts[n]
    } else {
      sec = ""
      local_key = key
    }
    if (sec != section) {
      if (section != "" || sec != "") print ""
      if (sec != "") print "[" sec "]"
      section = sec
    }
    print local_key " = " val
  }
' "$tmp.merged" > "$tmp"

mv "$tmp" "$OURS"
exit 0
