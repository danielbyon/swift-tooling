#!/usr/bin/env bash
set -euo pipefail

readonly script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
readonly repository_root=$(cd -- "$script_directory/.." && pwd -P)
validation_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-tooling-config.XXXXXX")

cleanup() {
    rm -rf "$validation_root"
}

trap cleanup EXIT

cp "$repository_root/toolchain.lock" "$validation_root/toolchain.lock"
mkdir -p "$validation_root/config"
cp "$repository_root/config/swiftformat.base" "$validation_root/config/swiftformat.base"
cp "$repository_root/config/swiftlint.base.yml" "$validation_root/config/swiftlint.base.yml"
bash "$repository_root/Scripts/generate-mintfile.sh" "$repository_root/toolchain.lock" "$validation_root/Mintfile"
bash "$repository_root/bin/swift-tooling" --root "$repository_root" --release-root "$validation_root" bootstrap
bash "$repository_root/bin/swift-tooling" --root "$repository_root" --release-root "$validation_root" exec swiftlint rules --config "$repository_root/config/swiftlint.base.yml" >/dev/null

printf '%s\n' 'allow_zero_lintable_files: true' > "$validation_root/swiftlint-empty.yml"
bash "$repository_root/bin/swift-tooling" --root "$repository_root" --release-root "$validation_root" exec swiftlint lint --config "$repository_root/config/swiftlint.base.yml" --config "$validation_root/swiftlint-empty.yml" "$validation_root"
bash "$repository_root/bin/swift-tooling" --root "$repository_root" --release-root "$validation_root" exec swiftformat --lint --config "$repository_root/config/swiftformat.base" stdin --stdin-path ConfigSmoke.swift < /dev/null
