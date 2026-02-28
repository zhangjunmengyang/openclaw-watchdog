# Design Decisions

## Why This Exists

Running an AI agent fleet (OpenClaw + multiple Discord bots) on a single machine means one failure can cascade into total silence. We learned this the hard way:

- **Feb 27**: Gateway process alive, HTTP healthz OK, but heartbeat scheduler dead. 11 hours of silence. Nobody noticed until a human looked.
- **Feb 28**: Network blip. Naive watchdog restarted gateway 10 times in 45 minutes. The "fix" was worse than the problem.
- **Feb 25**: A `config.patch` call replaced all bot tokens with placeholder strings. 6 bots went offline. Recovery required finding a backup file.

Each incident taught us something. This watchdog is the synthesis.

## Architecture: Four Modules, One Process

```
openclaw-watchdog (main loop, 15s tick)
├── gateway-health      ← Is the process alive? Is it responding?
├── agent-heartbeat     ← Are the agents actually doing work?
├── config-safeguard    ← Did the config just change? Is it safe?
└── config-backup       ← Periodic git snapshots of everything
```

One process, one LaunchAgent, one PID file. Replaces three separate scripts that had no coordination.

### Why Not Separate Processes?

The old setup had `network-watchdog.sh`, `heartbeat-watchdog.sh`, and `config-backup.sh` as independent LaunchAgents. Problems:

1. **No coordination**: network-watchdog would restart gateway while heartbeat-watchdog was checking health, causing false positives.
2. **Duplicate logic**: Each script had its own health check, logging, and restart code.
3. **Config inconsistency**: Different cooldown values, different retry logic.

Unified process means modules can share state. Gateway-health knows heartbeat status. Config-safeguard can tell gateway-health to hold off restarts during a rollback.

## Exponential Backoff: The Core Innovation

The old watchdog:
```
health check failed → SIGTERM → restart → health check failed → SIGTERM → ...
```

The new watchdog:
```
health check failed → wait 30s → recheck → still failed → wait 60s → recheck → 
still failed → wait 120s → recheck → still failed → wait 240s → 
ONLY NOW: restart gateway
```

### Why This Matters

Network blips last 10-60 seconds typically. A restart takes 30+ seconds (kill + start + reinitialize all Discord connections). By waiting, we often avoid a restart entirely.

More importantly: each restart resets all Discord WebSocket sessions. If the network is still flaky during reconnection, Discord rate-limits us, making recovery even slower.

### Separate Failure Domains

Not all failures are equal:

| Failure | Type | Action |
|---------|------|--------|
| Process dead | Fatal | Restart immediately |
| Healthz failing, process alive | Maybe transient | Backoff then restart |
| Network down | Transient | Wait for recovery |
| Discord API unreachable | Transient | Don't restart, wait |
| Proxy unhealthy | Maybe transient | 3 strikes then restart |

The old watchdog treated everything as "restart now." That's wrong.

## Config Safeguard: Defense Against Ourselves

The most dangerous entity to an AI agent fleet isn't external attackers — it's the fleet itself making a bad config change.

### The Problem

OpenClaw's `config.patch` writes directly to `openclaw.json` and restarts the gateway. If the patch is wrong (bad token, invalid JSON, missing field), the gateway comes up broken. With 7 bots sharing one config, one mistake takes down everything.

### The Solution: Dead Man's Switch

Inspired by network router `commit confirmed`:

1. Config changes → automatic snapshot of previous config
2. 5-minute timer starts
3. If gateway stays healthy → timer expires → config confirmed
4. If gateway dies → **immediate rollback** → restart with old config

This means: you can't permanently break your config. The worst case is 5 minutes of downtime, after which the system self-heals.

### Flag File Protocol

```
~/.openclaw/watchdog/state/rollback-armed.flag
```

Line 1: deadline epoch (when to auto-confirm)
Line 2: path to snapshot file

Why a file and not an in-memory flag? Because if the watchdog itself crashes and restarts, it picks up the flag and continues monitoring. Crash-safe by design.

## Pure Bash: No Runtime Dependencies

This watchdog must be the most reliable piece of software on the machine. If it depends on Node.js (which it's monitoring) or Python packages (which can break), it's not reliable.

Pure Bash + coreutils means:
- No package manager needed
- No version conflicts
- Works on fresh macOS installs
- Starts in milliseconds

The only exception: `python3 -c` for JSON parsing, which is pre-installed on macOS and available on every Linux distro.

## Snapshot Strategy

Two independent snapshot mechanisms:

1. **Config safeguard snapshots** (`~/.openclaw/watchdog/snapshots/`): Triggered on config change. Fast, targeted (only openclaw.json). Used for rollback.

2. **Config backup git repo** (`~/.openclaw/watchdog/config-history/`): Hourly, comprehensive (config + workspace files + plists). Used for "what changed last week?"

Why both? Different purposes, different timescales, different retention policies.

## What This Doesn't Do

- **Not a monitoring dashboard**: No web UI, no Grafana integration. It's a CLI tool.
- **Not a distributed coordinator**: Single-machine only. If you need cross-machine, use proper orchestration.
- **Not an OpenClaw replacement**: This monitors OpenClaw, not replaces its built-in health monitoring.
- **Not an auto-updater**: It won't update OpenClaw. That's a human decision.

## Platform Support

Primary: **macOS** (LaunchAgent, `sysctl` for uptime, `shasum`)
Secondary: **Linux** (systemd hints, `/proc/uptime`, `sha256sum`)

macOS-first because that's where most individual OpenClaw deployments run (developer laptops, Mac Minis as home servers). Linux support is best-effort but the core logic is portable.
