#!/usr/bin/env bash
# Codex adapter for hive-mind.
# Translates the hub's canonical schema into Codex's current native layout.

set -euo pipefail

# --- A. Identity & location ------------------------------------------------
ADAPTER_API_VERSION="1.0.0"
ADAPTER_VERSION="0.1.0"
ADAPTER_NAME="codex"
ADAPTER_DIR="${ADAPTER_DIR:-$HOME/.codex}"
ADAPTER_MEMORY_MODEL="hierarchical"
# Even though Codex is hierarchical, the shared SessionStart helper needs
# the active global file path so it scans the file Codex will actually read.
ADAPTER_GLOBAL_MEMORY="${ADAPTER_DIR}/AGENTS.override.md"

adapter_list_memory_files() { :; }

# --- B. Files & sync rules -------------------------------------------------
ADAPTER_GITIGNORE_TEMPLATE="${ADAPTER_ROOT}/gitignore"
ADAPTER_GITATTRIBUTES_TEMPLATE="${ADAPTER_ROOT}/gitattributes"
ADAPTER_SECRET_FILES="auth.json"
# --- C. Lifecycle touchpoints ----------------------------------------------
# ADAPTER_EVENT_POST_EDIT is intentionally omitted: Codex's current hook
# surface does not install a PostToolUse-style per-edit hook, so the
# declaration would only mislead future code into assuming support that
# isn't there. `core/marker-nudge.sh` (the sole consumer) gates its own
# fallback on the var being unset, so leaving it out is the correct
# no-op. If Codex adds a post-edit hook later, declare it then, not now.
ADAPTER_HAS_HOOK_SYSTEM=true
ADAPTER_EVENT_SESSION_START="SessionStart"
ADAPTER_EVENT_TURN_END="Stop"

_codex_feature_state_file() {
  printf '%s' "$ADAPTER_DIR/.hive-mind-codex-hooks.state"
}

_codex_hooks_file() {
  printf '%s' "$ADAPTER_DIR/hooks.json"
}

_codex_config_file() {
  printf '%s' "$ADAPTER_DIR/config.toml"
}

_codex_detect_feature_state() {
  local config="$1"
  [ -f "$config" ] || {
    printf 'missing'
    return 0
  }

  awk '
    BEGIN { in_features = 0; state = "absent"; found = 0 }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      in_features = ($0 ~ /^[[:space:]]*\[features\][[:space:]]*$/)
      next
    }
    in_features && /^[[:space:]]*codex_hooks[[:space:]]*=/ {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      if (line ~ /^true([[:space:]]*#.*)?$/) {
        state = "true"
      } else if (line ~ /^false([[:space:]]*#.*)?$/) {
        state = "false"
      } else {
        state = "absent"
      }
      found = 1
      print state
      exit
    }
    END {
      if (!found) {
        print state
      }
    }
  ' "$config"
}

_codex_record_feature_state() {
  local config="$1"
  local state_file

  state_file="$(_codex_feature_state_file)"
  [ -f "$state_file" ] && return 0
  _codex_detect_feature_state "$config" > "$state_file"
}

_codex_strip_empty_features_section() {
  local config="$1"
  local tmp

  [ -f "$config" ] || return 0
  tmp="$(mktemp)"
  if awk '
    function flush_features(    i, has_content) {
      if (!capturing) {
        return
      }
      has_content = 0
      for (i = 2; i <= n; i++) {
        if (buf[i] !~ /^[[:space:]]*$/) {
          has_content = 1
          break
        }
      }
      if (has_content) {
        for (i = 1; i <= n; i++) {
          print buf[i]
        }
      }
      delete buf
      n = 0
      capturing = 0
    }

    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (capturing) {
        flush_features()
      }
      if ($0 ~ /^[[:space:]]*\[features\][[:space:]]*$/) {
        capturing = 1
        buf[++n] = $0
      } else {
        print
      }
      next
    }

    {
      if (capturing) {
        buf[++n] = $0
      } else {
        print
      }
    }

    END {
      flush_features()
    }
  ' "$config" > "$tmp"; then
    mv "$tmp" "$config"
  else
    rm -f "$tmp"
    return 1
  fi
}

_codex_set_feature_flag() {
  local config="$1" want="$2"
  local tmp

  tmp="$(mktemp)"
  if [ ! -f "$config" ]; then
    if [ "$want" = "absent" ]; then
      rm -f "$tmp"
      return 0
    fi
    printf '[features]\ncodex_hooks = %s\n' "$want" > "$tmp"
    mv "$tmp" "$config"
    return 0
  fi

  if awk -v want="$want" '
    BEGIN { in_features = 0; saw_features = 0; wrote_target = 0 }

    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (in_features && !wrote_target && want != "absent") {
        print "codex_hooks = " want
        wrote_target = 1
      }
      in_features = ($0 ~ /^[[:space:]]*\[features\][[:space:]]*$/)
      if (in_features) {
        saw_features = 1
      }
      print
      next
    }

    {
      if (in_features && $0 ~ /^[[:space:]]*codex_hooks[[:space:]]*=/) {
        if (want != "absent" && !wrote_target) {
          print "codex_hooks = " want
          wrote_target = 1
        }
        next
      }
      print
    }

    END {
      if (in_features && !wrote_target && want != "absent") {
        print "codex_hooks = " want
      } else if (!saw_features && want != "absent") {
        if (NR > 0) {
          print ""
        }
        print "[features]"
        print "codex_hooks = " want
      }
    }
  ' "$config" > "$tmp"; then
    mv "$tmp" "$config"
  else
    rm -f "$tmp"
    return 1
  fi

  _codex_strip_empty_features_section "$config"
}

_codex_restore_feature_state() {
  local config state state_file

  config="$(_codex_config_file)"
  state_file="$(_codex_feature_state_file)"
  [ -f "$state_file" ] || return 0

  state="$(cat "$state_file" 2>/dev/null || printf 'absent')"
  case "$state" in
    true)
      _codex_set_feature_flag "$config" true
      ;;
    false)
      _codex_set_feature_flag "$config" false
      ;;
    absent)
      _codex_set_feature_flag "$config" absent
      ;;
    missing)
      _codex_set_feature_flag "$config" absent
      if [ -f "$config" ] && ! grep -q '[^[:space:]]' "$config"; then
        rm -f "$config"
      fi
      ;;
    *)
      _codex_set_feature_flag "$config" absent
      ;;
  esac

  rm -f "$state_file"
}

adapter_install_hooks() {
  local hooks template config rendered bash_cmd

  hooks="$(_codex_hooks_file)"
  template="${ADAPTER_ROOT}/hooks.json"
  config="$(_codex_config_file)"

  [ -f "$template" ] || return 1
  mkdir -p "$ADAPTER_DIR"

  _codex_record_feature_state "$config"
  _codex_set_feature_flag "$config" true

  # Bare `bash` in a hooks.json command is not portable on Windows: when
  # Codex's hook runner invokes the command under PowerShell, `bash`
  # resolves via PATH to C:\Windows\System32\bash.exe (the WSL launcher),
  # which fails with "Access is denied" long before Git Bash is reached.
  #
  # Candidate priority on Windows (most to least reliable when spawned
  # from a non-MSYS parent process like PowerShell):
  #   1. $EXEPATH/bin/bash.exe — the Git Bash "wrapper" binary. Sets up
  #      MSYS signal handling + pipe plumbing correctly even when the
  #      parent is cmd/PowerShell. $EXEPATH is set by Git Bash itself.
  #   2. $EXEPATH/usr/bin/bash.exe — the raw msys2 bash. Fails with
  #      "couldn't create signal pipe, Win32 error 5" when spawned cold
  #      from PowerShell/cmd, but works if (1) is absent.
  #   3. Whatever `$BASH` or `command -v bash` points at, .exe-suffixed
  #      then bare. Fallback for non-standard Git installs.
  # Every candidate must pass [ -f ] before we commit to it — a dangling
  # path embedded in hooks.json would reproduce the exact regression
  # we're fixing.
  #
  # On Unix: cygpath is absent, bare `bash` is the correct dispatcher.
  bash_cmd=""
  if command -v cygpath >/dev/null 2>&1; then
    local _unix_bash _win_bash _git_root _candidate _candidates
    _unix_bash="${BASH:-$(command -v bash 2>/dev/null)}"
    _candidates=""
    if [ -n "$_unix_bash" ]; then
      _win_bash="$(cygpath -m "$_unix_bash" 2>/dev/null)"
      if [ -n "$_win_bash" ]; then
        # Derive the Git install root by stripping whichever tail the
        # currently-running bash happens to have. Git Bash's wrapper
        # lives under $GIT_ROOT/bin, the raw msys2 bash under
        # $GIT_ROOT/usr/bin. cygpath of either gives us one of those
        # absolute paths; strip it back to $GIT_ROOT so we can probe
        # both candidates regardless of which one we happen to be
        # running under right now.
        _git_root="$_win_bash"
        _git_root="${_git_root%.exe}"
        _git_root="${_git_root%/bash}"
        _git_root="${_git_root%/bin}"
        _git_root="${_git_root%/usr}"
        if [ -d "$_git_root" ]; then
          # Wrapper first — handles PowerShell/cmd spawn quirks (signal
          # pipe / stdin plumbing) where the raw msys2 binary fails.
          _candidates+="$_git_root/bin/bash.exe"$'\n'
          _candidates+="$_git_root/usr/bin/bash.exe"$'\n'
        fi
      fi
      # Fallback: whatever $BASH / command -v happens to point at.
      _candidates+="${_unix_bash}.exe"$'\n'
      _candidates+="$_unix_bash"
    fi
    while IFS= read -r _candidate; do
      [ -n "$_candidate" ] && [ -f "$_candidate" ] || continue
      # Windows-style paths pass through; unix-style paths ($BASH output)
      # go through cygpath.
      case "$_candidate" in
        [A-Za-z]:/*) bash_cmd="$_candidate" ;;
        *)           bash_cmd="$(cygpath -m "$_candidate" 2>/dev/null)" ;;
      esac
      [ -n "$bash_cmd" ] && break
    done <<< "$_candidates"
    if [ -z "$bash_cmd" ]; then
      # Windows detected (cygpath present) but no resolvable bash path —
      # warn loudly rather than silently shipping a hooks.json that will
      # dispatch through WSL's bash.exe and fail on every session.
      printf '%s\n' 'codex adapter: WARNING — could not resolve absolute Git Bash path on Windows; codex hooks may dispatch to WSL bash.exe and fail. Ensure Git Bash is installed and on PATH.' >&2
    fi
  fi
  [ -n "$bash_cmd" ] || bash_cmd="bash"

  # Resolve an absolute Windows-friendly path to the hive-mind source
  # root (where the hook-wrapper scripts live). We write absolute paths
  # into hooks.json rather than relying on $HOME/env expansion inside
  # the command string — Codex's Windows hook runner (PowerShell /
  # Windows native) silently strips inner quotes and doesn't reliably
  # expand shell variables, so we render everything up front.
  local hm_root hm_root_abs adapter_dir_abs
  hm_root="${HIVE_MIND_HUB_DIR:-$HOME/.hive-mind}/hive-mind"
  if command -v cygpath >/dev/null 2>&1; then
    hm_root_abs="$(cygpath -m "$hm_root" 2>/dev/null || printf '%s' "$hm_root")"
    adapter_dir_abs="$(cygpath -m "$ADAPTER_DIR" 2>/dev/null || printf '%s' "$ADAPTER_DIR")"
  else
    hm_root_abs="$hm_root"
    adapter_dir_abs="$ADAPTER_DIR"
  fi

  rendered="$(mktemp)"
  jq --arg dir "$ADAPTER_DIR" \
     --arg mem "$ADAPTER_GLOBAL_MEMORY" \
     --arg bashcmd "$bash_cmd" \
     --arg hmroot "$hm_root_abs" \
     --arg adir "$adapter_dir_abs" \
    'walk(if type == "string" then
      gsub("[$]HIVE_MIND_ROOT"; $hmroot)
      | gsub("[$]ADAPTER_DIR_ABS"; $adir)
      | gsub("[$]HOME/[.]codex/AGENTS[.]override[.]md"; $mem)
      | gsub("[$]HOME/[.]codex"; $dir)
      | sub("^bash "; "\"" + $bashcmd + "\" ")
    else . end)' \
    "$template" > "$rendered"

  if [ ! -f "$hooks" ]; then
    mv "$rendered" "$hooks"
    return 0
  fi

  if jq -e '
    (.hooks.SessionStart // [])
    | map(
        .hooks[]?
        | select(
            ((.command // "") | test("\\.hive-mind/bin/sync"))
            and
            ((.command // "") | test("hive-mind/core/check-dupes\\.sh"))
          )
      )
    | length > 0
  ' "$hooks" >/dev/null 2>&1 && jq -e '
    (.hooks.Stop // [])
    | map(.hooks[]? | select((.command // "") | test("\\.hive-mind/bin/sync")))
    | length > 0
  ' "$hooks" >/dev/null 2>&1; then
    rm -f "$rendered"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  if jq -s '
    .[0] as $user | .[1] as $new
    | ($user * $new) as $base
    | . = $base
    | .hooks = (
        ($user.hooks // {}) as $uh
        | ($new.hooks // {}) as $nh
        | (($uh | keys) + ($nh | keys) | unique
          | map({
              (.): (
                ($uh[.] // []) as $ue
                | ($nh[.] // []) as $ne
                | $ue + (
                    $ne | map(
                      . as $new_entry
                      | if any(
                          $ue[];
                          (.matcher // "") == ($new_entry.matcher // "")
                          and
                          (((.hooks // []) | map(.command // "")) == (($new_entry.hooks // []) | map(.command // "")))
                        )
                        then empty
                        else $new_entry
                        end
                    )
                  )
              )
            })
          | add
      )
  ' "$hooks" "$rendered" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$hooks"
    rm -f "$rendered"
  else
    rm -f "$tmp" "$rendered"
    return 1
  fi
}

adapter_uninstall_hooks() {
  local hooks config tmp remaining hook_count

  hooks="$(_codex_hooks_file)"
  config="$(_codex_config_file)"

  if [ -f "$hooks" ]; then
    tmp="$(mktemp)"
    if jq '
      if .hooks then
        .hooks |= with_entries(
          .value |= map(
            if .hooks then
              .hooks |= map(
                select(
                  ((.command // "") | test("((~/\\.hive-mind|\\$HOME/\\.hive-mind)/(bin/sync|hive-mind/core/check-dupes\\.sh))") | not)
                )
              )
            else . end
            | select((.hooks // []) | length > 0)
          )
        )
        | .hooks |= with_entries(select((.value | length) > 0))
        | if (.hooks | keys | length) == 0 then del(.hooks) else . end
      else . end
    ' "$hooks" > "$tmp" 2>/dev/null; then
      remaining="$(jq 'del(.hooks) | length' "$tmp" 2>/dev/null)"
      hook_count="$(jq '[.hooks // {} | .[] | .[]] | length' "$tmp" 2>/dev/null)"
      if [ "${remaining:-0}" = "0" ] && [ "${hook_count:-0}" = "0" ]; then
        rm -f "$tmp" "$hooks"
      else
        mv "$tmp" "$hooks"
      fi
    else
      rm -f "$tmp"
      return 1
    fi
  fi

  _codex_restore_feature_state
}

# --- D. Skills -------------------------------------------------------------
ADAPTER_SKILL_ROOT="$HOME/.agents/skills"
ADAPTER_SKILL_FORMAT="markdown-frontmatter"

# --- E. Settings merge -----------------------------------------------------
ADAPTER_SETTINGS_MERGE_BINDINGS=""
ADAPTER_MERGE_DRIVER_ENV=""

# --- F. User education -----------------------------------------------------
adapter_activation_instructions() {
  echo "Restart Codex so it reloads hooks.json and starts using the synced"
  echo "global memory. hive-mind syncs both ${ADAPTER_DIR}/AGENTS.md (shared"
  echo "across every adapter) and ${ADAPTER_GLOBAL_MEMORY} (Codex-scoped"
  echo "override layer) — Codex reads the concatenation at runtime."
}

adapter_disable_instructions() {
  echo "To temporarily disable hive-mind sync, remove the SessionStart +"
  echo "Stop entries from ${ADAPTER_DIR}/hooks.json or set [features].codex_hooks"
  echo "to false in ${ADAPTER_DIR}/config.toml. To fully disconnect from the hub:"
  echo "  rm ~/.hive-mind/.install-state/attached-adapters"
}

# --- G. Fallback -----------------------------------------------------------
ADAPTER_FALLBACK_STRATEGY=""

# --- H. Hub mapping --------------------------------------------------------
# Codex natively reads both AGENTS.md AND AGENTS.override.md at startup and
# concatenates them at runtime. To keep both files fully synced with the
# hub, each gets its own section of the canonical content.md: section 0
# for AGENTS.md (shared across every adapter), section 1 for the Codex-
# scoped override layer (see docs/contributing.md for the section registry).
#
# NOTE: hooks.json is deliberately NOT in ADAPTER_HUB_MAP. The hub's
# `config/hooks/` bucket is shared across every adapter that maps into
# it, which means fan-out would push Claude's Bash-syntax hook commands
# (PostToolUse, Notification, PermissionRequest, ...) into Codex's
# hooks.json on every sync. On Windows, Codex executes those commands
# under PowerShell 5.1, which chokes on `&&`, `||`, `$(...)`. Codex
# manages its own hooks.json locally via adapter_install_hooks instead
# — deterministic across machines, no cross-shell contamination.
ADAPTER_HUB_MAP=$'content.md[0]\tAGENTS.md
content.md[1]\tAGENTS.override.md'
ADAPTER_PROJECT_CONTENT_RULES=""

# --- I. File harvest rules -------------------------------------------------
ADAPTER_FILE_HARVEST_RULES=$'AGENTS.md\nAGENTS.override.md\nhooks.json'
ADAPTER_PROJECT_CONTENT_GLOBS=""

# --- J. Logging ------------------------------------------------------------
ADAPTER_LOG_PATH="${ADAPTER_DIR}/.sync-error.log"

# --- Healthcheck -----------------------------------------------------------
adapter_healthcheck() {
  if command -v codex >/dev/null 2>&1; then
    return 0
  fi
  [ -f "$ADAPTER_DIR/config.toml" ] \
    || [ -f "$ADAPTER_DIR/hooks.json" ] \
    || [ -f "$ADAPTER_DIR/AGENTS.override.md" ] \
    || [ -f "$ADAPTER_DIR/AGENTS.md" ]
}

# --- Migration -------------------------------------------------------------
adapter_migrate() { :; }
