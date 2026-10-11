#!/usr/bin/env bash

# This file is sourced by the deployment scripts. It deliberately parses the
# small .env subset used here instead of executing the file as shell code.

env_read() {
    local env_file=$1
    local wanted_key=$2
    local line key value first_character last_character

    ENV_VALUE=''
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] || continue
        key=${BASH_REMATCH[1]}
        [[ $key == "$wanted_key" ]] || continue

        value=${line#*=}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        if [[ ${#value} -ge 2 ]]; then
            first_character=${value:0:1}
            last_character=${value: -1}
            if [[ ($first_character == '"' && $last_character == '"') || ($first_character == "'" && $last_character == "'") ]]; then
                value=${value:1:${#value}-2}
            fi
        fi
        ENV_VALUE=$value
        return 0
    done < "$env_file"

    return 1
}

env_read_or_default() {
    local env_file=$1
    local wanted_key=$2
    local default_value=$3

    if env_read "$env_file" "$wanted_key"; then
        return 0
    fi

    ENV_VALUE=$default_value
}

env_append_default() {
    local env_file=$1
    local wanted_key=$2
    local default_value=$3

    env_read "$env_file" "$wanted_key" && return 0

    if [[ -s $env_file ]] && [[ $(tail -c 1 "$env_file") != $'\n' ]]; then
        printf '\n' >> "$env_file"
    fi
    printf '%s=%s\n' "$wanted_key" "$default_value" >> "$env_file"
}
