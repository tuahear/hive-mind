#!/usr/bin/env bash
# Fake adapter with malformed semver — should hard-error on load.
set -euo pipefail
ADAPTER_API_VERSION="not-a-version"
ADAPTER_VERSION="0.1.0"
ADAPTER_NAME="malformed"
ADAPTER_DIR="${FAKE_ADAPTER_HOME:-/tmp}/.fake-tool"
ADAPTER_MEMORY_MODEL="flat"
ADAPTER_GLOBAL_MEMORY="$ADAPTER_DIR/MEMORY.md"
ADAPTER_PROJECT_MEMORY_DIR="$ADAPTER_DIR/projects/{encoded_cwd}/memory"
adapter_list_memory_files() { :; }
ADAPTER_GITIGNORE_TEMPLATE="${ADAPTER_ROOT}/gitignore"
ADAPTER_GITATTRIBUTES_TEMPLATE="${ADAPTER_ROOT}/gitattributes"
ADAPTER_SECRET_FILES=""
ADAPTER_MARKER_TARGETS=$'*.md'
ADAPTER_HAS_HOOK_SYSTEM=true
adapter_install_hooks() { :; }
adapter_uninstall_hooks() { :; }
ADAPTER_SKILL_ROOT=""
ADAPTER_SKILL_FORMAT=""
ADAPTER_SETTINGS_MERGE_BINDINGS=""
adapter_activation_instructions() { echo "activate"; }
adapter_disable_instructions() { echo "disable"; }
ADAPTER_FALLBACK_STRATEGY=""
ADAPTER_LOG_PATH="$ADAPTER_DIR/.sync-error.log"
adapter_healthcheck() { mkdir -p "$ADAPTER_DIR"; }
adapter_migrate() { :; }
