#!/bin/bash
# Auto-sync ~/.claude memory to the tracking git repo.
# Invoked by the Stop hook after each turn. Intended to be fully non-blocking:
# every failure path logs and exits 0 so the hook never surfaces noise.

set +e
cd ~/.claude || exit 0

LOG=.sync-error.log
TS="$(date -u +%FT%TZ)"

# Early gate: if nothing has changed in the working tree AND there are no
# unpushed local commits, skip entirely — no network, no git, no cost. This
# makes the Stop hook a near-no-op on turns that didn't touch memory/config.
if [ -z "$(git status --porcelain)" ] && [ -z "$(git log @{u}.. --oneline 2>/dev/null)" ]; then
  exit 0
fi

# Pull-rebase first so our imminent push is a fast-forward. --autostash keeps
# any in-progress working-tree edits safe during the rebase. If the rebase
# hits a conflict we can't auto-resolve, abort cleanly (autostash restores the
# working tree) and log — we'd rather skip one sync cycle than leave the repo
# in a half-merged state.
if ! git pull --rebase --autostash --quiet 2>>"$LOG"; then
  git rebase --abort 2>/dev/null
  echo "$TS stop-hook pull-rebase failed — local edits preserved, resolve in ~/.claude" >>"$LOG"
fi

# Stage whatever changed in whitelisted paths (gitignore filters the rest).
git add -A 2>/dev/null

if ! git diff --cached --quiet; then
  MSG=""

  # Look for <!-- commit: ... --> markers inside staged memory files. The
  # memory-commit skill instructs agents to embed one of these in their
  # edit; we extract it as the commit message and strip the marker from
  # the file so it never enters git history. Hooks bypass Claude's tool
  # permission system, which is why all of this happens here rather than
  # asking the agent to do it via a separate Write tool call.
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in
      "CLAUDE.md"|projects/*/memory/*|projects/*/MEMORY.md|skills/*) ;;
      *) continue ;;
    esac
    grep -q '<!--[[:space:]]*commit:' "$f" || continue

    # Fence-aware extract + strip in a single awk pass. Markers inside ```
    # code fences are preserved (SKILL.md docs contain illustrative examples
    # that would otherwise be picked up as real commit messages). Every
    # non-fenced marker in the file is extracted into $msg_file (one per
    # line) and stripped from disk; across files, all messages are joined
    # with " + " into a single commit message.
    tmp="$(mktemp)"
    msg_file="$(mktemp)"
    awk -v msgfile="$msg_file" '
      BEGIN { fence = 0 }
      /^[[:space:]]*```/ { fence = 1 - fence; print; next }
      fence == 1 { print; next }
      {
        line = $0
        # Full-line marker: drop entirely.
        if (match(line, /^[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*[^>]+-->[[:space:]]*$/)) {
          msg = line
          sub(/^[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*/, "", msg)
          sub(/[[:space:]]*-->[[:space:]]*$/, "", msg)
          print msg >> msgfile
          next
        }
        # Inline marker: strip from line, keep remaining text.
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

    if [ -s "$msg_file" ]; then
      while IFS= read -r extracted; do
        extracted="$(printf %s "$extracted" | tr -d '\r')"
        [ -z "$extracted" ] && continue
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
  done < <(git diff --cached --name-only)

  # Clip the joined message so git log doesn't blow up on pathological cases
  # (many markers in one turn). 500 chars covers ~5-8 reasonable markers.
  if [ -n "$MSG" ]; then
    MSG="$(printf %s "$MSG" | head -c 500)"
  fi

  if [ -z "$MSG" ]; then
    # Deterministic fallback — first 1–3 basenames or "sync N files".
    files="$(git diff --cached --name-only)"
    n="$(echo "$files" | wc -l | tr -d ' ')"
    if [ "$n" -eq 1 ]; then
      MSG="update $(basename "$files")"
    elif [ "$n" -le 3 ]; then
      MSG="update $(echo "$files" | xargs -n1 basename | paste -sd', ' -)"
    else
      MSG="sync $n files"
    fi
  fi

  git commit -q -m "$MSG" 2>>"$LOG"
  git push -q 2>>"$LOG" || echo "$TS stop-hook push rejected — will retry next turn" >>"$LOG"
fi

exit 0
