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

# shellcheck source=/dev/null
source "$script_directory/toolchain-lock.sh"

swiftformat_package=$(toolchain_lock_value "$toolchain_lock" SWIFTFORMAT_PACKAGE)
swiftformat_version=$(toolchain_lock_value "$toolchain_lock" SWIFTFORMAT_VERSION)
swiftlint_package=$(toolchain_lock_value "$toolchain_lock" SWIFTLINT_PACKAGE)
swiftlint_version=$(toolchain_lock_value "$toolchain_lock" SWIFTLINT_VERSION)

package_pattern='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
version_pattern='^[A-Za-z0-9][A-Za-z0-9._-]*$'
[[ "$swiftformat_package" =~ $package_pattern && "$swiftlint_package" =~ $package_pattern ]] || {
    printf '%s\n' 'toolchain lock package values must use owner/repository syntax' >&2
    exit 1
}
[[ "$swiftformat_version" =~ $version_pattern && "$swiftlint_version" =~ $version_pattern ]] || {
    printf '%s\n' 'toolchain lock version values contain unsupported characters' >&2
    exit 1
}

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
