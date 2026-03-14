#!/usr/bin/env bash
set -euo pipefail

BINARY_NAME="keyboard-switch"
INSTALL_DIR="$HOME/.local/bin"
PLIST_LABEL="com.local.keyboard-switch"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

echo "==> Unloading LaunchAgent..."
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || \
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
    echo "==> Agent unloaded."
else
    echo "==> Agent was not running."
fi

echo "==> Removing files..."
rm -f "$PLIST_DST"
rm -f "$INSTALL_DIR/$BINARY_NAME"

echo "Done."
echo "Note: remove Input Monitoring permission manually in System Settings > Privacy & Security > Input Monitoring"
