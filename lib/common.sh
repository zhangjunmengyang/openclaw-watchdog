#!/usr/bin/env bash
# common.sh — Shared utilities for openclaw-watchdog
# Sourced by all modules. Not executable standalone.
#
# shellcheck disable=SC2034  # variables used by sourcing scripts

# === Version ===
WATCHDOG_VERSION="1.0.0"

# === Paths ===
WATCHDOG_DIR="${WATCHDOG_DIR:-$HOME/.openclaw/watchdog}"
WATCHDOG_LOG_DIR="${WATCHDOG_LOG_DIR:-$HOME/.openclaw/logs}"
WATCHDOG_SNAPSHOT_DIR="${WATCHDOG_DIR}/snapshots"
WATCHDOG_STATE_DIR="${WATCHDOG_DIR}/state"
WATCHDOG_CONFIG="${WATCHDOG_DIR}/config.conf"

# === Defaults (overridden by config.conf) ===

# Gateway health
HEALTH_CHECK_URL="${HEALTH_CHECK_URL:-http://127.0.0.1:18789/healthz}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"
BACKOFF_INITIAL="${BACKOFF_INITIAL:-30}"
BACKOFF_MAX="${BACKOFF_MAX:-300}"
BACKOFF_MULTIPLIER="${BACKOFF_MULTIPLIER:-2}"
COOLDOWN="${COOLDOWN:-120}"

# Network
PING_TARGET="${PING_TARGET:-8.8.8.8}"
PING_TIMEOUT="${PING_TIMEOUT:-3}"
TUN_SETTLE="${TUN_SETTLE:-8}"
DISCORD_CHECK_URL="${DISCORD_CHECK_URL:-https://discord.com/api/v10/gateway}"

# Proxy (blank to disable)
PROXY_URL="${PROXY_URL:-}"
LLM_API_CHECK_URL="${LLM_API_CHECK_URL:-https://api.anthropic.com}"
PROXY_CHECK_INTERVAL="${PROXY_CHECK_INTERVAL:-4}"
PROXY_FAIL_THRESHOLD="${PROXY_FAIL_THRESHOLD:-3}"

# Agent heartbeat
HEARTBEAT_CHECK_INTERVAL="${HEARTBEAT_CHECK_INTERVAL:-600}"
HEARTBEAT_THRESHOLD_MIN="${HEARTBEAT_THRESHOLD_MIN:-120}"
AGENT_WORKSPACES="${AGENT_WORKSPACES:-}"

# Config safeguard
CONFIG_PATH="${CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
ROLLBACK_TIMEOUT="${ROLLBACK_TIMEOUT:-300}"
SNAPSHOT_RETENTION="${SNAPSHOT_RETENTION:-20}"

# Config backup
BACKUP_INTERVAL="${BACKUP_INTERVAL:-3600}"
BACKUP_RETENTION="${BACKUP_RETENTION:-30}"

# Stability safety switches
DIAG_FREEZE_FLAG="${DIAG_FREEZE_FLAG:-$HOME/.openclaw/watchdog/diagnostic.freeze}"
RESTART_WINDOW_SEC="${RESTART_WINDOW_SEC:-900}"
RESTART_MAX_IN_WINDOW="${RESTART_MAX_IN_WINDOW:-3}"

# Logging
MAX_LOG_LINES="${MAX_LOG_LINES:-5000}"

# Gateway LaunchAgent label
GATEWAY_LAUNCHD_LABEL="${GATEWAY_LAUNCHD_LABEL:-ai.openclaw.gateway}"

# === OS detection ===
OS_TYPE="$(uname -s)"

# === Logging ===

_log_file="/dev/stderr"

log_init() {
    local module="$1"
    _log_file="${WATCHDOG_LOG_DIR}/watchdog-${module}.log"
    mkdir -p "${WATCHDOG_LOG_DIR}"
}

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] ${msg}"
    echo "${line}" >> "${_log_file}"
    if [[ "${WATCHDOG_FOREGROUND:-false}" == "true" ]]; then
        echo "${line}" >&2
    fi
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# Trim log file if too large
log_trim() {
    [[ -f "${_log_file}" ]] || return 0
    local lines
    lines="$(wc -l < "${_log_file}" | tr -d ' ')"
    if (( lines > MAX_LOG_LINES )); then
        local keep=$(( MAX_LOG_LINES / 2 ))
        tail -n "${keep}" "${_log_file}" > "${_log_file}.tmp" \
            && mv "${_log_file}.tmp" "${_log_file}"
        log_info "LOG_TRIM: ${lines} -> ${keep} lines"
    fi
}

# === Init ===

watchdog_init() {
    mkdir -p "${WATCHDOG_DIR}" "${WATCHDOG_SNAPSHOT_DIR}" \
             "${WATCHDOG_STATE_DIR}" "${WATCHDOG_LOG_DIR}"
    if [[ -f "${WATCHDOG_CONFIG}" ]]; then
        # shellcheck source=/dev/null
        source "${WATCHDOG_CONFIG}"
    fi
}

# === OS-portable helpers ===

get_uptime_seconds() {
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
        local boot_sec
        boot_sec="$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/')"
        echo $(( $(date +%s) - boot_sec ))
    else
        cut -d. -f1 /proc/uptime 2>/dev/null || echo 0
    fi
}

is_online() {
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
        /sbin/ping -c 1 -t "${PING_TIMEOUT}" "${PING_TARGET}" &>/dev/null
    else
        ping -c 1 -W "${PING_TIMEOUT}" "${PING_TARGET}" &>/dev/null
    fi
}

gateway_process_alive() {
    pgrep -f "openclaw.*gateway" &>/dev/null \
        || pgrep -f "openclaw/dist/index.js.*gateway" &>/dev/null \
        || (ps -Ao command 2>/dev/null | grep -E "openclaw-gateway|openclaw.*gateway|index\\.js gateway" | grep -v grep >/dev/null)
}

gateway_healthy() {
    local code
    code="$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
        "${HEALTH_CHECK_URL}" 2>/dev/null)"
    [[ "${code}" =~ ^(200|204|401|403)$ ]]
}

discord_reachable() {
    local code
    code="$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
        "${DISCORD_CHECK_URL}" 2>/dev/null)"
    [[ "${code}" == "200" ]]
}

proxy_healthy() {
    [[ -n "${PROXY_URL}" ]] || return 0  # disabled = healthy
    # Check proxy is listening
    curl -s --max-time 3 -o /dev/null "${PROXY_URL}" 2>/dev/null || return 1
    # Check LLM API reachable via proxy
    local code
    code="$(curl -s --max-time 8 --proxy "${PROXY_URL}" -o /dev/null \
        -w "%{http_code}" "${LLM_API_CHECK_URL}" 2>/dev/null)"
    [[ "${code}" =~ ^[0-9]+$ ]] && (( code > 0 ))
}

# Restart gateway (launchd on macOS, systemctl on Linux)
restart_gateway() {
    local reason="${1:-unknown}"
    log_info "RESTART: reason=${reason}"

    if [[ "${OS_TYPE}" == "Darwin" ]]; then
        local label="gui/$(id -u)/${GATEWAY_LAUNCHD_LABEL}"
        launchctl kickstart -k "${label}" >> "${_log_file}" 2>&1 || true
        log_info "RESTART: launchctl kickstart -k sent"
    else
        systemctl --user restart openclaw-gateway >> "${_log_file}" 2>&1 || true
        log_info "RESTART: systemctl restart sent"
    fi

    # Verify restart
    local retries=0 max_retries=6
    while (( retries < max_retries )); do
        sleep 5
        if gateway_healthy; then
            log_info "RESTART: verified healthy"
            return 0
        fi
        retries=$(( retries + 1 ))
        log_info "RESTART: waiting... (${retries}/${max_retries})"
    done

    log_error "RESTART: gateway not healthy after ${max_retries} attempts"
    return 1
}

# JSON field reader (uses python3, pre-installed on macOS)
json_get() {
    local file="$1" field="$2"
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    val = d
    for k in sys.argv[2].split('.'):
        val = val[k]
    print(val)
except Exception:
    print('')
" "${file}" "${field}" 2>/dev/null
}

# Portable SHA-256 checksum
file_checksum() {
    local file="$1"
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
        shasum -a 256 "${file}" 2>/dev/null | cut -d' ' -f1
    else
        sha256sum "${file}" 2>/dev/null | cut -d' ' -f1
    fi
}

now_epoch() { date +%s; }
