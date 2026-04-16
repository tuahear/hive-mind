#!/usr/bin/env bats
# Pin docs/CONTRIBUTING-adapters.md against the actual contract.
#
# The docs table drifts over time as core/adapter-loader.sh and
# tests/adapter-conformance/conformance.bats add new required
# variables. If an adapter author follows the doc and the doc is
# stale, they ship an adapter that fails conformance and blame the
# contract. Cheaper to fail here than in a PR reviewer's inbox.
#
# Strategy: extract the required-variable arrays from adapter-loader.sh
# and the "declared (may be empty)" names from conformance.bats, and
# assert each name appears verbatim in the docs file.

REPO_ROOT="$BATS_TEST_DIRNAME/.."
DOC="$REPO_ROOT/docs/CONTRIBUTING-adapters.md"
LOADER="$REPO_ROOT/core/adapter-loader.sh"
CONFORMANCE="$REPO_ROOT/tests/adapter-conformance/conformance.bats"

@test "every required-non-empty variable from adapter-loader is documented" {
  [ -f "$DOC" ]
  # Extract the required_nonempty_vars=(...) block and pull out each
  # ADAPTER_* name. Parsing the loader rather than maintaining a
  # parallel list keeps the test honest with the source of truth.
  # ADAPTER_* names never contain whitespace so splitting via the
  # default IFS is safe here.
  required="$(awk '/required_nonempty_vars=\(/,/\)/' "$LOADER" | grep -oE 'ADAPTER_[A-Z_]+')"
  [ -n "$required" ]
  for var in $required; do
    grep -q "\`$var\`" "$DOC" || {
      echo "docs missing required-non-empty variable: $var" >&2
      return 1
    }
  done
}

@test "every required-declared-may-be-empty variable from adapter-loader is documented" {
  required="$(awk '/required_defined_vars=\(/,/\)/' "$LOADER" | grep -oE 'ADAPTER_[A-Z_]+')"
  [ -n "$required" ]
  for var in $required; do
    grep -q "\`$var\`" "$DOC" || {
      echo "docs missing required-declared variable: $var" >&2
      return 1
    }
  done
}

@test "every ADAPTER_* name asserted as declared in conformance tests is documented" {
  # The conformance suite has @test "ADAPTER_FOO is declared..." blocks
  # that catch vars the loader doesn't currently enforce. Anything the
  # conformance suite treats as required should also be in the docs.
  conformance_vars="$(grep -oE '@test "ADAPTER_[A-Z_]+ is declared' "$CONFORMANCE" | grep -oE 'ADAPTER_[A-Z_]+' | sort -u)"
  [ -n "$conformance_vars" ]
  for var in $conformance_vars; do
    grep -q "\`$var\`" "$DOC" || {
      echo "docs missing conformance-declared variable: $var" >&2
      return 1
    }
  done
}
