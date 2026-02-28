#!/usr/bin/env bash
# uninstall.sh — Remove openclaw-watchdog
set -euo pipefail

echo "=== openclaw-watchdog uninstaller ==="

# Stop and remove LaunchAgent
LABEL="ai.openclaw.watchdog"
if launchctl list "${LABEL}" &>/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    echo "Stopped LaunchAgent: ${LABEL}"
fi
rm -f "${HOME}/Library/LaunchAgents/${LABEL}.plist"

# Remove symlink
if [[ -L "/usr/local/bin/openclaw-watchdog" ]]; then
    rm -f "/usr/local/bin/openclaw-watchdog"
    echo "Removed symlink: /usr/local/bin/openclaw-watchdog"
fi

echo ""
echo "LaunchAgent removed. Watchdog stopped."
echo ""
echo "Config and snapshots preserved at: ~/.openclaw/watchdog/"
echo "To remove everything: rm -rf ~/.openclaw/watchdog/"
echo ""
echo "Note: This does NOT remove the git clone. Delete it manually if desired."
