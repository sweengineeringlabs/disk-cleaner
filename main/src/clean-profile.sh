#!/bin/bash

# clean-profile.sh - Core cleaning logic for disk-cleaner

clean_profile() {
    local profile="$1"
    local p_name p_marker p_type p_command p_output_pattern p_wrapper
    p_name=$(toml_get "profiles.${profile}.name")
    p_marker=$(toml_get "profiles.${profile}.marker")
    p_type=$(toml_get "profiles.${profile}.type")
    p_command=$(toml_get "profiles.${profile}.command")
    p_output_pattern=$(toml_get "profiles.${profile}.output_pattern")
    p_wrapper=$(toml_get "profiles.${profile}.wrapper")

    declare -a p_alt_markers=()
    declare -a p_targets=()
    declare -a p_optional_targets=()
    declare -a p_recursive_targets=()
    toml_get_array "profiles.${profile}.alt_markers" p_alt_markers
    toml_get_array "profiles.${profile}.targets" p_targets
    toml_get_array "profiles.${profile}.optional_targets" p_optional_targets
    toml_get_array "profiles.${profile}.recursive_targets" p_recursive_targets

    echo ""
    echo -e "${CYAN}━━━ ${p_name} ━━━${NC}"
    echo -e "${CYAN}Scanning for ${p_name} projects in: $SEARCH_PATH${NC}"

    if [[ "$ALL" == true ]]; then
        echo -e "${MAGENTA}Mode: ALL (ignoring Exclude/Include filters)${NC}"
    fi

    # Find projects by marker files
    declare -a all_markers=("$p_marker")
    all_markers+=("${p_alt_markers[@]}")

    declare -a found_dirs=()
    for marker in "${all_markers[@]}"; do
        while IFS= read -r mfile; do
            local mdir
            mdir="$(dirname "$mfile")"
            # Deduplicate: skip if directory already found
            local already=false
            for fd in "${found_dirs[@]}"; do
                if [[ "$fd" == "$mdir" ]]; then
                    already=true
                    break
                fi
            done
            if [[ "$already" == false ]]; then
                found_dirs+=("$mdir")
            fi
        done < <(find "$SEARCH_PATH" -name "$marker" -type f 2>/dev/null)
    done

    # Sort directories
    IFS=$'\n' found_dirs=($(sort <<< "${found_dirs[*]}")); unset IFS

    # Apply include/exclude filters
    declare -a to_clean=()
    declare -a skipped=()

    for dir in "${found_dirs[@]}"; do
        if should_clean "$dir"; then
            to_clean+=("$dir")
        else
            skipped+=("$dir")
        fi
    done

    echo ""
    echo -e "${CYAN}Found ${#found_dirs[@]} ${p_name} projects${NC}"
    echo -e "${GREEN}  To clean: ${#to_clean[@]}${NC}"
    echo -e "${YELLOW}  Skipped:  ${#skipped[@]}${NC}"

    grand_total_projects=$((grand_total_projects + ${#found_dirs[@]}))
    grand_total_cleaned=$((grand_total_cleaned + ${#to_clean[@]}))
    grand_total_skipped=$((grand_total_skipped + ${#skipped[@]}))

    # Show skipped
    if [[ ${#skipped[@]} -gt 0 && "$ALL" != true && (${#EXCLUDE_PATTERNS[@]} -gt 0 || ${#INCLUDE_PATTERNS[@]} -gt 0) ]]; then
        echo ""
        echo -e "${YELLOW}Skipped projects:${NC}"
        for s in "${skipped[@]}"; do
            local rel
            rel=$(get_relative_path "$s")
            echo -e "  ${DARKYELLOW}- $rel${NC}"
        done
    fi

    # Nothing to clean
    if [[ ${#to_clean[@]} -eq 0 ]]; then
        return
    fi

    # Dry run
    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        echo -e "${MAGENTA}[DRY RUN] Would clean:${NC}"
        for dir in "${to_clean[@]}"; do
            local rel
            rel=$(get_relative_path "$dir")
            echo -e "  ${WHITE}- $rel${NC}"
            if [[ "$p_type" == "remove" ]]; then
                for t in "${p_targets[@]}"; do
                    if [[ -d "$dir/$t" ]]; then
                        local sz
                        sz=$(dir_size_bytes "$dir/$t")
                        echo -e "    ${GRAY}remove: $t ($(format_size "$sz"))${NC}"
                    fi
                done
                for t in "${p_optional_targets[@]}"; do
                    if [[ -d "$dir/$t" ]]; then
                        local sz
                        sz=$(dir_size_bytes "$dir/$t")
                        echo -e "    ${GRAY}remove: $t ($(format_size "$sz"))${NC}"
                    fi
                done
                for t in "${p_recursive_targets[@]}"; do
                    local count
                    count=$(find "$dir" -type d -name "$t" 2>/dev/null | wc -l)
                    if [[ "$count" -gt 0 ]]; then
                        echo -e "    ${GRAY}remove recursive: $t ($count found)${NC}"
                    fi
                done
            elif [[ "$p_type" == "command" ]]; then
                local cmd="$p_command"
                if [[ -n "$p_wrapper" && -f "$dir/$p_wrapper" ]]; then
                    cmd="${p_wrapper} clean"
                fi
                echo -e "    ${GRAY}would run: $cmd${NC}"
            fi
        done
        return
    fi

    echo ""
    echo -e "${CYAN}Cleaning ${p_name} projects...${NC}"
    echo ""

    local profile_removed=0
    local profile_size_mib=0

    if [[ "$PARALLEL" == true && ${#to_clean[@]} -gt 1 && "$p_type" == "command" ]]; then
        # Parallel mode for command-type profiles
        declare -a PIDS=()
        for dir in "${to_clean[@]}"; do
            (
                rel=$(get_relative_path "$dir")
                pushd "$dir" > /dev/null || exit 1
                local cmd="$p_command"
                if [[ -n "$p_wrapper" && -f "$p_wrapper" ]]; then
                    cmd="$p_wrapper clean"
                fi
                result=$(eval "$cmd" 2>&1) || true
                popd > /dev/null || exit 1
                echo "Cleaned: $rel"
                if [[ -n "$result" ]]; then
                    echo "  $result"
                fi
            ) &
            PIDS+=($!)
        done

        for pid in "${PIDS[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        echo -e "${GREEN}Parallel cleaning complete${NC}"
    else
        for dir in "${to_clean[@]}"; do
            local rel
            rel=$(get_relative_path "$dir")

            if [[ "$p_type" == "command" ]]; then
                echo -ne "${WHITE}Cleaning: $rel${NC}"

                pushd "$dir" > /dev/null || continue
                local cmd="$p_command"
                if [[ -n "$p_wrapper" && -f "$dir/$p_wrapper" ]]; then
                    cmd="$p_wrapper clean"
                fi
                local result
                result=$(eval "$cmd" 2>&1) || true
                popd > /dev/null || true

                # Parse output for file count (Rust-specific pattern)
                if [[ -n "$p_output_pattern" ]]; then
                    # Convert TOML regex to bash-compatible
                    local bash_pattern="${p_output_pattern//\\d/[0-9]}"
                    bash_pattern="${bash_pattern//+/\+}"
                    if [[ "$result" =~ Removed\ ([0-9]+)\ files ]]; then
                        local files="${BASH_REMATCH[1]}"
                        profile_removed=$((profile_removed + files))
                        grand_total_removed_files=$((grand_total_removed_files + files))

                        if [[ "$result" =~ ([0-9]+)\.?([0-9]*)\ *(GiB|MiB|KiB) ]]; then
                            local whole="${BASH_REMATCH[1]}"
                            local frac="${BASH_REMATCH[2]:-0}"
                            local unit="${BASH_REMATCH[3]}"
                            # Normalize frac to 2 digits
                            frac="${frac}00"; frac="${frac:0:2}"
                            local val_x100=$(( whole * 100 + 10#$frac ))
                            case "$unit" in
                                GiB) grand_total_size_kib=$(( grand_total_size_kib + val_x100 * 1048576 / 100 )) ;;
                                MiB) grand_total_size_kib=$(( grand_total_size_kib + val_x100 * 1024 / 100 )) ;;
                                KiB) grand_total_size_kib=$(( grand_total_size_kib + val_x100 / 100 )) ;;
                            esac
                        fi
                        echo -e " ${GRAY}- $(echo "$result" | tr -d '\n')${NC}"
                    elif [[ "$result" =~ error: ]]; then
                        echo -e " ${RED}- Error${NC}"
                        echo -e "  ${RED}$result${NC}"
                    else
                        echo -e " ${GRAY}- Done${NC}"
                    fi
                elif [[ "$result" =~ error:|Error ]]; then
                    echo -e " ${RED}- Error${NC}"
                    echo -e "  ${RED}$result${NC}"
                else
                    echo -e " ${GRAY}- Done${NC}"
                fi

            elif [[ "$p_type" == "remove" ]]; then
                echo -e "${WHITE}Cleaning: $rel${NC}"

                # Remove target directories
                for t in "${p_targets[@]}"; do
                    if [[ -d "$dir/$t" ]]; then
                        local sz
                        sz=$(dir_size_bytes "$dir/$t")
                        rm -rf "$dir/$t"
                        echo -e "  ${GRAY}removed: $t ($(format_size "$sz"))${NC}"
                    fi
                done

                # Remove optional targets (only if they exist, no warning if absent)
                for t in "${p_optional_targets[@]}"; do
                    if [[ -d "$dir/$t" ]]; then
                        local sz
                        sz=$(dir_size_bytes "$dir/$t")
                        rm -rf "$dir/$t"
                        echo -e "  ${GRAY}removed: $t ($(format_size "$sz"))${NC}"
                    fi
                done

                # Remove recursive targets (e.g., __pycache__)
                for t in "${p_recursive_targets[@]}"; do
                    local count=0
                    while IFS= read -r rdir; do
                        rm -rf "$rdir"
                        count=$((count + 1))
                    done < <(find "$dir" -type d -name "$t" 2>/dev/null)
                    if [[ "$count" -gt 0 ]]; then
                        echo -e "  ${GRAY}removed recursive: $t ($count directories)${NC}"
                    fi
                done
            fi
        done
    fi
}
