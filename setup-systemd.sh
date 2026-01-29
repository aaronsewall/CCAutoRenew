#!/bin/bash

# Setup script for Claude Auto-Renew systemd integration

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
LOCAL_BIN="$HOME/.local/bin"

echo "Claude Auto-Renew Systemd Setup"
echo "================================"

# Check if systemd is available
if ! command -v systemctl &> /dev/null; then
    echo "ERROR: systemd not found. This setup is for Linux systems with systemd."
    echo ""
    echo "For macOS, you can use launchd (not yet supported)."
    echo "For now, the daemon will work without sleep/wake integration."
    exit 1
fi

# Check if user session is available
if ! systemctl --user status &> /dev/null; then
    echo "ERROR: systemd user session not available."
    echo "Make sure you're running this as a regular user, not root."
    exit 1
fi

# Create directories
mkdir -p "$SYSTEMD_USER_DIR"
mkdir -p "$LOCAL_BIN"

# Install wake handler script
echo "Installing wake handler to $LOCAL_BIN/claude-wake-handler.sh..."
cp "$SCRIPT_DIR/claude-wake-handler.sh" "$LOCAL_BIN/"
chmod +x "$LOCAL_BIN/claude-wake-handler.sh"

# Install systemd service
echo "Installing systemd service to $SYSTEMD_USER_DIR/..."
cp "$SCRIPT_DIR/systemd/claude-auto-renew-wake.service" "$SYSTEMD_USER_DIR/"

# Reload systemd
echo "Reloading systemd user daemon..."
systemctl --user daemon-reload

# Enable the service
echo "Enabling wake handler service..."
systemctl --user enable claude-auto-renew-wake.service

echo ""
echo "Setup complete!"
echo ""
echo "The daemon will now automatically recalculate windows when your system wakes from sleep."
echo ""
echo "To verify installation:"
echo "  systemctl --user status claude-auto-renew-wake.service"
echo ""
echo "To test manually:"
echo "  systemctl --user start claude-auto-renew-wake.service"
