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
svt_name=SVT-AV1-v4.3.0
svt_archive="$build_dir/$svt_name.tar.bz2"
svt_digest=9223ce06e6172ad41357ed23b3b00f036e03794b86b0e20ea9ccb3f648b8955d
prefix="$build_dir/install"

mkdir -p "$build_dir"
if [[ ${MPCUT_FFMPEG_BUILD_LOCK:-} != "$build_dir" ]]; then
    # Keep the lock file in place so waiting processes use the same inode.
    export MPCUT_FFMPEG_BUILD_LOCK="$build_dir"
    exec /usr/bin/lockf -k "$build_dir/.lock" /bin/bash "$root/scripts/build-ffmpeg.sh"
fi
fetch_source() (
    file=$1 expected=$2 url=$3
    if [[ ! -f "$file" ]]; then
        download=$(mktemp "$build_dir/.source-download.XXXXXX")
        trap 'rm -f "$download"' EXIT
        curl --fail --location --silent --show-error --retry 3 "$url" --output "$download"
        if ! printf '%s  %s\n' "$expected" "$download" | shasum -a 256 --check --status; then
            echo "Invalid checksum for downloaded source ${file##*/}." >&2
            exit 1
        fi
        mv "$download" "$file"
    elif ! printf '%s  %s\n' "$expected" "$file" | shasum -a 256 --check --status; then
        echo "Invalid source checksum at $file." >&2
        exit 1
    fi
)
fetch_source "$archive" "$digest" "https://ffmpeg.org/releases/$source_name.tar.xz"
fetch_source "$svt_archive" "$svt_digest" "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.3.0/$svt_name.tar.bz2"

# Only a successful install marks the recipe and its outputs valid.
hardware_patch="$root/packaging/ffmpeg-require-hardware.patch"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
compiler=$(xcrun --sdk macosx --find clang)
for required_tool in cmake pkg-config; do
    if ! command -v "$required_tool" >/dev/null; then
        echo "Install CMake and pkg-config to build the bundled media libraries." >&2
        exit 1
    fi
done
recipe=$(
    {
        shasum -a 256 "${BASH_SOURCE[0]}" "$hardware_patch"
        printf '%s\n' "$SDKROOT"
        xcrun --sdk macosx --show-sdk-build-version
        "$compiler" --version
        cmake --version
        pkg-config --version
    } | shasum -a 256 | cut -d ' ' -f 1
)
if [[ -f "$build_dir/.recipe" && $(cat "$build_dir/.recipe") == "$recipe" &&
      -f "$prefix/ffmpeg-source-name" && -f "$prefix/svt-source-name" &&
      -f "$prefix/SVT-AV1/LICENSE.md" && -f "$prefix/SVT-AV1/PATENTS.md" &&
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
tar -xf "$svt_archive" -C "$stage"
jobs=$(/usr/sbin/sysctl -n hw.ncpu)
cmake -S "$stage/$svt_name" -B "$stage/svt-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$compiler" \
    -DCMAKE_OSX_SYSROOT="$SDKROOT" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$stage/svt" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DEXCLUDE_HASH=ON
cmake --build "$stage/svt-build" --parallel "$jobs"
cmake --install "$stage/svt-build"
mkdir "$stage/objects"

cd "$stage/objects"
# The FFmpeg configure script accepts a relative source link and otherwise
# rejects out-of-tree builds under paths containing spaces.
ln -s "../$source_name" src
ln -s ../svt svt
# FFmpeg expands pkg-config flags as shell words. Keep dependency paths
# relative so that configure and make also work in a checkout with spaces.
sed -i '' 's|^prefix=.*|prefix=./svt|' svt/lib/pkgconfig/SvtAv1Enc.pc
export PKG_CONFIG_LIBDIR=./svt/lib/pkgconfig
export PKG_CONFIG_PATH=
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
    --enable-videotoolbox --enable-libsvtav1 --pkg-config-flags=--static \
    --enable-encoder=h264_videotoolbox,hevc_videotoolbox,libsvtav1
make -j "$jobs" DESTDIR="$stage" install
cd "$build_dir"
install -m 644 "$stage/$source_name"/{COPYING.LGPLv2.1,LICENSE.md} "$stage$prefix/"
mkdir -p "$stage$prefix/SVT-AV1"
install -m 644 "$stage/$svt_name"/{LICENSE.md,LICENSE-BSD2.md,PATENTS.md} "$stage$prefix/SVT-AV1/"
install -m 644 "$stage/$svt_name/third_party/fastfeat/LICENSE" "$stage$prefix/SVT-AV1/fastfeat-LICENSE"
install -m 644 "$stage/$svt_name/third_party/safestringlib/LICENSE" "$stage$prefix/SVT-AV1/safestringlib-LICENSE"
printf '%s\n' "$svt_name" > "$stage$prefix/svt-source-name"
printf '%s\n' "$source_name" > "$stage$prefix/ffmpeg-source-name"
printf '%s\n' "$recipe" > "$stage/recipe"
if [[ -d "$prefix" ]]; then
    mv "$prefix" "$stage/previous-install"
fi
mv "$stage$prefix" "$prefix"
mv "$stage/recipe" "$build_dir/.recipe"
