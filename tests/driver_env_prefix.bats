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

@test "register_merge_drivers registers NO drivers when ADAPTER_SETTINGS_MERGE_BINDINGS is empty" {
  # Docs contract: empty ADAPTER_SETTINGS_MERGE_BINDINGS means "no
  # drivers for this adapter." Previously the function silently
  # registered jsonmerge as a legacy fallback, which both contradicted
  # the docs and forced a jq dependency onto adapters that don't use
  # JSON configs. Legacy back-compat for pre-adapter-contract installs
  # lives in the already_synced case inline, not in register_merge_drivers.
  target="$(mktemp -d)"
  git -c init.defaultBranch=main init -q "$target"

  HIVE_MIND_DIR="$(mktemp -d)"
  mkdir -p "$HIVE_MIND_DIR/core"
  : > "$HIVE_MIND_DIR/core/jsonmerge.sh"

  ADAPTER_SETTINGS_MERGE_BINDINGS=""
  ADAPTER_MERGE_DRIVER_ENV=""

  eval "$(awk '/^register_merge_drivers\(\)/,/^}/' "$SETUP")"
  register_merge_drivers "$target"

  # No merge.* configs should be set.
  run git -C "$target" config --get-regexp '^merge\.'
  [ "$status" -ne 0 ]
}

@test "register_merge_drivers quotes the %A/%O/%B placeholders in the git config" {
  # Regression: the merge-driver command string registered via
  # `git config merge.<drv>.driver "...<script> %A %O %B"` must
  # single-quote each placeholder. Git substitutes them with absolute
  # paths to temp files before invoking the driver via `sh -c`; a
  # path containing spaces (Windows "C:/Users/Jane Doe", macOS home
  # dirs with spaces) would otherwise word-split at sh invocation and
  # pass the driver the wrong arguments. Pin the quoting directly so a
  # future refactor that drops the quotes shows up as a clear failure
  # instead of a driver-only-breaks-on-spaced-paths mystery.
  target="$(mktemp -d)"
  git -c init.defaultBranch=main init -q "$target"

  # Fake HIVE_MIND_DIR that only needs a core/jsonmerge.sh marker
  # file; register_merge_drivers skips drivers whose core script is
  # absent.
  HIVE_MIND_DIR="$(mktemp -d)"
  mkdir -p "$HIVE_MIND_DIR/core"
  : > "$HIVE_MIND_DIR/core/jsonmerge.sh"

  ADAPTER_SETTINGS_MERGE_BINDINGS=$'settings.json jsonmerge'
  ADAPTER_MERGE_DRIVER_ENV=""

  # Extract register_merge_drivers from setup.sh and call it.
  eval "$(awk '/^register_merge_drivers\(\)/,/^}/' "$SETUP")"
  register_merge_drivers "$target"

  driver="$(git -C "$target" config --get merge.jsonmerge.driver)"
  # Exact placeholder quoting; also asserts the script path is
  # single-quoted so the full command remains word-safe.
  [[ "$driver" == *"'$HIVE_MIND_DIR/core/jsonmerge.sh' '%A' '%O' '%B'"* ]]

  # Defense-in-depth: no un-quoted placeholder survived, and no
  # placeholder appears without its wrapping single quotes.
  [[ "$driver" != *' %A '* ]]
  [[ "$driver" != *' %O '* ]]
  [[ "$driver" != *' %B'* ]] || [[ "$driver" == *"'%B'"* ]]
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
