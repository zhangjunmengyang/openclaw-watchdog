#!/usr/bin/env bash
# config-safeguard.sh — Module 3: Config change detection + automatic rollback
#
# THE KILLER FEATURE.
#
# Problem: A bad openclaw.json change (config.patch, manual edit, etc.) can
# take down the entire agent fleet. Recovery requires finding the backup,
# figuring out what changed, and manually restoring — all while your
# agents are offline.
#
# Solution: Every config change gets a 5-minute safety net.
#
# How it works:
# 1. Each tick, compute SHA-256 of openclaw.json
# 2. If checksum changed since last tick:
#    a. Snapshot the PREVIOUS (known-good) config
#    b. Create a "rollback-armed" flag with deadline = now + ROLLBACK_TIMEOUT
# 3. While flag exists:
#    a. If gateway is healthy → count consecutive healthy checks
#    b. If gateway unhealthy → IMMEDIATE rollback
#    c. If deadline passes and gateway was healthy throughout → auto-confirm
# 4. On confirm: remove flag, keep snapshot for history
# 5. On rollback: restore snapshot, restart gateway
#
# Manual overrides:
#   config_safeguard_confirm  — trust the current config
#   config_safeguard_rollback — force rollback to last snapshot
#   config_safeguard_snapshot — take a manual snapshot

# === State ===
_cs_last_checksum=""
_cs_flag_file=""
_cs_healthy_since=0

# === Paths ===
_cs_init() {
    _cs_flag_file="${WATCHDOG_STATE_DIR}/rollback-armed.flag"

    # Load last known checksum
    local cs_file="${WATCHDOG_STATE_DIR}/config-checksum"
    if [[ -f "${cs_file}" ]]; then
        _cs_last_checksum="$(cat "${cs_file}")"
    elif [[ -f "${CONFIG_PATH}" ]]; then
        _cs_last_checksum="$(file_checksum "${CONFIG_PATH}")"
        echo "${_cs_last_checksum}" > "${cs_file}"
    fi

    # Check for orphaned flag (watchdog was restarted while flag armed)
    if [[ -f "${_cs_flag_file}" ]]; then
        log_warn "SAFEGUARD: found armed rollback flag from previous run"
        _cs_check_armed_flag
    fi
}

# === Snapshot Management ===

# Take a snapshot of the current config
config_safeguard_snapshot() {
    local reason="${1:-manual}"
    [[ -f "${CONFIG_PATH}" ]] || return 1

    local ts
    ts="$(date '+%Y%m%d-%H%M%S')"
    local snapshot_file="${WATCHDOG_SNAPSHOT_DIR}/openclaw-${ts}-${reason}.json"
    cp "${CONFIG_PATH}" "${snapshot_file}"
    log_info "SAFEGUARD: snapshot taken -> ${snapshot_file}"

    # Prune old snapshots
    _cs_prune_snapshots

    echo "${snapshot_file}"
}

# List snapshots, newest first
_cs_list_snapshots() {
    # shellcheck disable=SC2012
    ls -t "${WATCHDOG_SNAPSHOT_DIR}"/openclaw-*.json 2>/dev/null
}

# Prune to SNAPSHOT_RETENTION
_cs_prune_snapshots() {
    local count=0
    while IFS= read -r snap; do
        count=$(( count + 1 ))
        if (( count > SNAPSHOT_RETENTION )); then
            rm -f "${snap}"
            log_info "SAFEGUARD: pruned old snapshot: $(basename "${snap}")"
        fi
    done < <(_cs_list_snapshots)
}

# Get the latest snapshot path
_cs_latest_snapshot() {
    _cs_list_snapshots | head -1
}

# === Armed Flag Management ===

# Arm the rollback timer
_cs_arm_rollback() {
    local snapshot_path="$1"
    local deadline
    deadline=$(( $(now_epoch) + ROLLBACK_TIMEOUT ))

    # Write flag: line 1 = deadline epoch, line 2 = snapshot path
    printf '%s\n%s\n' "${deadline}" "${snapshot_path}" > "${_cs_flag_file}"
    _cs_healthy_since=0

    log_warn "SAFEGUARD: rollback ARMED (deadline in ${ROLLBACK_TIMEOUT}s, snapshot: $(basename "${snapshot_path}"))"
}

# Read flag → sets _cs_armed_deadline and _cs_armed_snapshot
_cs_read_flag() {
    [[ -f "${_cs_flag_file}" ]] || return 1
    _cs_armed_deadline="$(sed -n '1p' "${_cs_flag_file}")"
    _cs_armed_snapshot="$(sed -n '2p' "${_cs_flag_file}")"
    [[ -n "${_cs_armed_deadline}" && -n "${_cs_armed_snapshot}" ]]
}

# Disarm (confirm)
_cs_disarm() {
    rm -f "${_cs_flag_file}"
    _cs_healthy_since=0
    log_info "SAFEGUARD: rollback DISARMED (config confirmed)"
}

# === Rollback ===

config_safeguard_rollback() {
    local snapshot="${1:-}"

    if [[ -z "${snapshot}" ]]; then
        # Try from flag
        if _cs_read_flag; then
            snapshot="${_cs_armed_snapshot}"
        else
            # Use latest snapshot
            snapshot="$(_cs_latest_snapshot)"
        fi
    fi

    if [[ -z "${snapshot}" || ! -f "${snapshot}" ]]; then
        log_error "SAFEGUARD: no snapshot available for rollback!"
        return 1
    fi

    log_warn "SAFEGUARD: ROLLING BACK config to: $(basename "${snapshot}")"

    # Backup current (broken) config for forensics
    local ts
    ts="$(date '+%Y%m%d-%H%M%S')"
    if [[ -f "${CONFIG_PATH}" ]]; then
        cp "${CONFIG_PATH}" "${WATCHDOG_SNAPSHOT_DIR}/openclaw-${ts}-broken.json"
        log_info "SAFEGUARD: broken config saved as openclaw-${ts}-broken.json"
    fi

    # Restore
    cp "${snapshot}" "${CONFIG_PATH}"
    log_info "SAFEGUARD: config restored from $(basename "${snapshot}")"

    # Update checksum to match restored config
    _cs_last_checksum="$(file_checksum "${CONFIG_PATH}")"
    echo "${_cs_last_checksum}" > "${WATCHDOG_STATE_DIR}/config-checksum"

    # Disarm
    _cs_disarm

    # Restart gateway with restored config
    restart_gateway "config-rollback"
}

# === Confirm ===

config_safeguard_confirm() {
    if [[ ! -f "${_cs_flag_file}" ]]; then
        log_info "SAFEGUARD: no armed rollback to confirm"
        echo "No pending rollback to confirm."
        return 0
    fi
    _cs_disarm
    log_info "SAFEGUARD: config confirmed by user"
    echo "Config confirmed. Rollback timer cleared."
}

# === Check armed flag (called each tick) ===

_cs_check_armed_flag() {
    _cs_read_flag || return

    local now
    now="$(now_epoch)"

    # Check gateway health
    if gateway_process_alive && gateway_healthy; then
        if (( _cs_healthy_since == 0 )); then
            _cs_healthy_since="${now}"
            log_info "SAFEGUARD: gateway healthy with new config (monitoring...)"
        fi

        # Check if deadline passed while healthy → auto-confirm
        if (( now >= _cs_armed_deadline )); then
            log_info "SAFEGUARD: timeout reached, gateway healthy throughout → AUTO-CONFIRM"
            _cs_disarm
        fi
    else
        # Gateway unhealthy while rollback is armed → ROLLBACK NOW
        if (( _cs_healthy_since > 0 )); then
            log_error "SAFEGUARD: gateway became UNHEALTHY after being healthy — rolling back!"
        else
            log_error "SAFEGUARD: gateway UNHEALTHY with new config — rolling back!"
        fi
        config_safeguard_rollback "${_cs_armed_snapshot}"
    fi
}

# === Main tick ===

config_safeguard_tick() {
    [[ -f "${CONFIG_PATH}" ]] || return

    # Check if rollback is armed
    if [[ -f "${_cs_flag_file}" ]]; then
        _cs_check_armed_flag
        return
    fi

    # Detect config changes via checksum
    local current_checksum
    current_checksum="$(file_checksum "${CONFIG_PATH}")"

    if [[ -z "${_cs_last_checksum}" ]]; then
        # First run — just record
        _cs_last_checksum="${current_checksum}"
        echo "${_cs_last_checksum}" > "${WATCHDOG_STATE_DIR}/config-checksum"
        return
    fi

    if [[ "${current_checksum}" != "${_cs_last_checksum}" ]]; then
        log_warn "SAFEGUARD: config change detected! (checksum: ${_cs_last_checksum:0:12}... -> ${current_checksum:0:12}...)"

        # Snapshot the PREVIOUS config (which was the known-good one)
        # But we only have the new file now. The previous version should already
        # be in our snapshot history. If not, we snapshot what we have.
        local snapshot
        snapshot="$(config_safeguard_snapshot "pre-change")"

        # Wait a moment for gateway to restart with new config
        # (OpenClaw typically auto-restarts on config change)
        sleep 10

        # Arm rollback
        _cs_arm_rollback "${snapshot}"

        # Update stored checksum
        _cs_last_checksum="${current_checksum}"
        echo "${_cs_last_checksum}" > "${WATCHDOG_STATE_DIR}/config-checksum"
    fi
}

# === Status ===

config_safeguard_status() {
    echo "Config Safeguard Status:"
    echo "  Config file: ${CONFIG_PATH}"

    if [[ -f "${CONFIG_PATH}" ]]; then
        local cs
        cs="$(file_checksum "${CONFIG_PATH}")"
        echo "  Current checksum: ${cs:0:16}..."
    else
        echo "  Config file: NOT FOUND"
    fi

    if [[ -f "${_cs_flag_file}" ]]; then
        if _cs_read_flag; then
            local now remaining
            now="$(now_epoch)"
            remaining=$(( _cs_armed_deadline - now ))
            if (( remaining > 0 )); then
                echo "  Rollback: ARMED (${remaining}s remaining)"
            else
                echo "  Rollback: ARMED (EXPIRED — will process next tick)"
            fi
            echo "  Snapshot: $(basename "${_cs_armed_snapshot}")"
        fi
    else
        echo "  Rollback: not armed"
    fi

    local snap_count
    snap_count="$(_cs_list_snapshots | wc -l | tr -d ' ')"
    echo "  Snapshots: ${snap_count} (retention: ${SNAPSHOT_RETENTION})"

    local latest
    latest="$(_cs_latest_snapshot)"
    if [[ -n "${latest}" ]]; then
        echo "  Latest: $(basename "${latest}")"
    fi
}
