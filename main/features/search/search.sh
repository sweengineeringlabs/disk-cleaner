#!/bin/bash

# search.sh - Search feature: finds and reports projects without modifying them

search_profile() {
    local profile="$1"
    local profile_index="$2"
    local profile_count="$3"
    local p_name p_marker p_type p_command p_clean_dir
    p_name=$(toml_get "profiles.${profile}.name")
    p_marker=$(toml_get "profiles.${profile}.marker")
    p_type=$(toml_get "profiles.${profile}.type")
    p_command=$(toml_get "profiles.${profile}.command")
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
        echo -e "${CYAN}Searching for ${p_name} projects in: $SEARCH_PATH${NC}"
    fi

    # Find projects by marker files
    declare -a all_markers=("$p_marker")
    all_markers+=("${p_alt_markers[@]}")

    spinner_start "Searching for ${p_name} projects..."

    declare -a found_dirs=()
    for marker in "${all_markers[@]}"; do
        while IFS= read -r mfile; do
            local mdir
            mdir="$(dirname "$mfile")"
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

    # Sort
    IFS=$'\n' found_dirs=($(sort <<< "${found_dirs[*]}")); unset IFS

    # Filter
    declare -a to_show=()
    declare -a skipped=()
    for dir in "${found_dirs[@]}"; do
        if should_clean "$dir"; then
            to_show+=("$dir")
        else
            skipped+=("$dir")
        fi
    done

    if [[ "$JSON_OUTPUT" == true ]]; then
        emit_json_event "{\"event\":\"scan_complete\",\"profile\":\"$profile\",\"found\":${#found_dirs[@]},\"matched\":${#to_show[@]},\"skipped\":${#skipped[@]}}"
    fi

    grand_total_projects=$((grand_total_projects + ${#found_dirs[@]}))
    grand_total_cleaned=$((grand_total_cleaned + ${#to_show[@]}))
    grand_total_skipped=$((grand_total_skipped + ${#skipped[@]}))

    if [[ ${#to_show[@]} -eq 0 ]]; then
        if [[ "$JSON_OUTPUT" != true ]]; then
            echo ""
            echo -e "${GRAY}No ${p_name} projects found.${NC}"
        fi
        return
    fi

    if [[ "$JSON_OUTPUT" != true ]]; then
        echo ""
        echo -e "${CYAN}Found ${#to_show[@]} ${p_name} projects:${NC}"
        echo ""
    fi

    local project_index=0
    for dir in "${to_show[@]}"; do
        [[ "$CANCELLED" == true ]] && break
        project_index=$((project_index + 1))
        local rel
        rel=$(get_relative_path "$dir")

        local total_artifact_size=0
        local has_artifacts=false

        if [[ "$p_type" == "command" && -n "$p_clean_dir" ]]; then
            if [[ -d "$dir/$p_clean_dir" ]]; then
                local sz
                sz=$(dir_size_bytes "$dir/$p_clean_dir")
                total_artifact_size=$((total_artifact_size + sz))
                has_artifacts=true

                if [[ "$JSON_OUTPUT" == true ]]; then
                    emit_json_event "{\"event\":\"search_result\",\"profile\":\"$profile\",\"project\":\"$rel\",\"path\":\"$dir\",\"has_artifacts\":true,\"artifact_size_bytes\":$sz,\"artifacts\":[{\"name\":\"$p_clean_dir\",\"exists\":true,\"size_bytes\":$sz}]}"
                else
                    echo -e "  ${GRAY}[$project_index/${#to_show[@]}] ${NC}${WHITE}$rel${NC} ${YELLOW}($(format_size "$sz"))${NC}"
                    echo -e "    ${GRAY}$p_clean_dir: $(format_size "$sz")${NC}"
                fi
            else
                if [[ "$JSON_OUTPUT" == true ]]; then
                    emit_json_event "{\"event\":\"search_result\",\"profile\":\"$profile\",\"project\":\"$rel\",\"path\":\"$dir\",\"has_artifacts\":false,\"artifact_size_bytes\":0,\"artifacts\":[{\"name\":\"$p_clean_dir\",\"exists\":false,\"size_bytes\":0}]}"
                else
                    echo -e "  ${GRAY}[$project_index/${#to_show[@]}] ${NC}${WHITE}$rel${NC} ${GREEN}(clean)${NC}"
                fi
            fi
        elif [[ "$p_type" == "remove" ]]; then
            local artifacts_json=""
            local artifacts_text=""

            for t in "${p_targets[@]}"; do
                if [[ -d "$dir/$t" ]]; then
                    local sz
                    sz=$(dir_size_bytes "$dir/$t")
                    total_artifact_size=$((total_artifact_size + sz))
                    has_artifacts=true
                    artifacts_text+="    ${GRAY}$t: $(format_size "$sz")${NC}\n"
                fi
            done
            for t in "${p_optional_targets[@]}"; do
                if [[ -d "$dir/$t" ]]; then
                    local sz
                    sz=$(dir_size_bytes "$dir/$t")
                    total_artifact_size=$((total_artifact_size + sz))
                    has_artifacts=true
                    artifacts_text+="    ${GRAY}$t: $(format_size "$sz")${NC}\n"
                fi
            done
            for t in "${p_recursive_targets[@]}"; do
                local count
                count=$(find "$dir" -type d -name "$t" 2>/dev/null | wc -l)
                if [[ "$count" -gt 0 ]]; then
                    local sz=0
                    while IFS= read -r rdir; do
                        local rsz
                        rsz=$(dir_size_bytes "$rdir")
                        sz=$((sz + rsz))
                    done < <(find "$dir" -type d -name "$t" 2>/dev/null)
                    total_artifact_size=$((total_artifact_size + sz))
                    has_artifacts=true
                    artifacts_text+="    ${GRAY}$t (recursive, $count dirs): $(format_size "$sz")${NC}\n"
                fi
            done

            if [[ "$JSON_OUTPUT" == true ]]; then
                emit_json_event "{\"event\":\"search_result\",\"profile\":\"$profile\",\"project\":\"$rel\",\"path\":\"$dir\",\"has_artifacts\":$has_artifacts,\"artifact_size_bytes\":$total_artifact_size}"
            else
                if [[ "$has_artifacts" == true ]]; then
                    echo -e "  ${GRAY}[$project_index/${#to_show[@]}] ${NC}${WHITE}$rel${NC} ${YELLOW}($(format_size "$total_artifact_size"))${NC}"
                    echo -ne "$artifacts_text"
                else
                    echo -e "  ${GRAY}[$project_index/${#to_show[@]}] ${NC}${WHITE}$rel${NC} ${GREEN}(clean)${NC}"
                fi
            fi
        fi

        grand_total_size_bytes=$((grand_total_size_bytes + total_artifact_size))
    done

    # Show skipped
    if [[ "$JSON_OUTPUT" != true && ${#skipped[@]} -gt 0 && "$ALL" != true && (${#EXCLUDE_PATTERNS[@]} -gt 0 || ${#INCLUDE_PATTERNS[@]} -gt 0) ]]; then
        echo ""
        echo -e "${YELLOW}Skipped (${#skipped[@]}):${NC}"
        for s in "${skipped[@]}"; do
            local rel
            rel=$(get_relative_path "$s")
            echo -e "  ${DARKYELLOW}- $rel${NC}"
        done
    fi
}
