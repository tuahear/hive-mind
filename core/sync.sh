#!/bin/bash
# Auto-sync memory to the tracking git repo.
# Invoked by the turn-end hook after each turn. Intended to be fully
# non-blocking: every failure path logs and exits 0 so the hook never
# surfaces noise.
#
# Adapter-agnostic: uses ADAPTER_DIR (set by the calling adapter or shim)
# to locate the memory repo. Falls back to ~/.claude for backward compat.

set +e

CORE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ADAPTER_DIR may be set by the adapter shim that invokes us. If not,
# fall back to ~/.claude (backward compat with pre-refactor hook commands).
: "${ADAPTER_DIR:=$HOME/.claude}"
cd "$ADAPTER_DIR" || exit 0

# Cross-process lock. The Stop hook runs async and retries with backoff,
# so rapid turns or a stuck upstream can spawn many concurrent sync
# processes racing for git's index.lock. A simple mkdir-based lock
# (atomic on every POSIX filesystem) lets at most one sync run at a
# time; late arrivals exit cleanly and let the current one finish.
HIVE_MIND_STATE_DIR="${ADAPTER_DIR}/.hive-mind-state"
LOCK_DIR="${HIVE_MIND_STATE_DIR}/sync.lock"
mkdir -p "$HIVE_MIND_STATE_DIR" 2>/dev/null
acquire_lock() {
  # Atomic acquisition: mkdir fails if the dir exists. On success, write
  # the timestamp and owner PID IMMEDIATELY so a contending process can
  # check staleness without a race and so we can verify ownership on
  # release. Returns 0 on acquire, 1 on contended-and-not-stale.
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    date +%s > "$LOCK_DIR/created-at" 2>/dev/null
    echo "$$" > "$LOCK_DIR/owner-pid" 2>/dev/null
    return 0
  fi
  return 1
}

release_lock() {
  # Only remove the lock dir if we still own it. If a slow-running sync
  # exceeded STALE_AGE_SEC, a newer process may have reclaimed the lock
  # and started its own work — removing that process's lock would allow
  # another sync to start concurrently, defeating mutual exclusion.
  lock_owner=""
  [ -f "$LOCK_DIR/owner-pid" ] && lock_owner="$(cat "$LOCK_DIR/owner-pid" 2>/dev/null)"
  if [ "$lock_owner" = "$$" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null
  fi
}

STALE_AGE_SEC=300  # 5 minutes

if ! acquire_lock; then
  # Stale-lock detection. The timestamp file is written by the lock
  # holder IMMEDIATELY after mkdir (no window without it). If the
  # file is missing, the holder crashed between mkdir and the write —
  # give it a short grace period (2s, << any real sync) before
  # treating the lock as stale, so we never race a just-acquired lock.
  lock_ts_file="$LOCK_DIR/created-at"
  if [ ! -f "$lock_ts_file" ]; then
    sleep 2
  fi
  lock_ts=""
  [ -f "$lock_ts_file" ] && lock_ts="$(cat "$lock_ts_file" 2>/dev/null)"
  case "$lock_ts" in
    ''|*[!0-9]*) lock_ts=0 ;;
  esac
  now_ts="$(date +%s)"
  # Consider the lock live if the owner PID is still running, even past
  # the staleness age. This stops a legitimately slow sync from having
  # its lock reclaimed under its feet. Only check the age as a fallback
  # for dead / missing / unknown owners.
  owner_pid=""
  [ -f "$LOCK_DIR/owner-pid" ] && owner_pid="$(cat "$LOCK_DIR/owner-pid" 2>/dev/null)"
  owner_alive=0
  case "$owner_pid" in
    ''|*[!0-9]*) owner_alive=0 ;;
    *) kill -0 "$owner_pid" 2>/dev/null && owner_alive=1 ;;
  esac
  if [ "$owner_alive" -eq 1 ]; then
    exit 0
  fi
  if [ "$lock_ts" -eq 0 ] || [ "$((now_ts - lock_ts))" -gt "$STALE_AGE_SEC" ]; then
    # Genuinely stale. Reclaim — but use acquire_lock again so we
    # handle the unlikely case of another process reclaiming first.
    rm -rf "$LOCK_DIR" 2>/dev/null
    acquire_lock || exit 0
  else
    exit 0
  fi
fi
trap 'release_lock' EXIT

# Log path: prefer adapter-declared path (Appendix A.2), fall back to the
# per-directory default so pre-refactor installs keep working.
if [ -n "${ADAPTER_LOG_PATH:-}" ]; then
  LOG="$ADAPTER_LOG_PATH"
else
  LOG=.sync-error.log
fi
TS="$(date -u +%FT%TZ)"

# Mirror per-project memory across path-variant directories before the
# early-exit gate. This is local-only and idempotent: it writes any
# missing <variant>/memory/.hive-mind sidecars (bootstrap) and unifies
# content across variants whose normalized git-remote URL matches.
# Running it BEFORE the gate means a brand-new clone on a fresh machine
# bootstraps its sidecars on the very first turn-end without any manual
# step. On steady state it does nothing and the gate below still
# short-circuits the network call.
mirror="$CORE_DIR/mirror-projects.sh"
if [ ! -x "$mirror" ]; then
  # Legacy path (pre-refactor installs).
  mirror="$ADAPTER_DIR/hive-mind/scripts/mirror-projects.sh"
fi
if [ -x "$mirror" ]; then
  if ! ADAPTER_DIR="$ADAPTER_DIR" "$mirror" 2>>"$LOG"; then
    echo "$TS sync mirror-projects failed" >>"$LOG"
  fi
fi

# Early gate: if nothing has changed in the working tree AND there are no
# unpushed local commits, skip entirely -- no network, no git, no cost.
# Determine "unpushed" with the same fallback used by the push block:
# prefer @{u}, fall back to origin/<branch>, give up (treat as unpushed
# so we don't short-circuit) when neither is configured.
_early_unpushed=0
_current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if git rev-parse --abbrev-ref @{u} >/dev/null 2>&1; then
  [ -n "$(git log @{u}.. --oneline 2>/dev/null)" ] && _early_unpushed=1
elif git rev-parse --verify "origin/$_current_branch" >/dev/null 2>&1; then
  [ -n "$(git log "origin/$_current_branch..HEAD" --oneline 2>/dev/null)" ] && _early_unpushed=1
else
  # No upstream and no matching remote branch — never short-circuit,
  # the push block below needs to do the first push.
  _early_unpushed=1
fi
if [ -z "$(git status --porcelain)" ] && [ "$_early_unpushed" -eq 0 ]; then
  exit 0
fi

# Pull-rebase first so our imminent push is a fast-forward.
if ! git pull --rebase --autostash --quiet 2>>"$LOG"; then
  git rebase --abort 2>/dev/null
  echo "$TS sync pull-rebase failed -- local edits preserved, resolve in $ADAPTER_DIR" >>"$LOG"
fi

# --- Memory repo format version check -------------------------------------
HIVE_MIND_FORMAT_VERSION=1
FORMAT_FILE=".hive-mind-format"

# Read remote format version from the branch's configured upstream (not
# a hardcoded origin/main — users may track a different default branch).
upstream="$(git rev-parse --abbrev-ref @{u} 2>/dev/null)"
remote_fmt=""
if [ -n "$upstream" ]; then
  remote_fmt="$(git show "$upstream:$FORMAT_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
fi

if [ -n "$remote_fmt" ]; then
  if [ "$remote_fmt" -gt "$HIVE_MIND_FORMAT_VERSION" ] 2>/dev/null; then
    echo "$TS ERROR sync: remote memory repo is format $remote_fmt but this install only knows format $HIVE_MIND_FORMAT_VERSION -- upgrade hive-mind" >>"$LOG"
    exit 0
  fi
fi

# Seed format file on first sync if absent from working tree.
if [ ! -f "$FORMAT_FILE" ]; then
  printf 'format-version=%d\n' "$HIVE_MIND_FORMAT_VERSION" > "$FORMAT_FILE"
fi

# Stage whatever changed in whitelisted paths (gitignore filters the rest).
git add -A 2>/dev/null
# Force-stage the format file so it reaches the remote even when a
# pre-refactor .gitignore (one that hasn't been refreshed via setup.sh
# on this install) would otherwise ignore it. Without this, remote
# format-version state stops advancing and future installs can't
# reliably detect / abort on a newer-format remote.
if [ -f "$FORMAT_FILE" ]; then
  git add -f -- "$FORMAT_FILE" 2>/dev/null || true
fi

# Secret-file safety gate. ADAPTER_SECRET_FILES is a space-separated list
# of relative paths that MUST NOT be synced, even if a misconfigured
# .gitignore would otherwise allow them (e.g. Codex's auth.json). Unstage
# any that slipped in so `git diff --cached` below won't commit them.
if [ -n "${ADAPTER_SECRET_FILES:-}" ]; then
  for secret in $ADAPTER_SECRET_FILES; do
    if git diff --cached --name-only -- "$secret" 2>/dev/null | grep -q .; then
      git rm --cached --quiet -- "$secret" 2>/dev/null || true
      echo "$TS WARN sync: refused to sync secret file '$secret' (declared by adapter)" >>"$LOG"
    fi
  done
fi

if ! git diff --cached --quiet; then
  MSG=""

  # Build marker-target globs from ADAPTER_MARKER_TARGETS if set, else
  # use the defaults that match the original Claude Code whitelist.
  if [ -z "${ADAPTER_MARKER_TARGETS:-}" ]; then
    ADAPTER_MARKER_TARGETS=$'*.md\n**/*.md'
  fi

  # Determine if a staged file matches the marker-target globs.
  file_is_marker_target() {
    local f="$1"
    while IFS= read -r glob; do
      [ -z "$glob" ] && continue
      # shellcheck disable=SC2254
      case "$f" in
        $glob) return 0 ;;
      esac
    done <<< "$ADAPTER_MARKER_TARGETS"
    return 1
  }

  # Look for <!-- commit: ... --> markers inside staged memory files.
  # Delegate the fence-aware extract-and-strip to core/marker-extract.sh
  # so the parsing logic isn't duplicated. marker-extract mutates the
  # file in-place (strips markers, trims trailing blanks) and echoes
  # extracted messages to stdout, one per line.
  extractor="$CORE_DIR/marker-extract.sh"
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    file_is_marker_target "$f" || continue

    if [ -x "$extractor" ]; then
      while IFS= read -r extracted; do
        extracted="$(printf %s "$extracted" | tr -d '\r')"
        [ -z "$extracted" ] && continue
        # Dedup: mirror-projects.sh copies an edited file into path-variant
        # peers, so the same marker appears in multiple staged files.
        case " + $MSG + " in
          *" + $extracted + "*) continue ;;
        esac
        if [ -z "$MSG" ]; then
          MSG="$extracted"
        else
          MSG="$MSG + $extracted"
        fi
      done < <("$extractor" "$f" 2>>"$LOG")
      # Re-stage if marker-extract mutated the working-tree copy. Compare
      # index vs worktree via `git diff` -- portable and doesn't depend on
      # shasum/sha1sum availability.
      if ! git diff --quiet -- "$f" 2>/dev/null; then
        git add "$f"
      fi
    fi
  done < <(git diff --cached --name-only -z)

  # Clip joined message.
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

# --- Rate-limited push ----------------------------------------------------
# Push runs whenever there are unpushed commits — NOT only when this
# invocation made a new commit. Otherwise a debounced/failed push from a
# prior turn would never get retried until the next file change. The
# push-block lives outside the staged-diff branch so it always fires.
#
# Fresh installs may not have an upstream configured yet (`@{u}` is
# undefined until the first `git push -u`). In that case, fall back to
# comparing against the remote's same-named branch if it exists, and if
# even that's missing, push unconditionally — otherwise first-install
# initial commits would be silently stranded.
need_push=0
current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if git rev-parse --abbrev-ref @{u} >/dev/null 2>&1; then
  [ -n "$(git log @{u}.. --oneline 2>/dev/null)" ] && need_push=1
elif git rev-parse --verify "origin/$current_branch" >/dev/null 2>&1; then
  [ -n "$(git log "origin/$current_branch..HEAD" --oneline 2>/dev/null)" ] && need_push=1
else
  # No upstream and no matching remote branch — this is the very first
  # push on a fresh-initialized repo. Push unconditionally so the
  # initial commit actually reaches the remote.
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
      ''|*[!0-9]*) ;;  # non-numeric or empty → treat as "no recorded push"
      *)
        if [ "$((now - last_push))" -lt "$HIVE_MIND_MIN_PUSH_INTERVAL_SEC" ]; then
          should_push=0
        fi
        ;;
    esac
  fi

  # HIVE_MIND_FORCE_PUSH overrides debounce (used by `hivemind sync`).
  if [ "${HIVE_MIND_FORCE_PUSH:-}" = "1" ]; then
    should_push=1
  fi

  if [ "$should_push" -eq 1 ]; then
    # If there's no upstream, set it on this push so subsequent syncs
    # can use `@{u}` for the unpushed-commits check. Build as an array
    # so branch names with unusual characters can't be reinterpreted
    # as flags via word-splitting; `--` separates refspec from flags.
    push_args=()
    if ! git rev-parse --abbrev-ref @{u} >/dev/null 2>&1; then
      push_args=(-u origin -- "$current_branch")
    fi

    # Exponential backoff on push failure (1s, 2s, 4s, 8s, cap at 30s).
    max_retries=5
    backoff=1
    push_ok=0
    for (( _attempt=1; _attempt<=max_retries; _attempt++ )); do
      if git push -q "${push_args[@]}" 2>>"$LOG"; then
        push_ok=1
        break
      fi
      echo "$TS WARN sync: push failed, backing off ${backoff}s" >>"$LOG"
      sleep "$backoff"
      backoff=$((backoff * 2))
      [ "$backoff" -gt 30 ] && backoff=30
    done

    if [ "$push_ok" -eq 1 ]; then
      # Redirect both stderr and stdout — a read-only adapter dir or
      # a full disk would otherwise leak "permission denied" /
      # "no space left" into the hook transcript.
      mkdir -p "$HIVE_MIND_STATE_DIR" 2>>"$LOG" || true
      date +%s > "$LAST_PUSH_FILE" 2>>"$LOG" || true
    else
      echo "$TS ERROR sync: push failed after $max_retries retries" >>"$LOG"
    fi
  fi
fi

exit 0
