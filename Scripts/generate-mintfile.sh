#!/usr/bin/env bash
set -euo pipefail

readonly script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
readonly repository_root=$(cd -- "$script_directory/.." && pwd -P)

toolchain_lock=${1:-$repository_root/toolchain.lock}
output_file=${2:-}

if [[ -z "$output_file" ]]; then
    printf '%s\n' 'Usage: generate-mintfile.sh TOOLCHAIN_LOCK OUTPUT_FILE' >&2
    exit 2
fi
[[ -f "$toolchain_lock" ]] || {
    printf 'toolchain lock does not exist: %s\n' "$toolchain_lock" >&2
    exit 1
}

lock_value() {
    local key=$1
    awk -F= -v expected_key="$key" '$1 == expected_key { print substr($0, index($0, "=") + 1); exit }' "$toolchain_lock"
}

swiftformat_package=$(lock_value SWIFTFORMAT_PACKAGE)
swiftformat_version=$(lock_value SWIFTFORMAT_VERSION)
swiftlint_package=$(lock_value SWIFTLINT_PACKAGE)
swiftlint_version=$(lock_value SWIFTLINT_VERSION)

[[ -n "$swiftformat_package" && -n "$swiftformat_version" ]] || {
    printf '%s\n' 'toolchain lock must define the SwiftFormat package and version' >&2
    exit 1
}
[[ -n "$swiftlint_package" && -n "$swiftlint_version" ]] || {
    printf '%s\n' 'toolchain lock must define the SwiftLint package and version' >&2
    exit 1
}

mkdir -p "$(dirname "$output_file")"
{
    printf '%s@%s\n' "$swiftformat_package" "$swiftformat_version"
    printf '%s@%s\n' "$swiftlint_package" "$swiftlint_version"
} > "$output_file"
