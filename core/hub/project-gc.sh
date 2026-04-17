#!/usr/bin/env bash
# Garbage-collect hub project dirs with no live sidecar on this machine.
#
# A hub project dir (projects/<normalized-remote>/) becomes a GC
# candidate when no attached adapter on this machine has a variant
# whose .hive-mind sidecar references that project-id. The dir must
# also be untouched in git for at least N days (safety margin for
# other machines whose sidecars we can't observe).
#
# Default: report-only. Auto-delete requires HIVE_MIND_HUB_PROJECT_GC_AUTO=1.
# Set HIVE_MIND_HUB_PROJECT_GC_DAYS=0 to disable GC entirely.
#
# Sourced by core/hub/sync.sh (calls hub_gc_projects after harvest).
# Expects: HIVE_MIND_HUB_DIR, HUB_TOOL_DIRS[] array.

set +e

: "${HIVE_MIND_HUB_DIR:=$HOME/.hive-mind}"
: "${HIVE_MIND_HUB_PROJECT_GC_DAYS:=30}"
: "${HIVE_MIND_HUB_PROJECT_GC_AUTO:=0}"

# Collect all live project-ids from attached adapters' sidecars.
_gc_collect_live_ids() {
  local tool_dir variant sidecar id
  for tool_dir in "${HUB_TOOL_DIRS[@]}"; do
    [ -d "$tool_dir/projects" ] || continue
    for variant in "$tool_dir"/projects/*/; do
      [ -d "$variant" ] || continue
      sidecar="${variant%.}/.hive-mind"
      [ -f "$sidecar" ] || sidecar="${variant%/}/.hive-mind"
      [ -f "$sidecar" ] || continue
      id="$(awk -F= '/^project-id=/ { sub(/^project-id=/, ""); print; exit }' "$sidecar" 2>/dev/null)"
      [ -n "$id" ] && printf '%s\n' "$id"
    done
  done | sort -u
}

# Days since git last touched any file under a hub project dir.
# Falls back to filesystem mtime if git log fails.
_gc_last_touch_days() {
  local project_dir="$1"
  local rel="${project_dir#"$HIVE_MIND_HUB_DIR/"}"
  local last_ts now_ts

  last_ts="$(git -C "$HIVE_MIND_HUB_DIR" log -1 --format=%ct -- "$rel" 2>/dev/null)"
  if [ -z "$last_ts" ] || [ "$last_ts" = "0" ]; then
    # macOS stat -f %m, then GNU stat -c %Y.
    last_ts="$(find "$project_dir" -type f -exec stat -f %m {} + 2>/dev/null | sort -rn | head -1)"
    [ -z "$last_ts" ] && \
      last_ts="$(find "$project_dir" -type f -exec stat -c %Y {} + 2>/dev/null | sort -rn | head -1)"
  fi
  [ -z "$last_ts" ] && { echo 999; return; }
  now_ts="$(date +%s)"
  echo $(( (now_ts - last_ts) / 86400 ))
}

hub_gc_projects() {
  [ "$HIVE_MIND_HUB_PROJECT_GC_DAYS" = "0" ] && return 0

  local hub_projects="$HIVE_MIND_HUB_DIR/projects"
  [ -d "$hub_projects" ] || return 0

  local TS
  TS="$(date -u +%FT%TZ)"
  local log="${HIVE_MIND_HUB_DIR}/.sync-error.log"
  local live_ids
  live_ids="$(_gc_collect_live_ids)"

  local candidate_count=0 delete_count=0

  # Find hub project dirs by their .hive-mind sidecar.
  while IFS= read -r -d '' sidecar; do
    local project_dir
    project_dir="$(dirname "$sidecar")"
    local id="${project_dir#"$hub_projects/"}"
    [ -z "$id" ] && continue

    # Skip if any live sidecar references this id.
    if printf '%s\n' "$live_ids" | grep -Fxq "$id"; then
      continue
    fi

    candidate_count=$((candidate_count + 1))
    local age_days
    age_days="$(_gc_last_touch_days "$project_dir")"

    if [ "$age_days" -lt "$HIVE_MIND_HUB_PROJECT_GC_DAYS" ]; then
      echo "$TS gc: candidate (${age_days}d < ${HIVE_MIND_HUB_PROJECT_GC_DAYS}d threshold): $id" >>"$log"
      continue
    fi

    if [ "$HIVE_MIND_HUB_PROJECT_GC_AUTO" = "1" ]; then
      rm -rf "$project_dir"
      delete_count=$((delete_count + 1))
      echo "$TS gc: deleted (${age_days}d stale, no live sidecar): $id" >>"$log"
    else
      echo "$TS gc: would delete (${age_days}d stale, no live sidecar): $id" >>"$log"
    fi
  done < <(find "$hub_projects" -name ".hive-mind" -type f -print0 2>/dev/null)

  [ "$candidate_count" -gt 0 ] && printf 'gc: %d candidate(s), %d deleted\n' "$candidate_count" "$delete_count"
  return 0
}
