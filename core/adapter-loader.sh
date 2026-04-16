#!/usr/bin/env bash
# Core adapter loader. Sources an adapter's adapter.sh and validates the
# capability surface. Called by setup.sh and core scripts that need
# adapter-provided paths/functions.
#
# Usage:
#   source core/adapter-loader.sh
#   load_adapter "claude-code"   # sources adapters/claude-code/adapter.sh
#
# On success the caller inherits all ADAPTER_* variables and adapter_*
# functions. On failure the loader prints a diagnostic and returns non-zero.

set -euo pipefail

# The adapter API version this core understands.
HIVE_MIND_CORE_API_VERSION="1.0.0"

# --- semver helpers --------------------------------------------------------

# Parse a semver string into three variables via nameref.
# semver_parse "1.2.3" major minor patch  →  major=1 minor=2 patch=3
semver_parse() {
  local ver="$1"
  if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi
  local IFS='.'
  # shellcheck disable=SC2162
  read "$2" "$3" "$4" <<< "$ver"
}

# --- logging helper (lightweight — full log.sh loaded separately) ----------

_loader_log() {
  local level="$1"; shift
  printf '%s %s adapter-loader: %s\n' "$(date -u +%FT%TZ)" "$level" "$*" >&2
}

# --- main entry point ------------------------------------------------------

load_adapter() {
  local adapter_name="$1"
  local loader_root
  loader_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local adapter_file="$loader_root/adapters/$adapter_name/adapter.sh"

  if [ ! -f "$adapter_file" ]; then
    _loader_log ERROR "adapter '$adapter_name' not found at $adapter_file"
    return 1
  fi

  # ADAPTER_ROOT is set before sourcing so the adapter can reference its
  # own bundled assets (gitignore template, skills, etc.) portably.
  ADAPTER_ROOT="$loader_root/adapters/$adapter_name"
  export ADAPTER_ROOT

  # shellcheck source=/dev/null
  source "$adapter_file"

  _validate_adapter "$adapter_name" || return 1
}

# --- validation ------------------------------------------------------------

_validate_adapter() {
  local name="$1"
  local ok=1

  # Required variables that must be defined AND non-empty.
  local required_nonempty_vars=(
    ADAPTER_API_VERSION
    ADAPTER_VERSION
    ADAPTER_NAME
    ADAPTER_DIR
    ADAPTER_MEMORY_MODEL
    ADAPTER_GITIGNORE_TEMPLATE
    ADAPTER_GITATTRIBUTES_TEMPLATE
    ADAPTER_MARKER_TARGETS
    ADAPTER_HAS_HOOK_SYSTEM
    ADAPTER_LOG_PATH
  )
  for var in "${required_nonempty_vars[@]}"; do
    if [ -z "${!var+x}" ]; then
      _loader_log ERROR "adapter '$name' missing required variable: $var"
      ok=0
    elif [ -z "${!var}" ]; then
      _loader_log ERROR "adapter '$name' required variable is empty: $var"
      ok=0
    fi
  done

  # Required variables that must be defined (may be empty string).
  local required_defined_vars=(
    ADAPTER_SECRET_FILES
    ADAPTER_SETTINGS_MERGE_BINDINGS
    ADAPTER_FALLBACK_STRATEGY
  )
  for var in "${required_defined_vars[@]}"; do
    if [ -z "${!var+x}" ]; then
      _loader_log ERROR "adapter '$name' missing required variable: $var (may be empty but must be declared)"
      ok=0
    fi
  done

  # Enum check: ADAPTER_HAS_HOOK_SYSTEM must be literal "true" or "false".
  if [ -n "${ADAPTER_HAS_HOOK_SYSTEM+x}" ]; then
    case "$ADAPTER_HAS_HOOK_SYSTEM" in
      true|false) ;;
      *)
        _loader_log ERROR "adapter '$name' ADAPTER_HAS_HOOK_SYSTEM must be 'true' or 'false', got '$ADAPTER_HAS_HOOK_SYSTEM'"
        ok=0
        ;;
    esac
  fi

  # Bail early if fundamentals are missing.
  [ "$ok" -eq 1 ] || return 1

  # --- API version compatibility ---
  if ! semver_parse "$ADAPTER_API_VERSION" a_major a_minor a_patch; then
    _loader_log ERROR "adapter '$name' declares malformed ADAPTER_API_VERSION='$ADAPTER_API_VERSION' (must be semver)"
    return 1
  fi

  local c_major c_minor c_patch
  semver_parse "$HIVE_MIND_CORE_API_VERSION" c_major c_minor c_patch

  if [ "$a_major" -ne "$c_major" ]; then
    _loader_log ERROR "adapter '$name' API major version $a_major does not match core major $c_major — upgrade required"
    return 1
  fi

  if [ "$a_minor" -gt "$c_minor" ]; then
    _loader_log ERROR "adapter '$name' API minor version $a_minor exceeds core minor $c_minor — upgrade core"
    return 1
  fi

  # --- memory model validation ---
  case "$ADAPTER_MEMORY_MODEL" in
    flat|hierarchical) ;;
    *)
      _loader_log ERROR "adapter '$name' declares invalid ADAPTER_MEMORY_MODEL='$ADAPTER_MEMORY_MODEL' (must be flat|hierarchical)"
      return 1
      ;;
  esac

  if [ "$ADAPTER_MEMORY_MODEL" = "flat" ]; then
    if [ -z "${ADAPTER_GLOBAL_MEMORY:-}" ]; then
      _loader_log ERROR "adapter '$name' uses flat memory model but ADAPTER_GLOBAL_MEMORY is not set"
      return 1
    fi
    if [ -z "${ADAPTER_PROJECT_MEMORY_DIR:-}" ]; then
      _loader_log ERROR "adapter '$name' uses flat memory model but ADAPTER_PROJECT_MEMORY_DIR is not set"
      return 1
    fi
  fi

  # --- required functions ---
  local required_funcs=(
    adapter_install_hooks
    adapter_uninstall_hooks
    adapter_healthcheck
    adapter_activation_instructions
    adapter_disable_instructions
    adapter_migrate
  )
  for func in "${required_funcs[@]}"; do
    if ! declare -f "$func" >/dev/null 2>&1; then
      _loader_log ERROR "adapter '$name' missing required function: $func"
      ok=0
    fi
  done

  [ "$ok" -eq 1 ] || return 1

  # --- template files exist ---
  if [ ! -f "$ADAPTER_GITIGNORE_TEMPLATE" ]; then
    _loader_log ERROR "adapter '$name' gitignore template not found: $ADAPTER_GITIGNORE_TEMPLATE"
    return 1
  fi
  if [ ! -f "$ADAPTER_GITATTRIBUTES_TEMPLATE" ]; then
    _loader_log ERROR "adapter '$name' gitattributes template not found: $ADAPTER_GITATTRIBUTES_TEMPLATE"
    return 1
  fi

  return 0
}

# --- adapter detection (which adapter to use on this machine) --------------

# Detect which adapters are available based on installed host tools.
# Prints adapter names (one per line) for every adapter whose healthcheck
# passes. Caller picks the one they want (e.g. first match, or user flag).
detect_adapters() {
  local loader_root
  loader_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local adapters_dir="$loader_root/adapters"
  [ -d "$adapters_dir" ] || return 0

  for d in "$adapters_dir"/*/; do
    [ -d "$d" ] || continue
    local name
    name="$(basename "$d")"
    [ -f "$d/adapter.sh" ] || continue

    # Quick healthcheck — source in a subshell so a broken adapter
    # doesn't pollute the caller's environment.
    if (
      ADAPTER_ROOT="$d"
      export ADAPTER_ROOT
      # shellcheck source=/dev/null
      source "$d/adapter.sh" 2>/dev/null
      adapter_healthcheck 2>/dev/null
    ); then
      printf '%s\n' "$name"
    fi
  done
}
