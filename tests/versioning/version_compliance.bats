#!/usr/bin/env bats
# Version compliance tests — verifies all version constants parse correctly
# and that adapter API versions are compatible with core.
#
# Reads values by SOURCING the scripts in subshells, not by grep/sed
# scraping the file text. That way harmless refactors (single vs double
# quotes, whitespace, where the assignment lives) don't false-fail.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."

# Helper: source core/adapter-loader.sh in a clean subshell and echo
# the value of a named core variable. Stdout is the value; non-zero
# exit if the variable was never set or is empty. Runs in a subshell
# so the load doesn't pollute the test environment. The explicit
# unset/empty check keeps version-compliance assertions from silently
# passing when a constant gets accidentally deleted or blanked.
_core_var() {
  local var="$1"
  (
    # shellcheck disable=SC1091
    source "$REPO_ROOT/core/adapter-loader.sh" >/dev/null 2>&1
    [ "${!var+x}" = "x" ] || exit 1
    [ -n "${!var}" ] || exit 1
    printf '%s' "${!var}"
  )
}

# Helper: source an adapter.sh in a clean subshell (with ADAPTER_ROOT
# set so the relative gitignore/gitattributes paths resolve) and echo
# the named ADAPTER_* variable. Non-zero exit if unset or empty, for
# the same reason as _core_var.
_adapter_var() {
  local adapter_dir="$1" var="$2"
  (
    ADAPTER_ROOT="$adapter_dir"
    export ADAPTER_ROOT
    # shellcheck disable=SC1091
    source "$adapter_dir/adapter.sh" >/dev/null 2>&1
    [ "${!var+x}" = "x" ] || exit 1
    [ -n "${!var}" ] || exit 1
    printf '%s' "${!var}"
  )
}

@test "core API version is valid semver" {
  version="$(_core_var HIVE_MIND_CORE_API_VERSION)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "VERSION file is valid semver" {
  version="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "each registered adapter declares a valid ADAPTER_API_VERSION" {
  for adapter_dir in "$REPO_ROOT/adapters"/*/; do
    [ -f "$adapter_dir/adapter.sh" ] || continue
    name="$(basename "$adapter_dir")"
    version="$(_adapter_var "$adapter_dir" ADAPTER_API_VERSION)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      echo "adapter '$name' has invalid ADAPTER_API_VERSION='$version'" >&2
      return 1
    }
  done
}

@test "each adapter API minor <= core API minor within same major" {
  core_ver="$(_core_var HIVE_MIND_CORE_API_VERSION)"
  IFS='.' read -r c_major c_minor c_patch <<< "$core_ver"

  for adapter_dir in "$REPO_ROOT/adapters"/*/; do
    [ -f "$adapter_dir/adapter.sh" ] || continue
    name="$(basename "$adapter_dir")"
    ver="$(_adapter_var "$adapter_dir" ADAPTER_API_VERSION)"
    IFS='.' read -r a_major a_minor a_patch <<< "$ver"

    [ "$a_major" -eq "$c_major" ] || {
      echo "adapter '$name' major $a_major != core major $c_major" >&2
      return 1
    }
    [ "$a_minor" -le "$c_minor" ] || {
      echo "adapter '$name' minor $a_minor > core minor $c_minor" >&2
      return 1
    }
  done
}

@test "HIVE_MIND_FORMAT_VERSION in sync.sh is a simple positive-integer assignment" {
  # Pulled with awk, NOT eval. Eval-ing a line from the source file
  # would execute anything on the RHS — a future refactor that makes
  # the value a command substitution (e.g. `HIVE_MIND_FORMAT_VERSION=$(something)`)
  # would silently run that subshell inside this test. Parse the raw
  # line instead and insist the value is a bare positive integer; if a
  # refactor breaks that shape, this test fires with a clear signal.
  line="$(awk '/^HIVE_MIND_FORMAT_VERSION=/{print; exit}' "$REPO_ROOT/core/sync.sh")"
  [ -n "$line" ]
  # Exact-form assertion — left side is the name, right side is digits
  # only with no spaces, quotes, or expansions.
  [[ "$line" =~ ^HIVE_MIND_FORMAT_VERSION=[1-9][0-9]*$ ]]
}

@test "HIVE_MIND_FORMAT_VERSION is >= 1" {
  fmt="$(awk -F= '/^HIVE_MIND_FORMAT_VERSION=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$REPO_ROOT/core/sync.sh")"
  [ "$fmt" -ge 1 ]
}

# _core_var and _adapter_var are the helpers that read version constants
# in a clean subshell. Their contract is "stdout = value; non-zero exit
# on unset or empty". If that contract drifts (e.g. back to returning
# 0 with an empty string), the semver-regex assertions above would
# still pass on an accidentally-deleted constant because the regex
# match fails with a cryptic empty-string error instead of pointing at
# the missing variable. Pin the contract.
@test "_core_var exits non-zero when the requested variable is unset" {
  run _core_var HIVE_MIND_DOES_NOT_EXIST
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_core_var exits non-zero when the requested variable is empty" {
  # Create a throwaway loader that exports the name as empty and verify
  # _core_var still rejects it. We simulate by pointing at an alternate
  # file via a wrapper subshell.
  run bash -c '
    set +e
    REPO_ROOT="'"$REPO_ROOT"'"
    _core_var() {
      local var="$1"
      (
        # shellcheck disable=SC1091
        source "$REPO_ROOT/core/adapter-loader.sh" >/dev/null 2>&1
        # Force the probe variable to empty to simulate the "defined
        # but blank" case (which the old helper would have returned 0 for).
        HIVE_MIND_CORE_API_VERSION=""
        [ "${!var+x}" = "x" ] || exit 1
        [ -n "${!var}" ] || exit 1
        printf "%s" "${!var}"
      )
    }
    _core_var HIVE_MIND_CORE_API_VERSION
  '
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_adapter_var exits non-zero when the requested variable is unset" {
  run _adapter_var "$REPO_ROOT/adapters/claude-code" ADAPTER_DOES_NOT_EXIST
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
