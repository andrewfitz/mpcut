#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -m) != arm64 ]]; then
    echo "Build the MPCut FFmpeg helper and libraries using a native arm64 shell." >&2
    exit 1
fi
build_dir="$root/.build/mpcut-ffmpeg"
source_name=ffmpeg-9.0.2
archive="$build_dir/$source_name.tar.xz"
digest=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
svt_name=SVT-AV1-v4.3.0
svt_archive="$build_dir/$svt_name.tar.bz2"
svt_digest=9223ce06e6172ad41357ed23b3b00f036e03794b86b0e20ea9ccb3f648b8955d
lame_name=lame-3.100
lame_archive="$build_dir/$lame_name.tar.gz"
lame_digest=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
opus_name=opus-1.6.1
opus_archive="$build_dir/$opus_name.tar.gz"
opus_digest=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
prefix="$build_dir/install"

mkdir -p "$build_dir"
if [[ ${MPCUT_FFMPEG_BUILD_LOCK:-} != "$build_dir" ]]; then
    # Keep the lock file in place so waiting processes use the same inode.
    export MPCUT_FFMPEG_BUILD_LOCK="$build_dir"
    exec /usr/bin/lockf -k "$build_dir/.lock" /bin/bash "$root/scripts/build-ffmpeg.sh"
fi
# A build that was killed outright never ran its exit handlers. This build holds
# the lock, so any stage folder or partial download found here is abandoned.
# Put back an install that was moved aside for replacement, then remove them.
if [[ -n "$build_dir" && -d "$build_dir" ]]; then
    for stale in "$build_dir"/.stage.??????; do
        if [[ ! -d "$stale" || -L "$stale" ]]; then
            continue
        fi
        if [[ -d "$stale/previous-install" && ! -e "$prefix" ]]; then
            mv "$stale/previous-install" "$prefix"
        fi
        rm -rf "$stale"
    done
    for stale in "$build_dir"/.source-download.??????; do
        if [[ -f "$stale" && ! -L "$stale" ]]; then
            rm -f "$stale"
        fi
    done
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
fetch_source "$lame_archive" "$lame_digest" "https://downloads.sourceforge.net/project/lame/lame/3.100/$lame_name.tar.gz"
fetch_source "$opus_archive" "$opus_digest" "https://downloads.xiph.org/releases/opus/$opus_name.tar.gz"

# Only a successful install marks the recipe and its outputs valid.
hardware_patch="$root/packaging/ffmpeg-require-hardware.patch"
# Assign before exporting: `export NAME=$(command)` reports the status of export.
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
export SDKROOT
compiler=$(xcrun --sdk macosx --find clang)
for required_tool in cmake pkg-config; do
    if ! command -v "$required_tool" >/dev/null; then
        echo "Install CMake and pkg-config to build the bundled media libraries." >&2
        exit 1
    fi
done
# Collect each input first so that a failing tool stops the build instead of
# contributing nothing to the recipe hash.
recipe_files=$(shasum -a 256 "${BASH_SOURCE[0]}" "$hardware_patch")
sdk_build=$(xcrun --sdk macosx --show-sdk-build-version)
compiler_version=$("$compiler" --version)
cmake_version=$(cmake --version)
pkg_config_version=$(pkg-config --version)
recipe=$(
    printf '%s\n' "$recipe_files" "$SDKROOT" "$sdk_build" "$compiler_version" \
        "$cmake_version" "$pkg_config_version" | shasum -a 256 | cut -d ' ' -f 1
)
if [[ -f "$build_dir/.recipe" && $(cat "$build_dir/.recipe") == "$recipe" &&
      -f "$prefix/ffmpeg-source-name" && -f "$prefix/svt-source-name" &&
      -f "$prefix/SVT-AV1/LICENSE.md" && -f "$prefix/SVT-AV1/PATENTS.md" &&
      -f "$prefix/SVT-AV1/LICENSE-BSD2.md" && -f "$prefix/SVT-AV1/fastfeat-LICENSE" &&
      -f "$prefix/SVT-AV1/safestringlib-LICENSE" && -f "$prefix/include/libswscale/swscale.h" &&
      -f "$prefix/lame-source-name" && -f "$prefix/LAME/COPYING" && -f "$prefix/LAME/LICENSE" &&
      -f "$prefix/opus-source-name" && -f "$prefix/Opus/COPYING" &&
      -f "$prefix/COPYING.LGPLv2.1" && -f "$prefix/LICENSE.md" &&
      -f "$prefix/include/libavformat/avformat.h" &&
      -f "$prefix/include/libavcodec/avcodec.h" &&
      -f "$prefix/include/libavutil/avutil.h" &&
      -f "$prefix/include/libswresample/swresample.h" &&
      -x "$prefix/bin/ffmpeg" &&
      -f "$prefix/lib/libavdevice.dylib" && -f "$prefix/lib/libavfilter.dylib" &&
      -f "$prefix/lib/libswscale.dylib" &&
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
# LAME supplies the MP3 encoder as a static library inside libavcodec. Build it in
# its own tree and copy the two products, so no absolute path reaches libtool.
tar -xf "$lame_archive" -C "$stage"
(
    cd "$stage/$lame_name"
    ./configure --host=aarch64-apple-darwin --build=aarch64-apple-darwin CC="$compiler" \
        CFLAGS="-O3 -arch arm64 -isysroot $SDKROOT -mmacosx-version-min=14.0" \
        --disable-shared --enable-static --with-pic \
        --disable-frontend --disable-decoder --disable-gtktest --disable-dependency-tracking
    make -j "$jobs" -C mpglib
    make -j "$jobs" -C libmp3lame
)
mkdir -p "$stage/lame/include/lame" "$stage/lame/lib"
install -m 644 "$stage/$lame_name/include/lame.h" "$stage/lame/include/lame/"
install -m 644 "$stage/$lame_name/libmp3lame/.libs/libmp3lame.a" "$stage/lame/lib/"
# libopus supplies the Opus encoder as a static library inside libavcodec too.
# FFmpeg accepts it only through pkg-config, so its opus.pc is copied as well.
tar -xf "$opus_archive" -C "$stage"
(
    cd "$stage/$opus_name"
    ./configure --host=aarch64-apple-darwin --build=aarch64-apple-darwin CC="$compiler" \
        CFLAGS="-O3 -arch arm64 -isysroot $SDKROOT -mmacosx-version-min=14.0" \
        --disable-shared --enable-static --with-pic \
        --disable-extra-programs --disable-doc --disable-dependency-tracking
    make -j "$jobs"
)
mkdir -p "$stage/opus/include/opus" "$stage/opus/lib/pkgconfig"
install -m 644 "$stage/$opus_name"/include/opus*.h "$stage/opus/include/opus/"
install -m 644 "$stage/$opus_name/.libs/libopus.a" "$stage/opus/lib/"
install -m 644 "$stage/$opus_name/opus.pc" "$stage/opus/lib/pkgconfig/"
mkdir "$stage/objects"

cd "$stage/objects"
# The FFmpeg configure script accepts a relative source link and otherwise
# rejects out-of-tree builds under paths containing spaces.
ln -s "../$source_name" src
ln -s ../svt svt
ln -s ../lame lame
ln -s ../opus opus
# FFmpeg expands pkg-config flags as shell words. Keep dependency paths
# relative so that configure and make also work in a checkout with spaces.
sed -i '' 's|^prefix=.*|prefix=./svt|' svt/lib/pkgconfig/SvtAv1Enc.pc
sed -i '' 's|^prefix=.*|prefix=./opus|' opus/lib/pkgconfig/opus.pc
export PKG_CONFIG_LIBDIR=./svt/lib/pkgconfig:./opus/lib/pkgconfig
export PKG_CONFIG_PATH=
# The text subtitle encoders let Re-encode convert cues where the output container needs another codec. Configure names
# components after their allcodecs.c symbols, so the mov_text encoder is `movtext`; an unmatched name is only a warning.
src/configure \
    --prefix="$prefix" \
    --arch=aarch64 --cc="$compiler" \
    --sysroot="$SDKROOT" \
    --extra-cflags="-mmacosx-version-min=14.0 -I./lame/include" \
    --extra-ldflags="-mmacosx-version-min=14.0 -L./lame/lib" \
    --extra-ldexeflags="-Wl,-rpath,@loader_path/../lib -Wl,-rpath,@loader_path/../Frameworks" \
    --install-name-dir=@rpath \
    --enable-shared --disable-static \
    --disable-autodetect --disable-ffplay --disable-ffprobe --disable-doc --disable-debug \
    --disable-indevs --disable-outdevs --enable-indev=lavfi \
    --disable-network --disable-encoders --enable-zlib --enable-bzlib \
    --enable-videotoolbox --enable-libsvtav1 --enable-libmp3lame --pkg-config-flags=--static \
    --enable-libopus --disable-decoder=libopus \
    --enable-encoder=h264_videotoolbox,hevc_videotoolbox,prores_videotoolbox,libsvtav1,mjpeg,aac,alac,libmp3lame,flac,libopus,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,wrapped_avframe,rawvideo \
    --enable-encoder=movtext,srt,subrip,ass,ssa,webvtt
make -j "$jobs" DESTDIR="$stage" install
# Configure only warns about an encoder name it does not know, so a renamed component would ship without its encoder
# and an export would fall back or fail later. Refuse the build unless every requested encoder is present.
available=$("$stage$prefix/bin/ffmpeg" -hide_banner -encoders)
for encoder in h264_videotoolbox hevc_videotoolbox prores_videotoolbox libsvtav1 mjpeg aac alac libmp3lame flac libopus \
    pcm_s16le pcm_s24le pcm_s32le pcm_f32le pcm_f64le wrapped_avframe rawvideo mov_text srt subrip ass ssa webvtt; do
    if ! grep -Eq "^ [A-Z.]{6} $encoder( |$)" <<< "$available"; then
        echo "error: the FFmpeg build has no $encoder encoder" >&2
        exit 1
    fi
done
cd "$build_dir"
install -m 644 "$stage/$source_name"/{COPYING.LGPLv2.1,LICENSE.md} "$stage$prefix/"
mkdir -p "$stage$prefix/SVT-AV1"
install -m 644 "$stage/$svt_name"/{LICENSE.md,LICENSE-BSD2.md,PATENTS.md} "$stage$prefix/SVT-AV1/"
install -m 644 "$stage/$svt_name/third_party/fastfeat/LICENSE" "$stage$prefix/SVT-AV1/fastfeat-LICENSE"
install -m 644 "$stage/$svt_name/third_party/safestringlib/LICENSE" "$stage$prefix/SVT-AV1/safestringlib-LICENSE"
mkdir -p "$stage$prefix/LAME"
install -m 644 "$stage/$lame_name"/{COPYING,LICENSE} "$stage$prefix/LAME/"
mkdir -p "$stage$prefix/Opus"
install -m 644 "$stage/$opus_name/COPYING" "$stage$prefix/Opus/"
printf '%s\n' "$opus_name" > "$stage$prefix/opus-source-name"
printf '%s\n' "$lame_name" > "$stage$prefix/lame-source-name"
printf '%s\n' "$svt_name" > "$stage$prefix/svt-source-name"
printf '%s\n' "$source_name" > "$stage$prefix/ffmpeg-source-name"
printf '%s\n' "$recipe" > "$stage/recipe"
if [[ -d "$prefix" ]]; then
    mv "$prefix" "$stage/previous-install"
fi
mv "$stage$prefix" "$prefix"
mv "$stage/recipe" "$build_dir/.recipe"
