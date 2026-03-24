#!/bin/bash

# common.sh - Shared utilities for disk-cleaner

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
DARKYELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Format size in bytes to human-readable (pure bash, no bc dependency)
format_size() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        local whole=$((bytes / 1073741824))
        local frac=$(( (bytes % 1073741824) * 100 / 1073741824 ))
        printf "%d.%02d GiB" "$whole" "$frac"
    elif (( bytes >= 1048576 )); then
        local whole=$((bytes / 1048576))
        local frac=$(( (bytes % 1048576) * 100 / 1048576 ))
        printf "%d.%02d MiB" "$whole" "$frac"
    elif (( bytes >= 1024 )); then
        local whole=$((bytes / 1024))
        local frac=$(( (bytes % 1024) * 100 / 1024 ))
        printf "%d.%02d KiB" "$whole" "$frac"
    else
        echo "${bytes} B"
    fi
}

# Get directory size in bytes (portable)
dir_size_bytes() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        du -sb "$dir" 2>/dev/null | cut -f1
    else
        echo 0
    fi
}

get_relative_path() {
    local full_path="$1"
    if [[ -n "$SEARCH_PATH" ]]; then
        echo "${full_path#$SEARCH_PATH/}"
    else
        echo "$full_path"
    fi
}

should_clean() {
    local project_path="$1"
    local relative_path
    relative_path=$(get_relative_path "$project_path")

    if [[ "$ALL" == true ]]; then
        return 0
    fi

    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$relative_path" == *"$pattern"* ]]; then
            return 1
        fi
    done

    if [[ ${#INCLUDE_PATTERNS[@]} -gt 0 ]]; then
        for pattern in "${INCLUDE_PATTERNS[@]}"; do
            if [[ "$relative_path" == *"$pattern"* ]]; then
                return 0
            fi
        done
        return 1
    fi

    return 0
}

# ─── Spinner ────────────────────────────────────────────────────────────────────

SPINNER_PID=""

spinner_start() {
    local msg="$1"
    if [[ "$JSON_OUTPUT" == true ]]; then
        return
    fi
    (
        local chars='|/-\'
        local i=0
        while true; do
            local c="${chars:$i:1}"
            printf "\r  ${CYAN}%s${NC} %s" "$c" "$msg" >&2
            i=$(( (i + 1) % 4 ))
            sleep 0.15
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}

spinner_stop() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r\033[K" >&2
    fi
}

# ─── Cancel Support ─────────────────────────────────────────────────────────────

CANCELLED=false

cancel_cleanup() {
    CANCELLED=true
    spinner_stop
    echo "" >&2
    if [[ "$JSON_OUTPUT" == true ]]; then
        emit_json_event "{\"event\":\"cancelled\"}"
    else
        echo -e "${YELLOW}Cancelled by user.${NC}" >&2
        if [[ $grand_total_cleaned -gt 0 || $grand_total_size_bytes -gt 0 ]]; then
            echo -e "${GRAY}  Cleaned so far: $grand_total_cleaned projects, $(format_size "$grand_total_size_bytes") freed${NC}" >&2
        fi
    fi
    exit 130
}

# Emit a JSON event line (for --json mode)
emit_json_event() {
    local json="$1"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
    # Insert timestamp into JSON object
    echo "${json%\}},\"timestamp\":\"$ts\"}"
}
