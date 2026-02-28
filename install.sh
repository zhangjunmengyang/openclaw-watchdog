#!/usr/bin/env bash
# install.sh — One-command installer for openclaw-watchdog
#
# Usage:
#   git clone https://github.com/zhangjunmengyang/openclaw-watchdog.git
#   cd openclaw-watchdog
#   ./install.sh
#
# Or from anywhere:
#   ./install.sh /path/to/openclaw-watchdog

set -euo pipefail

INSTALL_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

echo "=== openclaw-watchdog installer ==="
echo "Install from: ${INSTALL_DIR}"
echo ""

# Verify files exist
if [[ ! -f "${INSTALL_DIR}/openclaw-watchdog.sh" ]]; then
    echo "Error: openclaw-watchdog.sh not found in ${INSTALL_DIR}"
    echo "Are you running this from the project directory?"
    exit 1
fi

# Make scripts executable
chmod +x "${INSTALL_DIR}/openclaw-watchdog.sh"
chmod +x "${INSTALL_DIR}/install.sh"
chmod +x "${INSTALL_DIR}/uninstall.sh" 2>/dev/null || true

# Create config directory
WATCHDOG_DIR="${HOME}/.openclaw/watchdog"
mkdir -p "${WATCHDOG_DIR}"

# Copy default config if none exists
if [[ ! -f "${WATCHDOG_DIR}/config.conf" ]]; then
    cp "${INSTALL_DIR}/config/default.conf" "${WATCHDOG_DIR}/config.conf"
    echo "Created default config: ${WATCHDOG_DIR}/config.conf"
    echo "  → Edit this file to customize behavior"
else
    echo "Config already exists: ${WATCHDOG_DIR}/config.conf (not overwritten)"
fi

# Create symlink in PATH
LINK_TARGET="/usr/local/bin/openclaw-watchdog"
if [[ -w "/usr/local/bin" ]]; then
    ln -sf "${INSTALL_DIR}/openclaw-watchdog.sh" "${LINK_TARGET}"
    echo "Symlinked: ${LINK_TARGET} -> ${INSTALL_DIR}/openclaw-watchdog.sh"
else
    echo "Note: Cannot write to /usr/local/bin. You may want to:"
    echo "  sudo ln -sf '${INSTALL_DIR}/openclaw-watchdog.sh' '${LINK_TARGET}'"
    echo "  OR add ${INSTALL_DIR} to your PATH"
fi

# Install LaunchAgent (macOS only)
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo ""
    read -rp "Install LaunchAgent (auto-start on login)? [Y/n] " answer
    answer="${answer:-Y}"
    if [[ "${answer}" =~ ^[Yy] ]]; then
        "${INSTALL_DIR}/openclaw-watchdog.sh" install
    else
        echo "Skipped. Run 'openclaw-watchdog install' later to set up auto-start."
    fi
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Quick start:"
echo "  openclaw-watchdog status    # Check current state"
echo "  openclaw-watchdog start     # Start manually (foreground)"
echo "  openclaw-watchdog help      # See all commands"
echo ""
echo "Config safeguard is active by default."
echo "After any openclaw.json change, you have ${ROLLBACK_TIMEOUT:-300}s to confirm"
echo "or it auto-confirms if the gateway stays healthy."
