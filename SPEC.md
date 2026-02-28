# openclaw-watchdog — Specification

## Overview

A self-healing watchdog system for OpenClaw gateway deployments on macOS. Consolidates three previously separate scripts (network-watchdog, heartbeat-watchdog, config-backup) into a unified, production-quality tool with a critical new feature: **config safeguard with automatic rollback**.

The target user is anyone running OpenClaw on a Mac (or Linux) who needs their agent fleet to stay alive 24/7 without manual intervention.

## Architecture

One main entry point: `openclaw-watchdog.sh` (pure Bash, zero external dependencies beyond standard macOS tools + python3 for JSON parsing).

### Four Modules

#### 1. Gateway Health (`lib/gateway-health.sh`)
Monitors the OpenClaw gateway process and restarts it when necessary.

**Checks (every 15s):**
- Gateway process alive (pgrep)
- HTTP health check (`/healthz`)
- Discord API reachable (as indicator of network connectivity)
- LLM API reachable via proxy
- Discord WebSocket stuck detection (1006 error loop)
- Wake-from-sleep detection (uptime jump)

**Key improvement over current: Exponential Backoff**
- First failure: wait 30s, recheck
- Second failure: wait 60s, recheck
- Third failure: wait 120s, recheck
- Fourth failure: restart gateway
- Max backoff: 5 minutes
- Reset backoff counter on successful health check
- Separate backoff counters for different failure types

**Key improvement: Distinguish transient vs fatal**
- Network unreachable → wait for recovery, don't restart (transient)
- Gateway process dead → restart immediately (fatal)
- Gateway process alive but healthz fails → backoff then restart (maybe transient)
- Discord channels exited but gateway healthy → DON'T restart, wait for reconnect (transient)

#### 2. Agent Heartbeat (`lib/agent-heartbeat.sh`)
Monitors agent heartbeat freshness.

**Checks (every 10 minutes via internal timer):**
- Read each agent's `memory/heartbeat-state.json`
- If `lastHeartbeat` > threshold (default 120min) → alert
- If gateway is running but agents are stale → log warning
- If gateway is stopped → auto-restart

**Configurable per-agent thresholds** via config file.

#### 3. Config Safeguard (`lib/config-safeguard.sh`) ⭐ NEW — KILLER FEATURE
Automatic rollback of openclaw.json changes if not confirmed.

**How it works:**
1. **Pre-change snapshot**: Detect config file modification (via checksum comparison each cycle)
2. **Armed rollback timer**: After detecting change, create flag file with 5-minute deadline
3. **Health validation**: During 5 minutes, continuously check gateway health with new config
4. **Three outcomes:**
   - ✅ Gateway healthy for full 5 minutes → confirm, archive snapshot
   - ❌ Gateway unhealthy at any point → immediate rollback + restart
   - ⏰ 5 minutes elapsed with intermittent issues → rollback to be safe

**Flag file mechanism:**
- `~/.openclaw/watchdog/rollback-armed.flag` — contains timestamp + snapshot path
- Watchdog checks flag every cycle: if expired → rollback
- If gateway crashes while flag armed → rollback on restart

**Manual CLI:**
- `openclaw-watchdog confirm` — manually confirm current config
- `openclaw-watchdog rollback` — manually trigger rollback
- `openclaw-watchdog snapshot` — take manual snapshot

**Snapshot retention:** Last 20, auto-prune.

#### 4. Config Backup (`lib/config-backup.sh`)
Periodic git-based snapshots of all critical files.

**Files tracked:**
- `~/.openclaw/openclaw.json`
- Workspace core files (AGENTS.md, SOUL.md, MEMORY.md, etc.)
- LaunchAgent plists
- Watchdog config

**Schedule:** Every hour, only commits on change.
**Retention:** Last 30 commits.

## CLI Interface

```
openclaw-watchdog start          # Start all modules (foreground, for launchd)
openclaw-watchdog stop           # Stop gracefully
openclaw-watchdog status         # Show health of all modules + armed timers
openclaw-watchdog confirm        # Confirm current config (clear rollback timer)
openclaw-watchdog rollback       # Force rollback to last known good config
openclaw-watchdog snapshot       # Take manual config snapshot
openclaw-watchdog install        # Install unified LaunchAgent plist
openclaw-watchdog uninstall      # Remove LaunchAgent plist
openclaw-watchdog logs [module]  # Tail logs
```

## Configuration

`~/.openclaw/watchdog/config.conf` (sourced by main script):

```bash
# Gateway health
HEALTH_CHECK_URL="http://127.0.0.1:18789/healthz"
CHECK_INTERVAL=15
BACKOFF_INITIAL=30
BACKOFF_MAX=300
BACKOFF_MULTIPLIER=2
COOLDOWN=120

# Network
PING_TARGET="8.8.8.8"
DISCORD_CHECK_URL="https://discord.com/api/v10/gateway"

# Proxy (blank to disable)
PROXY_URL=""
LLM_API_CHECK_URL="https://api.anthropic.com"

# Agent heartbeat
HEARTBEAT_CHECK_INTERVAL=600  # 10 minutes in seconds
HEARTBEAT_THRESHOLD_MIN=120
AGENT_WORKSPACES="main:$HOME/.openclaw/workspace sentinel:$HOME/.openclaw/workspace-sentinel scholar:$HOME/.openclaw/workspace-scholar librarian:$HOME/.openclaw/workspace-librarian"

# Config safeguard
CONFIG_PATH="$HOME/.openclaw/openclaw.json"
ROLLBACK_TIMEOUT=300
SNAPSHOT_RETENTION=20

# Config backup
BACKUP_INTERVAL=3600
BACKUP_RETENTION=30

# Logging
LOG_DIR="$HOME/.openclaw/logs"
MAX_LOG_LINES=5000
```

## Directory Structure

```
openclaw-watchdog/
├── README.md
├── LICENSE                     # MIT
├── install.sh                  # One-command installer
├── uninstall.sh
├── openclaw-watchdog.sh        # Main entry point + CLI router
├── lib/
│   ├── common.sh               # Shared utilities (logging, config, etc.)
│   ├── gateway-health.sh       # Module 1: Gateway process monitoring
│   ├── agent-heartbeat.sh      # Module 2: Agent heartbeat monitoring
│   ├── config-safeguard.sh     # Module 3: Config change detection + rollback
│   └── config-backup.sh        # Module 4: Git-based config snapshots
├── config/
│   └── default.conf            # Default configuration template
├── launchd/
│   └── ai.openclaw.watchdog.plist
└── docs/
    ├── DESIGN.md
    └── TROUBLESHOOTING.md
```

## Design Principles

1. **Pure Bash** — no Node/Python runtime dependency (python3 only for JSON, pre-installed on macOS)
2. **Unified LaunchAgent** — one plist replaces three separate ones
3. **Exponential backoff** — learned from 2/28 restart storm
4. **Config safeguard first-class** — every config change gets a 5-min safety net
5. **Defensive by default** — if unsure, don't restart. Running-but-degraded > restart loop
6. **Observable** — every decision logged with reasoning. `status` shows everything

## Recovery Priority Order

1. Config safeguard (protect against self-inflicted config wounds)
2. Gateway process health (is the process alive and responding?)
3. Network recovery (wake from sleep, reconnect after outage)
4. Agent heartbeat (are agents actually doing their jobs?)

## Lessons That Shaped This Design

- **2/27**: Gateway stopped 11h. Process alive, healthz OK, but heartbeat scheduler dead. → Need heartbeat-level monitoring.
- **2/28**: Network blip → restart storm (10 SIGTERMs/45min). → Need backoff + transient vs fatal distinction.
- **2/25**: config.patch destroyed all bot tokens. → Need auto-snapshot + rollback.
