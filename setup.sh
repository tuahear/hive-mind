#!/bin/bash
# hive-mind installer. Sets up git-backed auto-sync for an AI tool's memory
# directory across machines.
#
# Currently supports Claude Code (~/.claude). Designed so that other tools
# (Cursor, Windsurf, …) can be added later without rewriting callers.
#
# Usage:
#   MEMORY_REPO=git@github.com:you/your-memory.git bash setup.sh
#   bash setup.sh git@github.com:you/your-memory.git
#   curl -fsSL https://raw.githubusercontent.com/tuahear/hive-mind/main/setup.sh | \
#       MEMORY_REPO=git@github.com:you/your-memory.git bash
#
# What it does (high-level):
#   1. Preflight: git / jq / curl / SSH auth to GitHub present
#   2. Detect current state of the memory dir (fresh / already-synced / existing)
#   3. Back up ~/.claude before any destructive operation
#   4. Clone the hive-mind scripts into ~/.claude/sync/ (gitignored by the
#      memory repo)
#   5. Lay down `.gitignore` + `.gitattributes` templates at the memory dir
#      root BEFORE the first commit so merge drivers are active during merge
#   6. Either clone MEMORY_REPO (fresh case) or init-in-place + merge with
#      --allow-unrelated-histories (existing-local-memory case)
#   7. Install hook config into settings.json (merges; doesn't replace)
#   8. Run sync.sh once to verify
#
# Failure modes all surface errors and bail before wrecking anything. The
# pre-step backup is always recoverable.

set -euo pipefail

HIVE_MIND_REPO="git@github.com:tuahear/hive-mind.git"
HIVE_MIND_RAW="https://raw.githubusercontent.com/tuahear/hive-mind/main"

MEMORY_DIR="$HOME/.claude"
SYNC_DIR="$MEMORY_DIR/sync"
BACKUP_DIR="$HOME/.claude.backup-$(date +%Y%m%d-%H%M%S)"

# Allow caller to pass repo via $1 as an alternative to MEMORY_REPO env var.
MEMORY_REPO="${MEMORY_REPO:-${1:-}}"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "--> $*"; }
confirm() {
    local prompt="${1:-continue?}"
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || { echo "aborted."; exit 1; }
}

# ---------- preflight ----------
log "preflight: checking required tools"
install_hint() {
    case "$1" in
        jq)
            echo "  install: brew install jq  |  winget install jqlang.jq  |  apt install jq" ;;
        git)
            echo "  install: https://git-scm.com/downloads (on Windows pick 'Git for Windows', includes Git Bash)" ;;
        curl)
            echo "  install: usually preinstalled; apt install curl / brew install curl / winget install curl" ;;
    esac
}
for tool in git curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: missing required tool: $tool" >&2
        install_hint "$tool" >&2
        exit 1
    fi
done

log "preflight: checking SSH auth to github.com"
set +o pipefail
ssh_out="$(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    git@github.com 2>&1 || true)"
set -o pipefail
grep -q "successfully authenticated" <<<"$ssh_out" \
    || die "github SSH auth failed. Add an SSH key: https://github.com/settings/keys"

# ---------- memory repo URL ----------
if [ -z "$MEMORY_REPO" ]; then
    # Fall back to whatever the existing memory repo is pointing at, if any.
    if [ -d "$MEMORY_DIR/.git" ]; then
        MEMORY_REPO="$(git -C "$MEMORY_DIR" remote get-url origin 2>/dev/null || true)"
    fi
fi
if [ -z "$MEMORY_REPO" ]; then
    echo
    echo "Need the SSH URL of your PRIVATE memory repo. Create an empty"
    echo "private repo on GitHub first (no README, no .gitignore, no license),"
    echo "then paste its SSH URL (e.g. git@github.com:you/claude-memory.git)."
    read -r -p "MEMORY_REPO: " MEMORY_REPO
fi
[ -n "$MEMORY_REPO" ] || die "MEMORY_REPO is required"
log "memory repo: $MEMORY_REPO"

# ---------- detect state ----------
if [ ! -d "$MEMORY_DIR" ]; then
    STATE=fresh
elif [ -d "$MEMORY_DIR/.git" ]; then
    if git -C "$MEMORY_DIR" remote get-url origin >/dev/null 2>&1; then
        STATE=already_synced
    else
        STATE=existing
    fi
elif [ -z "$(ls -A "$MEMORY_DIR" 2>/dev/null)" ]; then
    STATE=fresh
else
    STATE=existing
fi
log "detected state: $STATE"

case "$STATE" in
    already_synced)
        log "~/.claude is already a git repo with remote $(git -C "$MEMORY_DIR" remote get-url origin)"
        # Ensure sync/ exists even if the memory repo was set up pre-split.
        if [ ! -d "$SYNC_DIR/.git" ]; then
            log "installing sync/ scripts (not present yet)"
            rm -rf "$SYNC_DIR"
            git clone --quiet "$HIVE_MIND_REPO" "$SYNC_DIR"
            log "done — sync scripts now at $SYNC_DIR"
        else
            log "sync/ already present; pulling latest"
            git -C "$SYNC_DIR" pull --rebase --autostash --quiet
        fi
        exit 0
        ;;
esac

# ---------- back up ----------
if [ -d "$MEMORY_DIR" ]; then
    log "backing up $MEMORY_DIR to $BACKUP_DIR"
    cp -a "$MEMORY_DIR" "$BACKUP_DIR"
    log "backup done (restore with:  rm -rf $MEMORY_DIR && mv $BACKUP_DIR $MEMORY_DIR )"
fi

mkdir -p "$MEMORY_DIR"

# ---------- install sync/ (scripts) ----------
log "[1/5] cloning hive-mind scripts into $SYNC_DIR"
rm -rf "$SYNC_DIR"
git clone --quiet "$HIVE_MIND_REPO" "$SYNC_DIR"

# ---------- seed ignore + attrs ----------
log "[2/5] seeding memory-repo .gitignore + .gitattributes from templates"
cp "$SYNC_DIR/templates/gitignore"    "$MEMORY_DIR/.gitignore"
cp "$SYNC_DIR/templates/gitattributes" "$MEMORY_DIR/.gitattributes"

# ---------- flow A: fresh clone ----------
if [ "$STATE" = fresh ]; then
    log "[3/5] fresh flow: cloning $MEMORY_REPO into memory dir"
    # Clone into a tmp dir then move .git in, preserving the gitignore/attrs
    # and sync/ we just set up.
    TMP="$(mktemp -d)"
    if git clone --quiet "$MEMORY_REPO" "$TMP/memory" 2>/dev/null; then
        # Merge cloned files on top of our seeded dir.
        mv "$TMP/memory/.git" "$MEMORY_DIR/.git"
        # Copy any tracked files the remote already had.
        shopt -s dotglob
        for f in "$TMP/memory"/*; do
            [ -e "$f" ] && cp -a "$f" "$MEMORY_DIR/" 2>/dev/null || true
        done
        shopt -u dotglob
        rm -rf "$TMP"
        log "cloned existing remote contents"
    else
        # Empty remote: init locally + set remote; first push will seed it.
        rm -rf "$TMP"
        log "remote is empty; initializing locally"
        git -C "$MEMORY_DIR" init -b main -q
        git -C "$MEMORY_DIR" remote add origin "$MEMORY_REPO"
    fi
fi

# ---------- flow B: preserve local + merge ----------
if [ "$STATE" = existing ]; then
    log "[3/5] existing flow: init-in-place + merge with remote"
    cd "$MEMORY_DIR"
    git init -b main -q
    git remote add origin "$MEMORY_REPO"
    git add -A

    if git diff --cached --name-only | grep -qE '^(shell-snapshots|sessions|session-env|file-history|telemetry|debug|ide|backups|plugins)/'; then
        echo
        echo "WARNING: machine-local noise got staged despite .gitignore:"
        git diff --cached --name-only | grep -E '^(shell-snapshots|sessions|session-env|file-history|telemetry|debug|ide|backups|plugins)/' >&2
        die "aborting to avoid polluting the repo. Inspect .gitignore and retry."
    fi

    git commit -q -m "local memory snapshot before hive-mind sync"

    if git fetch origin main 2>/dev/null; then
        if ! git merge origin/main --allow-unrelated-histories --no-edit; then
            echo
            echo "MERGE CONFLICTS:"
            git diff --name-only --diff-filter=U >&2
            echo
            echo "Resolve manually in $MEMORY_DIR, then:"
            echo "  git add <files> && git commit --no-edit && git push -u origin main"
            echo "Backup at: $BACKUP_DIR"
            exit 2
        fi
    else
        log "remote is empty; nothing to merge"
    fi
fi

# ---------- install hook config ----------
log "[4/5] merging hook config into settings.json"
if [ -f "$MEMORY_DIR/settings.json" ]; then
    # Deep-merge the example hooks into existing settings.json, preserving
    # all other keys (permissions, effortLevel, etc).
    tmp="$(mktemp)"
    jq -s '.[0] * .[1]' "$MEMORY_DIR/settings.json" "$SYNC_DIR/templates/settings.json" >"$tmp"
    mv "$tmp" "$MEMORY_DIR/settings.json"
else
    cp "$SYNC_DIR/templates/settings.json" "$MEMORY_DIR/settings.json"
fi

# ---------- push + verify ----------
log "[5/5] running a sync cycle to verify and push"
if [ -x "$SYNC_DIR/scripts/sync.sh" ]; then
    "$SYNC_DIR/scripts/sync.sh"
    if [ -s "$MEMORY_DIR/.sync-error.log" ]; then
        echo
        echo "WARNING: sync produced errors:"
        tail -5 "$MEMORY_DIR/.sync-error.log" >&2
    fi
fi

# ---------- done ----------
echo
log "done."
echo
echo "IMPORTANT: open /hooks in Claude Code once (or start a fresh session)"
echo "so the settings watcher picks up the SessionStart + Stop hooks."
echo
[ -d "$BACKUP_DIR" ] && echo "Backup preserved at: $BACKUP_DIR (delete once you've confirmed a clean session)"
