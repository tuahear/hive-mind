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
#   4. Clone the hive-mind scripts into ~/.claude/hive-mind/ (gitignored by the
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

# Adapter selection: defaults to claude-code. Future adapters (codex, etc.)
# set ADAPTER=<name>. When running via curl | bash pre-clone, we can't
# source adapter.sh yet, so we resolve paths from adapter defaults below
# (Claude Code is the only shipped adapter at v1). Post-clone, the
# installer re-sources via core/adapter-loader.sh to validate the
# capability surface against HIVE_MIND_CORE_API_VERSION.
ADAPTER="${ADAPTER:-claude-code}"

case "$ADAPTER" in
    claude-code)
        MEMORY_DIR="$HOME/.claude"
        ;;
    *)
        echo "error: unknown adapter '$ADAPTER'" >&2
        echo "  supported: claude-code" >&2
        exit 1
        ;;
esac
HIVE_MIND_DIR="$MEMORY_DIR/hive-mind"
BACKUP_DIR="${MEMORY_DIR}.backup-$(date +%Y%m%d-%H%M%S)"

# Allow caller to pass repo via $1 as an alternative to MEMORY_REPO env var.
MEMORY_REPO="${MEMORY_REPO:-${1:-}}"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "--> $*"; }
# Mask any embedded credentials (https://token:x-oauth@host/...) from a
# git remote URL before printing it -- token leaks to terminal/CI logs
# are otherwise silent and permanent. Used for both MEMORY_REPO (user-
# supplied) and the `origin` URL read back from git config.
# Anchored to the userinfo segment (between `://` and the first `/`)
# so an `@` later in the URL path — e.g. `github.com/owner/repo@tag` —
# is not mistakenly redacted into `***@tag`. Mirror change to
# core/log.sh's hm_sanitize_url; docs/tests cover both.
sanitize_remote_url() {
    printf '%s' "$1" | sed 's|://[^@/]*@|://***@|'
}
confirm() {
    local prompt="${1:-continue?}"
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || { echo "aborted."; exit 1; }
}

# Install / refresh hive-mind skills under ~/.claude/skills/.
# Bundled skills use uniquely-namespaced folder names (e.g. `hive-mind`, not
# `memory-commit`) so collision with a user's own skills is unlikely. Users
# shouldn't edit hive-mind-installed skills in place; edit the upstream
# templates/skills/ copy and push to the hive-mind repo instead.
#
# Migration: if an older install left `skills/memory-commit/` behind, remove
# it (renamed to `skills/hive-mind/` on 2026-04-15). Safe because
# `memory-commit` was only ever shipped by hive-mind.
manage_claude_skills() {
    # Prefer the adapter's bundled skills dir; fall back to the legacy
    # templates/skills for pre-refactor installs.
    local src="$HIVE_MIND_DIR/adapters/$ADAPTER/skills"
    [ -d "$src" ] || src="$HIVE_MIND_DIR/templates/skills"
    # Install target: route through the adapter contract
    # (ADAPTER_SKILL_ROOT) when the adapter was loaded. Falls back to
    # $MEMORY_DIR/skills for pre-adapter-contract invocations and for
    # adapters that declare no skill root (ADAPTER_SKILL_ROOT="").
    local dst="${ADAPTER_SKILL_ROOT:-$MEMORY_DIR/skills}"
    [ -n "$dst" ] || return 0
    [ -d "$src" ] || return 0
    mkdir -p "$dst"
    if [ -d "$dst/memory-commit" ]; then
        log "migrating old memory-commit skill → hive-mind (removing $dst/memory-commit)"
        rm -rf "$dst/memory-commit"
    fi
    local count=0
    for skill_dir in "$src"/*/; do
        [ -d "$skill_dir" ] || continue
        local name
        name="$(basename "$skill_dir")"
        rm -rf "$dst/$name"
        cp -r "$skill_dir" "$dst/$name"
        count=$((count + 1))
    done
    [ $count -gt 0 ] && log "installed/refreshed $count skill(s) under $dst"
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
# Try to auto-install jq using whatever package manager this OS has. Returns
# 0 if the tool is on PATH after the attempt, 1 otherwise. git/curl are not
# auto-installed (they're typically prerequisites of the install path itself).
auto_install_jq() {
    log "jq not found; attempting auto-install"
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
        if [ "$tool" = jq ] && auto_install_jq; then
            log "jq installed"
            continue
        fi
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
log "memory repo: $(sanitize_remote_url "$MEMORY_REPO")"

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

# Define register_merge_drivers up-front so the already_synced branch (below)
# can call it. Full definition is in the fresh/existing flow section.
register_merge_drivers() {
    local target_git="$1"
    [ -d "$target_git/.git" ] || git -C "$target_git" rev-parse --git-dir >/dev/null 2>&1 || return 0

    local drivers=""
    if [ -n "${ADAPTER_SETTINGS_MERGE_BINDINGS:-}" ]; then
        drivers="$(printf '%s\n' "$ADAPTER_SETTINGS_MERGE_BINDINGS" | awk 'NF>=2 {print $2}' | sort -u)"
    fi

    # Lookup helper: for a given driver name, return the adapter-declared
    # env-prefix string (e.g. "TOMLMERGE_UNION_KEYS=permissions.allow,deny ").
    # Adapter declares ADAPTER_MERGE_DRIVER_ENV as newline-separated lines
    # of the form "<driver>:<KEY=val KEY2=val2>". Empty when not declared.
    # Reads via a here-string so the while loop runs in the current shell;
    # a pipeline (printf ... | while ...) would put the loop in a subshell
    # where `return` only exits the subshell, not this function, making
    # the control flow invisible to the caller and fragile under set -e.
    _driver_env_prefix() {
        local want_drv="$1"
        [ -n "${ADAPTER_MERGE_DRIVER_ENV:-}" ] || { printf ''; return 0; }
        local line d rest
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            d="${line%%:*}"
            rest="${line#*:}"
            if [ "$d" = "$want_drv" ]; then
                # Trim whitespace and emit with trailing space so the
                # caller can concatenate directly with the script path.
                printf '%s ' "$rest"
                return 0
            fi
        done <<< "$ADAPTER_MERGE_DRIVER_ENV"
        return 0
    }

    while IFS= read -r drv; do
        [ -z "$drv" ] && continue
        local driver_script="$HIVE_MIND_DIR/core/${drv}.sh"
        [ -f "$driver_script" ] || continue
        local env_prefix
        env_prefix="$(_driver_env_prefix "$drv")"
        # Quote the driver script path AND the %A/%O/%B placeholders.
        # Git substitutes the placeholders with absolute paths to temp
        # files before invoking the driver via `sh -c`; a repo path
        # containing spaces (Windows Git Bash "C:/Users/Jane Doe",
        # macOS home dirs with spaces) would otherwise word-split and
        # hand the driver the wrong arguments. Single-quote each one
        # so the shell sees them as single tokens.
        git -C "$target_git" config "merge.${drv}.driver" "${env_prefix}'${driver_script}' '%A' '%O' '%B'"
        git -C "$target_git" config "merge.${drv}.name" "hive-mind ${drv} driver"
    done <<< "$drivers"

    if [ -z "$drivers" ] && [ -f "$HIVE_MIND_DIR/core/jsonmerge.sh" ]; then
        # Quoted script path AND placeholders — see main loop above.
        git -C "$target_git" config merge.jsonmerge.driver "'$HIVE_MIND_DIR/core/jsonmerge.sh' '%A' '%O' '%B'"
        git -C "$target_git" config merge.jsonmerge.name "Deep-merge JSON with array union (hive-mind)"
    fi
}
register_jsonmerge_driver() { register_merge_drivers "$@"; }

case "$STATE" in
    already_synced)
        _origin_raw="$(git -C "$MEMORY_DIR" remote get-url origin 2>/dev/null)"
        log "$MEMORY_DIR is already a git repo with remote $(sanitize_remote_url "$_origin_raw")"

        # Read the previously-installed hive-mind version BEFORE pulling the
        # latest (so adapter_migrate can make version-conditional decisions).
        # Missing VERSION file = pre-refactor install; treat as 0.1.0.
        prev_version="0.1.0"
        if [ -f "$HIVE_MIND_DIR/VERSION" ]; then
            prev_version="$(tr -d '[:space:]' < "$HIVE_MIND_DIR/VERSION")"
        fi

        # Ensure sync/ exists even if the memory repo was set up pre-split.
        if [ ! -d "$HIVE_MIND_DIR/.git" ]; then
            log "installing sync/ scripts (not present yet)"
            rm -rf "$HIVE_MIND_DIR"
            git clone --quiet "$HIVE_MIND_REPO" "$HIVE_MIND_DIR"
            log "done — sync scripts now at $HIVE_MIND_DIR"
        else
            log "sync/ already present; pulling latest"
            git -C "$HIVE_MIND_DIR" pull --rebase --autostash --quiet
        fi
        # Source the adapter to get template paths + merge-binding list for refresh.
        # Adapter-dependent steps (template refresh, migrate, install_hooks)
        # run ONLY after a successful load_adapter — a partial / failed
        # source can leave ADAPTER_* vars and adapter_* functions in a
        # half-populated state, which would make the upgrade path worse
        # than doing nothing.
        _adapter_loaded=0
        if [ -f "$HIVE_MIND_DIR/core/adapter-loader.sh" ]; then
            ADAPTER_ROOT="$HIVE_MIND_DIR/adapters/$ADAPTER"
            export ADAPTER_ROOT
            # shellcheck disable=SC1091
            source "$HIVE_MIND_DIR/core/adapter-loader.sh"
            if load_adapter "$ADAPTER"; then
                _adapter_loaded=1
            else
                log "warning: adapter '$ADAPTER' failed to load — falling back to legacy jsonmerge registration, skipping template refresh / migrate / install_hooks"
            fi
        fi

        if [ "$_adapter_loaded" -eq 1 ]; then
            # Register every declared merge driver (adapter-agnostic).
            register_merge_drivers "$MEMORY_DIR"
            # Refresh gitignore + gitattributes from the adapter templates.
            if [ -n "${ADAPTER_GITIGNORE_TEMPLATE:-}" ] && [ -f "$ADAPTER_GITIGNORE_TEMPLATE" ]; then
                cp "$ADAPTER_GITIGNORE_TEMPLATE" "$MEMORY_DIR/.gitignore"
            fi
            if [ -n "${ADAPTER_GITATTRIBUTES_TEMPLATE:-}" ] && [ -f "$ADAPTER_GITATTRIBUTES_TEMPLATE" ]; then
                cp "$ADAPTER_GITATTRIBUTES_TEMPLATE" "$MEMORY_DIR/.gitattributes"
            fi
            # Migrate existing install, passing the previous version so the
            # adapter can make version-conditional decisions.
            declare -f adapter_migrate >/dev/null 2>&1 && adapter_migrate "$prev_version"
            # Re-run adapter_install_hooks so upgrades are self-healing.
            declare -f adapter_install_hooks >/dev/null 2>&1 && adapter_install_hooks
        else
            # Legacy fallback: register the known jsonmerge driver directly
            # so pre-adapter-contract installs keep working on upgrade.
            # Quoted script path AND %A/%O/%B placeholders — same
            # space-safety rationale as register_merge_drivers above.
            git -C "$MEMORY_DIR" config merge.jsonmerge.driver "'$HIVE_MIND_DIR/core/jsonmerge.sh' '%A' '%O' '%B'" 2>/dev/null || true
            git -C "$MEMORY_DIR" config merge.jsonmerge.name "Deep-merge JSON with array union (hive-mind)" 2>/dev/null || true
        fi
        manage_claude_skills

        # Run a sync cycle before exiting so any upgrade edits (refreshed
        # .gitignore / .gitattributes, migrated settings, re-installed
        # hooks) propagate to the remote immediately instead of waiting
        # for the next hook-driven sync. Without this, multi-machine
        # users can go hours between upgrade and propagation if they
        # don't start a new session on the upgraded machine — which
        # defeats the core cross-machine value of hive-mind. Force-push
        # bypasses the rate limit that sync.sh applies to normal
        # hook-driven runs. Non-blocking: errors log to the adapter's
        # log, installer exits 0 regardless.
        if [ -x "$HIVE_MIND_DIR/core/sync.sh" ]; then
            ADAPTER_DIR="$ADAPTER_DIR" \
            ADAPTER_LOG_PATH="${ADAPTER_LOG_PATH:-}" \
            ADAPTER_MARKER_TARGETS="${ADAPTER_MARKER_TARGETS:-}" \
            ADAPTER_SECRET_FILES="${ADAPTER_SECRET_FILES:-}" \
            ADAPTER_EVENT_SESSION_START="${ADAPTER_EVENT_SESSION_START:-}" \
            ADAPTER_EVENT_TURN_END="${ADAPTER_EVENT_TURN_END:-}" \
            ADAPTER_EVENT_POST_EDIT="${ADAPTER_EVENT_POST_EDIT:-}" \
            HIVE_MIND_FORCE_PUSH=1 \
                "$HIVE_MIND_DIR/core/sync.sh" || true
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
log "[1/5] cloning hive-mind scripts into $HIVE_MIND_DIR"
rm -rf "$HIVE_MIND_DIR"
git clone --quiet "$HIVE_MIND_REPO" "$HIVE_MIND_DIR"

# register_merge_drivers + register_jsonmerge_driver defined above (before
# the state case), so both already_synced and fresh/existing paths can use
# them. Adapter must be loaded first so ADAPTER_SETTINGS_MERGE_BINDINGS is set.

# ---------- load the adapter (validates API version, gives us template paths) ----------
ADAPTER_ROOT="$HIVE_MIND_DIR/adapters/$ADAPTER"
export ADAPTER_ROOT
# shellcheck disable=SC1091
source "$HIVE_MIND_DIR/core/adapter-loader.sh"
if ! load_adapter "$ADAPTER"; then
    die "failed to load adapter '$ADAPTER'"
fi

# ---------- seed ignore + attrs ----------
log "[2/5] seeding memory-repo .gitignore + .gitattributes from templates"
cp "$ADAPTER_GITIGNORE_TEMPLATE"     "$MEMORY_DIR/.gitignore"
cp "$ADAPTER_GITATTRIBUTES_TEMPLATE" "$MEMORY_DIR/.gitattributes"

# ---------- flow A: fresh clone ----------
if [ "$STATE" = fresh ]; then
    log "[3/5] fresh flow: cloning $MEMORY_REPO into memory dir"
    # Clone into a tmp dir then move .git in, preserving the gitignore/attrs
    # and sync/ we just set up.
    TMP="$(mktemp -d)"
    if git clone --quiet "$MEMORY_REPO" "$TMP/memory" 2>/dev/null; then
        # Merge cloned files on top of our seeded dir. SKIP .gitignore /
        # .gitattributes — those came from the adapter template and
        # MUST win over the remote copy on a fresh install, otherwise
        # template additions (e.g. .hive-mind-format whitelist, new
        # merge bindings) wouldn't take effect on machine #2 onward.
        mv "$TMP/memory/.git" "$MEMORY_DIR/.git"
        shopt -s dotglob
        for f in "$TMP/memory"/*; do
            [ -e "$f" ] || continue
            case "$(basename "$f")" in
                .gitignore|.gitattributes) continue ;;
            esac
            cp -a "$f" "$MEMORY_DIR/" 2>/dev/null || true
        done
        shopt -u dotglob
        rm -rf "$TMP"
        log "cloned existing remote contents (adapter .gitignore + .gitattributes preserved)"
    else
        rm -rf "$TMP"
        log "remote is empty; initializing locally"
        git -C "$MEMORY_DIR" init -b main -q
        git -C "$MEMORY_DIR" remote add origin "$MEMORY_REPO"
    fi
    register_jsonmerge_driver "$MEMORY_DIR"
fi

# ---------- flow B: preserve local + merge ----------
if [ "$STATE" = existing ]; then
    log "[3/5] existing flow: init-in-place + merge with remote"
    cd "$MEMORY_DIR"
    git init -b main -q
    git remote add origin "$MEMORY_REPO"
    register_jsonmerge_driver "$MEMORY_DIR"
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

# ---------- install skills ----------
manage_claude_skills

# ---------- install hook config (via adapter) ----------
log "[4/5] installing hook config via adapter"
adapter_install_hooks

# ---------- push + verify ----------
log "[5/5] running a sync cycle to verify and push"
if [ -x "$HIVE_MIND_DIR/core/sync.sh" ]; then
    # Pass every ADAPTER_* variable sync.sh consumes into the subprocess:
    # LOG_PATH (where to log), MARKER_TARGETS (which files host markers),
    # EVENT_* (for any event-name-dependent logging), and SECRET_FILES
    # (the pre-commit safety gate). Without SECRET_FILES, the verification
    # sync could silently commit declared-secret files on first install.
    ADAPTER_DIR="$ADAPTER_DIR" \
    ADAPTER_LOG_PATH="${ADAPTER_LOG_PATH:-}" \
    ADAPTER_MARKER_TARGETS="${ADAPTER_MARKER_TARGETS:-}" \
    ADAPTER_SECRET_FILES="${ADAPTER_SECRET_FILES:-}" \
    ADAPTER_EVENT_SESSION_START="${ADAPTER_EVENT_SESSION_START:-}" \
    ADAPTER_EVENT_TURN_END="${ADAPTER_EVENT_TURN_END:-}" \
    ADAPTER_EVENT_POST_EDIT="${ADAPTER_EVENT_POST_EDIT:-}" \
        "$HIVE_MIND_DIR/core/sync.sh"
    if [ -s "$ADAPTER_LOG_PATH" ]; then
        echo
        echo "WARNING: sync produced errors:"
        tail -5 "$ADAPTER_LOG_PATH" >&2
    fi
fi

# ---------- done ----------
echo
log "done."
echo
adapter_activation_instructions
echo
[ -d "$BACKUP_DIR" ] && echo "Backup preserved at: $BACKUP_DIR (delete once you've confirmed a clean session)"
