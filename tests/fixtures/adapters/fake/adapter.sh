#!/usr/bin/env bash
# Fake adapter for core tests. Points all paths at a BATS_TMPDIR subdirectory
# and uses a simulated hook config file. Exercises the full capability surface
# without requiring any real AI tool.
#
# Tests source this via load_adapter "fake" after symlinking or copying it
# into the adapters/ tree, or by setting ADAPTER_ROOT directly.

set -euo pipefail

# --- A. Identity & location ------------------------------------------------
ADAPTER_API_VERSION="1.0.0"
ADAPTER_VERSION="0.1.0"
ADAPTER_NAME="fake"

# Tests must set FAKE_ADAPTER_HOME before sourcing. Falls back to a
# reasonable default so the adapter always loads.
FAKE_ADAPTER_HOME="${FAKE_ADAPTER_HOME:-${BATS_TMPDIR:-/tmp}/fake-adapter}"
ADAPTER_DIR="$FAKE_ADAPTER_HOME/.fake-tool"
ADAPTER_MEMORY_MODEL="flat"
ADAPTER_GLOBAL_MEMORY="$ADAPTER_DIR/MEMORY.md"
ADAPTER_PROJECT_MEMORY_DIR="$ADAPTER_DIR/projects/{encoded_cwd}/memory"

adapter_list_memory_files() { :; }

# --- B. Files & sync rules -------------------------------------------------
ADAPTER_GITIGNORE_TEMPLATE="${ADAPTER_ROOT}/gitignore"
ADAPTER_GITATTRIBUTES_TEMPLATE="${ADAPTER_ROOT}/gitattributes"
ADAPTER_SECRET_FILES=""
ADAPTER_MARKER_TARGETS=$'*.md\n**/*.md'

# --- C. Lifecycle touchpoints ----------------------------------------------
ADAPTER_HAS_HOOK_SYSTEM=true
ADAPTER_EVENT_SESSION_START="SessionStart"
ADAPTER_EVENT_TURN_END="Stop"
ADAPTER_EVENT_POST_EDIT="PostToolUse"

adapter_install_hooks() {
  local config="$ADAPTER_DIR/hooks.json"
  mkdir -p "$ADAPTER_DIR"
  # Simulate a simple hook config. Idempotent — same content every time.
  cat > "$config" <<HOOKEOF
{
  "hooks": {
    "SessionStart": [{"command": "hive-mind-session-start"}],
    "Stop": [{"command": "hive-mind-sync"}],
    "PostToolUse": [{"matcher": "Edit|Write", "command": "hive-mind-nudge"}]
  }
}
HOOKEOF
}

adapter_uninstall_hooks() {
  local config="$ADAPTER_DIR/hooks.json"
  [ -f "$config" ] || return 0
  # Remove only hive-mind entries, leaving the rest. For the fake adapter
  # the entire file is hive-mind-owned, so just remove it.
  rm -f "$config"
}

# --- D. Skills (optional) --------------------------------------------------
ADAPTER_SKILL_ROOT="$ADAPTER_DIR/skills"
ADAPTER_SKILL_FORMAT="markdown-frontmatter"

# --- E. Settings merge -----------------------------------------------------
ADAPTER_SETTINGS_MERGE_BINDINGS=$'hooks.json jsonmerge'

# --- F. User education -----------------------------------------------------
adapter_activation_instructions() {
  echo "Restart the fake tool to activate hive-mind hooks."
}

adapter_disable_instructions() {
  echo "Remove hooks.json from $ADAPTER_DIR to disable."
}

# --- G. Fallback -----------------------------------------------------------
ADAPTER_FALLBACK_STRATEGY=""

# --- I. Hub mapping (v0.3.0 hub topology) ---------------------------------
ADAPTER_HUB_MAP=$'content.md\tMEMORY.md
config/hooks\thooks.json#hooks'
ADAPTER_PROJECT_CONTENT_RULES=$'content.md\tMEMORY.md
content.md\tmemory/MEMORY.md
memory\tmemory'

# --- H. Logging ------------------------------------------------------------
ADAPTER_LOG_PATH="$ADAPTER_DIR/.sync-error.log"

# --- Healthcheck -----------------------------------------------------------
adapter_healthcheck() {
  # In tests, the fake tool is always "installed" — the healthcheck just
  # verifies ADAPTER_DIR is writable.
  mkdir -p "$ADAPTER_DIR" 2>/dev/null
}

# --- Migration (optional) --------------------------------------------------
adapter_migrate() { :; }
