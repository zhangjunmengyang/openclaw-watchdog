# Troubleshooting

## Common Issues

### Watchdog starts but gateway never restarts

**Symptoms**: `openclaw-watchdog status` shows gateway unhealthy, but no restarts in logs.

**Cause**: Likely in cooldown period. After a restart, the watchdog waits `COOLDOWN` seconds (default: 120) before allowing another.

**Fix**: Check logs for "COOLDOWN: skipping restart" messages. If the cooldown is too long for your use case, reduce `COOLDOWN` in config.

### Restart storm (multiple rapid restarts)

**Symptoms**: Logs show many restarts in quick succession.

**Cause**: This was the exact problem openclaw-watchdog was built to solve! If you're seeing this, the exponential backoff may not be tuned for your environment.

**Fix**: 
1. Check if `BACKOFF_INITIAL` is too low (increase to 60s+)
2. Check if `BACKOFF_MAX` is too low (increase to 600s)
3. Check network stability — frequent network drops will trigger restarts

### Config rollback triggered unexpectedly

**Symptoms**: Config changes keep getting rolled back even though they're valid.

**Cause**: Gateway takes too long to start with new config, or healthz doesn't return 200 within the rollback timeout.

**Fix**:
1. Increase `ROLLBACK_TIMEOUT` (e.g., from 300 to 600 seconds)
2. After making a change, run `openclaw-watchdog confirm` to immediately accept it
3. Check `openclaw-watchdog status` to see the armed timer

### Agent heartbeat alerts but gateway is healthy

**Symptoms**: Heartbeat module reports stale agents, but gateway health is fine.

**Cause**: The gateway is running but not dispatching heartbeats to agents. This was exactly the Feb 27 failure mode — process alive, HTTP OK, but scheduler dead.

**Fix**: 
1. Restart the gateway: `openclaw gateway restart`
2. If persistent, check OpenClaw logs for heartbeat scheduler errors
3. Consider reducing `HEARTBEAT_THRESHOLD_MIN` for faster detection

### Watchdog can't restart gateway on macOS

**Symptoms**: "launchctl kickstart" errors in logs.

**Cause**: LaunchAgent label mismatch, or gateway isn't registered with launchd.

**Fix**:
1. Verify gateway label: `launchctl list | grep openclaw`
2. Update `GATEWAY_LAUNCHD_LABEL` in config to match
3. Ensure gateway plist has `KeepAlive: true`

### Logs growing too large

**Symptoms**: Disk space warnings, large files in `~/.openclaw/logs/`.

**Fix**: 
1. Reduce `MAX_LOG_LINES` (default: 5000)
2. Logs auto-trim every 100 ticks
3. Manual cleanup: `rm ~/.openclaw/logs/watchdog-*.log`

### Permission denied errors

**Symptoms**: Watchdog can't write to state/snapshot directories.

**Fix**:
```bash
chmod -R u+rw ~/.openclaw/watchdog/
chmod -R u+rw ~/.openclaw/logs/
```

## Diagnostic Commands

```bash
# Full status overview
openclaw-watchdog status

# Watch gateway health in real-time
openclaw-watchdog logs main

# Check if config change is pending confirmation
openclaw-watchdog status | grep "Rollback:"

# Force confirm a config change
openclaw-watchdog confirm

# Force rollback
openclaw-watchdog rollback

# Manual snapshot before risky changes
openclaw-watchdog snapshot

# Check gateway directly
curl -s http://127.0.0.1:18789/healthz
pgrep -f "openclaw.*gateway"

# Check agent heartbeats manually
cat ~/.openclaw/workspace/memory/heartbeat-state.json | python3 -m json.tool
```

## Log Message Reference

| Prefix | Meaning |
|--------|---------|
| `BACKOFF:` | Exponential backoff state changes |
| `COOLDOWN:` | Restart skipped due to cooldown |
| `RESTART:` | Gateway restart initiated |
| `FATAL:` | Gateway process dead (immediate restart) |
| `NETWORK:` | Network state changes |
| `WAKE:` | Sleep/wake detection |
| `PROXY:` | Proxy health check results |
| `HEARTBEAT:` | Agent heartbeat freshness |
| `SAFEGUARD:` | Config change detection and rollback |
| `BACKUP:` | Git-based config backup |
| `LOG_TRIM:` | Log file size management |

## Getting Help

1. Check the logs: `openclaw-watchdog logs main`
2. Check the design doc: `docs/DESIGN.md`
3. File an issue: https://github.com/zhangjunmengyang/openclaw-watchdog/issues
4. OpenClaw community: https://discord.com/invite/clawd
