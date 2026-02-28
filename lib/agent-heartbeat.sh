#!/usr/bin/env bash
# agent-heartbeat.sh — Module 2: Agent heartbeat freshness monitoring
#
# Checks each configured agent's heartbeat-state.json for staleness.
# If agents are stale but gateway is running → log warning.
# If gateway is stopped → auto-restart.
#
# Called from the main loop at HEARTBEAT_CHECK_INTERVAL cadence.

_ah_last_check=0

# Parse lastHeartbeat from an agent's heartbeat-state.json → epoch seconds
_parse_heartbeat_epoch() {
    local workspace="$1"
    local file="${workspace}/memory/heartbeat-state.json"
    [[ -f "${file}" ]] || { echo "0"; return; }

    python3 -c "
import json, sys
from datetime import datetime, timezone

def parse_ts(ts):
    # Handle various ISO formats
    for fmt in ('%Y-%m-%dT%H:%M:%S%z', '%Y-%m-%dT%H:%M:%S.%f%z',
                '%Y-%m-%dT%H:%M%z', '%Y-%m-%dT%H:%M:%S'):
        try:
            # Normalize timezone offset
            normalized = ts.replace('+08:00', '+0800').replace('+00:00', '+0000')
            dt = datetime.strptime(normalized, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return int(dt.timestamp())
        except ValueError:
            continue
    return 0

try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    ts = d.get('lastHeartbeat', '')
    print(parse_ts(ts))
except Exception:
    print(0)
" "${file}" 2>/dev/null
}

# Check all configured agents
agent_heartbeat_tick() {
    local now
    now="$(now_epoch)"

    # Rate limit: only check at configured interval
    if (( _ah_last_check > 0 )); then
        local elapsed=$(( now - _ah_last_check ))
        if (( elapsed < HEARTBEAT_CHECK_INTERVAL )); then
            return
        fi
    fi
    _ah_last_check="${now}"

    [[ -n "${AGENT_WORKSPACES}" ]] || return  # no agents configured

    local stale_agents=()
    local checked=0

    for entry in ${AGENT_WORKSPACES}; do
        local name="${entry%%:*}"
        local workspace="${entry#*:}"

        # Expand ~ if present
        workspace="${workspace/#\~/$HOME}"

        if [[ ! -d "${workspace}" ]]; then
            log_warn "HEARTBEAT: workspace not found for ${name}: ${workspace}"
            continue
        fi

        local last_epoch
        last_epoch="$(_parse_heartbeat_epoch "${workspace}")"
        checked=$(( checked + 1 ))

        if (( last_epoch == 0 )); then
            log_warn "HEARTBEAT: no valid timestamp for ${name}"
            continue
        fi

        local diff_min=$(( (now - last_epoch) / 60 ))
        if (( diff_min > HEARTBEAT_THRESHOLD_MIN )); then
            stale_agents+=("${name}(${diff_min}min)")
            log_warn "HEARTBEAT: ${name} stale by ${diff_min}min (threshold: ${HEARTBEAT_THRESHOLD_MIN}min)"
        fi
    done

    if (( ${#stale_agents[@]} > 0 )); then
        log_error "HEARTBEAT: stale agents: ${stale_agents[*]}"

        # If gateway is not healthy, try restarting it
        if ! gateway_process_alive; then
            log_error "HEARTBEAT: gateway process dead, restarting"
            restart_gateway "agents-stale-gateway-dead"
        elif ! gateway_healthy; then
            log_warn "HEARTBEAT: gateway process alive but unhealthy, agents stale"
            # Don't restart here — let gateway-health module handle it with backoff
        else
            log_warn "HEARTBEAT: gateway healthy but ${#stale_agents[@]}/${checked} agents stale — possible scheduler issue"
        fi
    elif (( checked > 0 )); then
        log_info "HEARTBEAT: all ${checked} agents OK"
    fi
}
