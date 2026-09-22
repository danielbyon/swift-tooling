#!/usr/bin/env bash
set -euo pipefail

readonly script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
readonly repository_root=$(cd -- "$script_directory/.." && pwd -P)

release_version=${1:-}
output_directory=${2:-}

[[ -n "$release_version" ]] || {
    printf 'Usage: build-release.sh VERSION OUTPUT_DIRECTORY\n' >&2
    exit 2
}
[[ -n "$output_directory" ]] || {
    printf 'Usage: build-release.sh VERSION OUTPUT_DIRECTORY\n' >&2
    exit 2
}

if [[ ! "$release_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Release version must look like vMAJOR.MINOR.PATCH: %s\n' "$release_version" >&2
    exit 2
fi

mkdir -p "$output_directory"
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-tooling-release.XXXXXX")
trap 'rm -rf "$staging_root"' EXIT

release_root="$staging_root/swift-tooling"
mkdir -p "$release_root"
for release_path in bin Scripts config Mintfile toolchain.lock; do
    cp -R "$repository_root/$release_path" "$release_root/$release_path"
done

chmod 0755 "$release_root/bin/swift-tooling" \
    "$release_root/Scripts/setup-swift-tools.sh" \
    "$release_root/Scripts/swift-tools.sh"

archive_name="swift-tooling-$release_version.tar.gz"
archive_path="$output_directory/$archive_name"
tar -czf "$archive_path" -C "$release_root" .

archive_sha256=$(shasum -a 256 "$archive_path" | awk '{print $1}')
printf '%s  %s\n' "$archive_sha256" "$archive_name" > "$archive_path.sha256"
cp "$repository_root/Scripts/setup-swift-tools.sh" "$output_directory/setup-swift-tools.sh"
chmod 0755 "$output_directory/setup-swift-tools.sh"
cat > "$output_directory/release-manifest.env" <<MANIFEST
RELEASE_VERSION=$release_version
RELEASE_SHA256=$archive_sha256
RELEASE_ASSET=$archive_name
MANIFEST

printf 'Built %s (%s)\n' "$archive_name" "$archive_sha256"
