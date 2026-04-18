#!/usr/bin/env bash
# Second fake adapter for cross-provider tests. Attaches to the same
# hub as the primary `fake` adapter, but maps the canonical hub schema
# onto a DIFFERENT tool-native layout — memory file is NOTES.md
# (not MEMORY.md), hook config is tool.json (not hooks.json). Lets
# tests/hub/cross-provider.bats prove that content edited via adapter
# A's tool dir reaches adapter B's tool dir under its B-native name.

set -euo pipefail

# --- A. Identity & location ------------------------------------------------
ADAPTER_API_VERSION="1.0.0"
ADAPTER_VERSION="0.1.0"
ADAPTER_NAME="fake-b"

FAKE_B_ADAPTER_HOME="${FAKE_B_ADAPTER_HOME:-${BATS_TMPDIR:-/tmp}/fake-b-adapter}"
ADAPTER_DIR="$FAKE_B_ADAPTER_HOME/.fake-b-tool"
ADAPTER_MEMORY_MODEL="flat"
ADAPTER_GLOBAL_MEMORY="$ADAPTER_DIR/NOTES.md"
ADAPTER_PROJECT_MEMORY_DIR="$ADAPTER_DIR/projects/{encoded_cwd}/notes"

adapter_list_memory_files() { :; }

# --- B. Files & sync rules -------------------------------------------------
ADAPTER_GITIGNORE_TEMPLATE="${ADAPTER_ROOT}/gitignore"
ADAPTER_GITATTRIBUTES_TEMPLATE="${ADAPTER_ROOT}/gitattributes"
ADAPTER_SECRET_FILES=""

# --- C. Lifecycle touchpoints ----------------------------------------------
ADAPTER_HAS_HOOK_SYSTEM=true
ADAPTER_EVENT_SESSION_START="OnStart"
ADAPTER_EVENT_TURN_END="OnEnd"
ADAPTER_EVENT_POST_EDIT="OnEdit"

adapter_install_hooks() {
  local config="$ADAPTER_DIR/tool.json"
  mkdir -p "$ADAPTER_DIR"
  cat > "$config" <<HOOKEOF
{"hooks":{"OnEnd":[{"hooks":[{"type":"command","command":"fake-b-sync"}]}]}}
HOOKEOF
}

adapter_uninstall_hooks() {
  rm -f "$ADAPTER_DIR/tool.json"
}

# --- D. Skills (optional) --------------------------------------------------
ADAPTER_SKILL_ROOT="$ADAPTER_DIR/skills"
ADAPTER_SKILL_FORMAT="markdown-frontmatter"

# --- E. Settings merge -----------------------------------------------------
ADAPTER_SETTINGS_MERGE_BINDINGS=""

# --- F. User education -----------------------------------------------------
adapter_activation_instructions() { echo "Restart fake-b."; }
adapter_disable_instructions() { echo "Remove tool.json from $ADAPTER_DIR."; }

# --- G. Fallback -----------------------------------------------------------
ADAPTER_FALLBACK_STRATEGY=""

# --- I. Hub mapping -------------------------------------------------------
# Same canonical hub content path as `fake`, but the tool-native layout
# differs: content.md → NOTES.md (not MEMORY.md). That mismatch is what
# makes the cross-provider round-trip test meaningful — an edit via
# fake's tool dir must surface under fake-b's tool-native name after
# the shared hub sync cycle.
ADAPTER_HUB_MAP=$'content.md\tNOTES.md'
ADAPTER_PROJECT_CONTENT_RULES=$'content.md\tnotes/NOTES.md
content.md\tNOTES.md
notes\tnotes'

# --- H. Logging ------------------------------------------------------------
ADAPTER_LOG_PATH="$ADAPTER_DIR/.sync-error.log"

# --- Healthcheck -----------------------------------------------------------
adapter_healthcheck() {
  mkdir -p "$ADAPTER_DIR" 2>/dev/null
}

# --- Migration -------------------------------------------------------------
adapter_migrate() { :; }
