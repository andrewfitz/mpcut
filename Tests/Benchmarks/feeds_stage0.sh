#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
scratch="${1:-.build/feeds-stage0-bench}"
work=$(mktemp -d)
export BACKSTAGE_SESSION="mpcut-feeds-bench-$$"
trap 'backstage quit >/dev/null 2>&1 || true; rm -f -- "$work/gallery.mp4"; rmdir "$work"' EXIT

swift build --build-tests --configuration release --scratch-path "$scratch" -Xswiftc -enable-testing
products=$(swift build --show-bin-path --configuration release --scratch-path "$scratch" -Xswiftc -enable-testing)
ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i 'color=c=gray:s=160x90:r=1:d=7200' \
    -c:v libx264 -threads 2 -pix_fmt yuv420p "$work/gallery.mp4"

run() {
    local suite=$1 class=$2 result=$3 launch logfile log attempt
    launch=$(backstage launch "$(xcrun --find xctest)" --timeout 1 --env MPCUT_MUTED=1 \
        --env MPCUT_FEEDS_BENCH=1 --env "MPCUT_FEEDS_BENCH_MEDIA=$work/gallery.mp4" \
        --env "MPCUT_FEEDS_BENCH_SPAN_SECONDS=${MPCUT_FEEDS_BENCH_SPAN_SECONDS:-3}" \
        --env "MPCUT_FEEDS_BENCH_FORCE_CI=${MPCUT_FEEDS_BENCH_FORCE_CI:-0}" \
        -- -XCTest "$class" "$products/$suite.xctest") || { printf '%s\n' "$launch" >&2; return 1; }
    logfile=$(printf '%s\n' "$launch" | plutil -extract log raw -o - -)
    for ((attempt=0; attempt<300; attempt++)); do
        log=$(tail -n 100 "$logfile")
        if [[ "$log" == *"Test Suite 'Selected tests' failed"* ]]; then
            printf '%s\n' "$log" >&2
            return 1
        fi
        if [[ "$log" == *"Test Suite 'Selected tests' passed"* && "$log" == *"Executed 1 test, with 0 failures"* \
            && "$log" == *"$result"* ]]; then
            printf '%s\n' "$log"
            backstage quit >/dev/null 2>&1 || true
            return 0
        fi
        sleep 1
    done
    printf 'Timed out waiting for %s\n%s\n' "$class" "$log" >&2
    return 1
}

run MPCutCoreTests FeedsPictureBenchmarkTests "FEEDS_PICTURE 3840x2160 arib-std-b67"
run MPCutAppTests FeedsProjectBenchmarkTests "FEEDS_PROJECT feeds="
