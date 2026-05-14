#!/usr/bin/env bash
# Hermes adapter for hive-mind.
#
# Hermes (https://github.com/NousResearch/hermes-agent) keeps all of its
# state under $HERMES_HOME (default ~/.hermes). This adapter mirrors that
# directory verbatim into hub/hermes/ — a blob round-trip with NO shared
# content.md tier, NO skill rename, NO per-project rules. Hermes state is
# isolated from claude-code / codex memory by design.
#
# Sync triggers off whatever other adapter is attached (or a manual
# `hivemind sync`); ADAPTER_HAS_HOOK_SYSTEM=false so a standalone-Hermes
# install does not auto-sync in v1.

set -euo pipefail

# --- A. Identity & location ------------------------------------------------
ADAPTER_API_VERSION="1.0.0"
ADAPTER_VERSION="0.1.0"
ADAPTER_NAME="hermes"
ADAPTER_DIR="${ADAPTER_DIR:-${HERMES_HOME:-$HOME/.hermes}}"
# The contract requires a memory model. Hermes has no flat/hierarchical
# memory layout the hub needs to reason about (the whole dir is a blob),
# but the loader enforces the enum + the flat-model path fields. Declare
# `flat` with harmless stubs — none of the flat-model machinery runs
# because ADAPTER_HUB_MAP does not reference content.md and there is no
# projects/<encoded-cwd>/ tree in ~/.hermes for mirror-projects to walk.
ADAPTER_MEMORY_MODEL="flat"
ADAPTER_GLOBAL_MEMORY="$ADAPTER_DIR/.hive-mind-noop"
ADAPTER_PROJECT_MEMORY_DIR="$ADAPTER_DIR/.hive-mind-noop/{encoded_cwd}"

adapter_list_memory_files() { :; }

# --- B. Files & sync rules -------------------------------------------------
ADAPTER_GITIGNORE_TEMPLATE="${ADAPTER_ROOT}/gitignore"
ADAPTER_GITATTRIBUTES_TEMPLATE="${ADAPTER_ROOT}/gitattributes"
# Hermes' setup wizard writes API keys (OpenRouter / OpenAI / Anthropic /
# ElevenLabs / Telegram tokens, etc.) to $ADAPTER_DIR/.env. The hub's
# basename gate must unstage it on every cycle.
ADAPTER_SECRET_FILES=".env"
ADAPTER_BACKUP_PATHS=""

# --- C. Lifecycle touchpoints ----------------------------------------------
# Hermes does not expose a stable hook surface today; sync runs off any
# other attached adapter's Stop hook (or `hivemind sync`). Declare the
# fallback as "manual" so a Hermes-only install is well-defined.
ADAPTER_HAS_HOOK_SYSTEM=false

# Contract-required functions. No-ops on Hermes because there is nothing
# to install — the hub-side sync entry point fires from a different
# adapter's hooks. Keeping the stubs lets the loader validate the
# adapter and lets `hivemind attach hermes` complete cleanly.
adapter_install_hooks() { :; }
adapter_uninstall_hooks() { :; }

# --- D. Skills -------------------------------------------------------------
# Skills are deliberately not surfaced through the hub-canonical
# `hub/skills/` tier — that tier fans out to every attached adapter's
# $ADAPTER_SKILL_ROOT, and Hermes' skills must stay isolated from
# Claude / Codex. The skills directory still rides along inside the
# blob mirror (everything under ~/.hermes goes through `hermes\t.`).
ADAPTER_SKILL_ROOT=""
ADAPTER_SKILL_FORMAT=""

# --- E. Settings merge -----------------------------------------------------
ADAPTER_SETTINGS_MERGE_BINDINGS=""
ADAPTER_MERGE_DRIVER_ENV=""

# --- F. User education -----------------------------------------------------
adapter_activation_instructions() {
  echo "Hermes is attached. The hub will mirror ${ADAPTER_DIR}/ to and from"
  echo "the memory repo on every sync. Sync runs when another attached"
  echo "adapter (claude-code, codex, ...) fires its turn-end hook, or when"
  echo "you run \`hivemind sync\` manually."
}

adapter_disable_instructions() {
  local hub="${HIVE_MIND_HUB_DIR:-$HOME/.hive-mind}"
  echo "Hermes has no hook entries to remove. To stop mirroring"
  echo "${ADAPTER_DIR}/, edit"
  echo "  ${hub}/.install-state/attached-adapters"
  echo "and remove only the line:"
  echo "  hermes"
}

# --- G. Fallback -----------------------------------------------------------
# No hook system → conformance requires the fallback be one of
# watcher | polling | manual.
ADAPTER_FALLBACK_STRATEGY="manual"

# --- H. Hub mapping --------------------------------------------------------
# Whole-dir blob mirror. The hub-side path `hermes` has no extension,
# so harvest/fan-out route through _hub_sync_dir (see
# core/hub/harvest-fanout.sh). Tool side `.` means "the full
# $ADAPTER_DIR tree" — _hub_sync_dir resolves $tool_dir/. to $tool_dir
# and walks every file under it.
#
# _hub_sync_dir honors a source-side .gitignore: if ~/.hermes/.gitignore
# exists (Hermes ships one by default — `.env`, `cache/`, `logs/`,
# `tmp/`, `*.log`), those paths are skipped in both directions. That is
# what keeps secrets (.env) and transient state out of the hub without
# the adapter having to enumerate them. The .gitignore file itself IS
# mirrored.
#
# Intentionally NO `content.md\t...` entry: Hermes is not on the shared
# global tier; its memory must not bleed into Claude / Codex global
# memory and vice versa.
ADAPTER_HUB_MAP=$'hermes\t.'

# Hermes has no per-project layout the hub needs to map. The whole-dir
# blob covers any project-style state Hermes maintains internally.
ADAPTER_PROJECT_CONTENT_RULES=""

# --- I. File harvest rules -------------------------------------------------
ADAPTER_FILE_HARVEST_RULES=$'**/*'
ADAPTER_PROJECT_CONTENT_GLOBS=""

# --- J. Logging ------------------------------------------------------------
ADAPTER_LOG_PATH="${ADAPTER_DIR}/.sync-error.log"

# --- Healthcheck -----------------------------------------------------------
adapter_healthcheck() {
  if command -v hermes >/dev/null 2>&1; then
    return 0
  fi
  [ -d "$ADAPTER_DIR" ]
}

# --- Migration -------------------------------------------------------------
adapter_migrate() { :; }
