#!/bin/bash

# Codex Auto-Renewal Daemon - Continuous Running Script
# Mirror of claude-auto-renew-daemon.sh adapted for the `codex` CLI.
# Codex has no ccusage equivalent, so timing is purely clock-based
# (5-hour window from last activity).

LOG_FILE="$HOME/.codex-auto-renew-daemon.log"
PID_FILE="$HOME/.codex-auto-renew-daemon.pid"
LAST_ACTIVITY_FILE="$HOME/.codex-last-activity"
START_TIME_FILE="$HOME/.codex-auto-renew-start-time"
STOP_TIME_FILE="$HOME/.codex-auto-renew-stop-time"
MESSAGE_FILE="$HOME/.codex-auto-renew-message"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to handle shutdown
cleanup() {
    log_message "Daemon shutting down..."
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT

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

    if [ -z "$start_epoch" ]; then
        if [ -n "$stop_epoch" ] && [ "$current_epoch" -ge "$stop_epoch" ]; then
            return 1
        else
            return 0
        fi
    fi

    if [ "$current_epoch" -lt "$start_epoch" ]; then
        return 1
    fi

    if [ -n "$stop_epoch" ] && [ "$current_epoch" -ge "$stop_epoch" ]; then
        return 1
    fi

    return 0
}

should_restart_tomorrow() {
    if [ ! -f "$START_TIME_FILE" ] || [ ! -f "$STOP_TIME_FILE" ]; then
        return 1
    fi

    local current_epoch=$(date +%s)
    local stop_epoch=$(cat "$STOP_TIME_FILE")

    if [ "$current_epoch" -ge "$stop_epoch" ]; then
        return 0
    fi

    return 1
}

schedule_next_day_restart() {
    if [ ! -f "$START_TIME_FILE" ]; then
        return 1
    fi

    local start_epoch=$(cat "$START_TIME_FILE")
    local stop_epoch=""

    if [ -f "$STOP_TIME_FILE" ]; then
        stop_epoch=$(cat "$STOP_TIME_FILE")
    fi

    # Roll forward enough days to land in the future so a multi-day
    # offline gap (e.g. weekend shutdown) doesn't strand the daemon
    # in an inner wait loop with a stale schedule.
    local current_epoch=$(date +%s)
    local next_start=$((start_epoch + 86400))
    local next_stop=""

    if [ -n "$stop_epoch" ]; then
        next_stop=$((stop_epoch + 86400))
        while [ "$next_stop" -le "$current_epoch" ]; do
            next_start=$((next_start + 86400))
            next_stop=$((next_stop + 86400))
        done
    else
        while [ "$next_start" -le "$current_epoch" ]; do
            next_start=$((next_start + 86400))
        done
    fi

    echo "$next_start" > "$START_TIME_FILE"
    if [ -n "$next_stop" ]; then
        echo "$next_stop" > "$STOP_TIME_FILE"
    fi

    rm -f "${START_TIME_FILE}.activated" 2>/dev/null

    log_message "🔄 Scheduled restart for tomorrow at $(date -d "@$next_start" 2>/dev/null || date -r "$next_start")"

    return 0
}

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

# Function to start a Codex session
start_codex_session() {
    log_message "Starting Codex session for renewal..."

    if ! command -v codex &> /dev/null; then
        log_message "ERROR: codex command not found"
        return 1
    fi

    local selected_message=""

    if [ -f "$MESSAGE_FILE" ]; then
        selected_message=$(cat "$MESSAGE_FILE")
        log_message "Using custom message: \"$selected_message\""
    else
        selected_message="Search the web for today's top 5 news headlines from South Korea and top 5 from the United States. For each headline, provide the source and a one-sentence summary. Format it nicely."
    fi

    # Run codex exec non-interactively, reading prompt from stdin.
    (echo "$selected_message" | codex exec - >> "$LOG_FILE" 2>&1) &
    local pid=$!

    # Wait up to 180 seconds (codex exec can be slower than claude on web search)
    local count=0
    while kill -0 $pid 2>/dev/null && [ $count -lt 180 ]; do
        sleep 1
        ((count++))
    done

    if kill -0 $pid 2>/dev/null; then
        kill $pid 2>/dev/null
        wait $pid 2>/dev/null
        local result=124
    else
        wait $pid
        local result=$?
    fi

    if [ $result -eq 0 ] || [ $result -eq 124 ]; then
        log_message "Codex session started successfully with message: $selected_message"
        date +%s > "$LAST_ACTIVITY_FILE"
        return 0
    else
        log_message "ERROR: Failed to start Codex session (exit=$result)"
        return 1
    fi
}

# Sleep cadence based on last activity (5h window assumption)
calculate_sleep_duration() {
    if [ -f "$LAST_ACTIVITY_FILE" ]; then
        local last_activity=$(cat "$LAST_ACTIVITY_FILE")
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_activity))
        local remaining=$((18000 - time_diff))  # 5h = 18000s

        if [ "$remaining" -le 300 ]; then
            echo 30
        elif [ "$remaining" -le 1800 ]; then
            echo 120
        else
            echo 600
        fi
    else
        echo 300
    fi
}

main() {
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

    echo $$ > "$PID_FILE"

    log_message "=== Codex Auto-Renewal Daemon Started ==="
    log_message "PID: $$"
    log_message "Logs: $LOG_FILE"

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

    if [ -f "$MESSAGE_FILE" ]; then
        custom_message=$(cat "$MESSAGE_FILE")
        log_message "Custom renewal message configured: \"$custom_message\""
    else
        log_message "Using default renewal message"
    fi

    while true; do
        if should_restart_tomorrow; then
            log_message "🛑 Stop time reached. Scheduling restart for tomorrow..."
            schedule_next_day_restart

            last_wait_log=0
            while ! is_monitoring_active; do
                current_epoch=$(date +%s)
                if [ $((current_epoch - last_wait_log)) -ge 1800 ]; then
                    time_until_start=$(get_time_until_start)
                    hours=$((time_until_start / 3600))
                    minutes=$(((time_until_start % 3600) / 60))
                    log_message "⏰ Waiting for tomorrow's start time (${hours}h ${minutes}m remaining)..."
                    last_wait_log=$current_epoch
                fi
                sleep 30
            done

            log_message "🌅 New day started! Resuming monitoring..."
            continue
        fi

        if ! is_monitoring_active; then
            current_epoch=$(date +%s)
            if [ $((current_epoch - ${_inactive_last_log:-0})) -ge 1800 ]; then
                if [ -f "$START_TIME_FILE" ]; then
                    time_until_start=$(get_time_until_start)
                    if [ "$time_until_start" -gt 0 ]; then
                        hours=$((time_until_start / 3600))
                        minutes=$(((time_until_start % 3600) / 60))
                        log_message "⏰ Waiting for start time (${hours}h ${minutes}m remaining)..."
                    else
                        log_message "🛑 Past stop time, waiting for tomorrow..."
                    fi
                else
                    log_message "🛑 Past stop time, no restart scheduled..."
                fi
                _inactive_last_log=$current_epoch
            fi
            sleep 30
            continue
        fi
        _inactive_last_log=0

        if [ -f "$START_TIME_FILE" ]; then
            if [ ! -f "${START_TIME_FILE}.activated" ]; then
                log_message "✅ Start time reached! Beginning auto-renewal monitoring..."
                touch "${START_TIME_FILE}.activated"
            fi
        fi

        current_time=$(date +%s)
        stop_time_approaching=false

        if [ -f "$STOP_TIME_FILE" ]; then
            stop_epoch=$(cat "$STOP_TIME_FILE")
            time_until_stop=$((stop_epoch - current_time))
            if [ "$time_until_stop" -le 600 ] && [ "$time_until_stop" -gt 0 ]; then
                stop_time_approaching=true
                minutes_until_stop=$((time_until_stop / 60))
                log_message "⚠️  Stop time approaching in ${minutes_until_stop} minutes - no new renewals"
            fi
        fi

        should_renew=false

        if [ "$stop_time_approaching" = false ]; then
            if [ -f "$LAST_ACTIVITY_FILE" ]; then
                last_activity=$(cat "$LAST_ACTIVITY_FILE")
                current_time=$(date +%s)
                time_diff=$((current_time - last_activity))

                if [ $time_diff -ge 18000 ]; then
                    should_renew=true
                    log_message "5 hours elapsed since last activity, renewing..."
                fi
            else
                should_renew=true
                log_message "No previous activity recorded, starting initial session..."
            fi
        fi

        if [ "$should_renew" = true ]; then
            sleep 60
            if start_codex_session; then
                log_message "Renewal successful!"
                sleep 300
            else
                log_message "Renewal failed, will retry in 1 minute"
                sleep 60
            fi
        fi

        sleep_duration=$(calculate_sleep_duration)
        log_message "Next check in $((sleep_duration / 60)) minutes"

        sleep "$sleep_duration"
    done
}

main
