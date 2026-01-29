#!/bin/bash
# Example: Standard work week schedule (M-F 7am-10pm)
# Provides 3 renewal windows per day

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

"$SCRIPT_DIR/claude-daemon-manager.sh" start \
    --at 07:00 \
    --stop 22:00 \
    --weekdays "1-5"

echo "Daemon started with weekday work hours schedule"
echo "- Active: Monday-Friday, 7:00 AM - 10:00 PM"
echo "- Renewals at approximately: 7:00 AM, 12:00 PM, 5:00 PM"
