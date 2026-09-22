#!/usr/bin/env bash
set -euo pipefail

readonly script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
readonly default_repository_url="https://github.com/danielbyon/swift-tooling"
readonly default_release_asset="swift-tooling.tar.gz"
readonly default_manifest_asset="release-manifest.env"

repository_root=$(pwd -P)
release_archive=''
release_version=''
release_sha256=''
release_asset=''
repository_url="${SWIFT_TOOLING_REPOSITORY_URL:-$default_repository_url}"
manifest_file=''
archive_file=''
temporary_root=''
transaction_active=0
transaction_count=0
transaction_target=()
transaction_backup=()
transaction_staged=()
transaction_was_present=()

usage() {
    cat <<'USAGE'
Usage: setup-swift-tools.sh [options]

Options:
  --repository-root PATH       Consumer repository root (default: current directory)
  --release-archive PATH       Local release archive, for tests/offline installs
  --release-version VERSION    Pin the remote release or identify a local archive
  --release-sha256 DIGEST      Release checksum for --release-archive
  --release-asset NAME         Remote release asset name
  --repository-url URL         Shared repository URL
  --help                       Show this help
USAGE
}

die() {
    printf 'swift-tooling setup: %s\n' "$1" >&2
    exit 1
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

validate_release_version() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "release version must look like vMAJOR.MINOR.PATCH: $1"
}

# This script is published as a standalone release asset, so its archive
# validator cannot depend on another file being downloaded beside it.
validate_release_archive() {
    local archive=$1
    local member listing entry_type
    local member_list detail_list

    member_list=$(mktemp "${TMPDIR:-/tmp}/swift-tooling-tar-members.XXXXXX")
    detail_list=$(mktemp "${TMPDIR:-/tmp}/swift-tooling-tar-details.XXXXXX")
    if ! tar -tzf "$archive" > "$member_list" || ! tar -tvzf "$archive" > "$detail_list"; then
        rm -f "$member_list" "$detail_list"
        die "could not inspect release archive: $archive"
    fi

    while IFS= read -r member; do
        case "$member" in
            ''|./) continue ;;
            /*|../*|*/../*|*/..|..)
                rm -f "$member_list" "$detail_list"
                die "release archive contains an unsafe path: $member"
                ;;
        esac
    done < "$member_list"

    while IFS= read -r listing; do
        entry_type=${listing:0:1}
        case "$entry_type" in
            -|d) ;;
            *)
                rm -f "$member_list" "$detail_list"
                die 'release archive contains a symlink, hard link, or special file'
                ;;
        esac
    done < "$detail_list"

    rm -f "$member_list" "$detail_list"
}

release_contents_match() {
    local archive=$1
    local root=$2
    local manifest_file
    local member relative current_sha archive_sha actual_file

    manifest_file=$(mktemp "${TMPDIR:-/tmp}/swift-tooling-manifest.XXXXXX")
    if ! tar -tzf "$archive" > "$manifest_file"; then
        rm -f "$manifest_file"
        return 1
    fi

    while IFS= read -r member; do
        case "$member" in
            ''|*/|./) continue ;;
        esac
        relative=${member#./}
        actual_file="$root/$relative"
        [[ -f "$actual_file" && ! -L "$actual_file" ]] || {
            rm -f "$manifest_file"
            return 1
        }
        if ! archive_sha=$(tar -xOf "$archive" "$member" | shasum -a 256 | awk '{print $1}'); then
            rm -f "$manifest_file"
            return 1
        fi
        current_sha=$(shasum -a 256 "$actual_file" | awk '{print $1}')
        if [[ "$archive_sha" != "$current_sha" ]]; then
            rm -f "$manifest_file"
            return 1
        fi
    done < "$manifest_file"

    while IFS= read -r -d '' actual_file; do
        relative=${actual_file#"$root"/}
        [[ "$relative" = .swift-tooling-release.tar.gz ]] && continue
        if ! grep -Fqx -- "./$relative" "$manifest_file" && ! grep -Fqx -- "$relative" "$manifest_file"; then
            rm -f "$manifest_file"
            return 1
        fi
    done < <(find "$root" -type f -print0)

    while IFS= read -r -d '' actual_file; do
        relative=${actual_file#"$root"/}
        [[ "$relative" = .swift-tooling-release.tar.gz ]] && continue
        rm -f "$manifest_file"
        return 1
    done < <(find "$root" ! -type f ! -type d -print0)

    rm -f "$manifest_file"
}

transaction_add_entry() {
    local target=$1
    local backup=$2
    local staged=$3
    local index=$transaction_count

    transaction_target[$index]="$target"
    transaction_backup[$index]="$backup"
    transaction_staged[$index]="$staged"
    transaction_was_present[$index]=0
    transaction_count=$((transaction_count + 1))
}

transaction_mark_present() {
    transaction_was_present[$1]=1
}

restore_transaction_entry() {
    local target=$1
    local backup=$2
    local staged=$3
    local was_present=$4

    if [[ -e "$backup" || -L "$backup" ]]; then
        rm -rf "$target"
        mv "$backup" "$target"
    elif [[ "$was_present" -eq 0 \
        && ! -e "$staged" && ! -L "$staged" \
        && ( -e "$target" || -L "$target" ) ]]; then
        rm -rf "$target"
    fi
}

restore_transaction() {
    local index

    if [[ "$transaction_active" -eq 1 ]]; then
        index=$((transaction_count - 1))
        while [[ "$index" -ge 0 ]]; do
            restore_transaction_entry \
                "${transaction_target[$index]}" \
                "${transaction_backup[$index]}" \
                "${transaction_staged[$index]}" \
                "${transaction_was_present[$index]}"
            index=$((index - 1))
        done
    fi
    transaction_active=0
    transaction_count=0
}

cleanup() {
    restore_transaction
    [[ -z "$manifest_file" ]] || rm -f "$manifest_file"
    [[ -z "$archive_file" ]] || rm -f "$archive_file"
    [[ -z "$temporary_root" ]] || rm -rf "$temporary_root"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_manifest_value() {
    local key=$1
    local file=$2
    awk -F= -v expected_key="$key" '$1 == expected_key { print substr($0, index($0, "=") + 1); exit }' "$file"
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --repository-root)
            [[ "$#" -ge 2 ]] || die '--repository-root requires a path'
            repository_root=$(cd -- "$2" && pwd -P)
            shift 2
            ;;
        --release-archive)
            [[ "$#" -ge 2 ]] || die '--release-archive requires a path'
            release_archive=$2
            shift 2
            ;;
        --release-version)
            [[ "$#" -ge 2 ]] || die '--release-version requires a value'
            release_version=$2
            shift 2
            ;;
        --release-sha256)
            [[ "$#" -ge 2 ]] || die '--release-sha256 requires a value'
            release_sha256=$2
            shift 2
            ;;
        --release-asset)
            [[ "$#" -ge 2 ]] || die '--release-asset requires a value'
            release_asset=$2
            shift 2
            ;;
        --repository-url)
            [[ "$#" -ge 2 ]] || die '--repository-url requires a URL'
            repository_url=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ -d "$repository_root" ]] || die "repository root does not exist: $repository_root"

if [[ -z "$release_archive" ]]; then
    if [[ -n "$release_version" ]]; then
        validate_release_version "$release_version"
        manifest_url="$repository_url/releases/download/$release_version/$default_manifest_asset"
    else
        manifest_url="$repository_url/releases/latest/download/$default_manifest_asset"
    fi
    manifest_file=$(mktemp "${TMPDIR:-/tmp}/swift-tooling-manifest.XXXXXX")
    archive_file=$(mktemp "${TMPDIR:-/tmp}/swift-tooling-archive.XXXXXX")

    curl --fail --location --silent --show-error "$manifest_url" --output "$manifest_file"
    manifest_release_version=$(parse_manifest_value RELEASE_VERSION "$manifest_file")
    if [[ -n "$release_version" && "$manifest_release_version" != "$release_version" ]]; then
        die "release manifest version differs from requested release: $manifest_release_version"
    fi
    release_version=${release_version:-$manifest_release_version}
    release_sha256=${release_sha256:-$(parse_manifest_value RELEASE_SHA256 "$manifest_file")}
    release_asset=${release_asset:-$(parse_manifest_value RELEASE_ASSET "$manifest_file")}
    release_asset=${release_asset:-$default_release_asset}
    [[ -n "$release_version" ]] || die 'release manifest did not provide RELEASE_VERSION'
    [[ -n "$release_sha256" ]] || die 'release manifest did not provide RELEASE_SHA256'
    validate_release_version "$release_version"

    archive_url="$repository_url/releases/download/$release_version/$release_asset"
    curl --fail --location --silent --show-error "$archive_url" --output "$archive_file"
    release_archive=$archive_file
else
    [[ -f "$release_archive" ]] || die "release archive does not exist: $release_archive"
    [[ -n "$release_version" ]] || die '--release-version is required with --release-archive'
    [[ -n "$release_sha256" ]] || die '--release-sha256 is required with --release-archive'
    release_asset=${release_asset:-${release_archive##*/}}
fi

validate_release_version "$release_version"
release_asset=${release_asset:-$default_release_asset}

actual_sha256=$(sha256_file "$release_archive")
if [[ "$actual_sha256" != "$release_sha256" ]]; then
    die "release checksum mismatch (expected $release_sha256, got $actual_sha256)"
fi

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-tooling-release.XXXXXX")
temporary_release="$temporary_root/release"
temporary_install="$temporary_root/install"

mkdir -p "$temporary_release" "$temporary_install"
validate_release_archive "$release_archive"
tar -xzf "$release_archive" -C "$temporary_release"

for required_file in \
    bin/swift-tooling \
    Scripts/setup-swift-tools.sh \
    Scripts/swift-tools.sh \
    Scripts/swift-tools-local.sh \
    config/swiftformat.base \
    config/swiftlint.base.yml \
    toolchain.lock \
    Mintfile; do
    [[ -f "$temporary_release/$required_file" ]] || die "release is missing $required_file"
done

tools_directory="$repository_root/.tools/swift-tooling"
install_directory="$tools_directory/$release_version"
mkdir -p "$tools_directory" "$repository_root/Scripts"
staged_install="$temporary_install/$release_version"
mv "$temporary_release" "$staged_install"

release_needs_install=1
existing_release_is_current=0
if [[ -e "$install_directory" ]]; then
    if [[ -f "$install_directory/.swift-tooling-release.tar.gz" ]]; then
        existing_release_sha256=$(sha256_file "$install_directory/.swift-tooling-release.tar.gz")
        if [[ "$existing_release_sha256" = "$release_sha256" ]] \
            && [[ -x "$install_directory/bin/swift-tooling" ]] \
            && release_contents_match "$release_archive" "$install_directory"; then
            existing_release_is_current=1
        fi
    fi
    if [[ "$existing_release_is_current" -eq 1 ]]; then
        rm -rf "$staged_install"
    fi
fi

if [[ "$existing_release_is_current" -ne 1 ]]; then
    cp "$release_archive" "$staged_install/.swift-tooling-release.tar.gz"
else
    release_needs_install=0
fi

stage_pin_files() {
    local lock_target="$repository_root/Scripts/swift-tools.lock"
    local adapter_target="$repository_root/Scripts/swift-tools.sh"
    local current_lock_version=''
    local current_lock_sha256=''
    local adapter_source="$install_directory"

    if [[ "$release_needs_install" -eq 1 ]]; then
        adapter_source="$staged_install"
    fi

    staged_lock="$temporary_install/swift-tools.lock"
    cat > "$staged_lock" <<LOCK
SWIFT_TOOLING_REPOSITORY_URL=$repository_url
SWIFT_TOOLING_RELEASE_VERSION=$release_version
SWIFT_TOOLING_RELEASE_SHA256=$release_sha256
SWIFT_TOOLING_RELEASE_ASSET=$release_asset
LOCK

    if [[ -f "$lock_target" ]]; then
        current_lock_version=$(awk -F= '$1 == "SWIFT_TOOLING_RELEASE_VERSION" { print $2; exit }' "$lock_target")
        current_lock_sha256=$(awk -F= '$1 == "SWIFT_TOOLING_RELEASE_SHA256" { print $2; exit }' "$lock_target")
    fi

    adapter_needs_install=0
    if [[ ! -f "$adapter_target" || "$current_lock_version" != "$release_version" || "$current_lock_sha256" != "$release_sha256" ]]; then
        staged_adapter="$temporary_install/swift-tools.sh"
        cp "$adapter_source/Scripts/swift-tools.sh" "$staged_adapter"
        chmod 0755 "$staged_adapter"
        adapter_needs_install=1
    fi
}

stage_consumer_files() {
    local gitignore_target="$repository_root/.gitignore"
    local local_config_target="$repository_root/Scripts/swift-tools-local.sh"
    local local_config_source="$install_directory"

    if [[ "$release_needs_install" -eq 1 ]]; then
        local_config_source="$staged_install"
    fi

    staged_gitignore="$temporary_install/.gitignore"
    if [[ -L "$gitignore_target" || ( -e "$gitignore_target" && ! -f "$gitignore_target" ) ]]; then
        die "consumer .gitignore is not a regular file: $gitignore_target"
    fi
    if [[ -f "$gitignore_target" ]]; then
        cp "$gitignore_target" "$staged_gitignore"
    else
        : > "$staged_gitignore"
    fi
    if ! grep -Fxq '.tools/' "$staged_gitignore"; then
        if [[ -s "$staged_gitignore" ]] && [[ "$(tail -c 1 "$staged_gitignore" | wc -l | tr -d ' ')" -eq 0 ]]; then
            printf '\n' >> "$staged_gitignore"
        fi
        printf '%s\n' '.tools/' >> "$staged_gitignore"
    fi

    gitignore_needs_install=1
    if [[ -f "$gitignore_target" ]] && cmp -s "$staged_gitignore" "$gitignore_target"; then
        rm -f "$staged_gitignore"
        gitignore_needs_install=0
    fi

    local_config_needs_install=0
    if [[ ! -e "$local_config_target" && ! -L "$local_config_target" ]]; then
        staged_local_config="$temporary_install/swift-tools-local.sh"
        cp "$local_config_source/Scripts/swift-tools-local.sh" "$staged_local_config"
        chmod 0644 "$staged_local_config"
        local_config_needs_install=1
    fi
}

commit_staged_files() {
    local adapter_target="$repository_root/Scripts/swift-tools.sh"
    local lock_target="$repository_root/Scripts/swift-tools.lock"
    local local_config_target="$repository_root/Scripts/swift-tools-local.sh"
    local gitignore_target="$repository_root/.gitignore"
    local previous_install="$temporary_install/previous-release"
    local adapter_backup="$temporary_install/swift-tools.sh.previous"
    local lock_backup="$temporary_install/swift-tools.lock.previous"
    local local_config_backup="$temporary_install/swift-tools-local.sh.previous"
    local gitignore_backup="$temporary_install/.gitignore.previous"
    local release_entry=-1
    local adapter_entry=-1
    local lock_entry
    local local_config_entry=-1
    local gitignore_entry=-1

    transaction_active=0
    transaction_count=0
    if [[ "$release_needs_install" -eq 1 ]]; then
        transaction_add_entry "$install_directory" "$previous_install" "$staged_install"
        release_entry=$((transaction_count - 1))
    fi
    if [[ "$adapter_needs_install" -eq 1 ]]; then
        transaction_add_entry "$adapter_target" "$adapter_backup" "${staged_adapter:-}"
        adapter_entry=$((transaction_count - 1))
    fi
    transaction_add_entry "$lock_target" "$lock_backup" "$staged_lock"
    lock_entry=$((transaction_count - 1))
    if [[ "$local_config_needs_install" -eq 1 ]]; then
        transaction_add_entry "$local_config_target" "$local_config_backup" \
            "${staged_local_config:-}"
        local_config_entry=$((transaction_count - 1))
    fi
    if [[ "$gitignore_needs_install" -eq 1 ]]; then
        transaction_add_entry "$gitignore_target" "$gitignore_backup" "$staged_gitignore"
        gitignore_entry=$((transaction_count - 1))
    fi
    transaction_active=1

    if [[ "$release_needs_install" -eq 1 ]]; then
        if [[ -e "$install_directory" || -L "$install_directory" ]]; then
            transaction_mark_present "$release_entry"
            if ! mv "$install_directory" "$previous_install"; then
                restore_transaction
                die "could not stage the existing release: $install_directory"
            fi
        fi
        if ! mv "$staged_install" "$install_directory"; then
            restore_transaction
            die "could not install the swift-tooling release: $install_directory"
        fi
    fi

    if [[ "$adapter_needs_install" -eq 1 ]]; then
        if [[ -e "$adapter_target" || -L "$adapter_target" ]]; then
            transaction_mark_present "$adapter_entry"
            if ! mv "$adapter_target" "$adapter_backup"; then
                restore_transaction
                die 'could not stage the existing swift-tools adapter'
            fi
        fi
        if ! mv "$staged_adapter" "$adapter_target"; then
            restore_transaction
            die 'could not install the swift-tools adapter'
        fi
    fi

    if [[ -e "$lock_target" || -L "$lock_target" ]]; then
        transaction_mark_present "$lock_entry"
        if ! mv "$lock_target" "$lock_backup"; then
            restore_transaction
            die 'could not stage the existing swift-tools lock file'
        fi
    fi
    if ! mv "$staged_lock" "$lock_target"; then
        restore_transaction
        die 'could not install the swift-tools lock file'
    fi

    if [[ "$local_config_needs_install" -eq 1 ]]; then
        if [[ -e "$local_config_target" || -L "$local_config_target" ]]; then
            transaction_mark_present "$local_config_entry"
            if ! mv "$local_config_target" "$local_config_backup"; then
                restore_transaction
                die 'could not stage the existing local swift-tools configuration'
            fi
        fi
        if ! mv "$staged_local_config" "$local_config_target"; then
            restore_transaction
            die 'could not install the local swift-tools configuration'
        fi
    fi

    if [[ "$gitignore_needs_install" -eq 1 ]]; then
        if [[ -e "$gitignore_target" || -L "$gitignore_target" ]]; then
            transaction_mark_present "$gitignore_entry"
            if ! mv "$gitignore_target" "$gitignore_backup"; then
                restore_transaction
                die 'could not stage the consumer .gitignore'
            fi
        fi
        if ! mv "$staged_gitignore" "$gitignore_target"; then
            restore_transaction
            die 'could not install the consumer .gitignore'
        fi
    fi

    transaction_active=0
    transaction_count=0
    rm -f "$adapter_backup" "$lock_backup" "$local_config_backup" "$gitignore_backup"
    rm -rf "$previous_install"
}

stage_pin_files
stage_consumer_files
commit_staged_files

printf 'Installed swift-tooling %s under %s\n' "$release_version" "$install_directory"
