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
    exec /usr/bin/lockf -k "$root/.build/.mpcut-app.lock" /bin/bash "$root/scripts/build-app.sh" "$output_dir"
fi

"$root/scripts/build-ffmpeg.sh"
ffmpeg="$root/.build/mpcut-ffmpeg"
export MPCUT_BUNDLED_FFMPEG=1
swift_args=(--package-path "$root" --scratch-path "$root/.build/packaged" --configuration release)
swift_args+=(-Xcc "-I$ffmpeg/install/include" -Xlinker "-L$ffmpeg/install/lib" -Xlinker -lavformat)
swift_args+=(-Xlinker -rpath -Xlinker '@loader_path/../Frameworks')
xcrun swift build "${swift_args[@]}" --product MPCutDesktop
xcrun swift build "${swift_args[@]}" --product mpcut
bin_dir=$(xcrun swift build "${swift_args[@]}" --show-bin-path)

staging=$(mktemp -d "$output_dir/.MPCut-stage.XXXXXX")
app="$staging/MPCut.app"
contents="$app/Contents"
final="$output_dir/MPCut.app"
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
install -m 755 "$ffmpeg/install/bin/ffmpeg" "$contents/Helpers/ffmpeg"
install -m 644 "$root/packaging/Info.plist" "$contents/Info.plist"
install -m 644 "$root/packaging/Credits.html" "$contents/Resources/Credits.html"
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
version=$("$contents/Helpers/mpcut" --version)
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Expected a three-part MPCut release version, got $version." >&2
    exit 1
fi
plutil -insert CFBundleShortVersionString -string "$version" "$contents/Info.plist"
plutil -insert CFBundleVersion -string "$version" "$contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$contents/Info.plist"
env -i PATH=/usr/bin:/bin "$contents/Helpers/mpcut" --help >/dev/null
env -i PATH=/usr/bin:/bin "$contents/Helpers/ffmpeg" -version >/dev/null

if [[ -e "$final" || -L "$final" ]]; then
    mv "$final" "$previous"
fi
mv "$app" "$final"
printf '%s\n' "$final"
