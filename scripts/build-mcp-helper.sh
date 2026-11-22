#!/bin/bash
set -euo pipefail

if [[ $# != 2 ]]; then
    echo "Usage: $0 APP_CONTENTS VERSION" >&2
    exit 2
fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
    echo "Build the MPCut MCP helper on Apple Silicon using a native arm64 shell." >&2
    exit 1
fi
mkdir -p "$1/Helpers" "$1/Resources"
contents=$(cd "$1" && pwd)
version=$2

go_version=go1.27.4
go_digest=91a44a2b8a716600ad94a4f143e156116620db8828086a6e3602291be9bd0bb4
if [[ $(awk '$1 == "toolchain" { print $2 }' "$root/mcp/go.mod") != "$go_version" ]]; then
    echo "Update the pinned Go archive and checksum to match mcp/go.mod." >&2
    exit 1
fi
unset GOROOT
export GOTOOLCHAIN=local GOWORK=off
export GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 MACOSX_DEPLOYMENT_TARGET=14.0
pinned_go() {
    [[ $("$1" version 2>/dev/null) == "go version $go_version darwin/arm64" ]]
}

go=$(command -v go || true)
if [[ -z "$go" ]] || ! pinned_go "$go"; then
    go_cache="$root/.build/$go_version"
    go="$go_cache/go/bin/go"
    if [[ ! -f "$go_cache/ready" ]] || ! pinned_go "$go"; then
        mkdir -p "$go_cache"
        # Standalone helper builds share this cache with full app builds.
        if [[ ${MPCUT_GO_BOOTSTRAP_LOCK:-} != "$go_cache" ]]; then
            export MPCUT_GO_BOOTSTRAP_LOCK="$go_cache"
            exec /usr/bin/lockf -k "$go_cache/.lock" /bin/bash "$root/scripts/build-mcp-helper.sh" "$contents" "$version"
        fi

        for stale in "$go_cache"/.stage.??????; do
            [[ ! -d "$stale" || -L "$stale" ]] || rm -rf "$stale"
        done
        stage=$(mktemp -d "$go_cache/.stage.XXXXXX")
        trap 'rm -rf "$stage"' EXIT
        verify_archive() {
            printf '%s  %s\n' "$go_digest" "$1" | shasum -a 256 --check --status
        }
        archive="$go_cache/$go_version.darwin-arm64.tar.gz"
        if [[ ! -f "$archive" ]] || ! verify_archive "$archive"; then
            curl --fail --location --silent --show-error --retry 3 "https://go.dev/dl/${archive##*/}" --output "$stage/archive.tar.gz"
            if ! verify_archive "$stage/archive.tar.gz"; then
                echo "Invalid checksum for ${archive##*/}." >&2
                exit 1
            fi
            mv -f "$stage/archive.tar.gz" "$archive"
        fi
        tar -xzf "$archive" -C "$stage"
        pinned_go "$stage/go/bin/go"
        "$stage/go/bin/go" version > "$stage/ready"
        rm -f "$go_cache/ready"
        rm -rf "$go_cache/go"
        mv "$stage/go" "$go_cache/go"
        mv "$stage/ready" "$go_cache/ready"
    fi
fi

mkdir -p "$contents/Resources/MCPTools"
install -m 644 "$root"/Sources/MPCutApp/MCPResources/*.json "$contents/Resources/MCPTools/"
"$go" build -C "$root/mcp" -mod=readonly -trimpath \
    -ldflags="-linkmode=external -extldflags=-mmacosx-version-min=14.0 -X main.version=$version" \
    -o "$contents/Helpers/mpcut-mcp" .

go_notices="$contents/Resources/MCPNotices"
mkdir -p "$go_notices"
goroot=$("$go" env GOROOT)
install -m 644 "$goroot/LICENSE" "$go_notices/Go-LICENSE"
install -m 644 "$goroot/PATENTS" "$go_notices/Go-PATENTS"
copy_notices() {
    local source=$1 destination=$2 license found=0
    for license in "$source"/{LICENSE,COPYING,NOTICE,PATENTS}*; do
        [[ -f "$license" ]] || continue
        mkdir -p "$destination"
        install -m 644 "$license" "$destination/"
        found=1
    done
    if [[ $found == 0 ]]; then
        echo "Missing notices in $source." >&2
        return 1
    fi
}

# The standard library ships with a separate set of vendored module notices.
for module_dir in "$goroot"/src/vendor/golang.org/x/*; do
    copy_notices "$module_dir" "$go_notices/Go-stdlib/golang.org/x/${module_dir##*/}"
done
modules=$("$go" list -C "$root/mcp" -mod=readonly -deps -f '{{with .Module}}{{if not .Main}}{{.Path}} {{.Dir}}{{end}}{{end}}' . | sort -u)
while read -r module module_dir; do
    [[ -n "$module" ]] || continue
    copy_notices "$module_dir" "$go_notices/$module"
done <<< "$modules"
