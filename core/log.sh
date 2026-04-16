#!/usr/bin/env bash
# Shared logging helpers for core scripts and adapters.
#
# Line format (Appendix A.2):
#   YYYY-MM-DDTHH:MM:SSZ LEVEL component: message
#
# Usage:
#   source core/log.sh
#   hm_log INFO sync "pushed 1 commit to origin/main"
#   hm_log WARN sync "rate-limited, backing off 4s"
#
# Log path comes from the adapter (ADAPTER_LOG_PATH). If not set, falls
# back to a sensible default that won't lose messages.

# Minimum log level. Override via HIVE_MIND_LOG_LEVEL env var.
: "${HIVE_MIND_LOG_LEVEL:=INFO}"

_hm_level_num() {
  case "$1" in
    DEBUG) echo 0 ;;
    INFO)  echo 1 ;;
    WARN)  echo 2 ;;
    ERROR) echo 3 ;;
    *)     echo 1 ;;
  esac
}

hm_log() {
  local level="$1" component="$2"; shift 2
  local msg="$*"

  local min_num cur_num
  min_num="$(_hm_level_num "$HIVE_MIND_LOG_LEVEL")"
  cur_num="$(_hm_level_num "$level")"
  [ "$cur_num" -ge "$min_num" ] || return 0

  local ts
  ts="$(date -u +%FT%TZ)"
  local log_path="${ADAPTER_LOG_PATH:-${ADAPTER_DIR:+$ADAPTER_DIR/.sync-error.log}}"
  log_path="${log_path:-/tmp/hive-mind.log}"

  printf '%s %s %s: %s\n' "$ts" "$level" "$component" "$msg" >> "$log_path" 2>/dev/null || true
}

# Strip embedded credentials from a URL before logging.
# https://x-access-token:ghp_xxx@github.com/… → https://***@github.com/…
hm_sanitize_url() {
  local url="$1"
  printf '%s' "$url" | sed -E 's|://[^@]+@|://***@|'
}
