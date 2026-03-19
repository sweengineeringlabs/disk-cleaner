#!/bin/bash

# clean-profile.sh - Core cleaning logic for disk-cleaner

clean_profile() {
    local profile="$1"
    local profile_index="$2"
    local profile_count="$3"
    local p_name p_marker p_type p_command p_output_pattern p_wrapper p_clean_dir
    p_name=$(toml_get "profiles.${profile}.name")
    p_marker=$(toml_get "profiles.${profile}.marker")
    p_type=$(toml_get "profiles.${profile}.type")
    p_command=$(toml_get "profiles.${profile}.command")
    p_output_pattern=$(toml_get "profiles.${profile}.output_pattern")
    p_wrapper=$(toml_get "profiles.${profile}.wrapper")
    p_clean_dir=$(toml_get "profiles.${profile}.clean_dir")

    declare -a p_alt_markers=()
    declare -a p_targets=()
    declare -a p_optional_targets=()
    declare -a p_recursive_targets=()
    toml_get_array "profiles.${profile}.alt_markers" p_alt_markers
    toml_get_array "profiles.${profile}.targets" p_targets
    toml_get_array "profiles.${profile}.optional_targets" p_optional_targets
    toml_get_array "profiles.${profile}.recursive_targets" p_recursive_targets

    if [[ "$JSON_OUTPUT" == true ]]; then
        emit_json_event "{\"event\":\"scan_start\",\"profile\":\"$profile\",\"name\":\"$p_name\",\"path\":\"$SEARCH_PATH\"}"
    else
        echo ""
        echo -e "${CYAN}━━━ ${p_name} [$profile_index/$profile_count] ━━━${NC}"
        echo -e "${CYAN}Scanning for ${p_name} projects in: $SEARCH_PATH${NC}"

        if [[ "$ALL" == true ]]; then
            echo -e "${MAGENTA}Mode: ALL (ignoring Exclude/Include filters)${NC}"
        fi
    fi

    # Find projects by marker files
    declare -a all_markers=("$p_marker")
    all_markers+=("${p_alt_markers[@]}")

    spinner_start "Scanning for ${p_name} projects..."

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

    spinner_stop

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

    if [[ "$JSON_OUTPUT" == true ]]; then
        emit_json_event "{\"event\":\"scan_complete\",\"profile\":\"$profile\",\"found\":${#found_dirs[@]},\"to_clean\":${#to_clean[@]},\"skipped\":${#skipped[@]}}"
    else
        echo ""
        echo -e "${CYAN}Found ${#found_dirs[@]} ${p_name} projects${NC}"
        echo -e "${GREEN}  To clean: ${#to_clean[@]}${NC}"
        echo -e "${YELLOW}  Skipped:  ${#skipped[@]}${NC}"
    fi

    grand_total_projects=$((grand_total_projects + ${#found_dirs[@]}))
    grand_total_cleaned=$((grand_total_cleaned + ${#to_clean[@]}))
    grand_total_skipped=$((grand_total_skipped + ${#skipped[@]}))

    # Show skipped
    if [[ "$JSON_OUTPUT" != true && ${#skipped[@]} -gt 0 && "$ALL" != true && (${#EXCLUDE_PATTERNS[@]} -gt 0 || ${#INCLUDE_PATTERNS[@]} -gt 0) ]]; then
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
        if [[ "$JSON_OUTPUT" == true ]]; then
            for dir in "${to_clean[@]}"; do
                local rel
                rel=$(get_relative_path "$dir")
                if [[ "$p_type" == "command" ]]; then
                    local cmd="$p_command"
                    if [[ -n "$p_wrapper" && -f "$dir/$p_wrapper" ]]; then
                        cmd="${p_wrapper} clean"
                    fi
                    local est_size=0
                    if [[ -n "$p_clean_dir" && -d "$dir/$p_clean_dir" ]]; then
                        est_size=$(dir_size_bytes "$dir/$p_clean_dir")
                    fi
                    emit_json_event "{\"event\":\"dry_run\",\"profile\":\"$profile\",\"project\":\"$rel\",\"command\":\"$cmd\",\"estimated_size_bytes\":$est_size}"
                else
                    emit_json_event "{\"event\":\"dry_run\",\"profile\":\"$profile\",\"project\":\"$rel\"}"
                fi
            done
        else
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
                    if [[ -n "$p_clean_dir" && -d "$dir/$p_clean_dir" ]]; then
                        local sz
                        sz=$(dir_size_bytes "$dir/$p_clean_dir")
                        echo -e "    ${GRAY}$p_clean_dir/ size: $(format_size "$sz")${NC}"
                    fi
                fi
            done
        fi
        return
    fi

    if [[ "$JSON_OUTPUT" != true ]]; then
        echo ""
        echo -e "${CYAN}Cleaning ${p_name} projects...${NC}"
        echo ""
    fi

    local profile_size_bytes=0
    local project_index=0

    [[ "$CANCELLED" == true ]] && return

    if [[ "$PARALLEL" == true && ${#to_clean[@]} -gt 1 && "$p_type" == "command" ]]; then
        # Parallel mode for command-type profiles
        declare -a PIDS=()
        for dir in "${to_clean[@]}"; do
            (
                rel=$(get_relative_path "$dir")
                # Measure build dir before cleaning
                local size_freed=0
                if [[ -n "$p_clean_dir" && -d "$dir/$p_clean_dir" ]]; then
                    size_freed=$(dir_size_bytes "$dir/$p_clean_dir")
                fi
                pushd "$dir" > /dev/null || exit 1
                local cmd="$p_command"
                if [[ -n "$p_wrapper" && -f "$p_wrapper" ]]; then
                    cmd="$p_wrapper clean"
                fi
                result=$(eval "$cmd" 2>&1) || true
                popd > /dev/null || exit 1
                echo "RESULT:$rel:$size_freed"
            ) &
            PIDS+=($!)
        done

        for pid in "${PIDS[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        echo -e "${GREEN}Parallel cleaning complete${NC}"
    else
        for dir in "${to_clean[@]}"; do
            [[ "$CANCELLED" == true ]] && break

            local rel
            rel=$(get_relative_path "$dir")
            project_index=$((project_index + 1))

            if [[ "$p_type" == "command" ]]; then
                # Measure build dir size before cleaning
                local size_freed=0
                if [[ -n "$p_clean_dir" && -d "$dir/$p_clean_dir" ]]; then
                    size_freed=$(dir_size_bytes "$dir/$p_clean_dir")
                fi

                if [[ "$JSON_OUTPUT" != true ]]; then
                    echo -ne "${GRAY}[$project_index/${#to_clean[@]}] ${NC}"
                    echo -ne "${WHITE}Cleaning: $rel${NC}"
                fi

                pushd "$dir" > /dev/null || continue
                local cmd="$p_command"
                if [[ -n "$p_wrapper" && -f "$dir/$p_wrapper" ]]; then
                    cmd="$p_wrapper clean"
                fi
                local result
                result=$(eval "$cmd" 2>&1) || true
                popd > /dev/null || true

                profile_size_bytes=$((profile_size_bytes + size_freed))
                grand_total_size_bytes=$((grand_total_size_bytes + size_freed))

                if [[ "$JSON_OUTPUT" == true ]]; then
                    emit_json_event "{\"event\":\"clean_complete\",\"profile\":\"$profile\",\"project\":\"$rel\",\"size_bytes\":$size_freed,\"cumulative_bytes\":$profile_size_bytes}"
                else
                    local sz_fmt cum_fmt
                    sz_fmt=$(format_size "$size_freed")
                    cum_fmt=$(format_size "$profile_size_bytes")
                    if [[ "$result" =~ error:|Error ]]; then
                        echo -e " ${RED}- Error${NC}"
                        echo -e "  ${RED}$result${NC}"
                    else
                        echo -e " ${GRAY}| freed: $sz_fmt | total: $cum_fmt${NC}"
                    fi
                fi

            elif [[ "$p_type" == "remove" ]]; then
                if [[ "$JSON_OUTPUT" != true ]]; then
                    echo -e "${GRAY}[$project_index/${#to_clean[@]}] ${NC}${WHITE}Cleaning: $rel${NC}"
                fi

                local project_size_bytes=0

                # Remove target directories
                for t in "${p_targets[@]}"; do
                    if [[ -d "$dir/$t" ]]; then
                        local sz
                        sz=$(dir_size_bytes "$dir/$t")
                        project_size_bytes=$((project_size_bytes + sz))
                        rm -rf "$dir/$t"
                        if [[ "$JSON_OUTPUT" != true ]]; then
                            echo -e "  ${GRAY}removed: $t ($(format_size "$sz"))${NC}"
                        fi
                    fi
                done

                # Remove optional targets (only if they exist, no warning if absent)
                for t in "${p_optional_targets[@]}"; do
                    if [[ -d "$dir/$t" ]]; then
                        local sz
                        sz=$(dir_size_bytes "$dir/$t")
                        project_size_bytes=$((project_size_bytes + sz))
                        rm -rf "$dir/$t"
                        if [[ "$JSON_OUTPUT" != true ]]; then
                            echo -e "  ${GRAY}removed: $t ($(format_size "$sz"))${NC}"
                        fi
                    fi
                done

                # Remove recursive targets (e.g., __pycache__)
                for t in "${p_recursive_targets[@]}"; do
                    local count=0
                    while IFS= read -r rdir; do
                        local sz
                        sz=$(dir_size_bytes "$rdir")
                        project_size_bytes=$((project_size_bytes + sz))
                        rm -rf "$rdir"
                        count=$((count + 1))
                    done < <(find "$dir" -type d -name "$t" 2>/dev/null)
                    if [[ "$count" -gt 0 && "$JSON_OUTPUT" != true ]]; then
                        echo -e "  ${GRAY}removed recursive: $t ($count directories)${NC}"
                    fi
                done

                profile_size_bytes=$((profile_size_bytes + project_size_bytes))
                grand_total_size_bytes=$((grand_total_size_bytes + project_size_bytes))

                if [[ "$JSON_OUTPUT" == true ]]; then
                    emit_json_event "{\"event\":\"clean_complete\",\"profile\":\"$profile\",\"project\":\"$rel\",\"size_bytes\":$project_size_bytes,\"cumulative_bytes\":$profile_size_bytes}"
                else
                    local pf_fmt cum_fmt
                    pf_fmt=$(format_size "$project_size_bytes")
                    cum_fmt=$(format_size "$profile_size_bytes")
                    echo -e "  ${CYAN}project freed: $pf_fmt | profile total: $cum_fmt${NC}"
                fi
            fi
        done
    fi

    if [[ "$JSON_OUTPUT" == true ]]; then
        emit_json_event "{\"event\":\"profile_complete\",\"profile\":\"$profile\",\"name\":\"$p_name\",\"cleaned\":${#to_clean[@]},\"freed_bytes\":$profile_size_bytes,\"cumulative_total_bytes\":$grand_total_size_bytes}"
    else
        echo ""
        echo -e "${GREEN}${p_name} complete: $(format_size "$profile_size_bytes") freed${NC}"
    fi
}
