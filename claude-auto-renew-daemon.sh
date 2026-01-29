#!/bin/bash

# Claude Auto-Renewal Daemon - Continuous Running Script
# Runs continuously in the background, checking for renewal windows

LOG_FILE="$HOME/.claude-auto-renew-daemon.log"
PID_FILE="$HOME/.claude-auto-renew-daemon.pid"
LAST_ACTIVITY_FILE="$HOME/.claude-last-activity"
START_TIME_FILE="$HOME/.claude-auto-renew-start-time"
STOP_TIME_FILE="$HOME/.claude-auto-renew-stop-time"
MESSAGE_FILE="$HOME/.claude-auto-renew-message"
WEEKDAYS_FILE="$HOME/.claude-auto-renew-weekdays"
DISABLE_CCUSAGE=false
FORCE_CHECK=false
LAST_SLEEP_FILE="$HOME/.claude-last-sleep"

# Error patterns for detection
ERROR_WEEKLY_LIMIT="exceeded.*weekly.*limit|weekly.*limit.*reached|rate.*limit.*exceeded"
ERROR_NETWORK="connection.*refused|network.*unreachable|could not resolve|timeout"
ERROR_NOT_INSTALLED="command not found|not installed|No such file"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}

# Function to handle shutdown
cleanup() {
    log_message "Daemon shutting down..."
    rm -f "$PID_FILE"
    exit 0
}

# Function to handle wake signal
handle_wake() {
    log_message "Wake signal received, forcing immediate window check..."
    FORCE_CHECK=true
}

# Function to handle sleep signal (for logging)
handle_sleep() {
    date +%s > "$LAST_SLEEP_FILE"
    log_message "System going to sleep, recording timestamp..."
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT
trap handle_wake SIGUSR1
trap handle_sleep SIGUSR2

# Function to check if we missed a renewal during sleep
check_missed_renewal() {
    if [ ! -f "$LAST_ACTIVITY_FILE" ]; then
        return 0  # No activity file, nothing to check
    fi

    local last_activity=$(cat "$LAST_ACTIVITY_FILE")
    local current_time=$(date +%s)
    local time_since_activity=$((current_time - last_activity))
    local renewal_interval=18000  # 5 hours in seconds

    if [ "$time_since_activity" -ge "$renewal_interval" ]; then
        local missed_count=$((time_since_activity / renewal_interval))
        log_message "Missed $missed_count renewal window(s) during sleep"
        return 0  # Indicates we should renew now
    fi

    return 1  # No missed renewals
}

# Function to check if we should skip renewal (duplicate prevention)
should_skip_renewal() {
    if [ ! -f "$LAST_ACTIVITY_FILE" ]; then
        return 1  # No activity recorded, don't skip
    fi

    local last_activity=$(cat "$LAST_ACTIVITY_FILE")
    local current_time=$(date +%s)
    local time_since_activity=$((current_time - last_activity))
    local min_interval=18000  # 5 hours

    if [ "$time_since_activity" -lt "$min_interval" ]; then
        local remaining=$((min_interval - time_since_activity))
        local hours=$((remaining / 3600))
        local minutes=$(((remaining % 3600) / 60))
        log_message "Skipping renewal: last activity was $((time_since_activity / 60)) minutes ago (need ${hours}h ${minutes}m more)"
        return 0  # Should skip
    fi

    return 1  # Don't skip
}

# Function to check if current day is a valid weekday
is_valid_weekday() {
    if [ ! -f "$WEEKDAYS_FILE" ]; then
        return 0  # No weekday restriction, always valid
    fi

    local weekday_config=$(cat "$WEEKDAYS_FILE")
    local current_dow=$(date +%u)  # 1=Monday, 7=Sunday

    # Parse weekday config (supports "1-5" or "1,2,3,4,5" formats)
    if [[ "$weekday_config" =~ ^([0-9])-([0-9])$ ]]; then
        local start_day=${BASH_REMATCH[1]}
        local end_day=${BASH_REMATCH[2]}
        if [ "$current_dow" -ge "$start_day" ] && [ "$current_dow" -le "$end_day" ]; then
            return 0
        fi
    else
        # Comma-separated list
        IFS=',' read -ra DAYS <<< "$weekday_config"
        for day in "${DAYS[@]}"; do
            if [[ "$day" =~ ^([0-9])-([0-9])$ ]]; then
                local start_day=${BASH_REMATCH[1]}
                local end_day=${BASH_REMATCH[2]}
                if [ "$current_dow" -ge "$start_day" ] && [ "$current_dow" -le "$end_day" ]; then
                    return 0
                fi
            elif [ "$current_dow" -eq "$day" ]; then
                return 0
            fi
        done
    fi

    return 1  # Not a valid weekday
}

# Function to calculate seconds until next valid weekday
get_seconds_until_next_valid_weekday() {
    if [ ! -f "$WEEKDAYS_FILE" ]; then
        echo "0"
        return
    fi

    local weekday_config=$(cat "$WEEKDAYS_FILE")
    local current_dow=$(date +%u)
    local days_to_wait=0

    # Find next valid day
    for i in $(seq 1 7); do
        local check_dow=$(( (current_dow + i - 1) % 7 + 1 ))

        # Check if this day is valid
        if [[ "$weekday_config" =~ ^([0-9])-([0-9])$ ]]; then
            local start_day=${BASH_REMATCH[1]}
            local end_day=${BASH_REMATCH[2]}
            if [ "$check_dow" -ge "$start_day" ] && [ "$check_dow" -le "$end_day" ]; then
                days_to_wait=$i
                break
            fi
        fi
    done

    if [ "$days_to_wait" -eq 0 ]; then
        echo "0"
        return
    fi

    # Calculate seconds: days * 86400 + time until start of that day
    local seconds_until_midnight=$(( 86400 - $(date +%s) % 86400 ))
    local total_seconds=$(( (days_to_wait - 1) * 86400 + seconds_until_midnight ))

    # Add time until configured start time if we have one
    if [ -f "$START_TIME_FILE" ]; then
        local start_epoch=$(cat "$START_TIME_FILE")
        local start_time_of_day=$(( start_epoch % 86400 ))
        total_seconds=$((total_seconds + start_time_of_day))
    fi

    echo "$total_seconds"
}

# Function to check if we're in the active monitoring window
is_monitoring_active() {
    local current_epoch=$(date +%s)
    local start_epoch=""
    local stop_epoch=""
    
    if [ -f "$START_TIME_FILE" ]; then
        start_epoch=$(cat "$START_TIME_FILE")
    fi
    
    if [ -f "$STOP_TIME_FILE" ]; then
        stop_epoch=$(cat "$STOP_TIME_FILE")
    fi
    
    # If no start time set, always active (unless stop time is set and passed)
    if [ -z "$start_epoch" ]; then
        if [ -n "$stop_epoch" ] && [ "$current_epoch" -ge "$stop_epoch" ]; then
            return 1  # Past stop time
        else
            return 0  # Active
        fi
    fi
    
    # Check if we're before start time
    if [ "$current_epoch" -lt "$start_epoch" ]; then
        return 1  # Before start time
    fi
    
    # Check if we're past stop time
    if [ -n "$stop_epoch" ] && [ "$current_epoch" -ge "$stop_epoch" ]; then
        return 1  # Past stop time
    fi
    
    return 0  # In active window
}

# Function to check if we should schedule next day restart
should_restart_tomorrow() {
    if [ ! -f "$START_TIME_FILE" ] || [ ! -f "$STOP_TIME_FILE" ]; then
        return 1  # No scheduling needed
    fi
    
    local current_epoch=$(date +%s)
    local stop_epoch=$(cat "$STOP_TIME_FILE")
    
    # Check if we've passed stop time
    if [ "$current_epoch" -ge "$stop_epoch" ]; then
        return 0  # Should restart tomorrow
    fi
    
    return 1  # Not yet time
}

# Function to schedule restart for next day
schedule_next_day_restart() {
    if [ ! -f "$START_TIME_FILE" ]; then
        return 1
    fi

    local start_epoch=$(cat "$START_TIME_FILE")
    local stop_epoch=""

    if [ -f "$STOP_TIME_FILE" ]; then
        stop_epoch=$(cat "$STOP_TIME_FILE")
    fi

    # Calculate how many days to skip
    local days_to_add=1

    if [ -f "$WEEKDAYS_FILE" ]; then
        local weekday_config=$(cat "$WEEKDAYS_FILE")
        local current_dow=$(date +%u)

        # Find next valid weekday
        for i in $(seq 1 7); do
            local check_dow=$(( (current_dow + i - 1) % 7 + 1 ))

            if [[ "$weekday_config" =~ ^([0-9])-([0-9])$ ]]; then
                local start_day=${BASH_REMATCH[1]}
                local end_day=${BASH_REMATCH[2]}
                if [ "$check_dow" -ge "$start_day" ] && [ "$check_dow" -le "$end_day" ]; then
                    days_to_add=$i
                    break
                fi
            fi
        done
    fi

    # Calculate next start time (skip invalid weekdays)
    local next_start=$((start_epoch + days_to_add * 86400))
    local next_stop=""

    if [ -n "$stop_epoch" ]; then
        next_stop=$((stop_epoch + days_to_add * 86400))
    fi

    # Update the time files
    echo "$next_start" > "$START_TIME_FILE"
    if [ -n "$next_stop" ]; then
        echo "$next_stop" > "$STOP_TIME_FILE"
    fi

    # Remove activation marker
    rm -f "${START_TIME_FILE}.activated" 2>/dev/null

    local day_name=$(date -d "@$next_start" '+%A' 2>/dev/null || date -r "$next_start" '+%A')
    log_message "Scheduled restart for $day_name at $(date -d "@$next_start" '+%H:%M' 2>/dev/null || date -r "$next_start" '+%H:%M')"

    return 0
}

# Function to get time until start
get_time_until_start() {
    if [ ! -f "$START_TIME_FILE" ]; then
        echo "0"
        return
    fi
    
    local start_epoch=$(cat "$START_TIME_FILE")
    local current_epoch=$(date +%s)
    local diff=$((start_epoch - current_epoch))
    
    if [ "$diff" -le 0 ]; then
        echo "0"
    else
        echo "$diff"
    fi
}

# Function to get ccusage command
get_ccusage_cmd() {
    if command -v ccusage &> /dev/null; then
        echo "ccusage"
    elif command -v bunx &> /dev/null; then
        echo "bunx ccusage"
    elif command -v npx &> /dev/null; then
        echo "npx ccusage@latest"
    else
        return 1
    fi
}

# Function to get minutes until reset
get_minutes_until_reset() {
    # If ccusage is disabled, return nothing to force time-based checking
    if [ "$DISABLE_CCUSAGE" = true ]; then
        return 1
    fi
    
    local ccusage_cmd=$(get_ccusage_cmd)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Try to get time remaining from ccusage
    local output=$($ccusage_cmd blocks 2>/dev/null | grep -i "time remaining" | head -1)
    
    if [ -z "$output" ]; then
        output=$($ccusage_cmd blocks --live 2>/dev/null | grep -i "remaining" | head -1)
    fi
    
    # Parse time
    local hours=0
    local minutes=0
    
    if [[ "$output" =~ ([0-9]+)h[[:space:]]*([0-9]+)m ]]; then
        hours=${BASH_REMATCH[1]}
        minutes=${BASH_REMATCH[2]}
    elif [[ "$output" =~ ([0-9]+)m ]]; then
        minutes=${BASH_REMATCH[1]}
    fi
    
    echo $((hours * 60 + minutes))
}

# Function to attempt a single Claude session (internal use)
attempt_claude_session() {
    log_message "Attempting Claude session..."

    if ! command -v claude &> /dev/null; then
        log_message "ERROR: claude command not found - please install Claude CLI"
        return 2  # Special exit code for "not installed"
    fi

    # Check if custom message is available
    local selected_message=""

    if [ -f "$MESSAGE_FILE" ]; then
        selected_message=$(cat "$MESSAGE_FILE")
        log_message "Using custom message: \"$selected_message\""
    else
        local messages=("hi" "hello" "hey there" "good day" "greetings" "howdy" "what's up" "salutations")
        local random_index=$((RANDOM % ${#messages[@]}))
        selected_message="${messages[$random_index]}"
    fi

    # Run claude and capture output for error detection
    local temp_output=$(mktemp)
    (echo "$selected_message" | claude >> "$LOG_FILE" 2>"$temp_output") &
    local pid=$!

    # Wait up to 10 seconds
    local count=0
    while kill -0 $pid 2>/dev/null && [ $count -lt 10 ]; do
        sleep 1
        ((count++))
    done

    # Kill if still running
    if kill -0 $pid 2>/dev/null; then
        kill $pid 2>/dev/null
        wait $pid 2>/dev/null
        local result=124
    else
        wait $pid
        local result=$?
    fi

    # Check stderr for error patterns
    local error_output=$(cat "$temp_output" 2>/dev/null)
    rm -f "$temp_output"

    # Detect specific error types
    if echo "$error_output" | grep -qiE "$ERROR_WEEKLY_LIMIT"; then
        log_message "ERROR: Weekly limit reached. Pausing until next week."
        # Calculate seconds until next Monday 00:00
        local days_until_monday=$(( (8 - $(date +%u)) % 7 ))
        [ "$days_until_monday" -eq 0 ] && days_until_monday=7
        local seconds_until_monday=$(( days_until_monday * 86400 - $(date +%s) % 86400 ))
        log_message "Sleeping for $((seconds_until_monday / 3600)) hours until weekly reset"
        sleep $seconds_until_monday
        return 3  # Special exit code for "weekly limit"
    fi

    if echo "$error_output" | grep -qiE "$ERROR_NETWORK"; then
        log_message "ERROR: Network issue detected. Will retry with backoff."
        return 4  # Special exit code for "network error"
    fi

    if [ $result -eq 0 ] || [ $result -eq 124 ]; then
        log_message "Claude session started successfully with message: $selected_message"
        date +%s > "$LAST_ACTIVITY_FILE"
        return 0
    else
        log_message "ERROR: Claude session failed (exit code: $result)"
        [ -n "$error_output" ] && log_message "Error output: $error_output"
        return 1
    fi
}

# Function to start Claude session with retry
start_claude_session() {
    local MAX_RETRIES=3
    local RETRY_DELAYS=(5 15 30)

    for attempt in $(seq 0 $((MAX_RETRIES - 1))); do
        attempt_claude_session
        local result=$?

        case $result in
            0) return 0 ;;  # Success
            2) return 2 ;;  # Not installed - don't retry
            3) return 0 ;;  # Weekly limit - already handled, don't retry
            4|1|*)          # Network or other error - retry
                if [ $attempt -lt $((MAX_RETRIES - 1)) ]; then
                    local delay=${RETRY_DELAYS[$attempt]}
                    log_message "Attempt $((attempt + 1))/$MAX_RETRIES failed. Retrying in ${delay}s..."
                    sleep $delay
                fi
                ;;
        esac
    done

    log_message "ERROR: All $MAX_RETRIES retry attempts failed"
    return 1
}

# Function to calculate next check time
calculate_sleep_duration() {
    local minutes_remaining=$(get_minutes_until_reset)
    
    if [ -n "$minutes_remaining" ] && [ "$minutes_remaining" -gt 0 ]; then
        log_message "Time remaining: $minutes_remaining minutes" >&2
        
        if [ "$minutes_remaining" -le 5 ]; then
            # Check every 30 seconds when close to reset
            echo 30
        elif [ "$minutes_remaining" -le 30 ]; then
            # Check every 2 minutes when within 30 minutes
            echo 120
        else
            # Check every 10 minutes otherwise
            echo 600
        fi
    else
        # Fallback: check based on last activity
        if [ -f "$LAST_ACTIVITY_FILE" ]; then
            local last_activity=$(cat "$LAST_ACTIVITY_FILE")
            local current_time=$(date +%s)
            local time_diff=$((current_time - last_activity))
            local remaining=$((18000 - time_diff))  # 5 hours = 18000 seconds
            
            if [ "$remaining" -le 300 ]; then  # 5 minutes
                echo 30
            elif [ "$remaining" -le 1800 ]; then  # 30 minutes
                echo 120
            else
                echo 600
            fi
        else
            # No info available, check every 5 minutes
            echo 300
        fi
    fi
}

# Main daemon loop
main() {
    # Check if already running
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Daemon already running with PID $OLD_PID"
            exit 1
        else
            log_message "Removing stale PID file"
            rm -f "$PID_FILE"
        fi
    fi
    
    # Save PID
    echo $$ > "$PID_FILE"
    
    log_message "=== Claude Auto-Renewal Daemon Started ==="
    log_message "PID: $$"
    log_message "Logs: $LOG_FILE"
    
    # Log ccusage status
    if [ "$DISABLE_CCUSAGE" = true ]; then
        log_message "⚠️  ccusage DISABLED - Using clock-based timing only"
    else
        log_message "✅ ccusage ENABLED - Using accurate timing when available"
    fi
    
    # Check for start and stop times
    if [ -f "$START_TIME_FILE" ]; then
        start_epoch=$(cat "$START_TIME_FILE")
        log_message "Start time configured: $(date -d "@$start_epoch" 2>/dev/null || date -r "$start_epoch")"
    else
        log_message "No start time set - will begin monitoring immediately"
    fi
    
    if [ -f "$STOP_TIME_FILE" ]; then
        stop_epoch=$(cat "$STOP_TIME_FILE")
        log_message "Stop time configured: $(date -d "@$stop_epoch" 2>/dev/null || date -r "$stop_epoch")"
    else
        log_message "No stop time set - will monitor continuously"
    fi
    
    # Check for custom message
    if [ -f "$MESSAGE_FILE" ]; then
        custom_message=$(cat "$MESSAGE_FILE")
        log_message "Custom renewal message configured: \"$custom_message\""
    else
        log_message "Using default random greeting messages for renewal"
    fi
    
    # Check ccusage availability
    if [ "$DISABLE_CCUSAGE" = false ] && ! get_ccusage_cmd &> /dev/null; then
        log_message "WARNING: ccusage not found. Using time-based checking."
        log_message "Install ccusage for more accurate timing: npm install -g ccusage"
    fi
    
    # Main loop
    while true; do
        # Handle wake signal - force immediate check
        if [ "$FORCE_CHECK" = true ]; then
            FORCE_CHECK=false
            log_message "Processing wake signal..."

            if is_monitoring_active && is_valid_weekday; then
                if check_missed_renewal; then
                    log_message "Triggering catch-up renewal after wake..."
                    if start_claude_session; then
                        log_message "Catch-up renewal successful!"
                    else
                        log_message "Catch-up renewal failed"
                    fi
                fi
            fi
        fi

        # Check if we should schedule next day restart first
        if should_restart_tomorrow; then
            log_message "🛑 Stop time reached. Scheduling restart for tomorrow..."
            schedule_next_day_restart
            
            # Wait for tomorrow's start time
            while ! is_monitoring_active; do
                time_until_start=$(get_time_until_start)
                hours=$((time_until_start / 3600))
                minutes=$(((time_until_start % 3600) / 60))
                
                if [ "$hours" -gt 0 ]; then
                    log_message "⏰ Waiting for tomorrow's start time (${hours}h ${minutes}m remaining)..."
                    sleep 3600  # Check every hour when waiting for tomorrow
                else
                    log_message "⏰ Waiting for start time (${minutes}m remaining)..."
                    sleep 300   # Check every 5 minutes when close
                fi
            done
            
            log_message "🌅 New day started! Resuming monitoring..."
            continue
        fi
        
        # Check if we're in monitoring window
        if ! is_monitoring_active; then
            # Calculate time until start or reason for inactivity
            if [ -f "$START_TIME_FILE" ]; then
                time_until_start=$(get_time_until_start)
                hours=$((time_until_start / 3600))
                minutes=$(((time_until_start % 3600) / 60))
                seconds=$((time_until_start % 60))
                
                if [ "$time_until_start" -gt 0 ]; then
                    # Before start time
                    if [ "$hours" -gt 0 ]; then
                        log_message "⏰ Waiting for start time (${hours}h ${minutes}m remaining)..."
                        sleep 300  # Check every 5 minutes when waiting
                    elif [ "$minutes" -gt 2 ]; then
                        log_message "⏰ Waiting for start time (${minutes}m ${seconds}s remaining)..."
                        sleep 60   # Check every minute when close
                    elif [ "$time_until_start" -gt 10 ]; then
                        log_message "⏰ Waiting for start time (${minutes}m ${seconds}s remaining)..."
                        sleep 10   # Check every 10 seconds when very close
                    else
                        log_message "⏰ Waiting for start time (${seconds}s remaining)..."
                        sleep 2    # Check every 2 seconds when imminent
                    fi
                else
                    # Past stop time, waiting for tomorrow
                    log_message "🛑 Past stop time, waiting for tomorrow..."
                    sleep 300
                fi
            else
                # No start time but inactive - must be past stop time
                log_message "🛑 Past stop time, no restart scheduled..."
                sleep 300
            fi
            continue
        fi
        
        # If we just entered active time, log it
        if [ -f "$START_TIME_FILE" ]; then
            # Check if this is the first time we're active today
            if [ ! -f "${START_TIME_FILE}.activated" ]; then
                log_message "✅ Start time reached! Beginning auto-renewal monitoring..."
                touch "${START_TIME_FILE}.activated"
            fi
        fi
        
        # Check if we're approaching stop time
        current_time=$(date +%s)
        stop_time_approaching=false
        
        if [ -f "$STOP_TIME_FILE" ]; then
            stop_epoch=$(cat "$STOP_TIME_FILE")
            time_until_stop=$((stop_epoch - current_time))
            
            # Don't start new renewals if stop time is within 10 minutes
            if [ "$time_until_stop" -le 600 ] && [ "$time_until_stop" -gt 0 ]; then
                stop_time_approaching=true
                minutes_until_stop=$((time_until_stop / 60))
                log_message "⚠️  Stop time approaching in ${minutes_until_stop} minutes - no new renewals"
            fi
        fi
        
        # Get minutes until reset
        minutes_remaining=$(get_minutes_until_reset)
        
        # Check if we should renew (only if not approaching stop time)
        should_renew=false
        
        if [ "$stop_time_approaching" = false ]; then
            if [ -n "$minutes_remaining" ] && [ "$minutes_remaining" -gt 0 ]; then
                if [ "$minutes_remaining" -le 2 ]; then
                    should_renew=true
                    log_message "Reset imminent ($minutes_remaining minutes), preparing to renew..."
                fi
            else
                # Fallback check
                if [ -f "$LAST_ACTIVITY_FILE" ]; then
                    last_activity=$(cat "$LAST_ACTIVITY_FILE")
                    current_time=$(date +%s)
                    time_diff=$((current_time - last_activity))
                    
                    if [ $time_diff -ge 18000 ]; then
                        should_renew=true
                        log_message "5 hours elapsed since last activity, renewing..."
                    fi
                else
                    # No activity recorded, safe to start
                    should_renew=true
                    log_message "No previous activity recorded, starting initial session..."
                fi
            fi
        fi

        # Duplicate prevention check
        if [ "$should_renew" = true ] && should_skip_renewal; then
            should_renew=false
        fi

        # Perform renewal if needed
        if [ "$should_renew" = true ]; then
            # Wait a bit to ensure we're in the renewal window
            sleep 60
            
            # Try to start session
            if start_claude_session; then
                log_message "Renewal successful!"
                # Sleep for 5 minutes after successful renewal
                sleep 300
            else
                log_message "Renewal failed, will retry in 1 minute"
                sleep 60
            fi
        fi
        
        # Calculate how long to sleep
        sleep_duration=$(calculate_sleep_duration)
        log_message "Next check in $((sleep_duration / 60)) minutes"
        
        # Sleep until next check
        sleep "$sleep_duration"
    done
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --disableccusage)
            DISABLE_CCUSAGE=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Start the daemon
main