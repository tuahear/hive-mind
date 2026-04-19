#!/usr/bin/env bats
# Two machines sharing one memory remote.
# Simulates the v0.3.0 value prop: edit memory on machine A, run sync;
# machine B runs sync and sees the update in its tool dir.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
HUB_SYNC="$REPO_ROOT/core/hub/sync.sh"

setup_machine() {
  # Builds a full hub install for a single machine under $1.
  # Env vars accumulated:
  #   <M>_HOME, <M>_HUB, <M>_TOOL
  local M="$1"
  local machine_home="$HOME/$M"
  mkdir -p "$machine_home"

  # Point the fake adapter at this machine's home.
  local hub="$machine_home/.hive-mind"
  local tool="$machine_home/.fake-tool"
  mkdir -p "$tool"

  git clone -q "$HOME/remote.git" "$hub"
  git -C "$hub" config user.email "$M@m.m"
  git -C "$hub" config user.name "$M"
  # Seed whitelist (fresh clone may or may not have it; overwrite so
  # stale blobs from a prior machine's commit don't break subsequent
  # whitelist assertions).
  cp "$REPO_ROOT/core/hub/gitignore"     "$hub/.gitignore"
  cp "$REPO_ROOT/core/hub/gitattributes" "$hub/.gitattributes"
  [ -f "$hub/.hive-mind-format" ] || printf 'format-version=1\n' > "$hub/.hive-mind-format"

  mkdir -p "$hub/.install-state"
  printf 'fake\n' > "$hub/.install-state/attached-adapters"

  # Stage any changes so the first sync isn't trapped by "dirty".
  # `git status --porcelain` can flag files as dirty purely because
  # of autocrlf normalization (Windows: LF in working tree but index
  # would write CRLF, or vice versa). `git add -A` then stages
  # nothing content-wise, so `git commit` exits non-zero. Tolerate
  # the no-op commit and keep going.
  if [ -n "$(git -C "$hub" status --porcelain 2>/dev/null)" ]; then
    git -C "$hub" add -A
    if ! git -C "$hub" diff --cached --quiet; then
      git -C "$hub" commit -q -m "seed whitelist for $M"
      git -C "$hub" push -q 2>/dev/null || true
    fi
  fi

  eval "${M}_HOME=\"$machine_home\""
  eval "${M}_HUB=\"$hub\""
  eval "${M}_TOOL=\"$tool\""
}

run_sync_on() {
  local machine_hub="$1"
  local machine_home
  machine_home="$(dirname "$machine_hub")"
  # Redirect FAKE_ADAPTER_HOME so the fake adapter's ADAPTER_DIR points
  # at THIS machine's tool dir for the duration of the sync.
  # Disable the git-fetch throttle so each run_sync_on actually talks
  # to the remote — tests simulate rapid back-to-back cross-machine
  # syncs, which the production 30s throttle would collapse into a
  # single network round trip.
  FAKE_ADAPTER_HOME="$machine_home" \
  HIVE_MIND_HUB_DIR="$machine_hub" \
  HIVE_MIND_ADAPTERS_DIR="$HIVE_MIND_ADAPTERS_DIR" \
  HIVE_MIND_FORCE_PUSH=1 \
  HIVE_MIND_MIN_FETCH_INTERVAL_SEC=0 \
    bash "$HUB_SYNC"
}

setup() {
  HOME="$(mktemp -d)"
  export HOME

  TEST_ADAPTERS_DIR="$HOME/_adapters"
  mkdir -p "$TEST_ADAPTERS_DIR/fake"
  cp "$REPO_ROOT/tests/fixtures/adapters/fake/"* "$TEST_ADAPTERS_DIR/fake/"
  export HIVE_MIND_ADAPTERS_DIR="$TEST_ADAPTERS_DIR"

  # Seed a shared bare remote — both machines clone from it.
  git -c init.defaultBranch=main init -q "$HOME/seed"
  git -C "$HOME/seed" config user.email t@t.t
  git -C "$HOME/seed" config user.name t
  printf 'seed\n' > "$HOME/seed/seed.md"
  git -C "$HOME/seed" add -A
  git -C "$HOME/seed" commit -q -m seed
  git clone -q --bare "$HOME/seed" "$HOME/remote.git"

  setup_machine mA
  setup_machine mB
}

teardown() {
  rm -rf "$HOME"
}

# === tests =================================================================

@test "machine A edits memory, syncs; machine B syncs and sees the edit" {
  # Precondition: both machines start with empty MEMORY.md (nothing
  # harvested yet).
  [ ! -f "$mA_TOOL/MEMORY.md" ]
  [ ! -f "$mB_TOOL/MEMORY.md" ]

  # User on machine A adds memory.
  printf '# note from machine A\n' > "$mA_TOOL/MEMORY.md"
  run run_sync_on "$mA_HUB"
  [ "$status" -eq 0 ]

  # Machine A's hub got the canonical form.
  grep -q '# note from machine A' "$mA_HUB/content.md"

  # Machine B runs its sync (no local edits, just pulling from remote).
  run run_sync_on "$mB_HUB"
  [ "$status" -eq 0 ]

  # Machine B's tool dir now has the note — with A's content, under
  # the tool-native name (MEMORY.md, not the canonical memory.md).
  [ -f "$mB_TOOL/MEMORY.md" ]
  grep -q '# note from machine A' "$mB_TOOL/MEMORY.md"
}

@test "concurrent edits on two machines are both preserved after a sync cycle" {
  # Machine A starts with content; syncs.
  printf 'alpha\n' > "$mA_TOOL/MEMORY.md"
  run run_sync_on "$mA_HUB"
  [ "$status" -eq 0 ]

  # Machine B syncs and picks up A's content.
  run run_sync_on "$mB_HUB"
  [ "$status" -eq 0 ]
  grep -q '^alpha$' "$mB_TOOL/MEMORY.md"

  # Both machines edit concurrently (add different lines to the
  # same file). The union merge driver on content.md (declared in
  # core/hub/gitattributes) concatenates both sides on conflict.
  printf 'alpha\ndelta-A\n' > "$mA_TOOL/MEMORY.md"
  printf 'alpha\nbeta-B\n'  > "$mB_TOOL/MEMORY.md"

  run run_sync_on "$mA_HUB"
  [ "$status" -eq 0 ]
  run run_sync_on "$mB_HUB"
  [ "$status" -eq 0 ]

  # Machine B's sync pulled A's commit and rebased local edits on top.
  # After the final push + another pull, both lines should be on both
  # machines. One more cross-pollinate for A.
  run run_sync_on "$mA_HUB"
  [ "$status" -eq 0 ]

  for tool in "$mA_TOOL/MEMORY.md" "$mB_TOOL/MEMORY.md"; do
    grep -q 'delta-A' "$tool"
    grep -q 'beta-B'  "$tool"
  done
}

@test "skill installed on machine A fans out to machine B after sync" {
  mkdir -p "$mA_TOOL/skills/my-skill"
  cat > "$mA_TOOL/skills/my-skill/SKILL.md" <<'EOF'
---
name: my-skill
description: shared skill
---
body
EOF

  run run_sync_on "$mA_HUB"
  [ "$status" -eq 0 ]

  [ -f "$mA_HUB/skills/my-skill/content.md" ]

  run run_sync_on "$mB_HUB"
  [ "$status" -eq 0 ]

  [ -f "$mB_TOOL/skills/my-skill/SKILL.md" ]
  grep -q 'shared skill' "$mB_TOOL/skills/my-skill/SKILL.md"
}
