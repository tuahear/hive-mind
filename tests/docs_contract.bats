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

@test "docs/adapters.md hub-tree skill path matches the on-disk canonical name used by core + tests" {
  # Regression: docs/adapters.md's hub-layout tree once showed
  # `skills/<name>/skill.md` (lowercase) while core/hub/sync.sh's
  # marker targets and every tests/hub/*.bats assertion used SKILL.md
  # (upper — the Agent Skills spec). An adapter author copy-pasting
  # from docs would create a file core's marker scan ignores and the
  # tests would silently stop exercising. Pin the docs-vs-code
  # consistency here so a future lower-case regression fails fast.
  local tree_doc="$REPO_ROOT/docs/adapters.md"
  [ -f "$tree_doc" ]
  # The hub-layout tree line for skills must read SKILL.md uppercase.
  run grep -E '^[[:space:]]*[├└]──[[:space:]]+skills/<name>/SKILL\.md[[:space:]]*$' "$tree_doc"
  [ "$status" -eq 0 ]
  # And MUST NOT contain a lowercase skill.md counterpart in the same doc.
  run grep -E 'skills/<name>/skill\.md' "$tree_doc"
  [ "$status" -ne 0 ]

  # Guard the code side too — core/hub/sync.sh's HUB_MARKER_TARGETS
  # globs for skills must include the SKILL.md form so the marker-
  # extract scan sees skill edits. If a future refactor drops it,
  # marker-style commit subjects on skill edits silently regress to
  # the "update <basename>" fallback.
  local hub_sync="$REPO_ROOT/core/hub/sync.sh"
  [ -f "$hub_sync" ]
  grep -q 'skills/\*\*/SKILL\.md' "$hub_sync"
}

@test "loader's required_defined_vars matches every ADAPTER_* declared-required by conformance" {
  # Closes the triangle: conformance <-> loader <-> docs. If conformance
  # tests treat a variable as required-declared, the loader must enforce
  # it too, or an adapter can load in production yet fail conformance
  # (or the reverse — subtle behavior differences between env where the
  # loader runs vs env where conformance runs). This test parses both
  # sources of truth and requires matching sets.
  loader_required="$(awk '/required_defined_vars=\(/,/\)/' "$LOADER" | grep -oE 'ADAPTER_[A-Z_]+' | sort -u)"
  conformance_required="$(grep -oE '@test "ADAPTER_[A-Z_]+ is declared' "$CONFORMANCE" | grep -oE 'ADAPTER_[A-Z_]+' | sort -u)"

  [ -n "$loader_required" ]
  [ -n "$conformance_required" ]

  # Every conformance-declared var must be in the loader's required list.
  for var in $conformance_required; do
    printf '%s\n' "$loader_required" | grep -Fxq "$var" || {
      echo "conformance requires '$var' as declared but loader's required_defined_vars does not enforce it" >&2
      return 1
    }
  done
}
