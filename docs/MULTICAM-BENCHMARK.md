# Multicam benchmark

The fixture contains four 320 × 180 H.264 cameras at 25 fps and one 48 kHz, mono, 16-bit PCM WAV. Each camera has a distinct hue and a closed GOP every second. The default camera and audio files each cover 180 seconds. The project has 20 angle changes plus the opening selection. The assembly plays group time 84–180 seconds, then 0–84 seconds, retaining every camera change. The master runs continuously through the camera changes and jumps once at the assembly edit. These inputs keep the benchmark small and exercise lossless joins. High-resolution footage and Smart Trim edge encoding can have different costs.

## Reproduce on macOS

Build the CLI and XCTest targets from the same checkout. Python 3, FFmpeg with libx264, and FFprobe must be available.

```sh
swift build
fixture_dir=$(mktemp -d /tmp/mpcut-multicam.XXXXXX)
python3 Tests/Benchmarks/multicam.py .build/debug/mpcut --fixture-dir "$fixture_dir"
MPCUT_MULTICAM_BENCHMARK_PROJECT="$fixture_dir/benchmark.cut" \
  swift test --filter MulticamPerformanceTests/testPreviewPerformance
```

Without `--fixture-dir`, the CLI benchmark uses temporary assets. To generate the project separately, run `python3 Tests/Benchmarks/multicam.py --fixture-only --fixture-dir "$fixture_dir"`. Then pass `--project "$fixture_dir/benchmark.cut"` to run the CLI benchmark on those files. The CLI benchmark requires the source directory to have no saved indexes before it runs and removes its own indexes after the run.

The first uncached measurement includes CLI startup and index discovery. The script runs five more preflights without sidecars, saves the five source indexes, and runs five preflights with sidecars. All six uncached preflights use `--no-sidecar`, and the harness checks that no index was written before timing index creation. The operating system’s file cache is left in its normal state. The harness measures CLI wall time and obtains peak resident memory from macOS `wait4`. Fixture generation, index creation, export, and output verification are timed separately or excluded from preflight. The script checks that both cache conditions produce identical dry-run JSON and that the eventual export uses the same plan.

Independent FFprobe packet hashes and presentation timestamps verify picture identity, switch order, and absence of output clock drift. A full FFmpeg decode compares every output PCM sample with the independently sliced source WAV. The CLI plan’s picture and audio spans must also agree with the fixture. The JPEG check decodes each image and compares its pixels with the source frame, allowing for JPEG compression and color conversion.

The optional desktop test attaches the production preview to an offscreen AppKit surface. It records elapsed time from a paused seek or alternate-angle audition request to frame submission. During playback it records the output clock’s lag past each scheduled picture join when the incoming frame is first submitted. It counts distinct frame submissions in a three-second continuous interval on the default fixture. It also times 20 filmstrip thumbnail requests across four rows, then repeats the same requests to exercise the in-memory cache. It reads the XCTest process’s peak resident size, which includes the harness, indexes, attached surface, and audio renderer. It does not measure WindowServer presentation, physical display latency, sustained playback under a visible filmstrip workload, or multiple simultaneously decoding live views.

## CLI results

Measured with a Swift debug build on an Apple M4 Max running macOS 27.0.1 during concurrent build and test activity. The table reports the median wall time for the two five-run conditions and their maximum peak RSS.

| Operation | Wall time | Peak RSS |
| --- | ---: | ---: |
| First preflight without sidecars | 0.11 s | 21.4 MiB |
| Preflight without sidecars | 0.14 s | 21.8 MiB |
| Preflight with sidecars | 0.07 s | 19.8 MiB |
| Copy export with sidecars | 3.53 s | 61.7 MiB |
| Aligned JPEG review with sidecars | 0.93 s | 50.1 MiB |

The four camera indexes took 0.07–0.24 seconds each to save. The WAV index took 0.06 seconds. All 4,500 compressed picture packets matched their mapped input, every picture PTS matched the exact 25 fps output grid, and all 8,640,000 decoded PCM samples matched. The review command produced 20 JPEGs, selecting the containing frame for all five requested group times in all four angles.

## Desktop results

The debug XCTest bundle ran on the same Mac with saved source indexes and no concurrent build or integration suite. The 21 scheduled joins include the 20 angle changes and one assembly jump.

| Operation | Samples | Median | Maximum |
| --- | ---: | ---: | ---: |
| Paused seek to an indexed picture | 22 | 6.27 ms | 11.48 ms |
| Paused alternate-angle audition | 4 | 7.37 ms | 11.36 ms |
| Scheduled join to incoming picture submission | 21 | 7.52 ms | 12.82 ms |

The preview submitted all 75 expected pictures in the three-second steady-playback sample. Peak XCTest RSS was 78.3 MiB.

The 20 sequential 80 × 45 thumbnail requests (five per camera) took 188.58 ms with an empty thumbnail cache. Repeating the batch took 0.26 ms from memory. Both passes disabled thumbnail sidecar I/O. The timeline can concurrently decode tiles in separate visible camera rows.

## Large multicam filmstrips

This XCTest uses the production thumbnail service to request six times spread across the shortest recording in a four-angle set. Each request targets a 486 × 274 backing-pixel tile. The parallel pass starts one task per camera. The sequential pass uses a fresh service and submits one request at a time. A warm pass repeats the parallel pass's requests against its in-memory cache. Timing excludes the initial media header probes and window presentation. The test disables sidecar reuse and leaves the operating system's file cache in its normal state.

```sh
camera_dir=$(mktemp -d /tmp/mpcut-camera-filmstrips.XXXXXX)
for angle in 1 2 3 4; do
  ffmpeg -hide_banner -loglevel error \
    -f lavfi -i 'testsrc2=size=1920x1080:rate=30' \
    -vf "hue=h=$((angle * 45))" -t 12 -c:v libx264 -preset ultrafast \
    -g 60 -pix_fmt yuv420p "$camera_dir/angle-$angle.mp4"
done
MPCUT_THUMBNAIL_BENCHMARK_MEDIA="$camera_dir" \
  swift test --filter MulticamThumbnailAuditTests/testFourLargeFilmstripsRenderConcurrentRequests
```

An Apple M4 Max running macOS 27.0.1 rendered all 24 tiles from four 2.5-hour 1920 × 1080 H.264 camera recordings. The Debug XCTest run took 800 ms for concurrent rendering, 1,801 ms for sequential rendering, and 1.01 ms for warm lookups. A separate probe confirmed that VideoToolbox could decode a picture in hardware from all four recordings. Timings varied with competing disk and indexing activity. Timing covers thumbnail requests from submission through return to the caller.

## Mixed-session startup

This opt-in XCTest benchmarks the production project and preview models. It creates four regular sessions and four distinct saved multicam projects. All eight sessions use the same 90-second, 1280 × 720 H.264/AAC recording. Each multicam project uses a one-second range from that recording, one angle, and no master audio. Analysis sidecars are disabled, and the operating system’s file cache remains in its normal state.

```sh
startup_dir=$(mktemp -d /tmp/mpcut-startup.XXXXXX)
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=1280x720:rate=30' \
  -f lavfi -i 'sine=frequency=500:sample_rate=48000' \
  -t 90 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac \
  "$startup_dir/camera.mp4"
MPCUT_PROJECT_STARTUP_SESSIONS=4 MPCUT_PROJECT_STARTUP_SOURCE="$startup_dir/camera.mp4" \
  swift test --filter MulticamPerformanceTests/testProjectSessionStartupPerformance
```

To use the pinned FFmpeg build for the test, run `scripts/build-ffmpeg.sh`, then pass its headers and libraries to SwiftPM.

```sh
ffmpeg_install="$PWD/.build/mpcut-ffmpeg/install"
MPCUT_BUNDLED_FFMPEG=1 MPCUT_PROJECT_STARTUP_SESSIONS=4 \
  MPCUT_PROJECT_STARTUP_SOURCE="$startup_dir/camera.mp4" \
  swift test -Xcc "-I$ffmpeg_install/include" -Xlinker "-L$ffmpeg_install/lib" \
  -Xlinker -lavformat -Xlinker -rpath -Xlinker "$ffmpeg_install/lib" \
  --filter MulticamPerformanceTests/testProjectSessionStartupPerformance
```

The test skips by default. Set `MPCUT_PROJECT_STARTUP_SESSIONS` to a value from 1 to 32 to select the number of sessions of each kind. When no source path is given, the test uses the package’s short ProRes fixture. It prints one `MPCUT_PROJECT_STARTUP_BENCHMARK` JSON record per run.

The A/B run used two copies of the same source snapshot on an Apple M4 Max running macOS 27.0.1. The eager baseline created a regular `AVPlayer` and registered the multicam audio renderer and synchronizer during preview initialization. The deferred version created the regular player when a native audio composition was ready and the multicam renderer and synchronizer when forward playback began. Both copies used the same test and FFmpeg libraries. The Debug XCTest process started fresh on every run, alternating eager and deferred builds for three runs each.

| Measurement | Eager audio resources | Deferred audio resources |
| --- | ---: | ---: |
| Construct all eight sessions | 64.05 ms | 11.51 ms |
| Start construction to regular edit readiness | 96.38 ms | 43.47 ms |
| Start construction to multicam edit readiness | 86.38 ms | 38.40 ms |
| Start construction to first multicam picture | 163.14 ms | 116.53 ms |
| Peak XCTest process RSS | 68.78 MB | 67.91 MB |
| XCTest process CPU over one settled idle second | 0.73 ms | 0.78 ms |

Each column reports the median across process launches. The three opening milestones add session construction time to the median per-editor time measured from when the batch begins opening. Regular readiness marks import completion. Multicam edit readiness marks publication of a complete source index, and first picture marks the first decoded picture published by the preview model. These timings exclude AppKit window creation, WindowServer presentation, and display latency. Peak RSS includes the test harness and decoded frames. The idle CPU measurement starts one second after all sessions reach the measured milestones. This run measures opening and settling with previews parked. First-play latency and multicam projects with several long recordings remain outside its scope.
