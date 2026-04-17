#!/usr/bin/env bats
# The hub sync engine's secret-file gate MUST match declared secrets
# by basename, not by exact path. ADAPTER_SECRET_FILES is documented
# as a list of filenames (docs/CONTRIBUTING-adapters.md); an adapter
# or hub-map misconfiguration that harvests a secret to a nested path
# (e.g. `config/auth.json`, `backups/auth.json`) must still be caught.
# A credential leak at a surprising path is exactly the failure mode
# this gate exists to prevent — an exact-path gate is weaker than
# advertised.
#
# Regression for v0.3.0 Copilot review round 3.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
HUB_SYNC="$REPO_ROOT/core/hub/sync.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME

  TEST_ADAPTERS_DIR="$HOME/_adapters"
  mkdir -p "$TEST_ADAPTERS_DIR/fake-b"
  cp "$REPO_ROOT/tests/fixtures/adapters/fake-b/"* "$TEST_ADAPTERS_DIR/fake-b/"
  export HIVE_MIND_ADAPTERS_DIR="$TEST_ADAPTERS_DIR"
  export FAKE_B_ADAPTER_HOME="$HOME"

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
  printf 'fake-b\n' > "$HUB/.install-state/attached-adapters"
  mkdir -p "$HOME/.fake-b-tool"

  # Patch fake-b to declare `auth.json` as a secret.
  sed -i.bak 's|^ADAPTER_SECRET_FILES=""|ADAPTER_SECRET_FILES="auth.json"|' \
    "$TEST_ADAPTERS_DIR/fake-b/adapter.sh"
  rm -f "$TEST_ADAPTERS_DIR/fake-b/adapter.sh.bak"
}

teardown() {
  rm -rf "$HOME"
}

run_sync() {
  HIVE_MIND_HUB_DIR="$HUB" bash "$HUB_SYNC"
}

# === basename-match cases the exact-path gate would have missed ===========

@test "secret at nested hub path is unstaged by basename match" {
  # Simulate a harvest that mistakenly landed auth.json under config/
  # rather than the hub root. ADAPTER_SECRET_FILES="auth.json" (basename
  # only) — the gate must still catch it.
  printf 'legit\n' > "$HOME/.fake-b-tool/NOTES.md"
  mkdir -p "$HUB/config"
  printf 'super secret token\n' > "$HUB/config/auth.json"

  run run_sync
  [ "$status" -eq 0 ]

  # Nested secret never reached remote.
  run git -C "$HOME/remote.git" log --all --oneline -- config/auth.json
  [ -z "$output" ]
  # Skip logged with the adapter-declared basename.
  grep -Fq "refused to sync secret 'auth.json'" "$HUB/.sync-error.log"
  # And the sync still functioned for non-secret content.
  grep -q '^legit$' "$HUB/content.md"
}

@test "secret smuggled into a whitelisted skills/ subdir is unstaged by basename match" {
  # The hub whitelist allows skills/** to reach the remote. An adapter
  # bug that harvests a secret file into skills/<name>/ would pass the
  # whitelist gate but MUST be caught by the secret-basename gate.
  # Exercise a realistic leak vector, not a root-level file the
  # gitignore whitelist already blocks.
  printf 'legit\n' > "$HOME/.fake-b-tool/NOTES.md"
  mkdir -p "$HUB/skills/sneaky"
  printf 'super secret token\n' > "$HUB/skills/sneaky/auth.json"

  run run_sync
  [ "$status" -eq 0 ]

  run git -C "$HOME/remote.git" log --all --oneline -- skills/sneaky/auth.json
  [ -z "$output" ]
  grep -Fq "refused to sync secret 'auth.json'" "$HUB/.sync-error.log"
}

@test "secret deeply nested under a whitelisted tree is still caught by basename match" {
  # Defense in depth: the awk basename extraction must handle paths
  # with any number of `/` components, not just one. Exercise inside
  # projects/<id>/memory/** (whitelisted) so the path reaches staging
  # without a whitelist bypass first.
  printf 'legit\n' > "$HOME/.fake-b-tool/NOTES.md"
  mkdir -p "$HUB/projects/github.com/alice/proj/memory/nested/deeper"
  printf 'super secret token\n' > "$HUB/projects/github.com/alice/proj/memory/nested/deeper/auth.json"

  run run_sync
  [ "$status" -eq 0 ]

  run git -C "$HOME/remote.git" log --all --oneline -- projects/github.com/alice/proj/memory/nested/deeper/auth.json
  [ -z "$output" ]
  grep -Fq "refused to sync secret 'auth.json'" "$HUB/.sync-error.log"
}

@test "file with legitimate non-secret basename is NOT affected by the secret gate" {
  # A user intentionally adding a project file named auth.json.example
  # or session.log must not be dropped. Pin that the gate matches
  # BASENAME EXACTLY (auth.json) and doesn't accidentally trip on
  # substrings or similar names.
  printf 'legit\n' > "$HOME/.fake-b-tool/NOTES.md"
  mkdir -p "$HUB/docs"
  printf 'public example\n' > "$HUB/docs/auth.json.example"

  run run_sync
  [ "$status" -eq 0 ]

  # The .example file survived (no mass "anything matching auth" kill).
  [ -f "$HUB/docs/auth.json.example" ] || {
    # Committed? Check remote.
    git -C "$HOME/remote.git" show HEAD:docs/auth.json.example >/dev/null
  }
  # And the skip log never mentioned it.
  run grep 'auth.json.example' "$HUB/.sync-error.log"
  [ "$status" -ne 0 ]
}

@test "adapter that mistakenly declared a path-shaped secret still gets caught by basename pass" {
  # Guard against an adapter declaring ADAPTER_SECRET_FILES="config/auth.json"
  # when the contract wants just "auth.json". The gate must strip the
  # accidental path component and still catch the file at any nested
  # location.
  sed -i.bak 's|^ADAPTER_SECRET_FILES="auth.json"|ADAPTER_SECRET_FILES="config/auth.json"|' \
    "$TEST_ADAPTERS_DIR/fake-b/adapter.sh"
  rm -f "$TEST_ADAPTERS_DIR/fake-b/adapter.sh.bak"

  printf 'legit\n' > "$HOME/.fake-b-tool/NOTES.md"
  mkdir -p "$HUB/skills/leak"
  printf 'super secret\n' > "$HUB/skills/leak/auth.json"

  run run_sync
  [ "$status" -eq 0 ]

  run git -C "$HOME/remote.git" log --all --oneline -- skills/leak/auth.json
  [ -z "$output" ]
  # The log message mentions `auth.json` (the basename-normalized form)
  # — that's the user-facing string a maintainer would grep for.
  grep -Fq "auth.json" "$HUB/.sync-error.log"
}
