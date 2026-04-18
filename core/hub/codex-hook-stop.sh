#!/bin/bash
# Codex Stop-hook wrapper. Runs hub sync (silent — errors go to the
# usual log) and emits `{}` as valid JSON output so Codex's hook
# runner is satisfied. See adapters/codex/adapter.sh for why this
# logic lives on disk rather than inline in hooks.json: PowerShell
# (and any other Windows-native dispatcher Codex uses) silently
# strips inner quotes from command strings, breaking any embedded
# `printf "{}"`. Invoking a script file by absolute path sidesteps
# the entire quoting lottery.
set +e

"$HOME/.hive-mind/bin/sync" >/dev/null 2>>"$HOME/.hive-mind/.sync-error.log"
printf '{}'
