#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [output-directory]" >&2
    exit 2
fi
if [[ $(uname -m) != arm64 ]]; then
    echo "Build MPCut on Apple Silicon using a native arm64 shell." >&2
    exit 1
fi
output_dir="${1:-$root/dist}"
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)

mkdir -p "$root/.build"
if [[ ${MPCUT_APP_BUILD_LOCK:-} != "$root" ]]; then
    export MPCUT_APP_BUILD_LOCK="$root"
    # Different checkouts can publish to the same destination. Hold its lock
    # while recovering abandoned stages and replacing the bundle.
    exec /usr/bin/lockf -k "$root/.build/.mpcut-app.lock" \
        /usr/bin/lockf -k "$output_dir/.mpcut-publish.lock" /bin/bash "$root/scripts/build-app.sh" "$output_dir"
fi

final="$output_dir/MPCut.app"
# A build that was killed outright never ran its exit handler. Its stage folder
# may hold the only copy of the previous bundle, moved aside just before the new
# one was to take its place. This build holds the lock, so every stage folder
# found here is abandoned: put that bundle back, then remove the leftovers.
if [[ -n "$output_dir" && -d "$output_dir" ]]; then
    for stale in "$output_dir"/.MPCut-stage.??????; do
        if [[ ! -d "$stale" || -L "$stale" ]]; then
            continue
        fi
        if [[ ( -e "$stale/previous.app" || -L "$stale/previous.app" ) && ! -e "$final" && ! -L "$final" ]]; then
            mv "$stale/previous.app" "$final"
        fi
        rm -rf "$stale"
    done
fi

if [[ -n "${MPCUT_TILETRAIL_PREFIX:-}" ]]; then
    MPCUT_TILETRAIL_PREFIX=$(cd "$MPCUT_TILETRAIL_PREFIX" && pwd)
    export MPCUT_TILETRAIL_PREFIX
    for file in include/tiletrail.h lib/libtiletrail.a LICENSE; do
        if [[ ! -f "$MPCUT_TILETRAIL_PREFIX/$file" ]]; then
            echo "TileTrail artifact is missing $file." >&2
            exit 1
        fi
    done
fi

"$root/scripts/build-ffmpeg.sh"
ffmpeg="$root/.build/mpcut-ffmpeg"
export MPCUT_BUNDLED_FFMPEG=1
swift_args=(--package-path "$root" --scratch-path "$root/.build/packaged" --configuration release)
swift_args+=(-Xcc "-I$ffmpeg/install/include" -Xlinker "-L$ffmpeg/install/lib" -Xlinker -lavformat)
swift_args+=(-Xlinker -rpath -Xlinker '@loader_path/../Frameworks')
xcrun swift build "${swift_args[@]}"
bin_dir=$(xcrun swift build "${swift_args[@]}" --show-bin-path)

staging=$(mktemp -d "$output_dir/.MPCut-stage.XXXXXX")
app="$staging/MPCut.app"
contents="$app/Contents"
previous="$staging/previous.app"
cleanup() {
    if [[ ( -e "$previous" || -L "$previous" ) && ! -e "$final" && ! -L "$final" ]]; then
        mv "$previous" "$final"
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
mkdir -p "$contents"/{Frameworks,Helpers,MacOS,Resources/FFmpeg}
install -m 755 "$bin_dir/MPCutDesktop" "$contents/MacOS/MPCut"
install -m 755 "$bin_dir/mpcut" "$contents/Helpers/mpcut"
# Strip the staged executables before signing, keeping SwiftPM's debug artifacts.
xcrun strip -S -x "$contents/MacOS/MPCut" "$contents/Helpers/mpcut"
version=$(DYLD_LIBRARY_PATH="$ffmpeg/install/lib" "$bin_dir/mpcut" --version)
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Expected a three-part MPCut release version, got $version." >&2
    exit 1
fi
"$root/scripts/build-mcp-helper.sh" "$contents" "$version"
install -m 755 "$ffmpeg/install/bin/ffmpeg" "$contents/Helpers/ffmpeg"
install -m 644 "$root/packaging/Info.plist" "$contents/Info.plist"
install -m 644 "$root/packaging/Credits.html" "$contents/Resources/Credits.html"
if [[ -n "${MPCUT_TILETRAIL_PREFIX:-}" ]]; then
    install -m 644 "$MPCUT_TILETRAIL_PREFIX/LICENSE" "$contents/Resources/TileTrail-LICENSE.txt"
fi
(cd "$root/packaging/premiere" && /usr/bin/zip -q -X "$contents/Resources/MPCut Premiere.ccx" manifest.json index.html index.js)
manual="$contents/Resources/Documentation"
mkdir -p "$manual/packaging"
# Finder metadata on screenshots is invalid inside a signed application bundle.
mkdir -p "$manual/docs"
/usr/bin/rsync -r --exclude='__pycache__/' --exclude='*.pyc' --exclude='.DS_Store' "$root/docs/" "$manual/docs/"
install -m 644 "$root/packaging/FFmpeg-Notice.txt" "$manual/packaging/"
mkdir -p "$manual/packaging/grok" "$manual/plugins/mpcut"
install -m 644 "$root/packaging/grok/Setup.md" "$manual/packaging/grok/"
/usr/bin/rsync -r --exclude='.DS_Store' "$root/plugins/mpcut/" "$manual/plugins/mpcut/"
install -m 644 "$root/README.md" "$root/CHANGELOG.md" "$root/AUDIT.md" "$manual/"
install -m 644 "$root/Sources/MPCutCore/Gap.png" "$contents/Resources/Gap.png"
install -m 644 "$root/Resources/MPCut.icns" "$contents/Resources/MPCut.icns"

for library in "$ffmpeg"/install/lib/*.dylib; do
    # Use only the names recorded in LC_ID_DYLIB and copy their actual contents.
    if [[ -L "$library" ]]; then
        continue
    fi
    install_name=$(xcrun otool -D "$library" | sed -n '2p')
    if [[ "$install_name" != @rpath/* ]]; then
        echo "Unexpected install name $install_name in $library." >&2
        exit 1
    fi
    install -m 755 "$library" "$contents/Frameworks/${install_name##*/}"
done

notices="$contents/Resources/FFmpeg"
install -m 644 "$root/packaging/FFmpeg-Notice.txt" "$notices/NOTICE.txt"
install -m 644 "$root/packaging/ffmpeg-require-hardware.patch" "$notices/changes.diff"
install -m 644 "$root/scripts/build-ffmpeg.sh" "$notices/build-ffmpeg.sh"
source_name=$(cat "$ffmpeg/install/ffmpeg-source-name")
svt_name=$(cat "$ffmpeg/install/svt-source-name")
install -m 644 "$ffmpeg/$source_name.tar.xz" "$notices/"
install -m 644 "$ffmpeg/install"/{COPYING.LGPLv2.1,LICENSE.md} "$notices/"
mkdir "$notices/SVT-AV1"
install -m 644 "$ffmpeg/install/SVT-AV1"/{LICENSE.md,LICENSE-BSD2.md,PATENTS.md,fastfeat-LICENSE,safestringlib-LICENSE} \
    "$ffmpeg/$svt_name.tar.bz2" "$notices/SVT-AV1/"
lame_name=$(cat "$ffmpeg/install/lame-source-name")
mkdir "$notices/LAME"
install -m 644 "$ffmpeg/install/LAME"/{COPYING,LICENSE} "$ffmpeg/$lame_name.tar.gz" "$notices/LAME/"
opus_name=$(cat "$ffmpeg/install/opus-source-name")
mkdir "$notices/Opus"
install -m 644 "$ffmpeg/install/Opus/COPYING" "$ffmpeg/$opus_name.tar.gz" "$notices/Opus/"

for binary in "$contents"/Frameworks/*.dylib "$contents"/Helpers/* "$contents/MacOS/MPCut"; do
    if [[ $(xcrun lipo -archs "$binary") != arm64 ]]; then
        echo "Expected an arm64 binary at $binary." >&2
        exit 1
    fi
    if ! xcrun vtool -show-build "$binary" | awk '
        $1 == "platform" && $2 == "MACOS" { macos = 1 }
        $1 == "minos" && $2 == "14.0" { minimum = 1 }
        END { exit !(macos && minimum) }
    '; then
        echo "Expected a macOS 14.0 deployment target in $binary." >&2
        exit 1
    fi
    # SwiftPM may add a search path into the active Swift toolchain.
    rpaths=$(xcrun otool -l "$binary" | sed -n '/cmd LC_RPATH/{n;n;s/^ *path \(.*\) (offset [0-9]*)$/\1/p;}')
    while IFS= read -r rpath; do
        case "$rpath" in
            "" | /usr/lib/swift | @loader_path | @loader_path/../Frameworks) ;;
            *) xcrun install_name_tool -delete_rpath "$rpath" "$binary" ;;
        esac
    done <<< "$rpaths"
    dependencies=$(xcrun otool -L "$binary" | sed -n '2,$s/^[[:space:]]*\(.*\) (compatibility version .*/\1/p')
    while IFS= read -r dependency; do
        case "$dependency" in
            /usr/lib/* | /System/Library/*) ;;
            @rpath/*)
                [[ -f "$contents/Frameworks/${dependency#@rpath/}" ]] && continue
                echo "Missing bundled library $dependency in $binary." >&2
                exit 1
                ;;
            *)
                echo "Unexpected library $dependency in $binary." >&2
                exit 1
                ;;
        esac
    done <<< "$dependencies"
    codesign --force --sign - --timestamp=none "$binary"
done

plutil -insert CFBundleShortVersionString -string "$version" "$contents/Info.plist"
plutil -insert CFBundleVersion -string "$version" "$contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$contents/Info.plist"
env -i PATH=/usr/bin:/bin "$contents/Helpers/mpcut" --help >/dev/null
env -i PATH=/usr/bin:/bin "$contents/Helpers/ffmpeg" -version >/dev/null
python3 "$root/scripts/mcp-reference.py" --check
# The bundle check uses assertions, which PYTHONOPTIMIZE would otherwise disable.
env -u PYTHONOPTIMIZE python3 "$root/Tests/Integration/mcp_bundle.py" "$app"

if [[ -e "$final" || -L "$final" ]]; then
    mv "$final" "$previous"
fi
mv "$app" "$final"
printf '%s\n' "$final"
