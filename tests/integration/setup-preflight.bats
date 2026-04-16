#!/usr/bin/env bats
# Preflight tests for setup.sh — pin the opt-in / opt-out contract of
# environment-sensitive checks that have historically surprised users.
#
# Each test extracts the target function from setup.sh via `awk` and
# evaluates it in the test's shell (no network, no side effects). The
# functions themselves are self-contained; evaluating the whole
# setup.sh would try to clone and attach, which is not what we want.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
SETUP="$REPO_ROOT/setup.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  # Quiet the `log` helper extracted out of setup.sh so test output
  # stays readable — setup.sh's real `log()` writes to stdout.
  log() { :; }
  die() { echo "DIE: $*"; return 1; }
}

teardown() {
  rm -rf "$HOME"
}

# === Thread 3: jq auto-install is opt-in =================================

@test "auto_install_jq: without HIVE_MIND_AUTO_INSTALL_JQ, returns non-zero and does not invoke any package manager" {
  # Seed a sentinel command path: if auto_install_jq ever runs brew /
  # apt-get / sudo / winget by accident, the test harness spots the
  # call via PATH interception. Install shims that tag a file when
  # invoked and prepend them to PATH.
  SHIM_DIR="$HOME/shims"
  mkdir -p "$SHIM_DIR"
  for cmd in brew apt-get dnf yum pacman apk winget choco scoop sudo; do
    cat > "$SHIM_DIR/$cmd" <<EOF
#!/bin/sh
echo "INVOKED: $cmd \$@" >> "$HOME/invoked.log"
exit 0
EOF
    chmod +x "$SHIM_DIR/$cmd"
  done
  PATH="$SHIM_DIR:$PATH"
  export PATH

  eval "$(awk '/^auto_install_jq\(\)/,/^}/' "$SETUP")"

  # Default (env var unset): must short-circuit and return non-zero.
  unset HIVE_MIND_AUTO_INSTALL_JQ
  run auto_install_jq
  [ "$status" -ne 0 ]
  # No package manager was invoked.
  [ ! -f "$HOME/invoked.log" ]

  # Explicit opt-out: same behavior.
  HIVE_MIND_AUTO_INSTALL_JQ=0 run auto_install_jq
  [ "$status" -ne 0 ]
  [ ! -f "$HOME/invoked.log" ]
}

@test "auto_install_jq: with HIVE_MIND_AUTO_INSTALL_JQ=1 and jq already on PATH, succeeds without invoking sudo" {
  # When the flag is set but jq is already present (common — package
  # managers happy-path on re-runs), the function should still return
  # 0 and NOT escalate privileges. The final `command -v jq` is what
  # carries the exit status, so with jq present we never need sudo.
  SHIM_DIR="$HOME/shims"
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/jq" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$SHIM_DIR/jq"
  # sudo shim that fails loudly if called — any invocation would abort
  # the test and catch an accidental "always shell out even when jq
  # is installed" regression.
  cat > "$SHIM_DIR/sudo" <<EOF
#!/bin/sh
echo "UNEXPECTED_SUDO" > "$HOME/sudo-invoked"
exit 1
EOF
  chmod +x "$SHIM_DIR/sudo"
  PATH="$SHIM_DIR:$PATH"
  export PATH

  eval "$(awk '/^auto_install_jq\(\)/,/^}/' "$SETUP")"

  HIVE_MIND_AUTO_INSTALL_JQ=1 run auto_install_jq
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/sudo-invoked" ]
}

@test "setup.sh install_hint mentions HIVE_MIND_AUTO_INSTALL_JQ so a user hitting the missing-jq error knows the opt-in" {
  # Scan the text of setup.sh for the opt-in hint. Preventing drift
  # where a refactor drops the hint and leaves users staring at a
  # generic "missing tool: jq" with no path forward.
  grep -q 'HIVE_MIND_AUTO_INSTALL_JQ=1' "$SETUP"
}

# === Thread 2: SSH preflight conditional on SSH URLs =====================

@test "_is_ssh_url correctly classifies every URL variant the installer might see" {
  eval "$(awk '/^_is_ssh_url\(\)/,/^}/' "$SETUP")"

  run _is_ssh_url "git@github.com:tuahear/hive-mind.git"
  [ "$status" -eq 0 ]
  run _is_ssh_url "git@gitlab.com:foo/bar.git"
  [ "$status" -eq 0 ]
  run _is_ssh_url "ssh://git@github.com:22/foo/bar.git"
  [ "$status" -eq 0 ]

  # HTTPS forms must not be classified as SSH — the whole point of the
  # Thread 2 fix is that https users never hit the SSH preflight.
  run _is_ssh_url "https://github.com/foo/bar.git"
  [ "$status" -ne 0 ]
  run _is_ssh_url "http://internal.example/foo.git"
  [ "$status" -ne 0 ]
  run _is_ssh_url "/local/path/bare.git"
  [ "$status" -ne 0 ]
  run _is_ssh_url "file:///local/path/bare.git"
  [ "$status" -ne 0 ]
  run _is_ssh_url ""
  [ "$status" -ne 0 ]
}

@test "_extract_ssh_host returns the hostname only for supported SSH URL shapes" {
  eval "$(awk '/^_extract_ssh_host\(\)/,/^}/' "$SETUP")"

  run _extract_ssh_host "git@github.com:tuahear/hive-mind.git"
  [ "$status" -eq 0 ]
  [ "$output" = "github.com" ]

  run _extract_ssh_host "git@gitlab.example.com:team/repo.git"
  [ "$status" -eq 0 ]
  [ "$output" = "gitlab.example.com" ]

  # ssh:// with user + port must strip both — the preflight passes the
  # bare hostname to `ssh -T git@<host>`, so a port leak would break
  # the command.
  run _extract_ssh_host "ssh://git@git.example.org:2222/foo/bar.git"
  [ "$status" -eq 0 ]
  [ "$output" = "git.example.org" ]

  # ssh:// without user prefix — still must extract host, not leak
  # path or port.
  run _extract_ssh_host "ssh://git.example.org/foo/bar.git"
  [ "$status" -eq 0 ]
  [ "$output" = "git.example.org" ]
}

@test "setup.sh preflight loop skips SSH probes entirely when HIVE_MIND_REPO and MEMORY_REPO are both https" {
  # Extract the full preflight block (the _is_ssh_url / _extract_ssh_host
  # helpers plus the dedup loop) and run it with both repo vars set to
  # HTTPS. No ssh shim is installed, so if the loop ever calls `ssh`,
  # the real ssh would probably try to connect and we'd detect a
  # non-zero exit even on a no-network runner. Better: intercept ssh
  # with a shim that records invocations and assert no record appears.
  SHIM_DIR="$HOME/shims"
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/ssh" <<EOF
#!/bin/sh
echo "SSH_INVOKED: \$@" >> "$HOME/ssh-invoked.log"
exit 0
EOF
  chmod +x "$SHIM_DIR/ssh"
  PATH="$SHIM_DIR:$PATH"
  export PATH

  # Pull the three helpers + the for-loop from setup.sh into this shell.
  # The helpers are defined as functions; the loop is top-level code.
  # Extract via a wider awk range covering the SSH preflight region.
  eval "$(awk '/^_is_ssh_url\(\)/,/^unset _seen_hosts _ssh_repo _host$/' "$SETUP")"

  export HIVE_MIND_REPO="https://github.com/tuahear/hive-mind.git"
  export MEMORY_REPO="https://memory.example.com/me/memory.git"

  # The awk slice above already ran the loop once. Reset the dedup
  # state and re-run the loop body with the https vars. (Re-extracting
  # and re-eval-ing is the cleanest reuse path; the bare vars above
  # are what the loop reads.)
  eval "$(awk '/^_seen_hosts=""$/,/^unset _seen_hosts _ssh_repo _host$/' "$SETUP")"

  [ ! -f "$HOME/ssh-invoked.log" ]
}

@test "setup.sh preflight invokes ssh exactly once per unique SSH host, even when HIVE_MIND_REPO and MEMORY_REPO share it" {
  # Dedup pin — a user pointing both at github.com should see one ssh
  # probe, not two. Regression would waste a round-trip per install on
  # every user and double the connect-timeout failure mode.
  SHIM_DIR="$HOME/shims"
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/ssh" <<EOF
#!/bin/sh
echo "\$@" >> "$HOME/ssh-invoked.log"
# Emit the banner string the preflight treats as success.
echo "Hi there! You've successfully authenticated, but GitHub does not provide shell access." >&2
exit 1
EOF
  chmod +x "$SHIM_DIR/ssh"
  PATH="$SHIM_DIR:$PATH"
  export PATH

  export HIVE_MIND_REPO="git@github.com:tuahear/hive-mind.git"
  export MEMORY_REPO="git@github.com:someone/memory.git"

  eval "$(awk '/^_is_ssh_url\(\)/,/^unset _seen_hosts _ssh_repo _host$/' "$SETUP")"

  [ -f "$HOME/ssh-invoked.log" ]
  # Exactly one ssh call landed (the dedup would otherwise add a
  # second for the same github.com host).
  [ "$(wc -l < "$HOME/ssh-invoked.log" | tr -d ' ')" = "1" ]
}
