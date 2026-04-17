#!/usr/bin/env bats
# The hub sync engine MUST bootstrap project-id sidecars (via
# core/mirror-projects.sh) before running hub_harvest on flat-layout
# adapters. Otherwise a fresh install with existing per-project memory
# silently does nothing — harvest skips variants whose sidecar is
# absent, so the hub's projects/<id>/ tree stays empty and cross-
# machine per-project sync never materializes.
#
# Regression for v0.3.0 Copilot review round 2.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
HUB_SYNC="$REPO_ROOT/core/hub/sync.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME

  TEST_ADAPTERS_DIR="$HOME/_adapters"
  mkdir -p "$TEST_ADAPTERS_DIR/fake"
  cp "$REPO_ROOT/tests/fixtures/adapters/fake/"* "$TEST_ADAPTERS_DIR/fake/"
  export HIVE_MIND_ADAPTERS_DIR="$TEST_ADAPTERS_DIR"
  export FAKE_ADAPTER_HOME="$HOME"

  git -c init.defaultBranch=main init -q "$HOME/seed"
  git -C "$HOME/seed" config user.email t@t.t
  git -C "$HOME/seed" config user.name t
  printf 'seed\n' > "$HOME/seed/seed.md"
  git -C "$HOME/seed" add seed.md
  git -C "$HOME/seed" commit -q -m seed
  git clone -q --bare "$HOME/seed" "$HOME/remote.git"

  HUB="$HOME/.hive-mind"
  export HIVE_MIND_HUB_DIR="$HUB"
  git clone -q "$HOME/remote.git" "$HUB"
  git -C "$HUB" config user.email t@t.t
  git -C "$HUB" config user.name t
  cp "$REPO_ROOT/core/hub/gitignore"     "$HUB/.gitignore"
  cp "$REPO_ROOT/core/hub/gitattributes" "$HUB/.gitattributes"
  printf 'format-version=1\n' > "$HUB/.hive-mind-format"
  git -C "$HUB" add .gitignore .gitattributes .hive-mind-format
  git -C "$HUB" commit -q -m "seed hub whitelist"
  git -C "$HUB" push -q

  mkdir -p "$HUB/.install-state"
  printf 'fake\n' > "$HUB/.install-state/attached-adapters"
  mkdir -p "$HOME/.fake-tool"
}

teardown() {
  rm -rf "$HOME"
}

run_sync() {
  HIVE_MIND_HUB_DIR="$HUB" bash "$HUB_SYNC"
}

@test "fresh install: per-project memory with no sidecar yet reaches the hub on the first sync" {
  # Simulate a fresh install where a user previously had a Claude
  # session in a git-backed project. mirror-projects would normally
  # write the sidecar on the first Stop hook — the hub engine must
  # run mirror-projects BEFORE hub_harvest so harvest doesn't skip
  # this variant.
  proj_dir="$HOME/myrepo"
  git -c init.defaultBranch=main init -q "$proj_dir"
  git -C "$proj_dir" remote add origin git@github.com:Owner/MyRepo.git

  variant="$HOME/.fake-tool/projects/-Users-alice-myrepo"
  mkdir -p "$variant"
  # Session jsonl that mirror-projects reads to derive the project-id.
  printf '{"cwd":"%s"}\n' "$proj_dir" > "$variant/session.jsonl"
  # Real memory content so mirror's content-gate fires (content-less
  # variants are intentionally left alone; exercising the gate matters
  # here because the fake adapter uses MEMORY.md as the per-project
  # memory file — same shape as Claude).
  printf '# project notes\n' > "$variant/MEMORY.md"

  # Sanity: sidecar doesn't exist yet.
  [ ! -f "$variant/.hive-mind" ]

  run run_sync
  [ "$status" -eq 0 ]

  # After the sync, the sidecar was bootstrapped...
  [ -f "$variant/.hive-mind" ]
  grep -Fq "project-id=github.com/owner/myrepo" "$variant/.hive-mind"

  # ...AND the per-project memory reached the hub under the normalized
  # remote ID. Without the pre-harvest mirror-projects call, the
  # harvest loop would skip the sidecar-less variant and this assertion
  # would fail silently.
  hub_proj="$HUB/projects/github.com/owner/myrepo"
  [ -f "$hub_proj/content.md" ]
  grep -q '# project notes' "$hub_proj/content.md"

  # Actually reach the remote — the hub gitignore's project-whitelist
  # must allow multi-level project-ids (normalized git remotes
  # routinely contain slashes). A regression to a single-level-only
  # whitelist would leave the file in the hub working tree but skip
  # it on `git add -A`, silently failing to propagate to other
  # machines. This assertion catches that class of bug.
  run git -C "$HOME/remote.git" show "HEAD:projects/github.com/owner/myrepo/content.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"# project notes"* ]]
}

@test "hierarchical-memory-model adapters are not touched by the mirror-projects pre-pass" {
  # The mirror-projects script early-exits when projects/ is absent
  # under the tool dir, which is exactly the shape a hierarchical-
  # model adapter (Codex / Kimi / Qwen, once they ship) presents.
  # Pin the no-op: a hierarchical-model attached adapter with no
  # projects/ tree must not cause the sync to fail or to create stray
  # files under the tool dir just because mirror-projects was invoked.
  # Hand-edit the fake adapter's memory-model to hierarchical for this
  # test and also provide the function declaration that model requires.
  sed -i.bak 's|^ADAPTER_MEMORY_MODEL="flat"|ADAPTER_MEMORY_MODEL="hierarchical"|' \
    "$TEST_ADAPTERS_DIR/fake/adapter.sh"
  rm -f "$TEST_ADAPTERS_DIR/fake/adapter.sh.bak"

  printf 'content only in tool dir\n' > "$HOME/.fake-tool/MEMORY.md"
  [ ! -d "$HOME/.fake-tool/projects" ]

  run run_sync
  [ "$status" -eq 0 ]

  # No projects/ tree got created by accident.
  [ ! -d "$HOME/.fake-tool/projects" ]
  # Top-level harvest still ran.
  grep -q 'content only in tool dir' "$HUB/content.md"
}

@test "empty variant gets sidecar when hub already has that project-id" {
  # Scenario: machine B creates a project variant (first session), but
  # the variant is empty — no MEMORY.md, no memory/ files. The hub
  # already has content for this project-id from machine A. Mirror-
  # projects must still create the sidecar so fan-out can populate it.
  variant="$HOME/.fake-tool/projects/-machine-b-variant"
  mkdir -p "$variant/memory"
  # Create a git repo at the cwd so derive_id_from_cwd works.
  mkdir -p "$HOME/myrepo"
  git -c init.defaultBranch=main init -q "$HOME/myrepo"
  git -C "$HOME/myrepo" remote add origin "https://github.com/test/myrepo.git"
  printf '{"cwd":"%s"}\n' "$HOME/myrepo" > "$variant/session.jsonl"
  # NO content in variant — empty.

  # Hub already has content for this project-id (from machine A).
  hub_proj="$HUB/projects/github.com/test/myrepo"
  mkdir -p "$hub_proj/memory"
  printf '# from machine A\n' > "$hub_proj/content.md"
  printf '# machine A feedback\n' > "$hub_proj/memory/note.md"
  printf 'project-id=github.com/test/myrepo\n' > "$hub_proj/.hive-mind"
  git -C "$HUB" add -A && git -C "$HUB" commit -q -m "machine A content"
  git -C "$HUB" push -q

  run run_sync
  [ "$status" -eq 0 ]

  # Sidecar must have been created despite empty variant.
  [ -f "$variant/.hive-mind" ]
  grep -q 'github.com/test/myrepo' "$variant/.hive-mind"
  # Fan-out must have populated the variant.
  [ -f "$variant/MEMORY.md" ]
  grep -q 'from machine A' "$variant/MEMORY.md"
}

@test "sync.sh gates mirror-projects on flat memory model so hierarchical adapters don't invoke it" {
  # Implementation-level pin: the conditional in core/hub/sync.sh must
  # key off ADAPTER_MEMORY_MODEL="flat" before running mirror-projects.
  # A future refactor that drops the gate would invoke mirror-projects
  # on every attached adapter — a noisy no-op for hierarchical ones
  # and a potential confusing log line on real adapters when users
  # debug sync issues. Pin the gate in source.
  grep -Fq 'ADAPTER_MEMORY_MODEL' "$HUB_SYNC"
  grep -Fq '= "flat"' "$HUB_SYNC"
  grep -Fq 'MIRROR_PROJECTS' "$HUB_SYNC"
}
