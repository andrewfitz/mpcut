#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -m) != arm64 ]]; then
    echo "Build the MPCut FFmpeg libraries using a native arm64 shell." >&2
    exit 1
fi
build_dir="$root/.build/mpcut-ffmpeg"
source_name=ffmpeg-9.0.2
archive="$build_dir/$source_name.tar.xz"
digest=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
prefix="$build_dir/install"

mkdir -p "$build_dir"
if [[ ${MPCUT_FFMPEG_BUILD_LOCK:-} != "$build_dir" ]]; then
    # Keep the lock file in place so waiting processes use the same inode.
    export MPCUT_FFMPEG_BUILD_LOCK="$build_dir"
    exec /usr/bin/lockf -k "$build_dir/.lock" /bin/bash "$root/scripts/build-ffmpeg.sh"
fi
if [[ ! -f "$archive" ]]; then
    download=$(mktemp "$build_dir/.ffmpeg-download.XXXXXX")
    trap 'rm -f "$download"' EXIT
    curl --fail --location --silent --show-error --retry 3 \
        "https://ffmpeg.org/releases/$source_name.tar.xz" --output "$download"
    if ! printf '%s  %s\n' "$digest" "$download" | shasum -a 256 --check --status; then
        echo "Downloaded FFmpeg source does not match the pinned checksum." >&2
        exit 1
    fi
    mv -f "$download" "$archive"
fi
if ! printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 --check --status; then
    echo "Invalid FFmpeg source checksum at $archive" >&2
    exit 1
fi

# Only a successful install marks the recipe and its outputs valid.
hardware_patch="$root/packaging/ffmpeg-require-hardware.patch"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
compiler=$(xcrun --sdk macosx --find clang)
recipe=$(
    {
        shasum -a 256 "${BASH_SOURCE[0]}" "$hardware_patch"
        printf '%s\n' "$SDKROOT"
        xcrun --sdk macosx --show-sdk-build-version
        "$compiler" --version
    } | shasum -a 256 | cut -d ' ' -f 1
)
if [[ -f "$build_dir/.recipe" && $(cat "$build_dir/.recipe") == "$recipe" &&
      -f "$prefix/ffmpeg-source-name" &&
      -f "$prefix/COPYING.LGPLv2.1" && -f "$prefix/LICENSE.md" &&
      -f "$prefix/include/libavformat/avformat.h" &&
      -f "$prefix/include/libavcodec/avcodec.h" &&
      -f "$prefix/include/libavutil/avutil.h" &&
      -f "$prefix/include/libswresample/swresample.h" &&
      -f "$prefix/lib/libavformat.dylib" && -f "$prefix/lib/libavcodec.dylib" &&
      -f "$prefix/lib/libavutil.dylib" && -f "$prefix/lib/libswresample.dylib" ]]; then
    exit 0
fi
stage=$(mktemp -d "$build_dir/.stage.XXXXXX")
cleanup() {
    if [[ -d "$stage/previous-install" && ! -e "$prefix" ]]; then
        mv "$stage/previous-install" "$prefix"
    fi
    rm -rf "$stage"
}
trap cleanup EXIT
tar -xf "$archive" -C "$stage"
patch -d "$stage/$source_name" -p1 < "$hardware_patch"
mkdir "$stage/objects"

cd "$stage/objects"
# The FFmpeg configure script accepts a relative source link and otherwise
# rejects out-of-tree builds under paths containing spaces.
ln -s "../$source_name" src
src/configure \
    --prefix="$prefix" \
    --arch=aarch64 --cc="$compiler" \
    --sysroot="$SDKROOT" \
    --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0 \
    --install-name-dir=@rpath \
    --enable-shared --disable-static \
    --disable-autodetect --disable-programs --disable-doc --disable-debug \
    --disable-avdevice --disable-avfilter --disable-swscale \
    --disable-network --disable-encoders --enable-zlib --enable-bzlib \
    --enable-videotoolbox
make -j "$(/usr/sbin/sysctl -n hw.ncpu)" DESTDIR="$stage" install
cd "$build_dir"
install -m 644 "$stage/$source_name"/{COPYING.LGPLv2.1,LICENSE.md} "$stage$prefix/"
printf '%s\n' "$source_name" > "$stage$prefix/ffmpeg-source-name"
printf '%s\n' "$recipe" > "$stage/recipe"
if [[ -d "$prefix" ]]; then
    mv "$prefix" "$stage/previous-install"
fi
mv "$stage$prefix" "$prefix"
mv "$stage/recipe" "$build_dir/.recipe"
