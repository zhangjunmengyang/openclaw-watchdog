# openclaw-watchdog

A self-healing reliability watchdog for OpenClaw deployments on macOS (Linux best effort).

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Shell](https://img.shields.io/badge/language-bash-89e051.svg)](#)
[![Platform](https://img.shields.io/badge/platform-macOS%20first-blue.svg)](#)

## Why this exists

When OpenClaw is your daily assistant, stability is your **lifeline**.

This project was built after real production incidents:
- gateway looked alive but stopped doing useful work
- transient network issues caused restart storms
- config changes could silently break all agents

`openclaw-watchdog` turns those lessons into an always-on safety layer.

---

## Core capabilities

### 1) Gateway health monitoring (with exponential backoff)
- process liveness checks
- `/healthz` checks
- network recovery handling (sleep/wake aware)
- proxy health checks
- Discord websocket stuck detection (1006 loops)

### 2) Agent heartbeat freshness checks
- monitors `memory/heartbeat-state.json`
- alerts on stale agents
- detects "gateway alive but scheduler dead" class failures

### 3) Config safeguard (commit-confirmed style)
- detects `openclaw.json` changes by checksum
- arms a 5-minute rollback window
- auto-confirms healthy changes
- auto-rolls back unhealthy changes to last-known-good config
- supports manual confirm/rollback flags

### 4) Config history backup
- periodic git snapshots of critical files
- only commits on actual changes
- keeps an auditable local config history

---

## Architecture

```text
openclaw-watchdog (single loop)
├─ gateway-health      (process/http/proxy/ws)
├─ agent-heartbeat     (staleness checks)
├─ config-safeguard    (auto rollback window)
└─ config-backup       (git snapshots)
```

One process, one LaunchAgent, coordinated modules.

---

## Quick install (macOS)

```bash
git clone https://github.com/zhangjunmengyang/openclaw-watchdog.git
cd openclaw-watchdog
./install.sh
```

Then:

```bash
openclaw-watchdog status
```

---

## Commands

```bash
openclaw-watchdog start          # run watchdog foreground
openclaw-watchdog stop           # stop watchdog
openclaw-watchdog status         # health overview
openclaw-watchdog confirm        # confirm current config (clear rollback timer)
openclaw-watchdog rollback       # rollback to last known good config
openclaw-watchdog snapshot       # manual config snapshot
openclaw-watchdog backup         # run backup now
openclaw-watchdog install        # install LaunchAgent
openclaw-watchdog uninstall      # remove LaunchAgent
openclaw-watchdog logs [module]  # tail logs
```

---

## Config file

Default config template:

```text
config/default.conf
```

Runtime config location:

```text
~/.openclaw/watchdog/config.conf
```

Key knobs:
- `CHECK_INTERVAL`
- `COOLDOWN`
- `BACKOFF_INITIAL`, `BACKOFF_MAX`
- `ROLLBACK_TIMEOUT`
- `HEARTBEAT_THRESHOLD_MIN`
- `PROXY_URL`

---

## Safety controls

### Diagnostic freeze mode
Create this file to disable all auto-restarts while you investigate:

```bash
touch ~/.openclaw/watchdog/diagnostic.freeze
```

Remove it to resume automatic healing:

```bash
rm -f ~/.openclaw/watchdog/diagnostic.freeze
```

### Manual config control
Force rollback:

```bash
touch ~/.openclaw/watchdog/rollback-now.flag
```

Force confirm current config:

```bash
touch ~/.openclaw/watchdog/confirm-now.flag
```

---

## Incident-driven design principles

1. **Timeline first, diagnosis second**
2. **End-to-end signals over single probe signals**
3. **Transient failures must not trigger aggressive restart loops**
4. **Config changes must always have an automatic escape hatch**

---

## Files

```text
openclaw-watchdog.sh
lib/common.sh
lib/gateway-health.sh
lib/agent-heartbeat.sh
lib/config-safeguard.sh
lib/config-backup.sh
config/default.conf
launchd/ai.openclaw.watchdog.plist
docs/DESIGN.md
docs/TROUBLESHOOTING.md
```

---

## Notes

- macOS-first (LaunchAgent workflow)
- Linux support is best-effort
- Pure bash implementation, low dependency surface

---

## License

MIT
