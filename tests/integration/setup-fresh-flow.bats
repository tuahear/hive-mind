#!/usr/bin/env bats
# Integration tests for setup.sh fresh-install flow.
#
# Two invariants that are easy to break subtly:
#
#   1. The adapter's .gitignore / .gitattributes templates MUST win
#      over whatever older copies the remote repo already has. Remotes
#      grow stale (machine #1 set up months ago); machine #2's install
#      needs the current template's entries (e.g. .hive-mind-format
#      whitelist, new merge bindings) to land, not the remote's older
#      versions.
#
#   2. Skills install MUST route through $ADAPTER_SKILL_ROOT when the
#      adapter declares one, not a hardcoded $MEMORY_DIR/skills.
#      Otherwise adapters whose skill root lives elsewhere (future
#      non-Claude adapters) silently get their skills dropped into
#      the wrong place.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."

setup() {
  HOME="$(mktemp -d)"
  export HOME
}

teardown() {
  rm -rf "$HOME"
}

# Seed a bare remote whose content deliberately lacks some of the
# entries the current hub templates would add. If setup.sh copies
# these over the freshly-seeded hub templates (dotglob trap), the
# newer entries don't reach machine #2 — they'd stay on whatever
# shape machine #1 pushed months ago.
seed_older_remote() {
  git -c init.defaultBranch=main init -q "$HOME/seed"
  git -C "$HOME/seed" config user.email t@t.t
  git -C "$HOME/seed" config user.name t
  printf '/*\n!/.gitignore\n!/memory.md\n' > "$HOME/seed/.gitignore"
  printf '*.md merge=union\n' > "$HOME/seed/.gitattributes"
  printf 'legacy remote\n' > "$HOME/seed/memory.md"
  git -C "$HOME/seed" add .
  git -C "$HOME/seed" commit -q -m seed
  git clone -q --bare "$HOME/seed" "$HOME/remote.git"
}

@test "hub-clone flow preserves hub .gitignore and .gitattributes against an older remote" {
  # Regression: setup.sh seeds core/hub/{gitignore,gitattributes} into
  # the hub BEFORE cloning the memory repo's contents on top, and the
  # clone's dotglob copy must skip those two files so the newer hub
  # templates win. An older remote's stale copies overwriting the
  # current templates would silently drop whatever the current version
  # adds (e.g. the .hive-mind-format whitelist entry or new merge-
  # driver bindings). Pin the pattern.
  seed_older_remote

  HIVE_MIND_HUB_DIR="$HOME/test-hub"
  mkdir -p "$HIVE_MIND_HUB_DIR"

  # Seed hub templates the way setup.sh step [2/6] does.
  cp "$REPO_ROOT/core/hub/gitignore"     "$HIVE_MIND_HUB_DIR/.gitignore"
  cp "$REPO_ROOT/core/hub/gitattributes" "$HIVE_MIND_HUB_DIR/.gitattributes"

  # Mirror the hub-clone dotglob copy from setup.sh step [3/6]: skip
  # .gitignore/.gitattributes so the hub template wins.
  TMP="$(mktemp -d)"
  git clone -q "$HOME/remote.git" "$TMP/memory"
  mv "$TMP/memory/.git" "$HIVE_MIND_HUB_DIR/.git"
  shopt -s dotglob
  for f in "$TMP/memory"/*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
      .gitignore|.gitattributes) continue ;;
    esac
    cp -a "$f" "$HIVE_MIND_HUB_DIR/" 2>/dev/null || true
  done
  shopt -u dotglob
  rm -rf "$TMP"

  # Hub template entries survive the copy:
  grep -q 'hive-mind-format' "$HIVE_MIND_HUB_DIR/.gitignore"
  grep -q 'memory.md' "$HIVE_MIND_HUB_DIR/.gitattributes"
  # Non-template remote content still landed.
  grep -q 'legacy remote' "$HIVE_MIND_HUB_DIR/memory.md"
}

@test "manage_bundled_skills seeds the adapter's bundled skills into \$HIVE_MIND_HUB_DIR/skills/" {
  # Under the hub topology (v0.3.0+) bundled skills land in the hub's
  # canonical skills/ tree, not the adapter's own skill root. Fan-out
  # then routes them back into the tool's native skill dir on the next
  # sync cycle. This test pins the hub side — the tool-side delivery is
  # covered by tests/hub/cross-machine.bats "skill installed on machine
  # A fans out to machine B".
  ADAPTER_ROOT="$REPO_ROOT/adapters/claude-code"
  export ADAPTER_ROOT
  # shellcheck disable=SC1090
  source "$REPO_ROOT/core/adapter-loader.sh"
  load_adapter "claude-code"

  HIVE_MIND_SRC="$REPO_ROOT"
  HIVE_MIND_HUB_DIR="$HOME/.hive-mind"
  mkdir -p "$HIVE_MIND_HUB_DIR" "$ADAPTER_DIR"
  ADAPTER="claude-code"
  # Stub log so extracted setup function doesn't hit macOS /usr/bin/log.
  log() { :; }

  eval "$(awk '/^manage_bundled_skills\(\)/,/^}/' "$REPO_ROOT/setup.sh")"
  manage_bundled_skills

  [ -d "$HIVE_MIND_HUB_DIR/skills/hive-mind" ]
  [ -f "$HIVE_MIND_HUB_DIR/skills/hive-mind/SKILL.md" ]
}

@test "manage_bundled_skills removes the legacy memory-commit skill under the tool dir" {
  # Pre-0.3 installs shipped the hive-mind skill under the tool's
  # skills/memory-commit/. Upgrades must delete it to avoid a collision
  # with the renamed skills/hive-mind/ that fan-out will write to the
  # tool dir on the next sync.
  ADAPTER_ROOT="$REPO_ROOT/adapters/claude-code"
  export ADAPTER_ROOT
  # shellcheck disable=SC1090
  source "$REPO_ROOT/core/adapter-loader.sh"
  load_adapter "claude-code"

  HIVE_MIND_SRC="$REPO_ROOT"
  HIVE_MIND_HUB_DIR="$HOME/.hive-mind"
  mkdir -p "$HIVE_MIND_HUB_DIR" "$ADAPTER_DIR/skills/memory-commit"
  echo "legacy" > "$ADAPTER_DIR/skills/memory-commit/SKILL.md"
  ADAPTER="claude-code"
  log() { :; }

  eval "$(awk '/^manage_bundled_skills\(\)/,/^}/' "$REPO_ROOT/setup.sh")"
  manage_bundled_skills

  [ ! -d "$ADAPTER_DIR/skills/memory-commit" ]
}
