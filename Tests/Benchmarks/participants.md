# Participant scan and composition performance

The November 23, 2026 pass used an Apple M4 Max running macOS 27.0.1, FFmpeg 9.0.2 and the same TileTrail ABI v1 release library on both sides. All workloads used generated footage. The 1080p source repeats the annotated gallery from `Tests/Integration/participant_e2e_fixture.py` for 60 seconds at 30 fps, with H.264 video and no audio. CLI runs used `--no-sidecar`.

## Sparse scan

Sparse mode keeps decoding pictures so the scanner can account for timestamps, damage and scene changes. The previous path also mapped and converted each decoded picture to RGB before deciding whether TileTrail needed it. The frame tap now asks for pixels only after the sampling decision.

Two optimized native harness builds used the production MediaProbe decoder and RGB converter, the same TileTrail archive, and the same one-fifth-second sampling interval. The harness selects frames on the input's exact 1/15360 clock. It converts 1,800 pictures before the change and 300 after it, and pushes the same 300 observations into TileTrail. The harness compares complete TileTrail JSON across runs. It excludes Swift report assembly, sidecar I/O and startup probing.

| Metric | Before | After |
| --- | ---: | ---: |
| Median wall time | 51.45 s | 28.78 s |
| Median process CPU time | 2.68 s | 1.62 s |
| Median peak RSS | 46,448,640 bytes | 46,891,008 bytes |

Three alternating runs per build produced wall-time samples of 41.74, 51.45 and 53.92 seconds before, and 25.94, 28.78 and 42.42 seconds after. CPU time fell 40%. The host was running other builds, so the absolute wall times varied. Peak RSS varied by several MB within each build with no consistent directional change. JSON matched in all six runs.

An initial every-frame control increased median CPU time from 2.65 to 2.91 seconds when the new callback also ran for that mode. The final change uses preselection only in sparse mode. The every-frame control then matched JSON across three alternating pairs, with all 1,800 pictures converted and analyzed in both builds. Median wall time was 12.65 to 13.33 seconds, process CPU time was 2.31 to 2.37 seconds, and peak RSS was 50,282,496 to 50,741,248 bytes. CPU time rose in one pair and fell in two pairs.

## Scan report import

The strict JSON check runs after Foundation decodes an imported report. It detects duplicate keys and trailing commas. A Swift `-O` harness compared the old and new check on two complete reports from generated one-hour galleries. Both builds validated the same input bytes. The new reader borrows the input and decodes ordinary keys directly, reserving JSON string decoding for keys with escapes.

| Report | Process CPU time, before → after | Peak RSS, before → after |
| --- | ---: | ---: |
| 15,486,805 bytes, 3,600 observations, 57,600 regions | 0.73 → 0.13 s | 37,535,744 → 21,987,328 bytes |
| 76,023,435 bytes, 18,000 observations, 288,000 regions | 2.63 → 0.51 s | 158,613,504 → 82,526,208 bytes |

These measurements cover file loading and the strict JSON check alone. Running the full `participants project accept` CLI on the 76 MB report, including typed decoding, validation and project writing, reduced process CPU time from 7.08 to 5.20 seconds and peak RSS from 520,404,992 to 427,130,880 bytes across the two debug builds. After normalizing newly assigned UUIDs, both projects contained the same 16 roster entries, 1,454 appearance intervals and source coverage.

## Scan report output

The frozen TileTrail release candidate produced an 85,537,861-byte report for the one-hour sparse 30 fps gallery. A fresh process decoded that saved report into the production Swift model and wrote it with the original whole-report encoder. Peak RSS rose from 387,678,208 bytes after decoding to 1,005,387,776 bytes during output encoding. The production batched writer peaked at 389,988,352 bytes overall. Both outputs matched the saved report byte for byte. The writer uses Foundation's existing JSON encoding for each batch of up to 32 history rows and stages the document before publishing or writing stdout.

The original CLI reached 1,314,422,784 bytes peak RSS on the full `--no-sidecar` scan. An instrumented run with the same frozen archive, FFmpeg decoder and source measured peak RSS of 41,500,672 bytes after native scanning, 142,884,864 bytes through Rust JSON snapshot creation and analyzer release, and 676,102,144 bytes after decoding that snapshot onto the Swift source clock. The final linked CLI reached 794,542,080 bytes peak RSS through publication and stdout, a 39.6% reduction. Its file and stdout matched the original 85,537,861-byte report. Automatic sidecar serialization has its own memory costs. See the [one-hour scan measurements](participants-hour.md).

## Composition and export

The preflight fixture has 2,000 sequence occurrences and 2,000 timed output overrides. A baseline stack sample showed the overlap validator rescanning shots. Validation now checks adjacent intervals within each sorted clock and occurrence, and the timeline looks up intersecting intervals and active shots in those same scopes.

An isolated Swift `-O` comparison ran the production plan validator 20 times per process on a reversed list of 2,000 occurrence shots plus two adjacent global shots. Across three alternating runs per build, median measured validation time fell from 22.65 to 0.54 seconds under the same host contention. Median process CPU time fell from 0.74 to 0.03 seconds. Median peak RSS rose from 9,224,192 to 11,223,040 bytes. The serialized plans matched. Both versions accepted the adjacent ranges and overlap across scopes, and rejected a same-scope overlap.

The export fixture repeats four five-second source intervals for a 20-second, 600-frame output at 1280×720. Two pre-change debug exports under heavier host load took 18.07 and 21.93 seconds with peak RSS of 83,869,696 and 87,097,344 bytes. Composition spent most sampled writer-loop time in Core Image output rendering, with source reading and VideoToolbox decode also visible. This pass changes shot planning. The picture compositor and encoder used the same rendering paths in both builds.

## CLI verification

One pair of TileTrail-enabled debug builds exercised the public commands before the final every-frame callback adjustment. The newer build also contained contemporaneous project and privacy changes, and host load shifted during the comparison.

| Command and input | Before wall / peak RSS | After wall / peak RSS |
| --- | ---: | ---: |
| Sparse scan, five-second gallery | 1.01 s / 27,951,104 bytes | 0.95 s / 28,655,616 bytes |
| Sparse scan plus scene detection, same gallery | 0.62 s / 28,344,320 bytes | 0.50 s / 28,983,296 bytes |
| Every-frame scan, same gallery | 0.55 s / 28,442,624 bytes | 0.98 s / 28,884,992 bytes |
| Preflight, 2,000 timed occurrences | 16.21 s / 24,199,168 bytes | 1.54 s / 28,049,408 bytes |
| Render, 600 frames | 5.51 s / 86,900,736 bytes | 3.44 s / 92,962,816 bytes |

Scan results matched after accounting for unrelated schema changes that added the recording content hash, changed the analysis fingerprint, and serialized the existing false default for ambiguous identity. The combined scene report matched. Preflight and render reports matched after accounting for the distinct destination paths. Independent FFmpeg and ffprobe checks matched decoded frame checksums, presentation timestamps and sample durations for all 600 frames. The single render pair establishes output parity under varying load.

The targeted integration tests for scan, acceptance and seat-swap composition, and for repeated-source occurrence shots with one program mix passed. The focused native tests covered RGB frame data and timing, sparse frame selection, timed-shot boundaries and occurrence precedence.

The render geometry index previously retained the full selected appearance for each participant and camera-off policy at each geometry boundary. It now stores a change only when the selected appearance ID changes. A lookup resolves the held ID against the bounds at the requested source time.

An isolated Swift `-O` harness indexed a one-hour gallery with four visible participants. One box moved every second while each participant kept the same appearance ID. Each run built the production index three times and queried every participant at every second, totaling 43,200 lookups. Three alternating runs per version produced identical sums of the returned box positions. Median process peak RSS fell from 23,838,720 to 12,320,768 bytes, and median elapsed time inside the harness fell from 1.09 to 0.40 seconds. Wall times varied with other builds on the host. These figures cover geometry indexing and lookup, excluding media decoding, rendering and file I/O.

## Desktop monitor and scan approval

An isolated Swift `-O` harness queried 900 playhead positions in a 30-minute synthetic gallery. Sixteen tiles each carried a new geometry interval every second, for 28,800 intervals. It compared the previous linear filter with the monitor's indexed query using production rational times and appearance records. Timing includes index construction. Both implementations returned the same ordered appearance checksum for each workload.

| Median of three runs | Linear | Indexed |
| --- | ---: | ---: |
| 30 seconds of forward playback at 30 fps | 73.77 ms | 2.35 ms |
| 900 seeks throughout the recording | 96.03 ms | 6.11 ms |
| Forward playback process peak RSS | 15,220,736 bytes | 15,958,016 bytes |
| Seek workload process peak RSS | 15,220,736 bytes | 16,252,928 bytes |

The seek workload advanced by 7,919 frames modulo the recording's 54,000-frame length. Each lookup preserves project order for overlapping tiles. Measurements exclude decoding and SwiftUI drawing.

An isolated name-matching harness evaluated 250 source labels over 300 inspector updates. Repeating the comparison on each update took 231.86 ms median across three runs. Reusing the matches while the selected participant, indexed media and transcript revision stayed current took 2.64 ms. Both paths returned the same candidate on every update.

Scan approval can read the entire recording to verify a digest when the cache has no entry. A separate harness hashed a 256 MiB zero-filled file in 1 MiB reads and measured how long a queued main-actor task waited. Across three alternating runs the median delay fell from 358.75 ms to 0.20 ms when verification moved to a worker. All six digests matched. Median total hash-and-dispatch time was 359.24 ms on the main actor and 406.40 ms on the worker under concurrent build load.

## Reproduce the source

```sh
mkdir -p /tmp/mpcut-participant-gallery
PYTHONPATH=Tests/Integration python3 -c 'from pathlib import Path; from participant_e2e_fixture import generate; generate(Path("/tmp/mpcut-participant-gallery"))'
ffmpeg -hide_banner -loglevel error -nostdin -stream_loop 11 \
  -i /tmp/mpcut-participant-gallery/gallery.mov -an \
  -vf 'fps=30,scale=1920:1080:flags=neighbor' -t 60 -c:v libx264 \
  -preset ultrafast -threads 4 -pix_fmt yuv420p -colorspace bt709 \
  -color_primaries bt709 -color_trc bt709 /tmp/mpcut-participant-gallery/gallery-1080p.mov
/usr/bin/time -lp path/to/mpcut participants scan \
  --file /tmp/mpcut-participant-gallery/gallery-1080p.mov \
  --backend cpu-only --sampling sparse --no-sidecar --json
```
