#!/usr/bin/env bats
# Tests for adapter API version compatibility checks.
# Exercises the version comparison logic in core/adapter-loader.sh.
#
# Uses HIVE_MIND_ADAPTERS_DIR so all fixtures stage into a temp dir
# instead of mutating the real $REPO_ROOT/adapters/ (safe under
# concurrent bats, leaves no debris on abort).

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
LOADER="$REPO_ROOT/core/adapter-loader.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/adapters"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  export FAKE_ADAPTER_HOME="$HOME"
  TEST_ADAPTERS_DIR="$HOME/_test_adapters"
  mkdir -p "$TEST_ADAPTERS_DIR"
  export HIVE_MIND_ADAPTERS_DIR="$TEST_ADAPTERS_DIR"
}

teardown() {
  # All staged fixtures live under $HOME/_test_adapters, wiped with $HOME.
  rm -rf "$HOME"
}

install_fixture() {
  local fixture="$1" name="$2"
  mkdir -p "$TEST_ADAPTERS_DIR/$name"
  cp "$FIXTURES/$fixture/"* "$TEST_ADAPTERS_DIR/$name/"
}

@test "major_mismatch_adapter_newer: adapter 2.0.0, core 1.x → refuses to load" {
  install_fixture "api-2.0.0" "api-2-0-0"

  run bash -c "HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' source '$LOADER' && HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter 'api-2-0-0'"
  [ "$status" -ne 0 ]
}

@test "major_mismatch_adapter_older: adapter 0.1.0, core 1.x → refuses to load" {
  # Create a fixture with major=0
  mkdir -p "$TEST_ADAPTERS_DIR/api-0-1-0"
  cp "$FIXTURES/api-2.0.0/"* "$TEST_ADAPTERS_DIR/api-0-1-0/"
  sed -i.bak 's/ADAPTER_API_VERSION="2.0.0"/ADAPTER_API_VERSION="0.1.0"/' "$TEST_ADAPTERS_DIR/api-0-1-0/adapter.sh"
  sed -i.bak 's/ADAPTER_NAME="api-2-0-0"/ADAPTER_NAME="api-0-1-0"/' "$TEST_ADAPTERS_DIR/api-0-1-0/adapter.sh"
  rm -f "$TEST_ADAPTERS_DIR/api-0-1-0/adapter.sh.bak"

  run bash -c "HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' source '$LOADER' && HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter 'api-0-1-0'"
  [ "$status" -ne 0 ]
}

@test "minor_forward_refused: adapter 1.3.0, core 1.0.x → refuses to load" {
  install_fixture "api-1.3.0" "api-1-3-0"

  run bash -c "HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' source '$LOADER' && HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter 'api-1-3-0'"
  [ "$status" -ne 0 ]
}

@test "minor_backward: adapter 1.0.0, core 1.0.x → loads silently" {
  # The fake adapter declares 1.0.0 — same as core. Should succeed.
  mkdir -p "$TEST_ADAPTERS_DIR/fake"
  cp "$REPO_ROOT/tests/fixtures/adapters/fake/"* "$TEST_ADAPTERS_DIR/fake/"

  run bash -c "HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' source '$LOADER' && FAKE_ADAPTER_HOME='$HOME' HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter 'fake'"
  [ "$status" -eq 0 ]
}

@test "patch_difference: any patch mismatch loads silently" {
  mkdir -p "$TEST_ADAPTERS_DIR/api-1-0-0"
  cp "$FIXTURES/api-2.0.0/"* "$TEST_ADAPTERS_DIR/api-1-0-0/"
  sed -i.bak 's/ADAPTER_API_VERSION="2.0.0"/ADAPTER_API_VERSION="1.0.5"/' "$TEST_ADAPTERS_DIR/api-1-0-0/adapter.sh"
  sed -i.bak 's/ADAPTER_NAME="api-2-0-0"/ADAPTER_NAME="api-1-0-0"/' "$TEST_ADAPTERS_DIR/api-1-0-0/adapter.sh"
  rm -f "$TEST_ADAPTERS_DIR/api-1-0-0/adapter.sh.bak"

  run bash -c "HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' source '$LOADER' && FAKE_ADAPTER_HOME='$HOME' HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter 'api-1-0-0'"
  [ "$status" -eq 0 ]
}

@test "missing_api_version: adapter without ADAPTER_API_VERSION → hard error" {
  install_fixture "missing-version" "missing-version"

  run bash -c "HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' source '$LOADER' && HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter 'missing-version'"
  [ "$status" -ne 0 ]
}

@test "malformed_semver: adapter declares invalid semver → hard error" {
  install_fixture "malformed" "malformed"

  run bash -c "HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' source '$LOADER' && HIVE_MIND_ADAPTERS_DIR='$TEST_ADAPTERS_DIR' load_adapter 'malformed'"
  [ "$status" -ne 0 ]
}
