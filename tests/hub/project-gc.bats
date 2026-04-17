#!/usr/bin/env bats
# Tests for core/hub/project-gc.sh — garbage collection of hub project
# dirs that have no live sidecar on this machine.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."

setup() {
  HOME="$(mktemp -d)"
  export HOME
  export HIVE_MIND_HUB_DIR="$HOME/.hive-mind"
  mkdir -p "$HIVE_MIND_HUB_DIR/projects"

  # Fake tool dir with one live project variant.
  TOOL="$HOME/.fake-tool"
  mkdir -p "$TOOL/projects/-variant-a"
  printf 'project-id=github.com/alice/alive\n' > "$TOOL/projects/-variant-a/.hive-mind"
  HUB_TOOL_DIRS=("$TOOL")

  # Hub has two projects: one alive, one stale.
  mkdir -p "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/memory"
  printf 'project-id=github.com/alice/alive\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/.hive-mind"
  printf '# alive\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/content.md"

  mkdir -p "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale/memory"
  printf 'project-id=github.com/bob/stale\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale/.hive-mind"
  printf '# stale\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale/content.md"

  # Use a git repo so _gc_last_touch_days can use git log.
  git -c init.defaultBranch=main init -q "$HIVE_MIND_HUB_DIR"
  git -C "$HIVE_MIND_HUB_DIR" config user.email test@example.com
  git -C "$HIVE_MIND_HUB_DIR" config user.name test
  git -C "$HIVE_MIND_HUB_DIR" add -A
  # Backdate the stale project's commit using a relative timestamp.
  local old_ts
  old_ts="$(( $(date +%s) - 60 * 86400 ))"
  GIT_AUTHOR_DATE="@$old_ts" GIT_COMMITTER_DATE="@$old_ts" \
    git -C "$HIVE_MIND_HUB_DIR" commit -q -m "old content"

  # Update the alive project (also backdated — alive survives because
  # of its sidecar, not recency).
  printf '# alive updated\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/content.md"
  git -C "$HIVE_MIND_HUB_DIR" add -A
  GIT_AUTHOR_DATE="@$old_ts" GIT_COMMITTER_DATE="@$old_ts" \
    git -C "$HIVE_MIND_HUB_DIR" commit -q -m "alive update (also old)"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/core/hub/project-gc.sh"
}

teardown() {
  rm -rf "$HOME"
}

@test "project with live sidecar is never GC'd even when stale" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=1

  # Both projects are old, but alice/alive has a live sidecar.
  hub_gc_projects >/dev/null

  [ -d "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive" ]
  [ -f "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/content.md" ]
}

@test "stale project with no sidecar is deleted under auto-delete" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=1

  hub_gc_projects >/dev/null

  [ ! -d "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale" ]
}

@test "stale project with no sidecar is reported but not deleted by default" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=0

  hub_gc_projects >/dev/null

  # Dir still exists (report-only).
  [ -d "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale" ]
  # But it was logged as a candidate.
  grep -q 'would delete.*github.com/bob/stale' "$HIVE_MIND_HUB_DIR/.sync-error.log"
}

@test "project with no sidecar but recent touch is not deleted" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=90
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=1

  # The stale project was committed ~60 days ago.
  # With threshold=90, it's too recent to delete.
  hub_gc_projects >/dev/null

  [ -d "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale" ]
}

@test "nested .hive-mind inside a project subdir does not cause GC of that subdir" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=1

  # Simulate a legacy memory/.hive-mind that got harvested into the hub.
  mkdir -p "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/memory"
  printf 'project-id=github.com/alice/alive\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/memory/.hive-mind"
  printf '# note\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/memory/note.md"
  git -C "$HIVE_MIND_HUB_DIR" add -A
  git -C "$HIVE_MIND_HUB_DIR" commit -q -m "add nested sidecar"

  hub_gc_projects >/dev/null

  # The memory subdir must NOT be deleted — it belongs to an active project.
  [ -d "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/memory" ]
  [ -f "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/memory/note.md" ]
}

@test "tool variant whose cwd still exists is kept" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1

  mkdir -p "$HOME/real-repo"
  mkdir -p "$TOOL/projects/-variant-live"
  printf '{"cwd":"%s"}\n' "$HOME/real-repo" > "$TOOL/projects/-variant-live/session.jsonl"

  hub_gc_tool_variants >/dev/null

  [ -d "$TOOL/projects/-variant-live" ]
}

@test "tool variant whose cwd is gone is removed under auto-delete" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=1

  # Variant with a sidecar pointing to a project that IS in the hub (fully harvested).
  mkdir -p "$TOOL/projects/-variant-orphan"
  printf '{"cwd":"/no/such/path/repo"}\n' > "$TOOL/projects/-variant-orphan/session.jsonl"
  printf 'project-id=github.com/alice/alive\n' > "$TOOL/projects/-variant-orphan/.hive-mind"

  hub_gc_tool_variants >/dev/null

  [ ! -d "$TOOL/projects/-variant-orphan" ]
}

@test "tool variant whose cwd is gone but has no sidecar is kept" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=1

  # No sidecar — harvest would have skipped this, content may be unharvested.
  mkdir -p "$TOOL/projects/-variant-no-sidecar"
  printf '{"cwd":"/no/such/path"}\n' > "$TOOL/projects/-variant-no-sidecar/session.jsonl"
  printf '# local only\n' > "$TOOL/projects/-variant-no-sidecar/MEMORY.md"

  hub_gc_tool_variants >/dev/null

  [ -d "$TOOL/projects/-variant-no-sidecar" ]
}

@test "tool variant whose cwd is gone is reported but not deleted by default" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=0

  mkdir -p "$TOOL/projects/-variant-orphan2"
  printf '{"cwd":"/no/such/path"}\n' > "$TOOL/projects/-variant-orphan2/session.jsonl"
  printf 'project-id=github.com/alice/alive\n' > "$TOOL/projects/-variant-orphan2/.hive-mind"

  hub_gc_tool_variants >/dev/null

  # Still exists — report-only.
  [ -d "$TOOL/projects/-variant-orphan2" ]
  grep -q 'would remove.*variant-orphan2' "$HIVE_MIND_HUB_DIR/.sync-error.log"
}

@test "tool variant whose cwd is gone but has unharvested content is kept" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1

  mkdir -p "$TOOL/projects/-variant-unharvested/memory"
  printf '{"cwd":"/no/such/path"}\n' > "$TOOL/projects/-variant-unharvested/session.jsonl"
  printf 'project-id=github.com/carol/unharvested\n' > "$TOOL/projects/-variant-unharvested/.hive-mind"
  printf '# precious memory\n' > "$TOOL/projects/-variant-unharvested/MEMORY.md"
  printf '# extra note\n' > "$TOOL/projects/-variant-unharvested/memory/note.md"

  # Hub has the project dir but is missing note.md.
  mkdir -p "$HIVE_MIND_HUB_DIR/projects/github.com/carol/unharvested"
  printf '# precious memory\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/carol/unharvested/content.md"

  hub_gc_tool_variants >/dev/null

  [ -d "$TOOL/projects/-variant-unharvested" ]
  [ -f "$TOOL/projects/-variant-unharvested/memory/note.md" ]
}

@test "tool variant GC is disabled when HIVE_MIND_HUB_PROJECT_GC_DAYS=0" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=0

  mkdir -p "$TOOL/projects/-variant-orphan"
  printf '{"cwd":"/no/such/path"}\n' > "$TOOL/projects/-variant-orphan/session.jsonl"

  hub_gc_tool_variants >/dev/null

  [ -d "$TOOL/projects/-variant-orphan" ]
}

@test "GC is disabled when HIVE_MIND_HUB_PROJECT_GC_DAYS=0" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=0
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=1

  hub_gc_projects >/dev/null

  [ -d "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale" ]
}
