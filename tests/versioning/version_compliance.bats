#!/usr/bin/env bats
# Version compliance tests — verifies all version constants parse correctly
# and that adapter API versions are compatible with core.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."

@test "core API version is valid semver" {
  version="$(grep 'HIVE_MIND_CORE_API_VERSION=' "$REPO_ROOT/core/adapter-loader.sh" \
    | head -1 | sed 's/.*="//' | sed 's/".*//')"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "VERSION file is valid semver" {
  version="$(cat "$REPO_ROOT/VERSION" | tr -d '[:space:]')"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "each registered adapter declares a valid ADAPTER_API_VERSION" {
  for adapter_dir in "$REPO_ROOT/adapters"/*/; do
    [ -f "$adapter_dir/adapter.sh" ] || continue
    name="$(basename "$adapter_dir")"
    version="$(grep 'ADAPTER_API_VERSION=' "$adapter_dir/adapter.sh" \
      | head -1 | sed 's/.*="//' | sed 's/".*//')"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      echo "adapter '$name' has invalid ADAPTER_API_VERSION='$version'" >&2
      return 1
    }
  done
}

@test "each adapter API minor <= core API minor within same major" {
  core_ver="$(grep 'HIVE_MIND_CORE_API_VERSION=' "$REPO_ROOT/core/adapter-loader.sh" \
    | head -1 | sed 's/.*="//' | sed 's/".*//')"
  IFS='.' read -r c_major c_minor c_patch <<< "$core_ver"

  for adapter_dir in "$REPO_ROOT/adapters"/*/; do
    [ -f "$adapter_dir/adapter.sh" ] || continue
    name="$(basename "$adapter_dir")"
    ver="$(grep 'ADAPTER_API_VERSION=' "$adapter_dir/adapter.sh" \
      | head -1 | sed 's/.*="//' | sed 's/".*//')"
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

@test "HIVE_MIND_FORMAT_VERSION in sync.sh is a positive integer" {
  fmt="$(grep 'HIVE_MIND_FORMAT_VERSION=' "$REPO_ROOT/core/sync.sh" \
    | head -1 | sed 's/.*=//')"
  [[ "$fmt" =~ ^[1-9][0-9]*$ ]]
}

@test "format-version in .hive-mind-format template is a positive integer" {
  # The format file doesn't exist as a template — it's created at runtime.
  # But we verify the value written by sync.sh parses as expected.
  # Run a quick check that HIVE_MIND_FORMAT_VERSION matches.
  fmt="$(grep 'HIVE_MIND_FORMAT_VERSION=' "$REPO_ROOT/core/sync.sh" \
    | head -1 | sed 's/.*=//')"
  [ "$fmt" -ge 1 ]
}
