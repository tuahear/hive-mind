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
  # Deterministic commit summary from the staged paths. Readable at a glance
  # in `git log`, no permission system involvement, no agent participation.
  files="$(git diff --cached --name-only)"
  n="$(echo "$files" | wc -l | tr -d ' ')"
  if [ "$n" -eq 1 ]; then
    MSG="update $(basename "$files")"
  elif [ "$n" -le 3 ]; then
    MSG="update $(echo "$files" | xargs -n1 basename | paste -sd', ' -)"
  else
    MSG="sync $n files"
  fi

  git commit -q -m "$MSG" 2>>"$LOG"
  git push -q 2>>"$LOG" || echo "$TS stop-hook push rejected — will retry next turn" >>"$LOG"
fi

exit 0
