#!/bin/bash
# Example: Custom schedule with cross-midnight
# Night owl schedule: 6 PM to 2 AM

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

"$SCRIPT_DIR/claude-daemon-manager.sh" start \
    --at 18:00 \
    --stop 02:00

echo "Daemon started with night owl schedule"
echo "- Active: 6:00 PM - 2:00 AM (next day)"
echo "- Renewals at approximately: 6:00 PM, 11:00 PM"
