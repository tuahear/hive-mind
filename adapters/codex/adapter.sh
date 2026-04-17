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
ADAPTER_MARKER_TARGETS=$'AGENTS.override.md\nskills/**/*.md'

# --- C. Lifecycle touchpoints ----------------------------------------------
ADAPTER_HAS_HOOK_SYSTEM=true
ADAPTER_EVENT_SESSION_START="SessionStart"
ADAPTER_EVENT_TURN_END="Stop"
ADAPTER_EVENT_POST_EDIT="PostToolUse"

_codex_feature_state_file() {
  printf '%s' "$ADAPTER_DIR/.hive-mind-codex-hooks.state"
}

_codex_hooks_file() {
  printf '%s' "$ADAPTER_DIR/hooks.json"
}

_codex_config_file() {
  printf '%s' "$ADAPTER_DIR/config.toml"
}

_codex_seed_global_memory() {
  local legacy="$ADAPTER_DIR/AGENTS.md"
  local active="$ADAPTER_GLOBAL_MEMORY"

  [ -f "$active" ] && return 0
  [ -f "$legacy" ] || return 0
  cp "$legacy" "$active"
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
        if (buf[i] !~ /^[[:space:]]*$/ && buf[i] !~ /^[[:space:]]*#/) {
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
  local hooks template config

  hooks="$(_codex_hooks_file)"
  template="${ADAPTER_ROOT}/hooks.json"
  config="$(_codex_config_file)"

  [ -f "$template" ] || return 1
  mkdir -p "$ADAPTER_DIR"

  _codex_seed_global_memory
  _codex_record_feature_state "$config"
  _codex_set_feature_flag "$config" true

  if [ ! -f "$hooks" ]; then
    cp "$template" "$hooks"
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
  ' "$hooks" "$template" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$hooks"
  else
    rm -f "$tmp"
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
  echo "global memory layer at ~/.codex/AGENTS.override.md."
}

adapter_disable_instructions() {
  echo "To temporarily disable hive-mind sync, remove the SessionStart +"
  echo "Stop entries from ~/.codex/hooks.json or set [features].codex_hooks"
  echo "to false in ~/.codex/config.toml. To fully disconnect from the hub:"
  echo "  rm ~/.hive-mind/.install-state/attached-adapters"
}

# --- G. Fallback -----------------------------------------------------------
ADAPTER_FALLBACK_STRATEGY=""

# --- H. Hub mapping --------------------------------------------------------
ADAPTER_HUB_MAP=$'content.md\tAGENTS.override.md\nconfig/hooks\thooks.json#hooks'
ADAPTER_PROJECT_CONTENT_RULES=""

# --- I. File harvest rules -------------------------------------------------
ADAPTER_FILE_HARVEST_RULES=$'AGENTS.override.md\nhooks.json'
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
