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

# No top-level set +e — this file is sourced; shell-option changes
# would leak into the caller. Functions handle errors internally.

# Collect all live project-ids from attached adapters' sidecars.
_gc_collect_live_ids() {
  local tool_dir variant sidecar id
  for tool_dir in "${HUB_TOOL_DIRS[@]}"; do
    [ -d "$tool_dir/projects" ] || continue
    for variant in "$tool_dir"/projects/*/; do
      [ -d "$variant" ] || continue
      # Check variant root (canonical), then legacy memory/ location.
      sidecar="${variant%/}/.hive-mind"
      [ -f "$sidecar" ] || sidecar="${variant%/}/memory/.hive-mind"
      [ -f "$sidecar" ] || continue
      id="$(awk -F= '/^project-id=/ { sub(/^project-id=/, ""); gsub(/\r/, ""); print; exit }' "$sidecar" 2>/dev/null)"
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
  : "${HIVE_MIND_HUB_PROJECT_GC_DAYS:=30}"
  : "${HIVE_MIND_HUB_PROJECT_GC_AUTO:=0}"
  [ "$HIVE_MIND_HUB_PROJECT_GC_DAYS" = "0" ] && return 0

  local hub_projects="${HIVE_MIND_HUB_DIR:=$HOME/.hive-mind}/projects"
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

    # Validate: the sidecar's project-id must match the path-derived id.
    # This prevents matching nested .hive-mind files (e.g., a legacy
    # memory/.hive-mind that got harvested into the hub) — dirname of
    # that would be <id>/memory, not the actual project root.
    local sidecar_id
    sidecar_id="$(awk -F= '/^project-id=/ { sub(/^project-id=/, ""); gsub(/\r/, ""); print; exit }' "$sidecar" 2>/dev/null)"
    [ "$sidecar_id" = "$id" ] || continue

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

  [ "$candidate_count" -gt 0 ] && echo "$TS gc: $candidate_count candidate(s), $delete_count deleted" >>"$log"
  return 0
}

# --- tool-side variant GC ---------------------------------------------------
# Remove tool variant dirs whose cwd no longer exists on disk. These
# accumulate when worktrees are deleted, repos are moved, or clones are
# removed. The variant's cwd is derived from its jsonl session files.
#
# Gated by HIVE_MIND_HUB_PROJECT_GC_AUTO=1 (report-only by default)
# and HIVE_MIND_HUB_PROJECT_GC_DAYS=0 to disable entirely.

hub_gc_tool_variants() {
  : "${HIVE_MIND_HUB_PROJECT_GC_DAYS:=30}"
  : "${HIVE_MIND_HUB_PROJECT_GC_AUTO:=0}"
  [ "$HIVE_MIND_HUB_PROJECT_GC_DAYS" = "0" ] && return 0

  local TS
  TS="$(date -u +%FT%TZ)"
  local log="${HIVE_MIND_HUB_DIR:=$HOME/.hive-mind}/.sync-error.log"
  local tool_dir variant deleted=0 reported=0

  for tool_dir in "${HUB_TOOL_DIRS[@]}"; do
    [ -d "$tool_dir/projects" ] || continue
    for variant in "$tool_dir"/projects/*/; do
      [ -d "$variant" ] || continue
      # Derive cwd from jsonl files.
      local cwd=""
      for jsonl in "$variant"/*.jsonl; do
        [ -f "$jsonl" ] || continue
        cwd="$(grep -m1 -oE '"cwd":"[^"]+"' "$jsonl" 2>/dev/null \
                 | sed -e 's/^"cwd":"//' -e 's/"$//')"
        [ -n "$cwd" ] && break
      done
      [ -z "$cwd" ] && continue

      # If the cwd still exists, the variant is live.
      [ -d "$cwd" ] && continue

      local variant_name="${variant%/}"
      variant_name="${variant_name##*/}"

      # Safety: require a sidecar so we can verify the hub has the content.
      # Without a sidecar, harvest would have skipped this variant — its
      # content may never have reached the hub. Keep it.
      local sidecar="${variant%/}/.hive-mind"
      [ -f "$sidecar" ] || sidecar="${variant%/}/memory/.hive-mind"
      local project_id=""
      if [ -f "$sidecar" ]; then
        project_id="$(awk -F= '/^project-id=/ { sub(/^project-id=/, ""); gsub(/\r/, ""); print; exit }' "$sidecar" 2>/dev/null)"
      fi
      if [ -z "$project_id" ]; then
        echo "$TS gc: skipped orphan variant (no sidecar, can't verify hub): $variant_name" >>"$log"
        continue
      fi

      # Verify every synced file in the variant has identical content in
      # the hub. Skip session files, sidecars, and OS metadata.
      local hub_proj="$HIVE_MIND_HUB_DIR/projects/$project_id"
      local has_unharvested=0
      while IFS= read -r -d '' vf; do
        local rel="${vf#"${variant%/}/"}"
        # Skip session files, sidecars, and OS metadata at any depth.
        local basename="${rel##*/}"
        case "$basename" in *.jsonl|.hive-mind|.DS_Store) continue ;; esac
        local hub_rel="$rel"
        case "$rel" in MEMORY.md) hub_rel="content.md" ;; esac
        if [ ! -f "$hub_proj/$hub_rel" ] || ! cmp -s "$vf" "$hub_proj/$hub_rel"; then
          has_unharvested=1
          break
        fi
      done < <(find "${variant%/}" -type f -print0 2>/dev/null)
      if [ "$has_unharvested" -eq 1 ]; then
        echo "$TS gc: skipped orphan variant (unharvested content for $project_id): $variant_name" >>"$log"
        continue
      fi

      if [ "$HIVE_MIND_HUB_PROJECT_GC_AUTO" = "1" ]; then
        rm -rf "${variant%/}"
        deleted=$((deleted + 1))
        echo "$TS gc: removed orphan tool variant (cwd gone): $variant_name" >>"$log"
      else
        reported=$((reported + 1))
        echo "$TS gc: would remove orphan tool variant (cwd gone): $variant_name" >>"$log"
      fi
    done
  done

  local total=$((deleted + reported))
  [ "$total" -gt 0 ] && echo "$TS gc: $total orphan tool variant(s), $deleted removed" >>"$log"
  return 0
}
