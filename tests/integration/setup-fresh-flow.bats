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
  printf '/*\n!/.gitignore\n!/content.md\n' > "$HOME/seed/.gitignore"
  printf '*.md merge=union\n' > "$HOME/seed/.gitattributes"
  printf 'legacy remote\n' > "$HOME/seed/content.md"
  git -C "$HOME/seed" add .
  git -C "$HOME/seed" commit -q -m seed
  git clone -q --bare "$HOME/seed" "$HOME/remote.git"
}

@test "second-machine install preserves remote hub content instead of overwriting with stale tool files" {
  # Regression: on a second-machine install, the hub remote already has
  # content from machine 1. If sidecars aren't bootstrapped before
  # fan-out, fan-out skips all project variants → the tool keeps its
  # stale content → harvest pushes old content and destroys memory.
  #
  # Simulate: remote has machine-1 project memory; tool dir has older
  # stale content. After setup, hub must still have machine-1 content.

  # Build a remote with machine-1 project content.
  git -c init.defaultBranch=main init -q "$HOME/seed"
  git -C "$HOME/seed" config user.email test@example.com
  git -C "$HOME/seed" config user.name t
  cp "$REPO_ROOT/core/hub/gitignore"     "$HOME/seed/.gitignore"
  cp "$REPO_ROOT/core/hub/gitattributes" "$HOME/seed/.gitattributes"
  printf 'format-version=1\n' > "$HOME/seed/.hive-mind-format"
  printf '# machine-1 global memory\n' > "$HOME/seed/content.md"
  mkdir -p "$HOME/seed/projects/github.com/test/repo/memory"
  printf '# machine-1 project index — must survive\n' > "$HOME/seed/projects/github.com/test/repo/content.md"
  printf '# machine-1 feedback — must survive\n' > "$HOME/seed/projects/github.com/test/repo/memory/feedback.md"
  git -C "$HOME/seed" add .
  git -C "$HOME/seed" commit -q -m "machine-1 content"
  git clone -q --bare "$HOME/seed" "$HOME/remote.git"

  # Machine-2 tool dir: has a project variant mapping to the same
  # project-id, but with OLDER/DIFFERENT content.
  export FAKE_ADAPTER_HOME="$HOME"
  export HIVE_MIND_ADAPTERS_DIR="$REPO_ROOT/tests/fixtures/adapters"
  ADAPTER_DIR="$HOME/.fake-tool"
  mkdir -p "$ADAPTER_DIR/projects/-machine-2-variant/memory"
  # Fake jsonl so derive_id_from_cwd can find the project-id.
  # Create a git repo at the fake cwd so sidecar bootstrap can derive remote.
  mkdir -p "$HOME/repo"
  git -c init.defaultBranch=main init -q "$HOME/repo"
  git -C "$HOME/repo" remote add origin "https://github.com/test/repo.git"
  printf '{"cwd":"%s"}\n' "$HOME/repo" > "$ADAPTER_DIR/projects/-machine-2-variant/session.jsonl"
  printf '# machine-2 stale project index\n' > "$ADAPTER_DIR/projects/-machine-2-variant/MEMORY.md"
  printf '# machine-2 stale feedback\n' > "$ADAPTER_DIR/projects/-machine-2-variant/memory/feedback.md"

  # Run the setup flow: source the helpers, pull, bootstrap, fan-out, harvest.
  source "$REPO_ROOT/core/hub/harvest-fanout.sh"
  source "$REPO_ROOT/core/adapter-loader.sh"
  load_adapter "fake"
  export ADAPTER_DIR

  HUB="$HOME/.hive-mind"
  export HIVE_MIND_HUB_DIR="$HUB"
  git clone -q "$HOME/remote.git" "$HUB"
  git -C "$HUB" config user.email test@example.com
  git -C "$HUB" config user.name t

  # Simulate setup.sh order: pull → sidecar bootstrap → fan-out → harvest
  ADAPTER_DIR="$ADAPTER_DIR" "$REPO_ROOT/core/mirror-projects.sh" || true
  hub_fan_out "$HUB" "$ADAPTER_DIR"
  hub_harvest "$ADAPTER_DIR" "$HUB"

  # Machine-1 content must survive — not overwritten by machine-2 stale files.
  grep -q 'machine-1 project index — must survive' "$HUB/projects/github.com/test/repo/content.md"
  grep -q 'machine-1 feedback — must survive' "$HUB/projects/github.com/test/repo/memory/feedback.md"
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
  grep -q 'content.md' "$HIVE_MIND_HUB_DIR/.gitattributes"
  # Non-template remote content still landed.
  grep -q 'legacy remote' "$HIVE_MIND_HUB_DIR/content.md"
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
  [ -f "$HIVE_MIND_HUB_DIR/skills/hive-mind/content.md" ]
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
