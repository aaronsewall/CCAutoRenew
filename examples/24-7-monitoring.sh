#!/bin/bash
# Example: Always-on monitoring (24/7)
# For users who need continuous coverage

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

"$SCRIPT_DIR/claude-daemon-manager.sh" start

echo "Daemon started with 24/7 monitoring"
echo "- Active: All day, every day"
echo "- Renewals: Every 5 hours as needed"
