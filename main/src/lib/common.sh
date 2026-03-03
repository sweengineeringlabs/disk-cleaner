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
