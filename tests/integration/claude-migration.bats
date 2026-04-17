#!/usr/bin/env bats
# Integration test for the Claude Code migration path.
# Seeds a fake pre-refactor install (old scripts/ paths in settings.json)
# and verifies that adapter_migrate rewrites them correctly.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."
LOADER="$REPO_ROOT/core/adapter-loader.sh"

setup() {
  HOME="$(mktemp -d)"
  export HOME
  source "$LOADER"
  load_adapter "claude-code"
}

teardown() {
  rm -rf "$HOME"
}

@test "migration: old hook commands are rewritten to hub-topology paths" {
  mkdir -p "$ADAPTER_DIR"

  # Seed a pre-refactor settings.json with old scripts/ paths.
  cat > "$ADAPTER_DIR/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "cd ~/.claude && { git pull --rebase --autostash --quiet 2>>.sync-error.log || { git rebase --abort 2>/dev/null; echo \"$(date -u +%FT%TZ) session-start pull failed\" >>.sync-error.log; }; ~/.claude/hive-mind/scripts/check-dupes.sh; true; }",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hive-mind/scripts/sync.sh",
            "timeout": 30,
            "async": true
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hive-mind/scripts/marker-nudge.sh",
            "timeout": 2
          }
        ]
      }
    ]
  },
  "permissions": {
    "allow": ["Bash(npm test)", "Read"]
  }
}
EOF

  adapter_migrate "0.1.0"

  # Old paths should be gone — neither the v0.1 scripts/ form nor the
  # v0.2 per-adapter core/ form may remain on disk after migration.
  run grep 'hive-mind/scripts/' "$ADAPTER_DIR/settings.json"
  [ "$status" -ne 0 ]
  run grep '\.claude/hive-mind/core/' "$ADAPTER_DIR/settings.json"
  [ "$status" -ne 0 ]

  # Stop hook promoted to the hub entry point; SessionStart /
  # PostToolUse helpers now sit under the hub's nested hive-mind src.
  grep -q '\.hive-mind/bin/sync' "$ADAPTER_DIR/settings.json"
  grep -q '\.hive-mind/hive-mind/core/check-dupes\.sh' "$ADAPTER_DIR/settings.json"
  grep -q '\.hive-mind/hive-mind/core/marker-nudge\.sh' "$ADAPTER_DIR/settings.json"

  # User's existing permissions preserved.
  jq -e '.permissions.allow | index("Bash(npm test)")' "$ADAPTER_DIR/settings.json" >/dev/null
  jq -e '.permissions.allow | index("Read")' "$ADAPTER_DIR/settings.json" >/dev/null
}

@test "migration: idempotent — re-running on already-migrated config is a no-op" {
  mkdir -p "$ADAPTER_DIR"
  cat > "$ADAPTER_DIR/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [{"hooks": [{"command": "\"$HOME/.hive-mind/bin/sync\""}]}]
  },
  "permissions": {"allow": ["Read"]}
}
EOF

  local before
  before="$(cat "$ADAPTER_DIR/settings.json")"

  adapter_migrate "0.3.0"

  [ "$(cat "$ADAPTER_DIR/settings.json")" = "$before" ]
}

@test "migration: no settings.json present → no error" {
  mkdir -p "$ADAPTER_DIR"
  [ ! -f "$ADAPTER_DIR/settings.json" ]

  run adapter_migrate "0.1.0"
  [ "$status" -eq 0 ]
}
