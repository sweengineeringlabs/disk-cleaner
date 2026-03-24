#!/bin/bash

# toml-parser.sh - Pure-bash TOML parser (single-line values only)

declare -A TOML_DATA
declare -a TOML_PROFILES=()

parse_toml() {
    local file="$1"
    local current_section=""

    if [[ ! -f "$file" ]]; then
        echo -e "${RED}Config file not found: $file${NC}" >&2
        exit 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip comments and trim
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        # Section header
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            # Track profile names
            if [[ "$current_section" =~ ^profiles\.(.+)$ ]]; then
                TOML_PROFILES+=("${BASH_REMATCH[1]}")
            fi
            continue
        fi

        # Key = value
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)\ *=\ *(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Strip quotes from simple string values
            if [[ "$value" =~ ^\"(.*)\"$ ]]; then
                value="${BASH_REMATCH[1]}"
            elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
                value="${BASH_REMATCH[1]}"
            fi

            TOML_DATA["${current_section}.${key}"]="$value"
        fi
    done < "$file"
}

# Get a TOML value (returns raw value)
toml_get() {
    local key="$1"
    echo "${TOML_DATA[$key]:-}"
}

# Parse a TOML array value like ["a", "b", "c"] into a bash array via nameref
toml_get_array() {
    local key="$1"
    local -n _arr="$2"
    local raw="${TOML_DATA[$key]:-}"
    _arr=()

    [[ -z "$raw" ]] && return

    # Strip brackets
    raw="${raw#\[}"
    raw="${raw%\]}"

    # Split on commas, strip quotes and whitespace
    IFS=',' read -ra items <<< "$raw"
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        item="${item#\"}"
        item="${item%\"}"
        item="${item#\'}"
        item="${item%\'}"
        [[ -n "$item" ]] && _arr+=("$item")
    done
}
