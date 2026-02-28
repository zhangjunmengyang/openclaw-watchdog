#!/usr/bin/env bash
# openclaw-watchdog — Self-healing watchdog for OpenClaw gateway
#
# Usage: openclaw-watchdog <command>
#
# Commands:
#   start       Start watchdog (foreground, for launchd/systemd)
#   stop        Stop running watchdog
#   status      Show health of all modules
#   confirm     Confirm current config (clear rollback timer)
#   rollback    Force rollback to last known good config
#   snapshot    Take manual config snapshot
#   backup      Run config backup now
#   install     Install LaunchAgent (macOS)
#   uninstall   Remove LaunchAgent
#   logs        Tail watchdog logs
#   version     Show version
#   help        Show this help
#
# For more info: https://github.com/zhangjunmengyang/openclaw-watchdog

set -euo pipefail

# Resolve script directory (works with symlinks)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source modules
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Initialize
watchdog_init
log_init "main"

# Source module libraries
# shellcheck source=lib/gateway-health.sh
source "${SCRIPT_DIR}/lib/gateway-health.sh"
# shellcheck source=lib/agent-heartbeat.sh
source "${SCRIPT_DIR}/lib/agent-heartbeat.sh"
# shellcheck source=lib/config-safeguard.sh
source "${SCRIPT_DIR}/lib/config-safeguard.sh"
# shellcheck source=lib/config-backup.sh
source "${SCRIPT_DIR}/lib/config-backup.sh"

# === PID file ===
PIDFILE="${WATCHDOG_STATE_DIR}/watchdog.pid"

_write_pid() {
    echo $$ > "${PIDFILE}"
}

_check_running() {
    if [[ -f "${PIDFILE}" ]]; then
        local pid
        pid="$(cat "${PIDFILE}")"
        if kill -0 "${pid}" 2>/dev/null; then
            echo "${pid}"
            return 0
        fi
        # Stale PID file
        rm -f "${PIDFILE}"
    fi
    return 1
}

# === Commands ===

cmd_start() {
    local existing_pid
    if existing_pid="$(_check_running)"; then
        echo "Watchdog already running (PID ${existing_pid})"
        exit 1
    fi

    WATCHDOG_FOREGROUND="${WATCHDOG_FOREGROUND:-true}"
    _write_pid

    # Initialize modules
    _cs_init
    _cb_init

    log_info "========== openclaw-watchdog v${WATCHDOG_VERSION} started =========="
    log_info "PID: $$"
    log_info "Config: CHECK_INTERVAL=${CHECK_INTERVAL}s BACKOFF=${BACKOFF_INITIAL}/${BACKOFF_MAX}s COOLDOWN=${COOLDOWN}s"
    log_info "Config safeguard: ROLLBACK_TIMEOUT=${ROLLBACK_TIMEOUT}s SNAPSHOTS=${SNAPSHOT_RETENTION}"

    if [[ -n "${AGENT_WORKSPACES}" ]]; then
        log_info "Agent heartbeat: interval=${HEARTBEAT_CHECK_INTERVAL}s threshold=${HEARTBEAT_THRESHOLD_MIN}min"
    fi

    # Trap for clean shutdown
    trap _shutdown SIGTERM SIGINT

    local loop_count=0

    while true; do
        loop_count=$(( loop_count + 1 ))

        # Module 1: Gateway health (every tick)
        gateway_health_tick

        # Module 2: Agent heartbeat (self-rate-limited)
        agent_heartbeat_tick

        # Module 3: Config safeguard (every tick)
        config_safeguard_tick

        # Module 4: Config backup (self-rate-limited)
        config_backup_tick

        # Periodic log trim
        if (( loop_count % 100 == 0 )); then
            log_trim
        fi

        sleep "${CHECK_INTERVAL}"
    done
}

_shutdown() {
    log_info "Shutting down (signal received)"
    rm -f "${PIDFILE}"
    exit 0
}

cmd_stop() {
    local pid
    if pid="$(_check_running)"; then
        kill "${pid}"
        echo "Watchdog stopped (PID ${pid})"
        rm -f "${PIDFILE}"
    else
        echo "Watchdog not running"
    fi
}

cmd_status() {
    echo "=== openclaw-watchdog v${WATCHDOG_VERSION} ==="
    echo ""

    # Running status
    local pid
    if pid="$(_check_running)"; then
        echo "Watchdog: RUNNING (PID ${pid})"
    else
        echo "Watchdog: NOT RUNNING"
    fi
    echo ""

    # Gateway status
    echo "Gateway:"
    if gateway_process_alive; then
        local gw_pid
        gw_pid="$(pgrep -f "openclaw.*gateway" | head -1 || true)"
        if [[ -z "${gw_pid}" ]]; then
            gw_pid="$(ps -Ao pid,command | grep -E 'openclaw-gateway|openclaw.*gateway|index\\.js gateway' | grep -v grep | awk 'NR==1{print $1}')"
        fi
        [[ -z "${gw_pid}" ]] && gw_pid="?"
        echo "  Process: alive (PID ${gw_pid})"
    else
        echo "  Process: NOT FOUND"
    fi
    if gateway_healthy; then
        echo "  Health: OK"
    else
        echo "  Health: UNHEALTHY"
    fi
    echo "  Network: $(is_online && echo 'online' || echo 'offline')"
    echo "  Discord: $(discord_reachable && echo 'reachable' || echo 'unreachable')"
    echo ""

    # Config safeguard
    _cs_init 2>/dev/null
    config_safeguard_status
    echo ""

    # Config backup
    _cb_init 2>/dev/null
    config_backup_status
}

cmd_confirm() {
    _cs_init 2>/dev/null
    config_safeguard_confirm
}

cmd_rollback() {
    _cs_init 2>/dev/null
    config_safeguard_rollback "$@"
}

cmd_snapshot() {
    _cs_init 2>/dev/null
    local path
    path="$(config_safeguard_snapshot "manual")"
    echo "Snapshot saved: ${path}"
}

cmd_backup() {
    _cb_init 2>/dev/null
    config_backup_now
}

cmd_install() {
    local plist_src="${SCRIPT_DIR}/launchd/ai.openclaw.watchdog.plist"
    local plist_dest="${HOME}/Library/LaunchAgents/ai.openclaw.watchdog.plist"

    if [[ ! -f "${plist_src}" ]]; then
        echo "Error: LaunchAgent plist not found at ${plist_src}"
        exit 1
    fi

    # Substitute paths in plist
    sed "s|__WATCHDOG_PATH__|${SCRIPT_DIR}/openclaw-watchdog.sh|g; s|__HOME__|${HOME}|g" \
        "${plist_src}" > "${plist_dest}"

    echo "LaunchAgent installed: ${plist_dest}"

    # Unload old watchdog agents if they exist
    local old_agents=("ai.openclaw.network-watchdog" "ai.openclaw.heartbeat-watchdog")
    for agent in "${old_agents[@]}"; do
        if launchctl list "${agent}" &>/dev/null; then
            echo "Unloading old agent: ${agent}"
            launchctl bootout "gui/$(id -u)/${agent}" 2>/dev/null || true
        fi
    done

    # Load new unified agent
    launchctl bootstrap "gui/$(id -u)" "${plist_dest}" 2>/dev/null || true
    echo "Watchdog loaded and started."
    echo ""
    echo "Old agents (network-watchdog, heartbeat-watchdog) have been unloaded."
    echo "You can safely remove their plist files from ~/Library/LaunchAgents/"
}

cmd_uninstall() {
    local label="ai.openclaw.watchdog"
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    rm -f "${HOME}/Library/LaunchAgents/${label}.plist"
    echo "Watchdog uninstalled."
}

cmd_logs() {
    local module="${1:-main}"
    local log_file="${WATCHDOG_LOG_DIR}/watchdog-${module}.log"

    if [[ ! -f "${log_file}" ]]; then
        echo "No log file: ${log_file}"
        echo "Available: $(ls "${WATCHDOG_LOG_DIR}"/watchdog-*.log 2>/dev/null | xargs -I{} basename {} .log | sed 's/watchdog-//' | tr '\n' ' ')"
        exit 1
    fi

    tail -f "${log_file}"
}

cmd_version() {
    echo "openclaw-watchdog v${WATCHDOG_VERSION}"
}

cmd_help() {
    cat << 'HELP'
openclaw-watchdog — Self-healing watchdog for OpenClaw gateway

USAGE:
    openclaw-watchdog <command> [args]

COMMANDS:
    start       Start watchdog (foreground, designed for launchd/systemd)
    stop        Stop running watchdog gracefully
    status      Show health of all modules, armed rollbacks, gateway status
    confirm     Confirm current config (clear the 5-minute rollback timer)
    rollback    Force rollback to the last known good config
    snapshot    Take a manual config snapshot
    backup      Run config backup to git history now
    install     Install macOS LaunchAgent (replaces old watchdog agents)
    uninstall   Remove LaunchAgent
    logs [mod]  Tail logs (mod: main|gateway-health|heartbeat|config)
    version     Show version
    help        Show this help

CONFIG SAFEGUARD:
    When openclaw.json changes, a 5-minute rollback timer starts automatically.
    If the gateway stays healthy for 5 minutes, the new config is confirmed.
    If the gateway becomes unhealthy, the config is rolled back immediately.

    Use 'confirm' to skip the wait, or 'rollback' to force a restore.

CONFIGURATION:
    Edit ~/.openclaw/watchdog/config.conf to customize behavior.
    See config/default.conf for all available options.

MORE INFO:
    https://github.com/zhangjunmengyang/openclaw-watchdog
HELP
}

# === Main ===
case "${1:-help}" in
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    status)    cmd_status ;;
    confirm)   cmd_confirm ;;
    rollback)  shift; cmd_rollback "$@" ;;
    snapshot)  cmd_snapshot ;;
    backup)    cmd_backup ;;
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    logs)      shift; cmd_logs "$@" ;;
    version)   cmd_version ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'openclaw-watchdog help' for usage."
        exit 1
        ;;
esac
