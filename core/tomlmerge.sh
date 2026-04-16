#!/usr/bin/env bash
# Git merge driver for TOML config files.
#
# Registered locally via (setup.sh does this — adapter-agnostic path):
#   git config merge.tomlmerge.driver '$ADAPTER_DIR/hive-mind/core/tomlmerge.sh %A %O %B'
# On Claude Code, $ADAPTER_DIR resolves to ~/.claude; on Codex, ~/.codex; etc.
# Referenced per-file in .gitattributes:
#   config.toml merge=tomlmerge
#
# Called by git as: tomlmerge.sh <ours> <base> <theirs>
# Must write the merged result to <ours> and exit 0 on success.
# Exit non-zero -> git falls back to its default merge (conflict markers).
#
# Merge semantics (bash + awk/sed/grep/tr/cut/sort/mktemp — no jq, no
# python, no node; same standard-userland toolset as every other core
# script):
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
#
# Safety: if either file contains constructs we can't parse, we exit
# non-zero so git falls back to its default 3-way merge (with conflict
# markers). This surfaces the divergence to the user rather than silently
# dropping unparsed content.

set -e

OURS="$1"
# BASE="$2"  # unused — 2-way merge is sufficient for config files
THEIRS="$3"

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.ours" "$tmp.theirs" "$tmp.merged"' EXIT

# --- Parse TOML into a flat key=value representation ----------------------
# Output: section.key<TAB>value (one line per key; array literals are
# emitted whole and split later by parse_array only when needed for union
# merging).
# Exit non-zero if any non-blank, non-comment, non-section, non-key line
# appears (inline tables, array-of-tables, multi-line strings, etc.) so
# git can fall back to its default merge instead of silently dropping.
#
# Comment-loss safety: this driver reconstructs the output TOML from the
# flat key list, which drops comments and blank lines. Users frequently
# document config in TOML comments, so losing them on merge is a real
# data-loss hazard. If either input contains comments or non-trailing
# blank lines, exit non-zero so git falls back to its default 3-way
# merge (which preserves comments via conflict markers for manual
# resolution). Only activate the union-merge code path on "simple"
# comment-free, blank-line-free TOML.
toml_flatten() {
  awk '
    BEGIN { section = ""; unrecognized = 0; saw_content = 0 }
    /^[[:space:]]*#/  { unrecognized = 1; exit }
    /^[[:space:]]*$/  {
      # Blank lines are allowed before any content (file-leading whitespace)
      # but reject them once key/value content has started — they carry
      # visual grouping intent that would be lost in the reconstruction.
      if (saw_content) { unrecognized = 1; exit }
      next
    }
    /^\[\[/ { unrecognized = 1; exit }   # array-of-tables
    /^\[([^\]]+)\][[:space:]]*$/ {
      s = $0
      gsub(/^[[:space:]]*\[/, "", s)
      gsub(/\][[:space:]]*$/, "", s)
      section = s
      saw_content = 1
      next
    }
    /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/ {
      line = $0
      key = line
      sub(/[[:space:]]*=.*/, "", key)
      gsub(/^[[:space:]]+/, "", key)
      val = line
      sub(/^[^=]+=/, "", val)
      gsub(/^[[:space:]]+/, "", val)
      gsub(/[[:space:]]+$/, "", val)
      # Reject inline tables and multi-line strings.
      if (val ~ /^\{/ || val ~ /^"""/ || val ~ /^[[:space:]]*$/) {
        unrecognized = 1; exit
      }
      fullkey = (section != "" ? section "." : "") key
      print fullkey "\t" val
      saw_content = 1
      next
    }
    { unrecognized = 1; exit }
    END { exit unrecognized }
  ' "$1"
}

# --- Check if a key is in the union list ----------------------------------
# Accepts TOMLMERGE_UNION_KEYS as either newline-separated or
# comma-separated (the comma form is friendlier when the var is set
# via the merge-driver env-prefix written to git config, since
# newlines don't survive single-line config values cleanly).
is_union_key() {
  local key="$1"
  local union_keys="${TOMLMERGE_UNION_KEYS:-}"
  [ -z "$union_keys" ] && return 1
  printf '%s\n' "$union_keys" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -Fxq "$key"
}

# --- Parse array value into lines of elements -----------------------------
# Returns non-zero if the array is not well-formed (e.g. the closing `]`
# isn't the last non-whitespace char, which happens with inline comments
# like `[...]  # comment`). Caller must treat that as a parse failure.
parse_array() {
  local val="$1"
  # Must start with `[` and end with `]` (allowing trailing whitespace).
  # Inline comments or stray text after `]` are not supported.
  if [[ ! "$val" =~ ^\[.*\][[:space:]]*$ ]]; then
    return 1
  fi
  # Strip outer brackets and any trailing whitespace between `]` and EOL.
  val="${val#\[}"
  # Trim ALL trailing whitespace first so the `]` is the final char.
  val="${val%"${val##*[![:space:]]}"}"
  val="${val%\]}"
  # Reject anything that isn't a (possibly empty) comma-separated list of
  # double-quoted strings. Single quotes / bare identifiers / numbers /
  # booleans would survive the strip-quotes sed otherwise and get
  # corrupted by rebuild_array. On rejection, caller exits 1 so git
  # falls back to a normal 3-way merge.
  local tab=$'\t'
  local stripped="${val// /}"     # ignore spaces for the validation
  stripped="${stripped//${tab}/}"  # ignore tabs -- $'\t' is explicit vs literal char
  # Element class [^\",] forbids quotes AND commas inside the element --
  # the downstream split is just `tr ',' '\n'` (not quote-aware), so an
  # array like ["a,b"] would split into ["a", "b"] and silently corrupt
  # the config on write-back. Rejecting such arrays forces git to fall
  # back to its normal 3-way merge with conflict markers instead.
  if [ -n "$stripped" ] && [[ ! "$stripped" =~ ^\"[^\",]*\"(,\"[^\",]*\")*$ ]]; then
    return 1
  fi
  # Split on comma; emit exactly one line per element (always
  # terminated by \n via awk's print). Preserves empty-string
  # elements (`["", "x"]`). After bracket-strip an empty input means
  # "zero elements" -- don't emit a spurious blank line.
  if [ -z "$val" ]; then
    return 0
  fi
  printf '%s' "$val" | tr ',' '\n' | awk '{
    sub(/^[[:space:]]+/, "");
    sub(/[[:space:]]+$/, "");
    sub(/^"/, "");
    sub(/"$/, "");
    print
  }'
}

# --- Rebuild array from lines of elements ---------------------------------
# Emits every unique line (including empty-string elements, which are
# valid TOML). `sort -u` handles dedup. Reads into a bash array so
# empty-string elements aren't lost — `$(sort -u)` would strip the
# single trailing newline of a one-empty-element input and `[ -z ]`
# would then misclassify it as zero elements.
rebuild_array() {
  local elems=() elem
  while IFS= read -r elem; do
    elems+=("$elem")
  done < <(sort -u)
  if [ "${#elems[@]}" -eq 0 ]; then
    printf '[]'
    return
  fi
  local first=1 i
  printf '['
  for i in "${!elems[@]}"; do
    [ "$first" -eq 1 ] || printf ', '
    printf '"%s"' "${elems[$i]}"
    first=0
  done
  printf ']'
}

# --- Main merge logic -----------------------------------------------------

toml_flatten "$OURS" > "$tmp.ours" || exit 1
toml_flatten "$THEIRS" > "$tmp.theirs" || exit 1

# Look up a value for an exact key match. Uses awk for fixed-string
# key comparison on field 1 — grep with dotted keys would treat `.` as
# a regex wildcard and cross-match unrelated keys.
lookup_val() {
  local file="$1" key="$2"
  awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$file"
}

# Build merged flat representation. Theirs wins on scalar collision.
# For union keys, merge array elements.
{
  # All keys from both sides
  cut -f1 "$tmp.ours" "$tmp.theirs" | sort -u
} | while IFS= read -r key; do
  [ -z "$key" ] && continue
  ours_val="$(lookup_val "$tmp.ours" "$key")"
  theirs_val="$(lookup_val "$tmp.theirs" "$key")"

  if [ -n "$theirs_val" ] && [ -n "$ours_val" ]; then
    # Both sides have this key
    if is_union_key "$key" && [[ "$ours_val" == \[* ]] && [[ "$theirs_val" == \[* ]]; then
      # Union arrays -- both sides must parse cleanly. A non-zero return
      # from parse_array (e.g. inline comment after ]) exits the whole
      # script so git falls back to its default merge.
      #
      # Route parse_array output through temp files, NOT command
      # substitution. `$(...)` strips trailing newlines, which makes
      # "single empty element" indistinguishable from "zero elements"
      # (both collapse to ""). Files preserve exact line counts so
      # `[""]` survives the union round-trip.
      _ours_tmp="$(mktemp)"; _theirs_tmp="$(mktemp)"
      parse_array "$ours_val" > "$_ours_tmp" || { rm -f "$_ours_tmp" "$_theirs_tmp"; exit 1; }
      parse_array "$theirs_val" > "$_theirs_tmp" || { rm -f "$_ours_tmp" "$_theirs_tmp"; exit 1; }
      merged_val="$(cat "$_ours_tmp" "$_theirs_tmp" | rebuild_array)"
      rm -f "$_ours_tmp" "$_theirs_tmp"
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
done > "$tmp.merged" || exit 1

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
