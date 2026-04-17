#!/bin/bash
# hive-mind installer (v0.3.0+ hub topology).
#
# Installs or upgrades the single per-machine hub at $HIVE_MIND_HUB_DIR
# (default ~/.hive-mind), then attaches the adapter named by ADAPTER
# (default claude-code) to it. Rerunning with a different ADAPTER
# attaches a second tool to the same hub — one git repo, one remote,
# cross-provider + cross-machine memory sharing.
#
# Usage:
#   MEMORY_REPO=git@github.com:you/your-memory.git bash setup.sh
#   bash setup.sh git@github.com:you/your-memory.git
#   ADAPTER=codex bash setup.sh          # attach a second adapter
#
# What happens (high-level):
#   1. Preflight: git / jq / curl / SSH auth to GitHub present
#   2. Clone (or pull) the hive-mind source into
#      $HIVE_MIND_HUB_DIR/hive-mind/
#   3. Seed the hub:
#      - .gitignore / .gitattributes from core/hub/ templates
#      - bin/sync symlink -> hive-mind/core/hub/sync.sh
#      - .hive-mind-format file
#   4. Initialize or connect the hub's git repo to MEMORY_REPO
#   5. Load the adapter, register merge drivers on the hub
#   6. Attach adapter:
#      - Back up tool dir on first attach
#      - Harvest existing tool content -> hub (avoid losing user memory)
#      - Push, pull-rebase, fan out -> tool dir
#      - Install the tool's hooks, pointing at $HIVE_MIND_HUB_DIR/bin/sync
#      - Record adapter name in .install-state/attached-adapters
#   7. Run the hub's bin/sync once to verify

set -euo pipefail

# Where setup.sh clones the hive-mind source from. Env-overridable
# because hard-coding an SSH URL forces GitHub SSH auth even for users
# who only have HTTPS (corporate SSH restrictions, non-GitHub memory
# remotes, HTTPS token auth) — set `HIVE_MIND_REPO=https://github.com/
# tuahear/hive-mind.git` to skip the SSH preflight below.
: "${HIVE_MIND_REPO:=git@github.com:tuahear/hive-mind.git}"
: "${HIVE_MIND_HUB_DIR:=$HOME/.hive-mind}"
HIVE_MIND_SRC="$HIVE_MIND_HUB_DIR/hive-mind"

ADAPTER="${ADAPTER:-claude-code}"
MEMORY_REPO="${MEMORY_REPO:-${1:-}}"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "--> $*"; }
sanitize_remote_url() {
    printf '%s' "$1" | sed 's|://[^@/]*@|://***@|'
}
confirm() {
    local prompt="${1:-continue?}"
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || { echo "aborted."; exit 1; }
}

# ---------- preflight ----------
log "preflight: checking required tools"
install_hint() {
    case "$1" in
        jq) echo "  install: brew install jq  |  winget install jqlang.jq  |  apt install jq" ;;
        git) echo "  install: https://git-scm.com/downloads" ;;
        curl) echo "  install: apt install curl / brew install curl / winget install curl" ;;
    esac
}
# Auto-install jq is opt-in via HIVE_MIND_AUTO_INSTALL_JQ=1. Running
# `sudo apt-get install` (and the Linux / MSYS equivalents) implicitly
# during install is surprising in CI and locked-down environments, and
# can hang on interactive password prompts. Default behavior: fail with
# the install_hint output so the user picks their own package manager.
# Brew / winget / scoop don't need sudo, but for one predictable code
# path we gate every branch behind the same env flag.
auto_install_jq() {
    if [ "${HIVE_MIND_AUTO_INSTALL_JQ:-0}" != "1" ]; then
        return 1
    fi
    log "jq not found; HIVE_MIND_AUTO_INSTALL_JQ=1 set — attempting auto-install"
    case "$(uname -s)" in
        Darwin)
            command -v brew >/dev/null 2>&1 && brew install jq
            ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y jq
            elif command -v dnf      >/dev/null 2>&1; then sudo dnf install -y jq
            elif command -v yum      >/dev/null 2>&1; then sudo yum install -y jq
            elif command -v pacman   >/dev/null 2>&1; then sudo pacman -S --noconfirm jq
            elif command -v apk      >/dev/null 2>&1; then sudo apk add jq
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            if command -v winget >/dev/null 2>&1; then winget install --silent jqlang.jq
            elif command -v choco >/dev/null 2>&1; then choco install -y jq
            elif command -v scoop >/dev/null 2>&1; then scoop install jq
            fi
            ;;
    esac
    command -v jq >/dev/null 2>&1
}
for tool in git curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        if [ "$tool" = jq ] && auto_install_jq; then log "jq installed"; continue; fi
        echo "error: missing required tool: $tool" >&2
        install_hint "$tool" >&2
        [ "$tool" = jq ] && echo "  opt in to auto-install: HIVE_MIND_AUTO_INSTALL_JQ=1 bash setup.sh" >&2
        exit 1
    fi
done

# SSH preflight — only run when we actually need to clone via SSH.
# HIVE_MIND_REPO is the repo we clone for the installer itself; if the
# user has overridden it to an https:// URL they don't need a GitHub
# SSH key. MEMORY_REPO is the user's memory remote — if it's https://
# too, no SSH anywhere is required. Checking the actual host matters
# for non-GitHub remotes: a user with `git@gitlab.com:...` shouldn't
# be gated on GitHub SSH access.
_is_ssh_url() {
    case "$1" in
        git@*|ssh://*) return 0 ;;
        *) return 1 ;;
    esac
}
_extract_ssh_host() {
    # Accept `git@host:path` and `ssh://[user@]host[:port]/path` forms.
    local url="$1" host=""
    case "$url" in
        git@*)   host="${url#git@}"; host="${host%%:*}" ;;
        ssh://*) host="${url#ssh://}"; host="${host#*@}"; host="${host%%/*}"; host="${host%%:*}" ;;
    esac
    printf '%s' "$host"
}
_ssh_preflight() {
    local host="$1"
    [ -n "$host" ] || return 0
    log "preflight: checking SSH auth to $host"
    set +o pipefail
    local ssh_out
    ssh_out="$(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "git@$host" 2>&1 || true)"
    set -o pipefail
    # GitHub says "successfully authenticated". Other hosts vary
    # (GitLab: "Welcome to GitLab"; self-hosted: anything). Treat any
    # exit-code path that reached a banner as ok — only abort when we
    # clearly couldn't authenticate (permission denied) so this works
    # on non-GitHub remotes without adding per-host rules.
    case "$ssh_out" in
        *"Permission denied"*|*"Could not resolve hostname"*|*"Host key verification failed"*)
            die "SSH auth to $host failed. Add an SSH key for $host or set HIVE_MIND_REPO / MEMORY_REPO to an https:// URL. First line of ssh output: $(printf '%s' "$ssh_out" | head -1)"
            ;;
    esac
}
# Dedup hosts so a single GitHub-for-both setup doesn't probe twice.
_seen_hosts=""
for _ssh_repo in "$HIVE_MIND_REPO" "${MEMORY_REPO:-}"; do
    _is_ssh_url "$_ssh_repo" || continue
    _host="$(_extract_ssh_host "$_ssh_repo")"
    [ -z "$_host" ] && continue
    case "$_seen_hosts" in
        *",$_host,"*) continue ;;
    esac
    _seen_hosts="$_seen_hosts,$_host,"
    _ssh_preflight "$_host"
done
unset _seen_hosts _ssh_repo _host

# ---------- memory repo URL ----------
if [ -z "$MEMORY_REPO" ] && [ -d "$HIVE_MIND_HUB_DIR/.git" ]; then
    MEMORY_REPO="$(git -C "$HIVE_MIND_HUB_DIR" remote get-url origin 2>/dev/null || true)"
fi
if [ -z "$MEMORY_REPO" ]; then
    echo
    echo "Need the SSH URL of your PRIVATE memory repo. Create an empty"
    echo "private repo on GitHub first (no README, no .gitignore, no license),"
    echo "then paste its SSH URL (e.g. git@github.com:you/claude-memory.git)."
    read -r -p "MEMORY_REPO: " MEMORY_REPO
fi
[ -n "$MEMORY_REPO" ] || die "MEMORY_REPO is required"
log "memory repo: $(sanitize_remote_url "$MEMORY_REPO")"

# ---------- install/refresh hive-mind source ----------
log "[1/6] installing hive-mind source at $HIVE_MIND_SRC"
mkdir -p "$HIVE_MIND_HUB_DIR"
# Capture the previously-installed hive-mind version BEFORE `git pull`
# rewrites $HIVE_MIND_SRC/VERSION to the latest. adapter_migrate
# expects the pre-upgrade version string so adapter authors can gate
# migrations on specific transitions (v0.2.x → v0.3.x hook-path
# rewrite, for example). A missing VERSION file means a pre-0.2
# install without version tracking — use the documented "0.1.0"
# sentinel that adapter-loader.sh's migrate contract recognizes.
PREV_HIVE_MIND_VERSION="0.1.0"
if [ -f "$HIVE_MIND_SRC/VERSION" ]; then
    PREV_HIVE_MIND_VERSION="$(tr -d '[:space:]' < "$HIVE_MIND_SRC/VERSION" 2>/dev/null || echo "0.1.0")"
fi
if [ -d "$HIVE_MIND_SRC/.git" ]; then
    log "  source already present; pulling latest (previous version: $PREV_HIVE_MIND_VERSION)"
    git -C "$HIVE_MIND_SRC" pull --rebase --autostash --quiet || true
else
    rm -rf "$HIVE_MIND_SRC"
    git clone --quiet "$HIVE_MIND_REPO" "$HIVE_MIND_SRC"
fi

# ---------- load the adapter ----------
ADAPTER_ROOT="$HIVE_MIND_SRC/adapters/$ADAPTER"
[ -d "$ADAPTER_ROOT" ] || die "unknown adapter '$ADAPTER' (not found at $ADAPTER_ROOT)"
export ADAPTER_ROOT

# shellcheck source=/dev/null
source "$HIVE_MIND_SRC/core/adapter-loader.sh"
if ! load_adapter "$ADAPTER"; then
    die "failed to load adapter '$ADAPTER'"
fi

# ---------- merge driver registration (shared by hub init + upgrade) ----------
register_merge_drivers() {
    local target_git="$1"
    [ -d "$target_git/.git" ] || git -C "$target_git" rev-parse --git-dir >/dev/null 2>&1 || return 0

    local drivers=""
    if [ -n "${ADAPTER_SETTINGS_MERGE_BINDINGS:-}" ]; then
        drivers="$(printf '%s\n' "$ADAPTER_SETTINGS_MERGE_BINDINGS" | awk 'NF>=2 {print $2}' | sort -u)"
    fi

    _driver_env_prefix() {
        local want_drv="$1"
        [ -n "${ADAPTER_MERGE_DRIVER_ENV:-}" ] || { printf ''; return 0; }
        local line d rest
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            d="${line%%:*}"
            rest="${line#*:}"
            if [ "$d" = "$want_drv" ]; then
                printf '%s ' "$rest"
                return 0
            fi
        done <<< "$ADAPTER_MERGE_DRIVER_ENV"
        return 0
    }

    while IFS= read -r drv; do
        [ -z "$drv" ] && continue
        local driver_script="$HIVE_MIND_SRC/core/${drv}.sh"
        [ -f "$driver_script" ] || continue
        local env_prefix
        env_prefix="$(_driver_env_prefix "$drv")"
        git -C "$target_git" config "merge.${drv}.driver" "${env_prefix}'${driver_script}' '%A' '%O' '%B'"
        git -C "$target_git" config "merge.${drv}.name" "hive-mind ${drv} driver"
    done <<< "$drivers"
}

# ---------- seed hub tree ----------
log "[2/6] seeding hub at $HIVE_MIND_HUB_DIR"
mkdir -p "$HIVE_MIND_HUB_DIR/bin" \
         "$HIVE_MIND_HUB_DIR/.install-state" \
         "$HIVE_MIND_HUB_DIR/.hive-mind-state"

# bin/sync -> hive-mind/core/hub/sync.sh (relative so the symlink
# survives moves of $HIVE_MIND_HUB_DIR). macOS `ln -sf` replaces
# atomically; works cross-platform.
ln -sfn "../hive-mind/core/hub/sync.sh" "$HIVE_MIND_HUB_DIR/bin/sync"
chmod +x "$HIVE_MIND_SRC/core/hub/sync.sh" 2>/dev/null || true

# Seed BEFORE git init so merge drivers are active from commit 1.
cp "$HIVE_MIND_SRC/core/hub/gitignore"     "$HIVE_MIND_HUB_DIR/.gitignore"
cp "$HIVE_MIND_SRC/core/hub/gitattributes" "$HIVE_MIND_HUB_DIR/.gitattributes"

if [ ! -f "$HIVE_MIND_HUB_DIR/.hive-mind-format" ]; then
    printf 'format-version=1\n' > "$HIVE_MIND_HUB_DIR/.hive-mind-format"
fi

# ---------- init hub git repo ----------
if [ ! -d "$HIVE_MIND_HUB_DIR/.git" ]; then
    log "[3/6] cloning memory repo into hub"
    TMP="$(mktemp -d)"
    if git clone --quiet "$MEMORY_REPO" "$TMP/memory" 2>/dev/null; then
        mv "$TMP/memory/.git" "$HIVE_MIND_HUB_DIR/.git"
        shopt -s dotglob
        for f in "$TMP/memory"/*; do
            [ -e "$f" ] || continue
            case "$(basename "$f")" in
                .gitignore|.gitattributes) continue ;;
            esac
            cp -a "$f" "$HIVE_MIND_HUB_DIR/" 2>/dev/null || true
        done
        shopt -u dotglob
        rm -rf "$TMP"
        log "  pulled existing hub contents from remote"
    else
        rm -rf "$TMP"
        log "  remote is empty; initializing hub locally"
        git -C "$HIVE_MIND_HUB_DIR" init -b main -q
        git -C "$HIVE_MIND_HUB_DIR" remote add origin "$MEMORY_REPO"
    fi
else
    log "[3/6] hub git repo already present; pulling latest"
    if git -C "$HIVE_MIND_HUB_DIR" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        git -C "$HIVE_MIND_HUB_DIR" pull --rebase --autostash --quiet || true
    fi
fi

register_merge_drivers "$HIVE_MIND_HUB_DIR"

# ---------- attach adapter ----------
log "[4/6] attaching adapter '$ADAPTER' (ADAPTER_DIR=$ADAPTER_DIR)"

# First-ever attach on this hub? Back up the tool dir if it has content.
ATTACHED_FILE="$HIVE_MIND_HUB_DIR/.install-state/attached-adapters"
touch "$ATTACHED_FILE"
if ! grep -Fxq "$ADAPTER" "$ATTACHED_FILE" \
   && [ -d "$ADAPTER_DIR" ] \
   && [ -n "$(ls -A "$ADAPTER_DIR" 2>/dev/null)" ]; then
    BACKUP_DIR="${ADAPTER_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
    log "  backing up $ADAPTER_DIR to $BACKUP_DIR"
    cp -a "$ADAPTER_DIR" "$BACKUP_DIR"
fi
mkdir -p "$ADAPTER_DIR"

# ---------- harvest-then-seed ----------
# Harvest captures whatever the user has in the tool dir (existing
# CLAUDE.md, skills, permissions) into the hub — otherwise the fan-out
# below would overwrite it with possibly-empty hub content on a fresh
# install. The first push + pull-rebase sequence then merges with the
# remote (which may contain content from another machine).
# shellcheck source=/dev/null
source "$HIVE_MIND_SRC/core/hub/harvest-fanout.sh"

# Bootstrap project-id sidecars before harvest — same pre-pass the hub
# sync engine runs (core/hub/sync.sh). Without this, a fresh install
# with existing per-project memory has no sidecars → harvest skips
# every project → zero per-project content reaches the hub.
if [ "${ADAPTER_MEMORY_MODEL:-}" = "flat" ] && [ -x "$HIVE_MIND_SRC/core/mirror-projects.sh" ]; then
    log "  bootstrapping per-project sidecars"
    ADAPTER_DIR="$ADAPTER_DIR" "$HIVE_MIND_SRC/core/mirror-projects.sh" || true
fi

log "  harvesting existing tool content -> hub"
hub_harvest "$ADAPTER_DIR" "$HIVE_MIND_HUB_DIR"

# Commit whatever changed in the hub after harvest + seed.
(
    cd "$HIVE_MIND_HUB_DIR"
    git add -A >/dev/null 2>&1 || true
    if ! git diff --cached --quiet; then
        git commit -q -m "hub: attach $ADAPTER on $(hostname)"
    fi
    # First push needs -u; subsequent pushes don't.
    if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        git push -q 2>/dev/null || true
    else
        branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
        git push -q -u origin "$branch" 2>/dev/null || true
    fi
    # Pull back any remote state (e.g. from another machine).
    if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        git pull --rebase --autostash --quiet || true
    fi
)

log "  fanning hub content -> tool dir"
hub_fan_out "$HIVE_MIND_HUB_DIR" "$ADAPTER_DIR"

# Run adapter migration against any pre-0.3.0 hook paths in
# ADAPTER_DIR/settings.json so an upgrade install rewrites them to the
# hub entry point before adapter_install_hooks checks for presence.
declare -f adapter_migrate >/dev/null 2>&1 && adapter_migrate "$PREV_HIVE_MIND_VERSION"

# Install the tool's hooks (they now point at the hub's bin/sync).
adapter_install_hooks

# Record this adapter in the attached-adapters list.
if ! grep -Fxq "$ADAPTER" "$ATTACHED_FILE"; then
    printf '%s\n' "$ADAPTER" >> "$ATTACHED_FILE"
fi

# ---------- install bundled skills ----------
# Adapter ships a bundled hive-mind skill. Install into the hub's
# skills/ (canonical), then fan-out relays it to the tool dir. Older
# installs may have the legacy `skills/memory-commit/` name under the
# tool dir; clean it up so the renamed skill doesn't collide.
log "[5/6] installing bundled skills"
manage_bundled_skills() {
    local src="$HIVE_MIND_SRC/adapters/$ADAPTER/skills"
    [ -d "$src" ] || return 0
    local hub_skills="$HIVE_MIND_HUB_DIR/skills"
    mkdir -p "$hub_skills"
    if [ -d "$ADAPTER_DIR/skills/memory-commit" ]; then
        rm -rf "$ADAPTER_DIR/skills/memory-commit"
    fi
    local count=0
    for skill_dir in "$src"/*/; do
        [ -d "$skill_dir" ] || continue
        local name
        name="$(basename "$skill_dir")"
        rm -rf "$hub_skills/$name"
        cp -r "$skill_dir" "$hub_skills/$name"
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] && log "  installed/refreshed $count skill(s) under $hub_skills"
}
manage_bundled_skills

# ---------- verify ----------
log "[6/6] running hub sync cycle to verify"
if [ -x "$HIVE_MIND_HUB_DIR/bin/sync" ]; then
    HIVE_MIND_HUB_DIR="$HIVE_MIND_HUB_DIR" \
    HIVE_MIND_FORCE_PUSH=1 \
        "$HIVE_MIND_HUB_DIR/bin/sync" || true
    if [ -s "$HIVE_MIND_HUB_DIR/.sync-error.log" ]; then
        echo
        echo "WARNING: sync produced errors:"
        tail -5 "$HIVE_MIND_HUB_DIR/.sync-error.log" >&2
    fi
fi

# ---------- done ----------
echo
log "done."
echo
adapter_activation_instructions
echo
[ -n "${BACKUP_DIR:-}" ] && echo "Backup preserved at: $BACKUP_DIR (delete once you've confirmed a clean session)"
