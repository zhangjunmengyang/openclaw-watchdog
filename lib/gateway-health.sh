#!/usr/bin/env bash
# gateway-health.sh — Module 1: Gateway process monitoring with exponential backoff
#
# Unlike a naive watchdog that restarts on every failure,
# this module distinguishes transient issues (network blips)
# from fatal failures (process dead) and uses exponential backoff
# to avoid restart storms.
#
# Called from the main loop. Not standalone.

# === State ===
_gh_last_restart=0
_gh_health_backoff=0        # current backoff wait (0 = no backoff active)
_gh_health_fail_start=0     # epoch when first failure detected
_gh_network_was_down=false
_gh_last_uptime=0
_gh_proxy_fail_count=0
_gh_loop_count=0

# === Exponential Backoff Engine ===
# Returns 0 if we should restart now, 1 if we should keep waiting.
#
# Flow:
#   first failure  →  record start time, set backoff = BACKOFF_INITIAL
#   each cycle     →  if (now - fail_start) >= backoff, double backoff and recheck
#   if backoff > BACKOFF_MAX → give up waiting, return 0 (restart)
#   if health recovers at any point → reset everything

backoff_should_restart() {
    local now
    now="$(now_epoch)"

    if (( _gh_health_backoff == 0 )); then
        # First failure — start backoff
        _gh_health_fail_start="${now}"
        _gh_health_backoff="${BACKOFF_INITIAL}"
        log_warn "BACKOFF: health check failed, starting backoff (wait ${_gh_health_backoff}s)"
        return 1  # don't restart yet
    fi

    local elapsed=$(( now - _gh_health_fail_start ))

    if (( elapsed < _gh_health_backoff )); then
        # Still within current backoff window
        local remaining=$(( _gh_health_backoff - elapsed ))
        log_info "BACKOFF: waiting (${remaining}s remaining in ${_gh_health_backoff}s window)"
        return 1
    fi

    # Backoff window expired — recheck and escalate
    if gateway_healthy; then
        backoff_reset
        log_info "BACKOFF: gateway recovered during backoff"
        return 1
    fi

    # Still unhealthy — escalate
    local next_backoff=$(( _gh_health_backoff * BACKOFF_MULTIPLIER ))
    if (( next_backoff > BACKOFF_MAX )); then
        log_error "BACKOFF: max backoff reached (${BACKOFF_MAX}s), authorizing restart"
        backoff_reset
        return 0  # restart now
    fi

    _gh_health_backoff="${next_backoff}"
    _gh_health_fail_start="${now}"
    log_warn "BACKOFF: escalating to ${_gh_health_backoff}s"
    return 1
}

backoff_reset() {
    if (( _gh_health_backoff > 0 )); then
        log_info "BACKOFF: reset (was ${_gh_health_backoff}s)"
    fi
    _gh_health_backoff=0
    _gh_health_fail_start=0
}

# === Cooldown ===
in_cooldown() {
    local now elapsed
    now="$(now_epoch)"
    elapsed=$(( now - _gh_last_restart ))
    (( elapsed < COOLDOWN ))
}

do_restart() {
    local reason="$1"
    if in_cooldown; then
        local now elapsed
        now="$(now_epoch)"
        elapsed=$(( now - _gh_last_restart ))
        log_info "COOLDOWN: skipping restart (${elapsed}s/${COOLDOWN}s), reason=${reason}"
        return 1
    fi
    restart_gateway "${reason}"
    _gh_last_restart="$(now_epoch)"
    backoff_reset
    _gh_proxy_fail_count=0
}

# === Detection: Wake from sleep ===
check_wake_from_sleep() {
    local current_uptime
    current_uptime="$(get_uptime_seconds)"

    if (( _gh_last_uptime > 0 )); then
        # Uptime decreased → system rebooted
        if (( current_uptime < _gh_last_uptime )); then
            log_info "WAKE: system reboot detected (uptime: ${_gh_last_uptime}s -> ${current_uptime}s)"
            _gh_last_uptime="${current_uptime}"
            return 0
        fi

        # Uptime jumped too much → was sleeping
        local expected_max=$(( _gh_last_uptime + CHECK_INTERVAL * 10 ))
        if (( current_uptime > expected_max )); then
            local gap=$(( current_uptime - _gh_last_uptime - CHECK_INTERVAL ))
            log_info "WAKE: sleep/wake detected (gap ~${gap}s)"
            _gh_last_uptime="${current_uptime}"
            return 0
        fi
    fi

    _gh_last_uptime="${current_uptime}"
    return 1
}

# === Detection: Network recovery ===
check_network_recovery() {
    if is_online; then
        if [[ "${_gh_network_was_down}" == "true" ]]; then
            log_info "NETWORK: recovered, settling ${TUN_SETTLE}s..."
            sleep "${TUN_SETTLE}"
            if is_online && discord_reachable; then
                _gh_network_was_down=false
                return 0
            fi
            log_warn "NETWORK: still unstable after settle, skipping restart"
            _gh_network_was_down=false
        fi
    else
        if [[ "${_gh_network_was_down}" != "true" ]]; then
            log_warn "NETWORK: went down"
            _gh_network_was_down=true
        fi
    fi
    return 1
}

# === Detection: Gateway health (with backoff) ===
check_gateway_health() {
    # Fatal: process dead → restart immediately (no backoff)
    if ! gateway_process_alive; then
        log_error "FATAL: gateway process not found"
        sleep 5
        if ! gateway_process_alive; then
            log_error "FATAL: still dead after 5s, restarting"
            do_restart "process-dead"
            return
        fi
        log_info "RECOVERY: process appeared (launchd auto-restart?)"
        return
    fi

    # Non-fatal: process alive but healthz failing → backoff
    if ! gateway_healthy; then
        if backoff_should_restart; then
            do_restart "unhealthy-after-backoff"
        fi
        return
    fi

    # Healthy — reset backoff if active
    backoff_reset
}

# === Detection: Proxy health ===
check_proxy_health() {
    [[ -n "${PROXY_URL}" ]] || return  # disabled

    if ! proxy_healthy; then
        _gh_proxy_fail_count=$(( _gh_proxy_fail_count + 1 ))
        if (( _gh_proxy_fail_count >= PROXY_FAIL_THRESHOLD )); then
            log_error "PROXY: ${_gh_proxy_fail_count} consecutive failures, restarting gateway"
            _gh_proxy_fail_count=0
            do_restart "proxy-unhealthy"
        else
            log_warn "PROXY: check failed (${_gh_proxy_fail_count}/${PROXY_FAIL_THRESHOLD})"
        fi
    else
        if (( _gh_proxy_fail_count > 0 )); then
            log_info "PROXY: recovered (was ${_gh_proxy_fail_count} failures)"
        fi
        _gh_proxy_fail_count=0
    fi
}

# === Main tick (called every CHECK_INTERVAL from main loop) ===
gateway_health_tick() {
    _gh_loop_count=$(( _gh_loop_count + 1 ))

    # 1. Wake from sleep
    if check_wake_from_sleep; then
        sleep "${TUN_SETTLE}"
        if is_online; then
            do_restart "wake-from-sleep"
        else
            log_info "WAKE: network not ready, deferring"
        fi
        return
    fi

    # 2. Network recovery
    if check_network_recovery; then
        do_restart "network-recovery"
        return
    fi

    # Skip remaining checks if network is down
    if [[ "${_gh_network_was_down}" == "true" ]] || ! is_online; then
        return
    fi

    # 3. Gateway health (with backoff)
    check_gateway_health

    # 4. Proxy health (every PROXY_CHECK_INTERVAL ticks)
    if (( _gh_loop_count % PROXY_CHECK_INTERVAL == 0 )); then
        check_proxy_health
    fi
}
