#!/usr/bin/env bats
# Regression tests for the skills harvest path (issue #29).
#
# The bug: two attached adapters share the hub skills/ tree. When the
# user edits SKILL.md under adapter A, adapter A's harvest copies the
# edit to hub content.md. Then adapter B's harvest runs in the same
# sync cycle and blindly copies B's unchanged SKILL.md over the hub
# content.md A just wrote — silently reverting the edit.
#
# The fix: snapshot each tool-side skill file after every fan-out and
# skip the harvest copy when the tool file is byte-identical to its
# snapshot (the same harvest-stomp guard ADAPTER_HUB_MAP entries use).

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
HARVEST_FANOUT="$REPO_ROOT/core/hub/harvest-fanout.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  HUB="$HOME/.hive-mind"
  TOOL_A="$HOME/.adapter-a"
  TOOL_B="$HOME/.adapter-b"
  mkdir -p "$HUB" "$TOOL_A/skills" "$TOOL_B/skills"
  export HIVE_MIND_HUB_DIR="$HUB"
  export ADAPTER_LOG_PATH="$HOME/hub.log"
  # Empty content map — we only exercise the skills path here.
  export ADAPTER_HUB_MAP=""
  export ADAPTER_PROJECT_CONTENT_RULES=""
  # shellcheck source=/dev/null
  source "$HARVEST_FANOUT"
}

teardown() {
  rm -rf "$HOME"
}

# Seed identical SKILL.md in both tool dirs + populate snapshots as
# though a prior fan-out already synced them. Returns with HUB, TOOL_A,
# TOOL_B holding the same "v1" content and snapshots to match.
seed_two_adapter_skill() {
  mkdir -p "$TOOL_A/skills/abac" "$TOOL_B/skills/abac"
  printf 'v1\n' > "$TOOL_A/skills/abac/SKILL.md"
  printf 'v1\n' > "$TOOL_B/skills/abac/SKILL.md"
  # Simulate the hub state after a prior fan-out.
  mkdir -p "$HUB/skills/abac"
  printf 'v1\n' > "$HUB/skills/abac/content.md"
  # Drop snapshots that the previous fan-out would have written.
  local snap_a snap_b
  snap_a="$(_hub_snapshot_path "$TOOL_A" "skills/abac/SKILL.md")"
  snap_b="$(_hub_snapshot_path "$TOOL_B" "skills/abac/SKILL.md")"
  mkdir -p "$(dirname "$snap_a")" "$(dirname "$snap_b")"
  cp "$TOOL_A/skills/abac/SKILL.md" "$snap_a"
  cp "$TOOL_B/skills/abac/SKILL.md" "$snap_b"
}

@test "two-adapter harvest: edit in A survives B's harvest-stomp" {
  seed_two_adapter_skill

  # User edits adapter A's SKILL.md. Adapter B's copy is untouched.
  printf 'v2\n' > "$TOOL_A/skills/abac/SKILL.md"

  # Same order sync.sh uses: every attached adapter harvests before
  # any fan-out runs.
  ADAPTER_SKILL_ROOT="$TOOL_A/skills" hub_harvest "$TOOL_A" "$HUB"
  ADAPTER_SKILL_ROOT="$TOOL_B/skills" hub_harvest "$TOOL_B" "$HUB"

  # Hub must reflect A's v2, not B's v1.
  run cat "$HUB/skills/abac/content.md"
  [ "$status" -eq 0 ]
  [ "$output" = "v2" ]
}

@test "two-adapter round-trip: harvest + fan-out lands the edit in B" {
  seed_two_adapter_skill
  printf 'v2\n' > "$TOOL_A/skills/abac/SKILL.md"

  ADAPTER_SKILL_ROOT="$TOOL_A/skills" hub_harvest "$TOOL_A" "$HUB"
  ADAPTER_SKILL_ROOT="$TOOL_B/skills" hub_harvest "$TOOL_B" "$HUB"
  ADAPTER_SKILL_ROOT="$TOOL_A/skills" hub_fan_out "$HUB" "$TOOL_A"
  ADAPTER_SKILL_ROOT="$TOOL_B/skills" hub_fan_out "$HUB" "$TOOL_B"

  run cat "$TOOL_A/skills/abac/SKILL.md"
  [ "$output" = "v2" ]
  run cat "$TOOL_B/skills/abac/SKILL.md"
  [ "$output" = "v2" ]
}

@test "first-sync (no snapshot yet) still harvests real tool content" {
  # No snapshots seeded — a genuine first-time sync on this adapter.
  mkdir -p "$TOOL_A/skills/fresh"
  printf 'new\n' > "$TOOL_A/skills/fresh/SKILL.md"

  ADAPTER_SKILL_ROOT="$TOOL_A/skills" hub_harvest "$TOOL_A" "$HUB"

  [ -f "$HUB/skills/fresh/content.md" ]
  run cat "$HUB/skills/fresh/content.md"
  [ "$output" = "new" ]
}

@test "fan-out writes a snapshot so the next harvest skips unchanged files" {
  mkdir -p "$HUB/skills/foo"
  printf 'hub-content\n' > "$HUB/skills/foo/content.md"

  ADAPTER_SKILL_ROOT="$TOOL_A/skills" hub_fan_out "$HUB" "$TOOL_A"

  # Snapshot present + matches the tool file.
  snap="$(_hub_snapshot_path "$TOOL_A" "skills/foo/SKILL.md")"
  [ -f "$snap" ]
  cmp -s "$snap" "$TOOL_A/skills/foo/SKILL.md"

  # A follow-up harvest of an untouched tool file must not change the
  # hub — even if we overwrite the hub with a sentinel to prove the
  # cp was skipped.
  printf 'HUB-SENTINEL\n' > "$HUB/skills/foo/content.md"
  ADAPTER_SKILL_ROOT="$TOOL_A/skills" hub_harvest "$TOOL_A" "$HUB"
  run cat "$HUB/skills/foo/content.md"
  [ "$output" = "HUB-SENTINEL" ]
}
