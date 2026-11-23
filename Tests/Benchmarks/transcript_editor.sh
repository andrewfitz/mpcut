#!/bin/bash
# Link the archive benchmark against the release objects produced by scripts/build-app.sh.
set -euo pipefail
if (( $# < 1 || $# > 2 )); then
    echo "Usage: $0 OUTPUT_EXECUTABLE [RELEASE_CHECKOUT]" >&2
    exit 2
fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
checkout=$(cd "${2:-$root}" && pwd)
release="$checkout/.build/packaged/release"
maps="$checkout/.build/packaged/out/Intermediates.noindex/GeneratedModuleMaps"
ffmpeg="$checkout/.build/mpcut-ffmpeg/install"

# SwiftPM's Xcode build uses the checkout directory for the Swift package name.
package_name=$(basename "$checkout" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]/_/g')

xcrun swiftc -O -package-name "$package_name" -I "$release" \
    -Xcc "-fmodule-map-file=$maps/MediaProbe.modulemap" \
    -Xcc "-fmodule-map-file=$maps/FFPreview.modulemap" \
    -Xcc "-fmodule-map-file=$maps/PacketWriter.modulemap" \
    -Xcc "-fmodule-map-file=$checkout/Sources/CFFmpeg/module.modulemap" \
    -Xcc "-I$ffmpeg/include" \
    "$root/Tests/Benchmarks/transcript_editor.swift" \
    "$release/MPCutCore.o" "$release/MediaProbe.o" "$release/PacketWriter.o" "$release/FFPreview.o" \
    -L "$ffmpeg/lib" -lavformat -lavcodec -lavutil -lswscale -lswresample -lsqlite3 \
    -framework Accelerate -framework VideoToolbox \
    -Xlinker -rpath -Xlinker "$ffmpeg/lib" -o "$1"
