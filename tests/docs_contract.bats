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

@test "docs/adapters.md hub-tree uses content.md as the canonical content filename" {
  # Pin the hub-tree documentation against the canonical hub filename.
  # The hub stores all provider-agnostic content as `content.md` — both
  # the global memory and the per-skill main file. Docs showing SKILL.md
  # or memory.md in the hub tree would mislead adapter authors into
  # creating files the hub engine doesn't recognize.
  local tree_doc="$REPO_ROOT/docs/adapters.md"
  [ -f "$tree_doc" ]
  # Hub tree must show content.md for both global and skills.
  grep -q 'content\.md' "$tree_doc"
  # Must NOT show memory.md or SKILL.md as hub-canonical PATH names in the
  # tree (comments referencing tool-side names like "maps to SKILL.md" are fine).
  run grep -E '(├|└)──[[:space:]]+[^←]*\b(memory|SKILL)\.md' "$tree_doc"
  [ "$status" -ne 0 ]

  # Guard the code side too — core/hub/sync.sh's HUB_MARKER_TARGETS
  # must include content.md for both root and skills so marker extraction
  # works on content edits.
  local hub_sync="$REPO_ROOT/core/hub/sync.sh"
  [ -f "$hub_sync" ]
  grep -q 'skills/\*\*/content\.md' "$hub_sync"
  # Root content.md must appear in the marker targets too.
  grep 'HUB_MARKER_TARGETS' "$hub_sync" | grep -Fq 'content.md'
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
