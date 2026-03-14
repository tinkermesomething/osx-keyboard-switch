#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_NAME="keyboard-switch"
INSTALL_DIR="$HOME/.local/bin"
PLIST_LABEL="com.local.keyboard-switch"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG_FILE="$HOME/Library/Logs/$BINARY_NAME.log"
BINARY_DST="$INSTALL_DIR/$BINARY_NAME"

echo "==> Compiling $BINARY_NAME..."
swiftc -swift-version 5 \
    -framework IOKit \
    -framework Carbon \
    -framework Foundation \
    "$SCRIPT_DIR/Sources/$BINARY_NAME.swift" \
    -o "$SCRIPT_DIR/$BINARY_NAME"

echo "==> Installing binary to $BINARY_DST"
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/$BINARY_NAME" "$BINARY_DST"
chmod +x "$BINARY_DST"

echo "==> Installing LaunchAgent plist to $PLIST_DST"
sed \
    -e "s|INSTALL_PATH_PLACEHOLDER|$BINARY_DST|g" \
    -e "s|LOG_PATH_PLACEHOLDER|$LOG_FILE|g" \
    "$SCRIPT_DIR/com.local.keyboard-switch.plist" > "$PLIST_DST"

echo "==> Loading LaunchAgent..."
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    # Already loaded — restart it to pick up any binary changes
    launchctl kickstart -k "gui/$(id -u)/$PLIST_LABEL"
    echo "==> Restarted existing agent."
else
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
    echo "==> Agent loaded."
fi

echo ""
echo "Done. Logs: tail -f $LOG_FILE"
echo ""
echo "IMPORTANT: If this is the first install, grant Input Monitoring permission:"
echo "  System Settings > Privacy & Security > Input Monitoring"
echo "  Add: $BINARY_DST"
