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
# entries a current adapter template would add. If setup.sh copies
# these over the freshly-seeded templates (dotglob trap), the newer
# entries don't reach machine #2.
seed_older_remote() {
  git -c init.defaultBranch=main init -q "$HOME/seed"
  git -C "$HOME/seed" config user.email t@t.t
  git -C "$HOME/seed" config user.name t
  printf '/*\n!/.gitignore\n!/CLAUDE.md\n' > "$HOME/seed/.gitignore"
  printf '*.md merge=union\n' > "$HOME/seed/.gitattributes"
  printf 'legacy remote\n' > "$HOME/seed/CLAUDE.md"
  git -C "$HOME/seed" add .
  git -C "$HOME/seed" commit -q -m seed
  git clone -q --bare "$HOME/seed" "$HOME/remote.git"
}

@test "fresh flow preserves adapter .gitignore and .gitattributes against an older remote" {
  seed_older_remote

  ADAPTER_ROOT="$REPO_ROOT/adapters/claude-code"
  export ADAPTER_ROOT
  # shellcheck disable=SC1090
  source "$REPO_ROOT/core/adapter-loader.sh"
  load_adapter "claude-code"

  ADAPTER_DIR="$HOME/test-claude"
  MEMORY_DIR="$ADAPTER_DIR"
  mkdir -p "$MEMORY_DIR"

  # Seed templates the way setup.sh step [2/5] does.
  cp "$ADAPTER_GITIGNORE_TEMPLATE"     "$MEMORY_DIR/.gitignore"
  cp "$ADAPTER_GITATTRIBUTES_TEMPLATE" "$MEMORY_DIR/.gitattributes"

  # Mirror the fresh-flow dotglob copy from setup.sh: skip
  # .gitignore/.gitattributes so the adapter template wins.
  TMP="$(mktemp -d)"
  git clone -q "$HOME/remote.git" "$TMP/memory"
  mv "$TMP/memory/.git" "$MEMORY_DIR/.git"
  shopt -s dotglob
  for f in "$TMP/memory"/*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
      .gitignore|.gitattributes) continue ;;
    esac
    cp -a "$f" "$MEMORY_DIR/" 2>/dev/null || true
  done
  shopt -u dotglob
  rm -rf "$TMP"

  # Adapter template entries survive the copy:
  grep -q 'hive-mind-format' "$MEMORY_DIR/.gitignore"
  grep -q 'jsonmerge' "$MEMORY_DIR/.gitattributes"
  # Non-template remote content still landed:
  grep -q 'legacy remote' "$MEMORY_DIR/CLAUDE.md"
}

@test "skills install routes through ADAPTER_SKILL_ROOT when the adapter declares one" {
  ADAPTER_ROOT="$REPO_ROOT/adapters/claude-code"
  export ADAPTER_ROOT
  # shellcheck disable=SC1090
  source "$REPO_ROOT/core/adapter-loader.sh"
  load_adapter "claude-code"

  # Skill root pointed OUTSIDE $MEMORY_DIR: if manage_claude_skills
  # falls back to the hardcoded $MEMORY_DIR/skills, the skills land
  # in the wrong place and this test catches it.
  MEMORY_DIR="$HOME/test-claude"
  ADAPTER_SKILL_ROOT="$HOME/custom-skills-root"
  mkdir -p "$MEMORY_DIR"

  HIVE_MIND_DIR="$REPO_ROOT"
  ADAPTER_DIR="$MEMORY_DIR"
  ADAPTER="claude-code"
  # Stub log() so extracted function's log calls don't hit macOS /usr/bin/log.
  log() { :; }
  eval "$(awk '/^manage_claude_skills\(\)/,/^}/' "$REPO_ROOT/setup.sh")"
  manage_claude_skills

  [ -d "$ADAPTER_SKILL_ROOT/hive-mind" ]
  [ ! -d "$MEMORY_DIR/skills/hive-mind" ]
}

@test "skills fall back to \$MEMORY_DIR/skills when ADAPTER_SKILL_ROOT is empty" {
  # Adapters that don't declare a skill root (ADAPTER_SKILL_ROOT="")
  # keep the legacy install location.
  MEMORY_DIR="$HOME/test-claude"
  ADAPTER_SKILL_ROOT=""
  mkdir -p "$MEMORY_DIR"

  HIVE_MIND_DIR="$REPO_ROOT"
  ADAPTER_DIR="$MEMORY_DIR"
  ADAPTER="claude-code"
  log() { :; }
  eval "$(awk '/^manage_claude_skills\(\)/,/^}/' "$REPO_ROOT/setup.sh")"
  manage_claude_skills

  [ -d "$MEMORY_DIR/skills/hive-mind" ]
}
