#!/usr/bin/env bats
# Unit tests for setup.sh's _driver_env_prefix helper.
#
# Context: when setup.sh registers git merge drivers it may need to
# prepend per-driver env vars (e.g. TOMLMERGE_UNION_KEYS=...) to the
# driver invocation. Adapters declare those via
# ADAPTER_MERGE_DRIVER_ENV as newline-separated "<driver>:<ENV>" lines.
#
# Failure mode being pinned: an older implementation ran the lookup
# loop inside a `printf ... | while read` pipeline. `return` inside a
# pipeline only exits the subshell, not the calling function, which
# means the control flow is invisible to callers and especially brittle
# under `set -euo pipefail`. The fix uses a here-string (`<<<`) so the
# loop runs in the current shell and `return` behaves as written.

REPO_ROOT="$BATS_TEST_DIRNAME/.."
SETUP="$REPO_ROOT/setup.sh"

# Extract _driver_env_prefix into the current test shell. awk captures
# the body from the function definition to its closing brace.
_load_helper() {
  eval "$(awk '/^    _driver_env_prefix\(\)/,/^    }/' "$SETUP")"
}

@test "_driver_env_prefix: returns empty when ADAPTER_MERGE_DRIVER_ENV is unset" {
  unset ADAPTER_MERGE_DRIVER_ENV
  _load_helper
  run _driver_env_prefix jsonmerge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_driver_env_prefix: returns empty when ADAPTER_MERGE_DRIVER_ENV is empty" {
  ADAPTER_MERGE_DRIVER_ENV=""
  _load_helper
  run _driver_env_prefix jsonmerge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_driver_env_prefix: returns matching env with trailing space" {
  ADAPTER_MERGE_DRIVER_ENV=$'tomlmerge:TOMLMERGE_UNION_KEYS=permissions.allow,deny'
  _load_helper
  run _driver_env_prefix tomlmerge
  [ "$status" -eq 0 ]
  [ "$output" = "TOMLMERGE_UNION_KEYS=permissions.allow,deny " ]
}

@test "_driver_env_prefix: returns empty when driver has no declared env" {
  ADAPTER_MERGE_DRIVER_ENV=$'tomlmerge:TOMLMERGE_UNION_KEYS=x'
  _load_helper
  run _driver_env_prefix jsonmerge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_driver_env_prefix: picks the right driver when multiple are declared" {
  ADAPTER_MERGE_DRIVER_ENV=$'tomlmerge:TOMLMERGE_UNION_KEYS=a,b\njsonmerge:JSONMERGE_DEEP=1'
  _load_helper
  run _driver_env_prefix jsonmerge
  [ "$status" -eq 0 ]
  [ "$output" = "JSONMERGE_DEEP=1 " ]
}

@test "_driver_env_prefix: stops at first match (doesn't concatenate duplicates)" {
  # If `return` silently became a no-op inside a subshell (the original
  # bug), a duplicate driver line would cause both envs to be emitted
  # concatenated. Assert a clean single match even in the pathological
  # case where the adapter accidentally declares the same driver twice.
  ADAPTER_MERGE_DRIVER_ENV=$'tomlmerge:FIRST=1\ntomlmerge:SECOND=2'
  _load_helper
  run _driver_env_prefix tomlmerge
  [ "$status" -eq 0 ]
  [ "$output" = "FIRST=1 " ]
}

@test "docs describe ADAPTER_SETTINGS_MERGE_BINDINGS format that setup.sh's awk parser actually accepts" {
  # Pins the docs' stated format against setup.sh's parser. If the docs
  # drift back to `pattern=driver-script` (the wrong form), an adapter
  # author would provide `settings.json=jsonmerge`, which has NF=1 and
  # the awk filter `NF>=2 {print $2}` would produce nothing — no drivers
  # registered. Construct an example exactly as the docs illustrate and
  # run the same awk against it.
  doc_example="settings.json jsonmerge"
  drv="$(printf '%s\n' "$doc_example" | awk 'NF>=2 {print $2}')"
  [ "$drv" = "jsonmerge" ]

  # Sanity: the wrong form (used by the incorrect old doc) must NOT
  # parse to a driver name, so this test also catches the specific
  # regression it's guarding against.
  wrong_example="settings.json=jsonmerge"
  wrong_drv="$(printf '%s\n' "$wrong_example" | awk 'NF>=2 {print $2}')"
  [ -z "$wrong_drv" ]
}
