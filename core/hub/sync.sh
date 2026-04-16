#!/bin/bash
# Hub sync entry point (v0.3.0). Invoked by every attached tool's
# turn-end hook via the stable path "$HIVE_MIND_HUB_DIR/bin/sync"
# (which setup.sh either copies or symlinks to this file).
#
# Flow:
#   1. Acquire lock at $HIVE_MIND_HUB_DIR/.hive-mind-state/sync.lock
#   2. cd "$HIVE_MIND_HUB_DIR"
#   3. For each attached adapter: load + harvest (tool → hub)
#   4. Marker extract (reuse core/marker-extract.sh)
#   5. Format-version gate + force-stage .hive-mind-format
#   6. Secret-file gate (union of every attached adapter's secret list)
#   7. Commit + pull-rebase + retry push (reuse core/sync.sh logic)
#   8. For each attached adapter: fan-out (hub → tool)
#   9. Release lock
#
# Every failure logs and continues. Hook callers never see a non-zero
# exit from this script.

set +e

# Resolve the hive-mind repo root — the script may be invoked via a
# symlink at $HIVE_MIND_HUB_DIR/bin/sync. readlink -f isn't portable to
# macOS (BSD readlink lacks -f), so walk the chain manually.
_resolve_self() {
  local p="$1"
  while [ -L "$p" ]; do
    local link
    link="$(readlink "$p")"
    case "$link" in
      /*) p="$link" ;;
      *)  p="$(cd "$(dirname "$p")" && cd "$(dirname "$link")" && pwd)/$(basename "$link")" ;;
    esac
  done
  printf '%s' "$p"
}
_SELF="$(_resolve_self "${BASH_SOURCE[0]}")"
CORE_DIR="$(cd "$(dirname "$_SELF")/.." && pwd)"
HIVE_MIND_ROOT="$(cd "$CORE_DIR/.." && pwd)"

# Hub location. Env var lets tests and alt installs redirect.
: "${HIVE_MIND_HUB_DIR:=$HOME/.hive-mind}"
export HIVE_MIND_HUB_DIR

# Attached adapters live one-per-line in this file. Written by
# setup.sh on attach, read here.
ATTACHED_FILE="$HIVE_MIND_HUB_DIR/.install-state/attached-adapters"

HIVE_MIND_STATE_DIR="${HIVE_MIND_HUB_DIR}/.hive-mind-state"
LOCK_DIR="${HIVE_MIND_STATE_DIR}/sync.lock"
mkdir -p "$HIVE_MIND_STATE_DIR" 2>/dev/null

# Log path: hub-global; per-adapter logs remain in each adapter's
# ADAPTER_LOG_PATH for tool-local diagnostics but the hub sync's own
# operations log here. Exported so hub_harvest / hub_fan_out route
# machine-local-skip messages to the hub log (HIVE_MIND_HUB_LOG) rather
# than silently into whichever adapter's ADAPTER_LOG_PATH happened to be
# in scope at call time.
LOG="${HIVE_MIND_HUB_DIR}/.sync-error.log"
HIVE_MIND_HUB_LOG="$LOG"
export HIVE_MIND_HUB_LOG
TS="$(date -u +%FT%TZ)"

# --- locking (mirrors core/sync.sh semantics) ------------------------------
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    date +%s > "$LOCK_DIR/created-at" 2>/dev/null
    echo "$$" > "$LOCK_DIR/owner-pid" 2>/dev/null
    return 0
  fi
  return 1
}
release_lock() {
  local lock_owner=""
  [ -f "$LOCK_DIR/owner-pid" ] && lock_owner="$(cat "$LOCK_DIR/owner-pid" 2>/dev/null)"
  if [ "$lock_owner" = "$$" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null
  fi
}
STALE_AGE_SEC=300

if ! acquire_lock; then
  if [ ! -f "$LOCK_DIR/created-at" ]; then sleep 2; fi
  lock_ts=""; [ -f "$LOCK_DIR/created-at" ] && lock_ts="$(cat "$LOCK_DIR/created-at" 2>/dev/null)"
  case "$lock_ts" in ''|*[!0-9]*) lock_ts=0 ;; esac
  now_ts="$(date +%s)"
  owner_pid=""; [ -f "$LOCK_DIR/owner-pid" ] && owner_pid="$(cat "$LOCK_DIR/owner-pid" 2>/dev/null)"
  owner_alive=0
  case "$owner_pid" in
    ''|*[!0-9]*) owner_alive=0 ;;
    *) kill -0 "$owner_pid" 2>/dev/null && owner_alive=1 ;;
  esac
  if [ "$owner_alive" -eq 1 ]; then exit 0; fi
  if [ "$lock_ts" -eq 0 ] || [ "$((now_ts - lock_ts))" -gt "$STALE_AGE_SEC" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null
    acquire_lock || exit 0
  else
    exit 0
  fi
fi
trap 'release_lock' EXIT

# --- hub existence check ---------------------------------------------------
if [ ! -d "$HIVE_MIND_HUB_DIR/.git" ]; then
  echo "$TS WARN hub-sync: $HIVE_MIND_HUB_DIR is not a git repo -- bailing" >>"$LOG"
  exit 0
fi

cd "$HIVE_MIND_HUB_DIR" || exit 0

# --- harvest + fan-out helpers --------------------------------------------
# shellcheck source=/dev/null
source "$CORE_DIR/hub/harvest-fanout.sh"
# shellcheck source=/dev/null
source "$CORE_DIR/adapter-loader.sh"

# --- collect attached adapters --------------------------------------------
ATTACHED=()
if [ -f "$ATTACHED_FILE" ]; then
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    case "$name" in '#'*) continue ;; esac
    ATTACHED+=("$name")
  done < "$ATTACHED_FILE"
fi

if [ "${#ATTACHED[@]}" -eq 0 ]; then
  echo "$TS WARN hub-sync: no adapters attached (empty or missing $ATTACHED_FILE) -- bailing" >>"$LOG"
  exit 0
fi

# Load an adapter in a subshell to avoid polluting this shell's env with
# one adapter's vars before another's. Usage: `load_in_subshell claude-code CMD ARG...`.
# CMD runs with ADAPTER_* vars and ADAPTER_DIR populated.
# The phases below instead source the adapter in-process and snapshot
# the few fields they need (ADAPTER_DIR, ADAPTER_SECRET_FILES). This is
# cheaper than subshelling and required so harvest/fan-out see the
# right ADAPTER_HUB_MAP / ADAPTER_PROJECT_CONTENT_RULES values.

# Collect per-adapter data first (tool dirs + secret lists) so the git
# phase has everything it needs without re-sourcing. These arrays must
# NOT start with `ADAPTER_` — `load_adapter` unsets every variable
# matching `compgen -v ADAPTER_` before sourcing the next adapter, so
# any ADAPTER_-prefixed array we declare here would be wiped after the
# very first load_adapter call in the harvest loop (reducing the fan-out
# phase to a single adapter — silent cross-provider data loss).
declare -a HUB_TOOL_DIRS=()
declare -a HUB_ADAPTER_NAMES=()
declare -a HUB_SECRET_LISTS=()

# --- phase: harvest --------------------------------------------------------
# Bootstrap project-id sidecars BEFORE hub_harvest runs. mirror-projects
# walks each flat-layout adapter's projects/<encoded-cwd>/ tree and
# writes the <variant>/memory/.hive-mind sidecar that hub_harvest keys
# on. Without this pre-pass, a fresh install with existing per-project
# memory silently no-ops — hub_harvest's per-project loop skips
# variants whose sidecar is absent, so the hub's projects/<id>/ stays
# empty and cross-machine per-project sync never materializes.
# Hierarchical-memory-model adapters (Codex/Kimi) don't use the flat
# projects/<encoded-cwd>/ tree, so mirror-projects is a clean no-op
# for them (it exits when projects/ is absent).
MIRROR_PROJECTS="$CORE_DIR/mirror-projects.sh"
for name in "${ATTACHED[@]}"; do
  if ! load_adapter "$name" 2>>"$LOG"; then
    echo "$TS WARN hub-sync: failed to load adapter '$name' -- skipping" >>"$LOG"
    continue
  fi
  tool_dir="${ADAPTER_DIR:-}"
  if [ -z "$tool_dir" ] || [ ! -d "$tool_dir" ]; then
    echo "$TS WARN hub-sync: adapter '$name' ADAPTER_DIR missing ('$tool_dir') -- skipping" >>"$LOG"
    continue
  fi
  HUB_ADAPTER_NAMES+=("$name")
  HUB_TOOL_DIRS+=("$tool_dir")
  HUB_SECRET_LISTS+=("${ADAPTER_SECRET_FILES:-}")
  # Sidecar bootstrap: only for flat-model adapters (the only kind
  # that have a projects/<encoded-cwd>/ layout to mirror).
  if [ "${ADAPTER_MEMORY_MODEL:-}" = "flat" ] && [ -x "$MIRROR_PROJECTS" ]; then
    ADAPTER_DIR="$tool_dir" "$MIRROR_PROJECTS" 2>>"$LOG" || true
  fi
  hub_harvest "$tool_dir" "$HIVE_MIND_HUB_DIR"
done

if [ "${#HUB_ADAPTER_NAMES[@]}" -eq 0 ]; then
  echo "$TS WARN hub-sync: no usable attached adapters -- bailing" >>"$LOG"
  exit 0
fi

# Refresh remote refs BEFORE deciding whether the sync can short-circuit.
# Unlike the per-adapter sync this engine replaces, the hub handles the
# cross-machine propagation path: when nothing changed locally but
# another machine pushed memory updates, we still want to pull + fan out
# so the user sees fresh state on their next turn. Without this fetch,
# `git log @{u}..` compares against a stale origin/<branch> and the
# sync early-exits, leaving remote work invisible until the local tree
# accidentally dirties.
git fetch --quiet 2>>"$LOG" || true

_early_unpushed=0
_remote_ahead=0
_current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if git rev-parse --abbrev-ref @{u} >/dev/null 2>&1; then
  [ -n "$(git log @{u}.. --oneline 2>/dev/null)" ] && _early_unpushed=1
  [ -n "$(git log ..@{u} --oneline 2>/dev/null)" ] && _remote_ahead=1
elif git rev-parse --verify "origin/$_current_branch" >/dev/null 2>&1; then
  [ -n "$(git log "origin/$_current_branch..HEAD" --oneline 2>/dev/null)" ] && _early_unpushed=1
  [ -n "$(git log "HEAD..origin/$_current_branch" --oneline 2>/dev/null)" ] && _remote_ahead=1
else
  _early_unpushed=1
fi
_has_changes=0
[ -n "$(git status --porcelain 2>/dev/null)" ] && _has_changes=1

# --- phase: git pull-rebase ------------------------------------------------
if [ "$_has_changes" -eq 1 ] || [ "$_early_unpushed" -eq 1 ] || [ "$_remote_ahead" -eq 1 ]; then
  _pull_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  _pull_ok=1
  if git rev-parse --abbrev-ref @{u} >/dev/null 2>&1; then
    git pull --rebase --autostash --quiet 2>>"$LOG" || _pull_ok=0
  elif [ -n "$_pull_branch" ] \
       && git rev-parse --verify "origin/$_pull_branch" >/dev/null 2>&1; then
    git pull --rebase --autostash --quiet origin "$_pull_branch" 2>>"$LOG" || _pull_ok=0
  fi
  if [ "$_pull_ok" -eq 0 ]; then
    git rebase --abort 2>/dev/null
    echo "$TS hub-sync: pull-rebase failed -- local edits preserved in $HIVE_MIND_HUB_DIR" >>"$LOG"
  fi
fi

# --- phase: format version gate -------------------------------------------
HIVE_MIND_FORMAT_VERSION=1
FORMAT_FILE=".hive-mind-format"

_fmt_current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
upstream="$(git rev-parse --abbrev-ref @{u} 2>/dev/null)"
if [ -z "$upstream" ] && [ -n "$_fmt_current_branch" ] \
   && git rev-parse --verify "origin/$_fmt_current_branch" >/dev/null 2>&1; then
  upstream="origin/$_fmt_current_branch"
fi
remote_fmt=""
if [ -n "$upstream" ]; then
  remote_fmt="$(git show "$upstream:$FORMAT_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
fi
if [ -n "$remote_fmt" ] && [ "$remote_fmt" -gt "$HIVE_MIND_FORMAT_VERSION" ] 2>/dev/null; then
  echo "$TS ERROR hub-sync: remote is format $remote_fmt but this install only knows format $HIVE_MIND_FORMAT_VERSION -- upgrade hive-mind" >>"$LOG"
  exit 0
fi

if [ ! -f "$FORMAT_FILE" ]; then
  printf 'format-version=%d\n' "$HIVE_MIND_FORMAT_VERSION" > "$FORMAT_FILE"
fi

# --- phase: marker extraction ---------------------------------------------
# Walk every file in the working tree that looks like memory (memory.md,
# projects/*/memory.md, projects/*/memory/**, skills/**). The hub's
# canonical file names for memory are lowercase and adapter-agnostic;
# skills follow the Agent Skills spec and keep the upper-case SKILL.md
# name on disk (no skill.md fallback — that form doesn't exist in any
# shipped adapter's tool dir, so including it in the marker-target
# globs just adds dead patterns).
HUB_MARKER_TARGETS=$'memory.md\nprojects/*/memory.md\nprojects/*/memory/**\nskills/*\nskills/**/*.md\nskills/**/SKILL.md'

file_is_marker_target() {
  local f="$1" glob
  while IFS= read -r glob; do
    [ -z "$glob" ] && continue
    # shellcheck disable=SC2254
    case "$f" in $glob) return 0 ;; esac
  done <<< "$HUB_MARKER_TARGETS"
  return 1
}

# Stage everything before marker scan so the staged index holds exactly
# the files we'll commit.
git add -A 2>/dev/null
if [ -f "$FORMAT_FILE" ]; then
  git add -f -- "$FORMAT_FILE" 2>/dev/null || true
fi

# --- phase: secret-file gate ----------------------------------------------
# Union of every attached adapter's secret list. Same defense-in-depth
# gate as the per-adapter pre-hub sync engine: unstage any file the
# adapter declared as must-never-sync.
for secret_list in "${HUB_SECRET_LISTS[@]}"; do
  [ -z "$secret_list" ] && continue
  for secret in $secret_list; do
    if git diff --cached --name-only -- "$secret" 2>/dev/null | grep -q .; then
      git rm --cached --quiet -- "$secret" 2>/dev/null || true
      echo "$TS WARN hub-sync: refused to sync secret file '$secret' (declared by adapter)" >>"$LOG"
    fi
  done
done

# --- phase: commit with marker-derived message ----------------------------
if ! git diff --cached --quiet; then
  MSG=""
  extractor="$CORE_DIR/marker-extract.sh"
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    file_is_marker_target "$f" || continue
    if [ -x "$extractor" ]; then
      while IFS= read -r extracted; do
        extracted="$(printf %s "$extracted" | tr -d '\r')"
        [ -z "$extracted" ] && continue
        case " + $MSG + " in *" + $extracted + "*) continue ;; esac
        if [ -z "$MSG" ]; then MSG="$extracted"
        else MSG="$MSG + $extracted"; fi
      done < <("$extractor" "$f" 2>>"$LOG")
      if ! git diff --quiet -- "$f" 2>/dev/null; then
        git add -- "$f"
      fi
    fi
  done < <(git diff --cached --name-only -z)

  if [ -n "$MSG" ]; then
    MSG="$(printf %s "$MSG" | head -c 500)"
  fi

  if [ -z "$MSG" ]; then
    basenames=()
    while IFS= read -r -d '' f; do
      bn="${f##*/}"
      bn="${bn//[[:cntrl:]]/ }"
      basenames+=("$bn")
    done < <(git diff --cached --name-only -z)
    n="${#basenames[@]}"
    join_names() { awk 'NR>1{printf ", "}{printf "%s", $0} END{print ""}'; }
    if [ "$n" -eq 1 ]; then
      MSG="update ${basenames[0]}"
    elif [ "$n" -le 3 ]; then
      MSG="update $(printf '%s\n' "${basenames[@]}" | join_names)"
    else
      head3="$(printf '%s\n' "${basenames[@]:0:3}" | join_names)"
      MSG="update $head3, +$((n - 3)) more"
    fi
  fi

  git commit -q -m "$MSG" 2>>"$LOG"
fi

# --- phase: rate-limited push ---------------------------------------------
need_push=0
current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if git rev-parse --abbrev-ref @{u} >/dev/null 2>&1; then
  [ -n "$(git log @{u}.. --oneline 2>/dev/null)" ] && need_push=1
elif git rev-parse --verify "origin/$current_branch" >/dev/null 2>&1; then
  [ -n "$(git log "origin/$current_branch..HEAD" --oneline 2>/dev/null)" ] && need_push=1
else
  need_push=1
fi

if [ "$need_push" -eq 1 ]; then
  : "${HIVE_MIND_MIN_PUSH_INTERVAL_SEC:=10}"
  case "$HIVE_MIND_MIN_PUSH_INTERVAL_SEC" in
    ''|*[!0-9]*) HIVE_MIND_MIN_PUSH_INTERVAL_SEC=10 ;;
  esac
  LAST_PUSH_FILE="${HIVE_MIND_STATE_DIR}/last-push"

  should_push=1
  if [ -f "$LAST_PUSH_FILE" ]; then
    last_push="$(cat "$LAST_PUSH_FILE" 2>/dev/null)"
    now="$(date +%s)"
    case "$last_push" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$((now - last_push))" -lt "$HIVE_MIND_MIN_PUSH_INTERVAL_SEC" ]; then
          should_push=0
        fi
        ;;
    esac
  fi
  if [ "${HIVE_MIND_FORCE_PUSH:-}" = "1" ]; then
    should_push=1
  fi

  if [ "$should_push" -eq 1 ]; then
    push_args=()
    if ! git rev-parse --abbrev-ref @{u} >/dev/null 2>&1; then
      push_args=(-u origin -- "$current_branch")
    fi
    max_retries=5
    backoff=1
    push_ok=0
    for (( _attempt=1; _attempt<=max_retries; _attempt++ )); do
      if git push -q "${push_args[@]}" 2>>"$LOG"; then
        push_ok=1
        break
      fi
      echo "$(date -u +%FT%TZ) WARN hub-sync: push failed, backing off ${backoff}s" >>"$LOG"
      sleep "$backoff"
      backoff=$((backoff * 2))
      [ "$backoff" -gt 30 ] && backoff=30
    done
    if [ "$push_ok" -eq 1 ]; then
      mkdir -p "$HIVE_MIND_STATE_DIR" 2>>"$LOG" || true
      date +%s > "$LAST_PUSH_FILE" 2>>"$LOG" || true
    else
      echo "$(date -u +%FT%TZ) ERROR hub-sync: push failed after $max_retries retries" >>"$LOG"
    fi
  fi
fi

# --- phase: fan-out --------------------------------------------------------
# Re-load each adapter so ADAPTER_HUB_MAP + ADAPTER_PROJECT_CONTENT_RULES
# are in scope when hub_fan_out consults them. The HUB_* array names
# deliberately avoid the ADAPTER_ prefix — see the comment at the
# harvest phase for why.
i=0
while [ "$i" -lt "${#HUB_ADAPTER_NAMES[@]}" ]; do
  name="${HUB_ADAPTER_NAMES[$i]}"
  tool_dir="${HUB_TOOL_DIRS[$i]}"
  i=$((i + 1))
  if ! load_adapter "$name" 2>>"$LOG"; then
    echo "$TS WARN hub-sync: failed to re-load adapter '$name' for fan-out -- skipping" >>"$LOG"
    continue
  fi
  hub_fan_out "$HIVE_MIND_HUB_DIR" "$tool_dir"
done

exit 0
