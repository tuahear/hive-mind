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
  export HUB_TOOL_DIRS=("$TOOL")

  # Hub has two projects: one alive, one stale.
  mkdir -p "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/memory"
  printf 'project-id=github.com/alice/alive\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/.hive-mind"
  printf '# alive\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/content.md"

  mkdir -p "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale/memory"
  printf 'project-id=github.com/bob/stale\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale/.hive-mind"
  printf '# stale\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale/content.md"

  # Make stale project look old (touch files 60 days ago).
  # Use a git repo so _gc_last_touch_days can use git log.
  git -c init.defaultBranch=main init -q "$HIVE_MIND_HUB_DIR"
  git -C "$HIVE_MIND_HUB_DIR" config user.email test@example.com
  git -C "$HIVE_MIND_HUB_DIR" config user.name test
  git -C "$HIVE_MIND_HUB_DIR" add -A
  # Backdate the stale project's commit.
  GIT_AUTHOR_DATE="2026-02-01T00:00:00Z" GIT_COMMITTER_DATE="2026-02-01T00:00:00Z" \
    git -C "$HIVE_MIND_HUB_DIR" commit -q -m "old content"

  # Add the alive project with a recent commit.
  printf '# alive updated\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/content.md"
  git -C "$HIVE_MIND_HUB_DIR" add -A
  git -C "$HIVE_MIND_HUB_DIR" commit -q -m "recent update"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/core/hub/project-gc.sh"
}

teardown() {
  rm -rf "$HOME"
}

@test "project with live sidecar is never GC'd" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=1

  hub_gc_projects

  [ -d "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive" ]
  [ -f "$HIVE_MIND_HUB_DIR/projects/github.com/alice/alive/content.md" ]
}

@test "stale project with no sidecar is deleted under auto-delete" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=1

  hub_gc_projects

  [ ! -d "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale" ]
}

@test "stale project with no sidecar is reported but not deleted by default" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=0

  hub_gc_projects

  # Dir still exists (report-only).
  [ -d "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale" ]
  # But it was logged as a candidate.
  grep -q 'would delete.*github.com/bob/stale' "$HIVE_MIND_HUB_DIR/.sync-error.log"
}

@test "project with no sidecar but recent touch is not deleted" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=90
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=1

  # The stale project was committed on 2026-02-01 (~75 days ago).
  # With threshold=90, it's too recent to delete.
  hub_gc_projects

  [ -d "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale" ]
}

@test "tool variant whose cwd still exists is kept" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1

  # Variant points to a cwd that exists.
  mkdir -p "$HOME/real-repo"
  mkdir -p "$TOOL/projects/-variant-live"
  printf '{"cwd":"%s"}\n' "$HOME/real-repo" > "$TOOL/projects/-variant-live/session.jsonl"

  hub_gc_tool_variants

  [ -d "$TOOL/projects/-variant-live" ]
}

@test "tool variant whose cwd is gone is removed" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1

  # Variant points to a cwd that does NOT exist.
  mkdir -p "$TOOL/projects/-variant-orphan"
  printf '{"cwd":"/no/such/path/repo"}\n' > "$TOOL/projects/-variant-orphan/session.jsonl"

  hub_gc_tool_variants

  [ ! -d "$TOOL/projects/-variant-orphan" ]
}

@test "tool variant whose cwd is gone but has unharvested content is kept" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=1

  # Variant has content not yet in the hub.
  mkdir -p "$TOOL/projects/-variant-unharvested/memory"
  printf '{"cwd":"/no/such/path"}\n' > "$TOOL/projects/-variant-unharvested/session.jsonl"
  printf 'project-id=github.com/carol/unharvested\n' > "$TOOL/projects/-variant-unharvested/.hive-mind"
  printf '# precious memory\n' > "$TOOL/projects/-variant-unharvested/MEMORY.md"
  printf '# extra note\n' > "$TOOL/projects/-variant-unharvested/memory/note.md"

  # Hub has the project dir but is missing note.md.
  mkdir -p "$HIVE_MIND_HUB_DIR/projects/github.com/carol/unharvested"
  printf '# precious memory\n' > "$HIVE_MIND_HUB_DIR/projects/github.com/carol/unharvested/content.md"
  # No memory/note.md in hub.

  hub_gc_tool_variants

  # Must be kept — hub is missing memory/note.md.
  [ -d "$TOOL/projects/-variant-unharvested" ]
  [ -f "$TOOL/projects/-variant-unharvested/memory/note.md" ]
}

@test "tool variant GC is disabled when HIVE_MIND_HUB_PROJECT_GC_DAYS=0" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=0

  mkdir -p "$TOOL/projects/-variant-orphan"
  printf '{"cwd":"/no/such/path"}\n' > "$TOOL/projects/-variant-orphan/session.jsonl"

  hub_gc_tool_variants

  # Orphan still exists — GC disabled.
  [ -d "$TOOL/projects/-variant-orphan" ]
}

@test "GC is disabled when HIVE_MIND_HUB_PROJECT_GC_DAYS=0" {
  export HIVE_MIND_HUB_PROJECT_GC_DAYS=0
  export HIVE_MIND_HUB_PROJECT_GC_AUTO=1

  hub_gc_projects

  # Stale project still exists — GC was disabled.
  [ -d "$HIVE_MIND_HUB_DIR/projects/github.com/bob/stale" ]
}
