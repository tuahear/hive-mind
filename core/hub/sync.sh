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

# --- locking ----------------------------------------------------------------
# mkdir is atomic on all platforms. On successful acquire, write a
# heartbeat file inside the lock dir with the acquisition timestamp; on
# clean exit, the trap removes the lock. If a prior sync crashed or was
# killed before the trap could fire, the lock is left behind and every
# subsequent sync would silently hit the retry cap (5 × 2s) and exit 0.
# That turns a one-time crash into hours of invisible no-op syncs.
#
# Heartbeat-age check below breaks stale locks older than
# HIVE_MIND_LOCK_STALE_SECS (default 300s). Timestamp only — no PID
# liveness check, since PIDs aren't portable across shells/machines and
# a process from another cron/shell may legitimately hold the lock.
# Long-running syncs refresh the heartbeat at phase boundaries so the
# stale threshold reflects liveness, not just acquisition time.
_hm_sanitize_int() {
  local name="$1" default="$2" val
  # sync.sh runs under bash (shebang + arrays/declare elsewhere), so
  # use indirect expansion + printf -v instead of eval. Avoids any
  # risk of a caller-chosen variable name being shell-interpreted.
  case "$name" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  if [ "${!name+x}" = x ]; then
    val="${!name}"
  else
    val=""
  fi
  case "$val" in
    ''|*[!0-9]*) val="$default" ;;
  esac
  printf -v "$name" '%s' "$val"
}
# Default 300s is sized to be comfortably longer than any realistic
# single phase (harvest, fan-out, network git ops). A deployment with
# unusually long phases — huge harvest corpora, very slow network, big
# bundle push — must raise this explicitly, otherwise a peer could
# consider the holder stale and break the lock mid-phase. If this
# threshold proves insufficient in practice, the next step is a
# background heartbeat refresher (subshell + trap-kill) rather than
# more phase-boundary refresh calls.
_hm_sanitize_int HIVE_MIND_LOCK_STALE_SECS 300
# Test knob: override the retry sleep so bats can cover the
# "fresh lock is respected" path without waiting ~10s on every run.
# Intentionally undocumented — sync.sh defaults to a human-timescale
# 2s so real contention doesn't hammer the filesystem.
_hm_sanitize_int HIVE_MIND_LOCK_RETRY_SLEEP_SEC 2
# Grace period for a lock dir that has no heartbeat file. `mkdir`
# is atomic but the heartbeat write is a separate syscall, so a
# concurrent acquirer can momentarily observe `lock dir exists,
# heartbeat absent` during a healthy acquire. Only treat the
# heartbeat-absent state as stale once the lock dir itself is
# older than this threshold.
_hm_sanitize_int HIVE_MIND_LOCK_NO_HB_GRACE_SECS 10
LOCK_HEARTBEAT="$LOCK_DIR/heartbeat"

# Acquire the lock AND confirm the heartbeat landed. Without the
# heartbeat, a concurrent sync's _break_stale_lock would legitimately
# see an "abandoned" lock dir and break ours mid-run — release and
# return failure so the retry loop either re-acquires after the break
# or fails visibly.
acquire_lock() {
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  if ! date +%s > "$LOCK_HEARTBEAT" 2>/dev/null; then
    rm -rf "$LOCK_DIR" 2>/dev/null
    return 1
  fi
  return 0
}
release_lock() {
  local rm_status
  rm -rf "$LOCK_DIR" 2>/dev/null
  rm_status=$?
  # Report the removal operation's own result. An `[ ! -e ]` post-check
  # looks simpler but is racy — a peer sync can recreate the lock dir
  # between our rm and the test, producing a false failure + a
  # misleading "could not remove" warning. rm's exit status reflects
  # what *we* did, which is what the caller actually wants to know.
  [ "$rm_status" -eq 0 ]
}

# Refresh the heartbeat so long-running phases (git fetch/pull/push,
# large adapter harvests) don't get their lock broken by a peer sync.
# Safe to call from anywhere while the current process holds the lock;
# a no-op if the lock was already released.
refresh_lock_heartbeat() {
  # Match _break_stale_lock's safety guard: `test -d` follows
  # symlinks, so a symlinked $LOCK_DIR could have us writing the
  # heartbeat through the link to an unintended location. Refuse a
  # symlinked heartbeat path too (the file may be created fresh, but
  # if something placed a symlink there, don't follow it).
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || return 0
  [ ! -L "$LOCK_HEARTBEAT" ] || return 0
  date +%s > "$LOCK_HEARTBEAT" 2>/dev/null
}

# Portable directory mtime — GNU uses `stat -c %Y`, BSD/macOS uses
# `stat -f %m`. Prints seconds-since-epoch, or nothing on failure.
_lock_dir_mtime() {
  stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null
}

# Break the lock if its heartbeat is older than the staleness threshold,
# or if the heartbeat file is missing AND the lock dir itself is older
# than the grace window (catches legacy locks and crashes between mkdir
# and heartbeat write, without racing a healthy peer still mid-acquire).
# Logs the break so operators can see why a lock disappeared.
_break_stale_lock() {
  local hb_age now hb_ts dir_mtime dir_age
  # Only operate on real directories — not regular files, and not
  # symlinks (even symlinks that point to a directory: `test -d`
  # follows them, so without `! -L` we'd happily chase a symlink out
  # of $LOCK_DIR and rm -rf whatever it pointed at). release_lock's
  # `rm -rf` doesn't discriminate, so the guard has to. Defer to the
  # retry loop; acquire_lock already handles "path-exists-but-isn't-
  # acquirable" by failing mkdir and sleeping.
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || return 1
  now="$(date +%s 2>/dev/null)"
  [ -z "$now" ] && return 1

  # Treat a symlinked heartbeat the same as a missing one (fail closed,
  # go down the grace-window path). `test -f` follows symlinks, so
  # without this guard a symlink placed at the heartbeat path would
  # cause the later `cat` to read from (and potentially base break
  # decisions on) an arbitrary target file.
  if [ ! -f "$LOCK_HEARTBEAT" ] || [ -L "$LOCK_HEARTBEAT" ]; then
    dir_mtime="$(_lock_dir_mtime)"
    case "$dir_mtime" in ''|*[!0-9]*) dir_mtime=0 ;; esac
    if [ "$dir_mtime" -eq 0 ]; then
      # Can't determine dir age — fail closed (don't break). Peer
      # will come around again and eventually resolve.
      return 1
    fi
    dir_age=$((now - dir_mtime))
    if [ "$dir_age" -gt "$HIVE_MIND_LOCK_NO_HB_GRACE_SECS" ]; then
      if release_lock; then
        echo "$TS WARN hub-sync: broke lock with no heartbeat (age ${dir_age}s, legacy or crashed mid-acquire)" >>"$LOG"
        return 0
      fi
      # Unlink failed — fall through to the normal retry/sleep so we
      # don't spin on `continue`. Log so the operator can see what's
      # blocking cleanup.
      echo "$TS WARN hub-sync: could not remove stale lock $LOCK_DIR (no heartbeat, age ${dir_age}s) -- retrying" >>"$LOG"
      return 1
    fi
    return 1
  fi

  hb_ts="$(cat "$LOCK_HEARTBEAT" 2>/dev/null)"
  case "$hb_ts" in
    ''|*[!0-9]*) hb_ts=0 ;;
  esac
  hb_age=$((now - hb_ts))
  if [ "$hb_age" -gt "$HIVE_MIND_LOCK_STALE_SECS" ]; then
    if release_lock; then
      echo "$TS WARN hub-sync: broke stale lock (age ${hb_age}s > ${HIVE_MIND_LOCK_STALE_SECS}s)" >>"$LOG"
      return 0
    fi
    echo "$TS WARN hub-sync: could not remove stale lock $LOCK_DIR (age ${hb_age}s) -- retrying" >>"$LOG"
    return 1
  fi
  return 1
}

_lock_retries=0
while ! acquire_lock; do
  # Before burning the next sleep, see if the lock is stale. If it is,
  # break it and retry immediately (don't count the stale-break against
  # the retry budget — the budget is for genuine contention).
  if _break_stale_lock; then
    continue
  fi
  _lock_retries=$((_lock_retries + 1))
  [ "$_lock_retries" -ge 5 ] && exit 0
  sleep "$HIVE_MIND_LOCK_RETRY_SLEEP_SEC"
done
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
# shellcheck source=/dev/null
source "$CORE_DIR/hub/project-gc.sh"

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
# HUB_FILE_HARVEST_RULES: all synced file globs (global + skills + projects).
# Not consumed yet — reserved for future use (e.g., user-extensible sync).
declare -a HUB_FILE_HARVEST_RULES=()
# HUB_PROJECT_CONTENT_GLOBS + HUB_PROJECT_CONTENT_RULES: used by variant GC.
declare -a HUB_PROJECT_CONTENT_GLOBS=()
declare -a HUB_PROJECT_CONTENT_RULES=()

# --- phase: harvest --------------------------------------------------------
refresh_lock_heartbeat
# Bootstrap project-id sidecars BEFORE hub_harvest runs. mirror-projects
# walks each flat-layout adapter's projects/<encoded-cwd>/ tree and
# writes the <variant>/.hive-mind sidecar (at the variant root) that
# hub_harvest keys on. Without this pre-pass, a fresh install with
# memory silently no-ops — hub_harvest's per-project loop skips
# variants whose sidecar is absent, so the hub's projects/<id>/ stays
# empty and cross-machine per-project sync never materializes.
# Hierarchical-memory-model adapters (Codex/Kimi) don't use the flat
# projects/<encoded-cwd>/ tree, so mirror-projects is a clean no-op
# for them (it exits when projects/ is absent).
MIRROR_PROJECTS="$CORE_DIR/mirror-projects.sh"
# IMPORTANT: unset ADAPTER_DIR before each load so adapter N+1 does NOT
# inherit adapter N's tool directory. The loader preserves ADAPTER_DIR
# across its clear step as the supported caller-override hook (tests,
# alternative installs), but in sync.sh's sequential multi-adapter loop
# that "override" is actually a leftover from the previous adapter — if
# we don't clear it, adapter N+1's `ADAPTER_DIR="${ADAPTER_DIR:-default}"`
# fallback silently inherits adapter N's path and every subsequent
# harvest/fan-out writes adapter N+1's native files into adapter N's
# directory (e.g. Codex's hooks.json + AGENTS.override.md appearing
# under ~/.claude after Claude loaded first).
for name in "${ATTACHED[@]}"; do
  unset ADAPTER_DIR
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
  HUB_FILE_HARVEST_RULES+=("${ADAPTER_FILE_HARVEST_RULES:-}")
  HUB_PROJECT_CONTENT_GLOBS+=("${ADAPTER_PROJECT_CONTENT_GLOBS:-}")
  HUB_PROJECT_CONTENT_RULES+=("${ADAPTER_PROJECT_CONTENT_RULES:-}")
  # Sidecar bootstrap: only for flat-model adapters (the only kind
  # that have a projects/<encoded-cwd>/ layout to mirror).
  if [ "${ADAPTER_MEMORY_MODEL:-}" = "flat" ] && [ -x "$MIRROR_PROJECTS" ]; then
    ADAPTER_DIR="$tool_dir" "$MIRROR_PROJECTS" 2>>"$LOG" || true
  fi
  hub_harvest "$tool_dir" "$HIVE_MIND_HUB_DIR"
  # Strip commit markers from tool-side files AFTER harvest copied them
  # to the hub. Without this, fan-out later writes the hub's marker-
  # stripped content back to the tool variant, but the tool still has
  # the marker → mirror-projects on the NEXT sync copies it to siblings
  # again. Stripping here means tool and hub are both marker-free after
  # the commit phase, and fan-out is a content-identical no-op.
  if [ -x "$CORE_DIR/marker-extract.sh" ]; then
    # One recursive grep beats N per-file greps. On Windows/MSYS every
    # subprocess spawn is ~30-50ms, and an adapter with ~1k .md files
    # (Claude's projects/<variant>/memory/ accumulates across every repo
    # the user has opened) turns an innocuous per-file grep loop into
    # ~50s of pure subprocess overhead on every sync. `grep -rlE` scans
    # the tree in a single invocation and emits only matching paths, so
    # marker-extract.sh runs only on files that actually carry a marker.
    while IFS= read -r mf; do
      [ -n "$mf" ] || continue
      "$CORE_DIR/marker-extract.sh" "$mf" >/dev/null 2>>"$LOG" || true
    done < <(grep -rlE --include='*.md' '<!--[[:space:]]*commit:' "$tool_dir" 2>/dev/null)
  fi
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
#
# Throttle: on Windows/MSYS a single `git fetch` costs ~5s of network
# wait. Back-to-back syncs (Stop hook + SessionStart hook + a manual
# hivemind invocation) would each pay that cost even when nothing
# could plausibly have changed upstream in the last few seconds.
# HIVE_MIND_MIN_FETCH_INTERVAL_SEC caps the rate; default 30s is short
# enough that cross-machine propagation still feels instant within the
# same work session. Set to 0 to force a fetch every sync.
: "${HIVE_MIND_MIN_FETCH_INTERVAL_SEC:=30}"
case "$HIVE_MIND_MIN_FETCH_INTERVAL_SEC" in
  ''|*[!0-9]*) HIVE_MIND_MIN_FETCH_INTERVAL_SEC=30 ;;
esac
LAST_FETCH_FILE="${HIVE_MIND_STATE_DIR}/last-fetch"
_should_fetch=1
if [ -f "$LAST_FETCH_FILE" ] && [ "$HIVE_MIND_MIN_FETCH_INTERVAL_SEC" -gt 0 ]; then
  _last_fetch="$(cat "$LAST_FETCH_FILE" 2>/dev/null)"
  case "$_last_fetch" in
    ''|*[!0-9]*) ;;
    *)
      _now="$(date +%s)"
      if [ "$((_now - _last_fetch))" -lt "$HIVE_MIND_MIN_FETCH_INTERVAL_SEC" ]; then
        _should_fetch=0
      fi
      ;;
  esac
fi
if [ "$_should_fetch" -eq 1 ]; then
  git fetch --quiet 2>>"$LOG" || true
  date +%s > "$LAST_FETCH_FILE" 2>>"$LOG" || true
fi

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

refresh_lock_heartbeat
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
  # MSYS_NO_PATHCONV=1: on Git Bash / MSYS the `<ref>:<path>` argument
  # looks path-shaped to MSYS's path-translation pass, which rewrites
  # the `/` in `origin/main` to `\` and the `:` separator to `;` before
  # git sees it. Git then errors with "ambiguous argument
  # 'origin\main;.hive-mind-format'", the stderr redirect swallows it,
  # and the gate silently no-ops. Disabling translation for this one
  # call keeps the ref:path literal on every platform.
  remote_fmt="$(MSYS_NO_PATHCONV=1 git show "$upstream:$FORMAT_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
fi
if [ -n "$remote_fmt" ] && [ "$remote_fmt" -gt "$HIVE_MIND_FORMAT_VERSION" ] 2>/dev/null; then
  echo "$TS ERROR hub-sync: remote is format $remote_fmt but this install only knows format $HIVE_MIND_FORMAT_VERSION -- upgrade hive-mind" >>"$LOG"
  exit 0
fi

if [ ! -f "$FORMAT_FILE" ]; then
  printf 'format-version=%d\n' "$HIVE_MIND_FORMAT_VERSION" > "$FORMAT_FILE"
fi

# --- phase: project GC ----------------------------------------------------
# Remove hub project dirs with no live sidecar and stale last-touch,
# plus tool-side variant dirs whose cwd no longer exists on disk.
# Runs after harvest so newly discovered projects are not falsely GC'd.
hub_gc_projects 2>>"$LOG" || true
hub_gc_tool_variants 2>>"$LOG" || true

# --- phase: marker extraction ---------------------------------------------
# Walk every file that looks like content (content.md at root, per-project
# content.md + markdown subfiles, skills). Only markdown files are
# eligible for marker extraction — non-markdown assets are left alone.
HUB_MARKER_TARGETS=$'content.md\nprojects/**/content.md\nprojects/**/*.md\nskills/**/*.md\nskills/**/content.md'

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
#
# The contract declares ADAPTER_SECRET_FILES as a list of BASENAMES
# (docs/contributing.md: "Space-separated filenames that must
# never be synced"). A misconfigured adapter or an off-by-one hub map
# could harvest a secret to a path that isn't the literal basename at
# the hub root (e.g. `config/auth.json`, `backup/2024/auth.json`).
# Matching by basename catches every such path — the cost is unstaging
# a legitimate `notes/auth.json` the user intentionally named to match
# a known-secret basename, which is an acceptable trade for preventing
# a credential leak. If an adapter ever needs path-specific semantics,
# extend the contract with a second declared list that uses path
# globs; the current list stays basename-only to keep the invariant
# simple to reason about.
_staged_files_with_basename() {
  local want_base="$1"
  # Read NUL-delimited staged paths one at a time (preserves every
  # character including embedded newlines) and emit only those whose
  # basename matches. Plain bash parameter expansion instead of awk —
  # macOS's default awk treats `RS="\0"` as the POSIX-default
  # single-character record separator and drops every record after
  # the first NUL, so a sync with >1 staged path would silently match
  # only one of them. The bash loop works identically on BSD/macOS
  # and GNU/Linux.
  local path base
  while IFS= read -r -d '' path; do
    base="${path##*/}"
    [ "$base" = "$want_base" ] && printf '%s\0' "$path"
  done < <(git diff --cached --name-only -z 2>/dev/null)
}
for secret_list in "${HUB_SECRET_LISTS[@]}"; do
  [ -z "$secret_list" ] && continue
  for secret in $secret_list; do
    # Strip any accidental path component from the declared value so a
    # contract violation (e.g. `auth.json` mistakenly declared as
    # `config/auth.json`) still gets treated as a basename check.
    secret_base="${secret##*/}"
    [ -z "$secret_base" ] && continue
    # Walk every staged path whose basename matches.
    found=0
    while IFS= read -r -d '' matched_path; do
      [ -z "$matched_path" ] && continue
      git rm --cached --quiet -- "$matched_path" 2>/dev/null || true
      echo "$TS WARN hub-sync: refused to sync secret '$secret_base' (matched staged path '$matched_path', declared by adapter)" >>"$LOG"
      found=1
    done < <(_staged_files_with_basename "$secret_base")
    # Preserve backward compat: if the declared value was a path-like
    # form and matches verbatim too, unstage it. Covers a misconfigured
    # adapter that declared `config/auth.json` AND also happens to
    # stage exactly that path — the basename pass already handled it,
    # but being explicit avoids any future surprise where the two
    # forms diverge.
    if [ "$found" -eq 0 ] && [ "$secret" != "$secret_base" ]; then
      if git diff --cached --name-only -- "$secret" 2>/dev/null | grep -q .; then
        git rm --cached --quiet -- "$secret" 2>/dev/null || true
        echo "$TS WARN hub-sync: refused to sync secret '$secret' (declared by adapter, path-literal match)" >>"$LOG"
      fi
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

refresh_lock_heartbeat
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

refresh_lock_heartbeat
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
  # Same unset-before-load dance as the harvest phase (see comment
  # there). Without this, ADAPTER_DIR from the previous iteration leaks
  # through the loader's caller-override preservation and the next
  # adapter's internal state points at the wrong tool dir — harvest-
  # sourced env vars (ADAPTER_HUB_MAP paths, ADAPTER_LOG_PATH, etc.)
  # all derive from ADAPTER_DIR and would be silently wrong.
  unset ADAPTER_DIR
  if ! load_adapter "$name" 2>>"$LOG"; then
    echo "$TS WARN hub-sync: failed to re-load adapter '$name' for fan-out -- skipping" >>"$LOG"
    continue
  fi
  hub_fan_out "$HIVE_MIND_HUB_DIR" "$tool_dir"
done

exit 0
