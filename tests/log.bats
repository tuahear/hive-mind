#!/usr/bin/env bats
# Tests for core/log.sh helpers.
#
# hm_sanitize_url masks embedded credentials before they get echoed to a
# terminal, CI log, or the sync-error log. Token leaks via log output are
# silent and permanent (whatever was emitted is already indexed); the
# sanitize pattern MUST hold across the full set of URL shapes git
# accepts as origin remotes.

LOG_SH="$BATS_TEST_DIRNAME/../core/log.sh"

setup() {
  # shellcheck disable=SC1090
  source "$LOG_SH"
}

@test "HTTPS URL with user:token credentials is masked" {
  out="$(hm_sanitize_url 'https://x-access-token:ghp_secret@github.com/owner/repo.git')"
  [ "$out" = "https://***@github.com/owner/repo.git" ]
}

@test "HTTPS URL with just-token form (no user) is masked" {
  out="$(hm_sanitize_url 'https://ghp_secret@github.com/owner/repo.git')"
  [ "$out" = "https://***@github.com/owner/repo.git" ]
}

@test "URL without embedded credentials passes through unchanged" {
  out="$(hm_sanitize_url 'https://github.com/owner/repo.git')"
  [ "$out" = "https://github.com/owner/repo.git" ]
}

@test "SSH-form URL passes through unchanged (no user:pass surface)" {
  # git@host:path shape has no ://user:pass@ segment to mask.
  out="$(hm_sanitize_url 'git@github.com:owner/repo.git')"
  [ "$out" = "git@github.com:owner/repo.git" ]
}

@test "ssh:// URL with embedded credentials is masked" {
  out="$(hm_sanitize_url 'ssh://git:pw@gitserver.example.com:2222/owner/repo')"
  [ "$out" = "ssh://***@gitserver.example.com:2222/owner/repo" ]
}

@test "empty input is tolerated (no output, no error)" {
  out="$(hm_sanitize_url '')"
  [ -z "$out" ]
}

# setup.sh carries its own sanitize_remote_url for when it hasn't
# sourced log.sh. Both implementations MUST produce identical output
# -- otherwise we'd have a credential-leak gap at install time.
@test "setup.sh sanitize_remote_url produces identical output to hm_sanitize_url" {
  local setup="$BATS_TEST_DIRNAME/../setup.sh"
  out="$(
    eval "$(awk '/^sanitize_remote_url\(\)/,/^}/' "$setup")"
    sanitize_remote_url 'https://user:pass@host.com/repo'
  )"
  [ "$out" = "https://***@host.com/repo" ]
}

@test "@ later in path is NOT mangled (userinfo-only anchor)" {
  # The old regex `://[^@]*@` was greedy up to the first `@` anywhere
  # in the URL. For a URL like `https://github.com/owner/foo@tag/bar`
  # (a submodule/ref form that git does accept) the old pattern
  # swallowed `://github.com/owner/foo@` and produced `https://***@tag/bar`
  # — mangled. The new anchor `[^@/]*` stops at the first `/` so only
  # the userinfo segment is eligible for masking.
  out="$(hm_sanitize_url 'https://github.com/owner/foo@v1.2.3/bar')"
  [ "$out" = "https://github.com/owner/foo@v1.2.3/bar" ]
}

@test "credential URL with @-in-path both present: only userinfo is masked" {
  # Defense in depth: if a URL genuinely has both embedded creds AND
  # a later `@`, the mask must stop at the end of userinfo. Otherwise
  # the wrong substring gets redacted and log readers can't tell the
  # host apart from a ref token.
  out="$(hm_sanitize_url 'https://user:pw@host.example.com/owner/repo@tag/file')"
  [ "$out" = "https://***@host.example.com/owner/repo@tag/file" ]
}

@test "setup.sh sanitize_remote_url also preserves @-in-path" {
  # Parity with hm_sanitize_url is required — both run at install
  # time against the same URLs.
  local setup="$BATS_TEST_DIRNAME/../setup.sh"
  out="$(
    eval "$(awk '/^sanitize_remote_url\(\)/,/^}/' "$setup")"
    sanitize_remote_url 'https://github.com/owner/foo@v1.2.3/bar'
  )"
  [ "$out" = "https://github.com/owner/foo@v1.2.3/bar" ]
}
