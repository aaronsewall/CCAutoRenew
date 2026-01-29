#!/bin/bash

# Claude Auto-Renew Wake Handler
# Called by systemd when system wakes from sleep

PID_FILE="$HOME/.claude-auto-renew-daemon.pid"
LAST_WAKE_FILE="$HOME/.claude-last-wake"
LAST_SLEEP_FILE="$HOME/.claude-last-sleep"
LOG_FILE="$HOME/.claude-auto-renew-daemon.log"

log_wake() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WAKE] $1" >> "$LOG_FILE"
}

# Record wake time
current_time=$(date +%s)
echo "$current_time" > "$LAST_WAKE_FILE"

# Calculate sleep duration if we have a sleep timestamp
if [ -f "$LAST_SLEEP_FILE" ]; then
    sleep_start=$(cat "$LAST_SLEEP_FILE")
    sleep_duration=$((current_time - sleep_start))
    sleep_minutes=$((sleep_duration / 60))
    log_wake "System woke after ${sleep_minutes} minutes of sleep"
fi

# Check if daemon is running
if [ -f "$PID_FILE" ]; then
    daemon_pid=$(cat "$PID_FILE")
    if kill -0 "$daemon_pid" 2>/dev/null; then
        log_wake "Signaling daemon (PID $daemon_pid) to recalculate windows"
        kill -SIGUSR1 "$daemon_pid"
    else
        log_wake "Daemon PID file exists but process not running"
    fi
else
    log_wake "Daemon not running (no PID file)"
fi
