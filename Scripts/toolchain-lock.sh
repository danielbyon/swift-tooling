#!/usr/bin/env bash

# Read literal toolchain.lock assignments without executing the lock file.
# The accepted format is shell-like data: optional `export`, identifier
# assignments, quoted or unquoted literal values, backslash escapes, and
# trailing comments. Expansion syntax is rejected instead of evaluated.
# Repeated keys use the last value, matching normal assignment behavior.
toolchain_lock_parse_literal() {
    local key=$1
    local raw=$2
    local state=unquoted
    local char next value=''
    local started=0
    local pending_whitespace=0
    local index=0
    local length=${#raw}

    while [[ "$index" -lt "$length" ]]; do
        char=${raw:$index:1}
        case "$state" in
            unquoted)
                if [[ "$char" =~ [[:space:]] ]]; then
                    if [[ "$started" -eq 1 ]]; then
                        pending_whitespace=1
                    fi
                    index=$((index + 1))
                    continue
                fi
                if [[ "$pending_whitespace" -eq 1 ]]; then
                    if [[ "$char" = '#' ]]; then
                        break
                    fi
                    printf 'unquoted whitespace in toolchain lock value for %s\n' "$key" >&2
                    return 1
                fi
                if [[ "$char" = '#' ]]; then
                    if [[ "$started" -eq 0 ]]; then
                        break
                    fi
                    value="${value}#"
                    started=1
                elif [[ "$char" = "'" ]]; then
                    state=single
                    started=1
                elif [[ "$char" = '"' ]]; then
                    state=double
                    started=1
                elif [[ "$char" = '$' || "$char" = '`' ]]; then
                    printf 'expansion syntax is not allowed in toolchain lock value for %s\n' "$key" >&2
                    return 1
                elif [[ "$char" = \\ ]]; then
                    if [[ "$index" -ge $((length - 1)) ]]; then
                        printf 'trailing escape in toolchain lock value for %s\n' "$key" >&2
                        return 1
                    fi
                    next=${raw:$((index + 1)):1}
                    value="${value}${next}"
                    started=1
                    index=$((index + 2))
                    continue
                else
                    value="${value}${char}"
                    started=1
                fi
                ;;
            single)
                if [[ "$char" = "'" ]]; then
                    state=unquoted
                else
                    value="${value}${char}"
                fi
                ;;
            double)
                if [[ "$char" = '"' ]]; then
                    state=unquoted
                elif [[ "$char" = '$' || "$char" = '`' ]]; then
                    printf 'expansion syntax is not allowed in toolchain lock value for %s\n' "$key" >&2
                    return 1
                elif [[ "$char" = \\ ]]; then
                    if [[ "$index" -ge $((length - 1)) ]]; then
                        printf 'trailing escape in toolchain lock value for %s\n' "$key" >&2
                        return 1
                    fi
                    next=${raw:$((index + 1)):1}
                    case "$next" in
                        '$'|'`'|'"'|\\)
                            value="${value}${next}"
                            ;;
                        *)
                            value="${value}\\${next}"
                            ;;
                    esac
                    index=$((index + 2))
                    continue
                else
                    value="${value}${char}"
                fi
                ;;
        esac
        index=$((index + 1))
    done

    if [[ "$state" != unquoted ]]; then
        printf 'unterminated %s-quoted value for %s\n' "$state" "$key" >&2
        return 1
    fi

    toolchain_lock_parsed_value=$value
}

toolchain_lock_value() {
    local toolchain_lock=$1
    local expected_key=$2
    local line key raw value=''

    [[ -f "$toolchain_lock" ]] || {
        printf 'toolchain lock does not exist: %s\n' "$toolchain_lock" >&2
        return 1
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        line="${line#${line%%[![:space:]]*}}"
        if [[ "$line" == export[[:space:]]* ]]; then
            line=${line#export}
            line="${line#${line%%[![:space:]]*}}"
        fi
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            printf 'invalid toolchain lock assignment: %s\n' "$line" >&2
            return 1
        fi
        key=${BASH_REMATCH[1]}
        raw=${BASH_REMATCH[2]}
        toolchain_lock_parse_literal "$key" "$raw" || return 1
        [[ "$key" = "$expected_key" ]] && value=$toolchain_lock_parsed_value
    done < "$toolchain_lock"

    printf '%s' "$value"
}
