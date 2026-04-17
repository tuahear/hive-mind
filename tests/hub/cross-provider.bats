#!/usr/bin/env bats
# Two different adapters attached to one hub on the same machine.
# Simulates the v0.3.0 cross-provider value prop: edit memory via
# adapter A's tool dir, run the hub sync, adapter B's tool dir picks
# up the same content under its native name. The two fake adapters
# map the canonical `content.md` to different tool-native filenames
# (`MEMORY.md` vs `NOTES.md`) so a round-trip failure is observable
# at the tool-dir level, not just the hub level.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
HUB_SYNC="$REPO_ROOT/core/hub/sync.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME

  # Stage both fake adapters into a temp adapters dir so the loader
  # finds them via HIVE_MIND_ADAPTERS_DIR without mutating the real
  # adapters/ tree.
  TEST_ADAPTERS_DIR="$HOME/_adapters"
  mkdir -p "$TEST_ADAPTERS_DIR/fake" "$TEST_ADAPTERS_DIR/fake-b"
  cp "$REPO_ROOT/tests/fixtures/adapters/fake/"*   "$TEST_ADAPTERS_DIR/fake/"
  cp "$REPO_ROOT/tests/fixtures/adapters/fake-b/"* "$TEST_ADAPTERS_DIR/fake-b/"
  export HIVE_MIND_ADAPTERS_DIR="$TEST_ADAPTERS_DIR"
  export FAKE_ADAPTER_HOME="$HOME"
  export FAKE_B_ADAPTER_HOME="$HOME"

  # Seed a bare remote + hub clone.
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
  # Attach BOTH adapters — this is the whole point of this test file.
  printf 'fake\nfake-b\n' > "$HUB/.install-state/attached-adapters"

  mkdir -p "$HOME/.fake-tool" "$HOME/.fake-b-tool"
}

teardown() {
  rm -rf "$HOME"
}

run_sync() {
  HIVE_MIND_HUB_DIR="$HUB" bash "$HUB_SYNC"
}

# === tests =================================================================

@test "edit via adapter A's tool dir surfaces in adapter B's tool dir with the B-native name" {
  # User edits memory via the fake adapter's native MEMORY.md.
  printf '# shared memory from fake-a\n' > "$HOME/.fake-tool/MEMORY.md"

  run run_sync
  [ "$status" -eq 0 ]

  # Hub stores it under the canonical lowercase name.
  [ -f "$HUB/content.md" ]
  grep -q '# shared memory from fake-a' "$HUB/content.md"

  # fake-b's tool dir got it under its B-native name (NOTES.md, NOT
  # MEMORY.md — that's the cross-provider name remap).
  [ -f "$HOME/.fake-b-tool/NOTES.md" ]
  grep -q '# shared memory from fake-a' "$HOME/.fake-b-tool/NOTES.md"
  # And fake-a's MEMORY.md is still there (sanity — fan-out didn't clobber it).
  [ -f "$HOME/.fake-tool/MEMORY.md" ]
}

@test "edit via adapter B's tool dir flows back to adapter A's tool dir" {
  # Reverse direction: edit via fake-b's native NOTES.md.
  printf 'from fake-b\n' > "$HOME/.fake-b-tool/NOTES.md"

  run run_sync
  [ "$status" -eq 0 ]

  # Hub has canonical content...
  grep -q 'from fake-b' "$HUB/content.md"
  # ...and fake-a's MEMORY.md received it via fan-out.
  [ -f "$HOME/.fake-tool/MEMORY.md" ]
  grep -q 'from fake-b' "$HOME/.fake-tool/MEMORY.md"
}

@test "skill installed via adapter A is visible to adapter B after sync" {
  mkdir -p "$HOME/.fake-tool/skills/shared-skill"
  cat > "$HOME/.fake-tool/skills/shared-skill/SKILL.md" <<'EOF'
---
name: shared-skill
description: works for both fakes
---
body
EOF

  run run_sync
  [ "$status" -eq 0 ]

  [ -f "$HUB/skills/shared-skill/content.md" ]
  [ -f "$HOME/.fake-b-tool/skills/shared-skill/SKILL.md" ]
  grep -q 'works for both fakes' "$HOME/.fake-b-tool/skills/shared-skill/SKILL.md"
}

# NOTE: concurrent edits to the SAME hub path from two attached
# adapters in the SAME sync cycle are not guaranteed to union — the
# per-adapter harvest phase is last-writer-wins at the hub level (no
# git commit between adapters' harvest passes, so the union merge
# driver doesn't get a chance to kick in). Cross-MACHINE concurrent
# edits do union correctly — see tests/hub/cross-machine.bats
# "concurrent edits on two machines are both preserved". For realistic
# use (user edits one tool's memory at a time), last-writer-wins is
# harmless; the constraint is documented here as the behavior pin.

@test "secret file declared by one adapter is gated on push even if the other adapter would allow it" {
  # Regression guard for the hub sync's secret-file gate being the
  # UNION of every attached adapter's ADAPTER_SECRET_FILES. Re-declare
  # fake's secret list to include a file both tool dirs might contain;
  # the hub must refuse to push it regardless of which adapter
  # harvested it.
  #
  # (The shipped fake fixtures have ADAPTER_SECRET_FILES="" — inject a
  # rule by patching the fixture copy in this test's staging dir.)
  sed -i.bak 's|^ADAPTER_SECRET_FILES=""|ADAPTER_SECRET_FILES="secret.txt"|' \
    "$TEST_ADAPTERS_DIR/fake/adapter.sh"
  rm -f "$TEST_ADAPTERS_DIR/fake/adapter.sh.bak"

  printf 'super secret\n' > "$HOME/.fake-tool/secret.txt"
  printf 'ok\n'          > "$HOME/.fake-tool/MEMORY.md"

  run run_sync
  [ "$status" -eq 0 ]

  # secret.txt reached the local tool dir (never harvested in the first
  # place — it isn't in ADAPTER_HUB_MAP) but must not have reached the
  # hub's git history.
  run git -C "$HUB" log --all --oneline -- secret.txt
  [ -z "$output" ]
  # MEMORY.md's content DID cross to fake-b, confirming the sync ran.
  grep -q '^ok$' "$HOME/.fake-b-tool/NOTES.md"
}
