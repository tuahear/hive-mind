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

LOG=.sync-error.log
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
if [ -z "$(git status --porcelain)" ] && [ -z "$(git log @{u}.. --oneline 2>/dev/null)" ]; then
  exit 0
fi

# Pull-rebase first so our imminent push is a fast-forward.
if ! git pull --rebase --autostash --quiet 2>>"$LOG"; then
  git rebase --abort 2>/dev/null
  echo "$TS sync pull-rebase failed -- local edits preserved, resolve in $ADAPTER_DIR" >>"$LOG"
fi

# Stage whatever changed in whitelisted paths (gitignore filters the rest).
git add -A 2>/dev/null

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
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    file_is_marker_target "$f" || continue
    grep -q '<!--[[:space:]]*commit:' "$f" || continue

    # Fence-aware extract + strip in a single awk pass.
    tmp="$(mktemp)"
    msg_file="$(mktemp)"
    awk -v msgfile="$msg_file" '
      BEGIN { fence = 0 }
      /^[[:space:]]*```/ { fence = 1 - fence; print; next }
      fence == 1 { print; next }
      {
        line = $0
        if (match(line, /^[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*[^>]+-->[[:space:]]*$/)) {
          msg = line
          sub(/^[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*/, "", msg)
          sub(/[[:space:]]*-->[[:space:]]*$/, "", msg)
          print msg >> msgfile
          next
        }
        if (match(line, /<!--[[:space:]]*commit:[[:space:]]*[^>]+-->/)) {
          m = substr(line, RSTART, RLENGTH)
          msg = m
          sub(/^<!--[[:space:]]*commit:[[:space:]]*/, "", msg)
          sub(/[[:space:]]*-->$/, "", msg)
          print msg >> msgfile
          gsub(/[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*[^>]+-->/, "", line)
        }
        print line
      }
      END { close(msgfile) }
    ' "$f" > "$tmp"

    # Trim trailing blank lines.
    awk '{ lines[NR]=$0; last=NR }
         END {
           while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
           for (i=1; i<=last; i++) print lines[i]
         }' "$tmp" > "$tmp.trim" && mv "$tmp.trim" "$tmp"

    if [ -s "$msg_file" ]; then
      while IFS= read -r extracted; do
        extracted="$(printf %s "$extracted" | tr -d '\r')"
        [ -z "$extracted" ] && continue
        case " + $MSG + " in
          *" + $extracted + "*) continue ;;
        esac
        if [ -z "$MSG" ]; then
          MSG="$extracted"
        else
          MSG="$MSG + $extracted"
        fi
      done < "$msg_file"
    fi
    rm -f "$msg_file"

    if ! cmp -s "$f" "$tmp"; then
      mv "$tmp" "$f"
      git add "$f"
    else
      rm -f "$tmp"
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
  git push -q 2>>"$LOG" || echo "$TS sync push rejected -- will retry next turn" >>"$LOG"
fi

exit 0
