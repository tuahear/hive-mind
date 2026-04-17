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
# Returns 0 (too recent to delete) if git log has no history.
_gc_last_touch_days() {
  local project_dir="$1"
  local rel="${project_dir#"$HIVE_MIND_HUB_DIR/"}"
  local last_ts now_ts

  last_ts="$(git -C "$HIVE_MIND_HUB_DIR" log -1 --format=%ct -- "$rel" 2>/dev/null)"
  if [ -z "$last_ts" ] || [ "$last_ts" = "0" ]; then
    # No git history for this path — don't delete (age 0 = too recent).
    echo 0; return
  fi
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
# removed.
#
# Uses ADAPTER_PROJECT_CONTENT_RULES (via HUB_FILE_HARVEST_RULES[] parallel
# array) to know which files are synced content vs tool-local artifacts.
# Only synced files are compared against the hub for the safety check.
#
# Gated by HIVE_MIND_HUB_PROJECT_GC_AUTO=1 (report-only by default)
# and HIVE_MIND_HUB_PROJECT_GC_DAYS=0 to disable entirely.

# Check if a variant's synced content matches the hub, using the
# adapter's project content rules. Returns 0 if all synced content
# is identical to the hub (safe to delete), 1 if any differs.
_gc_variant_content_matches_hub() {
  local vdir="$1" hub_proj="$2" rules="$3"
  [ -d "$hub_proj" ] || return 1

  # Parse rules: each line is hub_rel<TAB>tool_rel.
  # File rules (both sides are files) compare directly.
  # Dir rules (tool_rel has no extension) compare recursively.
  while IFS=$'\t' read -r hub_rel tool_rel; do
    [ -z "$hub_rel" ] || [ -z "$tool_rel" ] && continue
    local tool_path="$vdir/$tool_rel"
    local hub_path="$hub_proj/$hub_rel"

    # Determine if this is a file rule or dir rule.
    case "$tool_rel" in
      *.*) # File rule: direct comparison.
        if [ -f "$tool_path" ]; then
          [ -f "$hub_path" ] && cmp -s "$tool_path" "$hub_path" || return 1
        fi
        ;;
      *)   # Dir rule: compare all files recursively.
        if [ -d "$tool_path" ]; then
          while IFS= read -r -d '' vf; do
            local rel="${vf#"$tool_path/"}"
            local bn="${rel##*/}"
            case "$bn" in .hive-mind|.DS_Store) continue ;; esac
            local hf="$hub_path/$rel"
            [ -f "$hf" ] && cmp -s "$vf" "$hf" || return 1
          done < <(find "$tool_path" -type f -print0 2>/dev/null)
        fi
        ;;
    esac
  done <<< "$rules"
  return 0
}

hub_gc_tool_variants() {
  : "${HIVE_MIND_HUB_PROJECT_GC_DAYS:=30}"
  : "${HIVE_MIND_HUB_PROJECT_GC_AUTO:=0}"
  [ "$HIVE_MIND_HUB_PROJECT_GC_DAYS" = "0" ] && return 0

  local TS
  TS="$(date -u +%FT%TZ)"
  local log="${HIVE_MIND_HUB_DIR:=$HOME/.hive-mind}/.sync-error.log"
  local deleted=0 reported=0 i

  for i in "${!HUB_TOOL_DIRS[@]}"; do
    local tool_dir="${HUB_TOOL_DIRS[$i]}"
    local rules="${HUB_FILE_HARVEST_RULES[$i]:-}"
    [ -d "$tool_dir/projects" ] || continue
    [ -z "$rules" ] && continue

    for variant in "$tool_dir"/projects/*/; do
      [ -d "$variant" ] || continue

      # Derive cwd from session files. If ANY session's cwd still
      # exists on disk, the variant is live — skip it.
      local any_cwd_found=0 any_cwd_alive=0
      while IFS= read -r -d '' sf; do
        local cwd
        cwd="$(grep -m1 -oE '"cwd":"[^"]+"' "$sf" 2>/dev/null \
                 | sed -e 's/^"cwd":"//' -e 's/"$//')"
        [ -z "$cwd" ] && continue
        any_cwd_found=1
        [ -d "$cwd" ] && { any_cwd_alive=1; break; }
      done < <(find "${variant%/}" -maxdepth 1 -type f \( -name '*.jsonl' -o -name '*.json' \) -print0 2>/dev/null)
      [ "$any_cwd_found" -eq 0 ] && continue
      [ "$any_cwd_alive" -eq 1 ] && continue

      local variant_name="${variant%/}"
      variant_name="${variant_name##*/}"

      # Require a sidecar — without one, harvest skipped this variant
      # and its content may never have reached the hub.
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

      # Verify synced content matches hub using the adapter's rules.
      local hub_proj="$HIVE_MIND_HUB_DIR/projects/$project_id"
      if ! _gc_variant_content_matches_hub "${variant%/}" "$hub_proj" "$rules"; then
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
