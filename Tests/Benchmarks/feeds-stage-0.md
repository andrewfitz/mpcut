# Tiles stage 0 benchmarks

Run `Tests/Benchmarks/feeds_stage0.sh` on macOS with FFmpeg and Backstage installed. Pass a scratch directory as the optional first argument. The runner builds optimized XCTest hosts, generates its own source movie, and runs the selected tests muted on Backstage.

## Dense gallery composition

The picture prototype takes a tagged pixel buffer at 1920 × 1080 or 3840 × 2160, applies the production Core Image treatment to 40 tile boxes and 40 nameplate boxes, crops eight pixels from each edge and fills an output buffer of the original size. The synthetic input has contrasting checkerboard squares and a bright strip outside the treated boxes. The test warms up for ten frames and times 60 frames per resolution and transfer, reusing the input and output allocations. A CPU read of the output synchronizes with the GPU. The measurement covers graph construction, GPU execution and the readback fence. Media decode, editor scheduling and display submission are outside this measurement.

The original Core Image blur and the new shared Metal blur both passed in optimized, isolated compositor XCTest builds, run muted in Backstage on an Apple M4 Max with macOS 27.0.1. Set `MPCUT_FEEDS_BENCH_FORCE_CI=1` to repeat the measurement with Core Image.

| Raster | Transfer | Core Image median | Core Image p95 | Metal median | Metal p95 |
| --- | --- | ---: | ---: | ---: | ---: |
| 1920 × 1080 | SDR | 16.72 ms | 18.11 ms | 3.02 ms | 3.73 ms |
| 1920 × 1080 | PQ | 16.73 ms | 19.15 ms | 3.07 ms | 3.46 ms |
| 1920 × 1080 | HLG | 16.48 ms | 18.35 ms | 3.00 ms | 3.34 ms |
| 3840 × 2160 | SDR | 32.64 ms | 41.58 ms | 7.86 ms | 8.49 ms |
| 3840 × 2160 | PQ | 30.07 ms | 34.19 ms | 7.87 ms | 8.56 ms |
| 3840 × 2160 | HLG | 28.55 ms | 33.10 ms | 7.52 ms | 8.33 ms |

At 4K, Core Image exceeded the 33.3 ms allowance for a 30 fps frame in the SDR and PQ 95th percentiles. With Metal the 95th percentile stayed below 9 ms for all three transfers. A separate Core Image run during heavier builds recorded medians of 133–301 ms across the six cases. The viewer can discard outdated requests to prevent them from queueing indefinitely.

The Metal compositor retains one immutable region layout for up to 1 MiB of GPU buffers. Its cache key includes the source extent and ordered rectangles so the same geometry can serve consecutive frames while changes in overlap precedence take effect immediately. A standalone optimized CPU microbenchmark cycled through 11 translated 80-region layouts at each raster. Both implementations produced identical bucket offsets, counts and ordered indices on every layout. Average CPU construction time fell from 109.0 µs to 15.7 µs at 1080p and from 392.0 µs to 27.8 µs at 4K over 2,200 calls per case. These samples exclude GPU buffer allocation and cache hits, and other builds were running.

An optimized standalone Metal comparison used the same fixed gallery, crop, output renders and warm-up as the compositor prototype. SHA-256 hashes of the active pixel rows matched for all six cases. Both kernels passed the checks for edge sampling, overlap order and reuse of the same rectangles on a new source image. A separate translucent fixture also produced an identical RGBA8 hash, retaining multiple alpha values and matching the input alpha outside the treated regions.

| Raster | Transfer | Uncached median / p95 | Cached median / p95 |
| --- | --- | ---: | ---: |
| 1920 × 1080 | SDR | 3.02 / 3.22 ms | 2.73 / 2.89 ms |
| 1920 × 1080 | PQ | 2.96 / 3.21 ms | 2.63 / 2.87 ms |
| 1920 × 1080 | HLG | 2.94 / 3.12 ms | 2.61 / 2.72 ms |
| 3840 × 2160 | SDR | 7.52 / 8.36 ms | 7.20 / 7.86 ms |
| 3840 × 2160 | PQ | 7.38 / 7.76 ms | 7.21 / 7.83 ms |
| 3840 × 2160 | HLG | 7.57 / 8.98 ms | 7.27 / 7.95 ms |

### Batched Metal dispatch and in-place composition

In the 80-region gallery, Metal now issues three dispatches over the packed blur atlas and one over the output. The previous compositor issued 241 dispatches. An immutable row table maps each atlas texel to its region. Once the atlas contains the blurred samples, the final kernel updates covered pixels in the frame's private linear RGBA16F texture, saving a second full-frame texture and its copy of the uncovered pixels. The decoded input remains available to other consumers.

The same optimized, display-free harness ran three interleaved trials per version on an Apple M4 Max. Each cell lists the median across trials of the 60-frame median and p95, after ten warm-up frames.

| Raster | Transfer | Previous median / p95 | Batched in-place median / p95 |
| --- | --- | ---: | ---: |
| 1920 × 1080 | SDR | 3.04 / 3.52 ms | 1.74 / 2.45 ms |
| 1920 × 1080 | PQ | 3.06 / 3.55 ms | 1.65 / 2.18 ms |
| 1920 × 1080 | HLG | 2.95 / 3.46 ms | 1.65 / 2.20 ms |
| 3840 × 2160 | SDR | 7.49 / 8.08 ms | 4.58 / 5.23 ms |
| 3840 × 2160 | PQ | 7.46 / 8.04 ms | 4.64 / 5.16 ms |
| 3840 × 2160 | HLG | 7.78 / 8.39 ms | 4.46 / 5.01 ms |

Median peak process memory footprint across trials fell from 604 to 440 MiB as reported by `/usr/bin/time -l`. The output row hashes matched for every raster and transfer, including the separate RGBA8 transparency fixture. Both versions passed the translated-extent, overlap order, changed-frame and HDR highlight checks. A repeat with concurrent system load produced 4K medians of 8.88–9.04 ms before and 6.07–7.22 ms after. These measurements end at the synchronized output buffer.

An additional 40 deterministic layouts used a translucent, above-white gradient at 1023 × 407 with a translated origin. Each included a one-pixel strip in both directions and 20 overlapping rectangles of varying dimensions. All 40 linear RGBA16F output hashes matched the previous kernel. In a separate opaque-cover experiment, caching the composited overlay or pruning nested nameplates changed the output hashes after crop and resize. The production cover path keeps its original compositing order.

## HDR path

The HDR inputs carry BT.2020 primaries and the respective PQ or HLG transfer attachment. The compositor imports the tagged buffer with Core Image tone mapping disabled and works in half-float extended linear BT.2020. It writes a packed 10-bit RGB surface tagged for the original transfer. The packed above-white highlight matched the crop-only reference at both resolutions for PQ (`0xe9da769d`) and HLG (`0xf71dc771`). The output carried the expected transfer and BT.2020 primaries. A sample within a treated tile changed with blur.

In the editor, the participant preview routes the decoded frame into the compositor with its source time and transform. An SDR program can request tone mapping as it imports an HDR buffer. For an HDR program the viewer verifies the transfer, pixel format and primaries before presentation. With extended range available it submits the HDR surface to the display layer. When the viewer needs SDR, it renders a separate sRGB BGRA8 preview. The HDR measurement ends at the pixel buffer, with the viewer behavior traced through source. [Participant preview](../../Sources/MPCutApp/ParticipantPreview.swift) · [Compositor](../../Sources/MPCutCore/ParticipantRenderPicture.swift) · [Output buffer](../../Sources/MPCutCore/ParticipantOutputPicture.swift) · [Viewer presentation](../../Sources/MPCutApp/PreviewSurface.swift)

## ISO batches

The Tiles CLI exported two silent H.264 feed crops, each one second at 8 fps, from the synthetic guest/host gallery used by the integration tests. Three fresh debug processes per case ran against the audit build and the updated batch renderer. An independent FFmpeg check verified the expected center color on every output frame. FFprobe reported identical dimensions, SDR color tags, presentation timestamps and frame durations across runs. Encoder output can vary across repeats of the same build.

| Output raster | Readers / decode requests / passes | Peak writers | Input surface cap | Median wall time before / after | Median process peak RSS before / after |
| --- | ---: | ---: | ---: | ---: | ---: |
| 160 × 90, 40 crops | 1 / 8 / 1 | 40 | 33,177,600 B | 4.43 / 1.83 s | 104.6 / 105.3 MiB |
| 1920 × 1080 | 1 / 8 / 1 | 2 | 199,065,600 B | 0.46 / 0.47 s | 78.1 / 78.1 MiB |
| 3840 × 2160 | 2 / 16 / 2 | 1 | 398,131,200 B | 0.90 / 0.69 s | 77.6 / 77.0 MiB |

For the 40-crop case, an 8 × 5 grid supplied distinct crop bounds on the same recording. All 40 movies were published on each run. Wall times ranged from 4.05 to 14.73 s before and 1.52 to 2.65 s after.

A repeat after limiting frame-graph sharing to batches with concurrent writers reproduced the same crop, timing and batch counts at both rasters. Median 4K wall time in that run was 1.17 s before and 0.96 s after.

The surface cap is the sum of the pixel-buffer pool limits for active writers. It excludes the codec, decoder and Core Image, and is separate from the sampled process RSS. One 4K writer can exceed the 192 MiB batching threshold and stays below the 512 MiB per-writer cap. The updated renderer shares frame timing and eligible treatment graphs within each batch and begins encoder finalization together. Silent MOVs publish the verified staged movie directly, avoiding the final compressed payload copy. Outputs with sound or another container still go through the muxer. The timings include CLI startup and fluctuate with concurrent load. The measurements cover the combined changes.

## Two-hour review project

The app test uses a generated two-hour, 1 fps H.264 source and a full-length sequence clip. It creates 40 feeds, 96,000 three-second appearance spans with changing boxes and nameplates, and verified coverage for the entire source. It saves with the editor's project writer, reopens in a new editor, checks the full participant model and source duration, then corrects one tile in the last span. It saves with the edit in undo history, undoes the edit, checks exact restoration and redo availability, and saves again. Each saved document must fit within 64 MiB (67,108,864 bytes). The low-resolution source keeps the benchmark focused on project I/O and edit history. Set `MPCUT_FEEDS_BENCH_SPAN_SECONDS` to change the update cadence and exercise the capacity boundary.

The test passed in Backstage against the adaptive-scan debug build with the compact writer. The saved document sizes were 1,035,209 bytes initially, 1,850,973 bytes with the edit in history, and 1,850,981 bytes after undo. Save took 9.45 s, reopen took 12.31 s, edit took 124 ms and undo took 13 ms under concurrent builds. These sizes describe the compact encoding.

In a core-only check, the editable JSON writer saved the same geometry and history states in 53,626,057 bytes initially, 45,999,965 bytes after the edit and 45,999,974 bytes after undo. The writer used indented JSON for the initial snapshot and compact JSON for the two larger history archives. Each fit within 64 MiB.

The integrated desktop benchmark also passed on Backstage with the editable JSON writer, a saved Solo layout and 96,000 spans. The initial document was 53,629,639 bytes. The edited and undone documents were 46,001,645 and 46,001,654 bytes respectively. The editor reopened both history states and retained their undo or redo entries. Save took 10.23 s, reopen 11.16 s, edit 311 ms, and undo 16 ms on the loaded machine.

## CLI review and save

Computing a reconciliation review token for the 32.9 MB fixture with 4,608 observations used 216,858,624 bytes of peak process RSS after switching to incremental JSON hashing, down from 414,941,184 bytes. Both runs returned byte-identical review receipts, including the token.

The CLI checks used debug builds before and after the review and project I/O changes. The long scan was a 32-period replay of the every-frame gallery observations in a 32,944,332-byte JSON file. Each row shows the median of three alternating runs per build. Stdout matched byte for byte.

| Long scan command | Median wall time before / after | Median peak RSS before / after |
| --- | ---: | ---: |
| `tiles inspect --at 80` | 1.87 / 1.35 s | 196.8 / 196.3 MiB |
| `tiles inspect --issues` | 1.89 / 1.41 s | 196.3 / 195.7 MiB |
| `tiles feeds list` | 1.85 / 1.35 s | 196.2 / 195.7 MiB |
| `tiles feeds inspect` | 1.85 / 1.39 s | 196.3 / 195.9 MiB |

Running the same review commands on the 45,999,965-byte edited project also produced identical stdout. For `inspect --at 80` and `inspect --issues`, the original audit runs took 20.87 s and 22.09 s, with peak RSS of 403 and 394 MiB. The updated debug build ran them in 10.89 s and 13.90 s, with peak RSS of 385 and 379 MiB. These are individual runs, and subsequent baseline reruns during concurrent builds took 49.72 s and 35.43 s. Under that build load, the baseline and updated `feeds list` runs took 39.76 and 20.34 s (398 and 380 MiB peak RSS), and `feeds inspect` took 35.26 and 11.77 s (403 and 382 MiB).

A feed rename on that project took 49.13 s of process CPU time before and 30.38 s after. Peak RSS fell from 1,695 to 1,274 MiB. The saved file retained the rename as an undo step. The two files differ only by the seven bytes of the fixed final `refs` entry in the newer writer. Both runs pruned the same older steps under the existing archive byte budget. The save figures are single runs taken during concurrent builds, when wall time fluctuated.

A saved-project stress case used a single unresolved tile that reappeared in 2,500 disjoint one-second intervals. The 5,000 detector events fell alternately at interval starts and in gaps. Across three alternating debug runs, `tiles inspect --issues` took a median of 0.65 s in the audit build and 0.19 s with binary search over the coalesced intervals. Median user CPU fell from 0.60 s to 0.16 s, and stdout matched byte for byte. An isolated optimized Swift lookup over 8,000 intervals and 16,001 timestamps took a median of 81.6 ms with a linear scan and 0.85 ms with binary search. The lookup reuses the existing interval array.

## Review thumbnails

A headless Swift harness requested 160 thumbnails from the same indexed ProRes frame using 16 crop bounds. It alternated three times between a new renderer for every request and a single renderer warmed with the first crop. Median process CPU time was 0.689 s for cold requests and 0.0082 s for cached requests. Median elapsed time was 5.07 s and 0.0098 s respectively. The cold comparison includes opening and decoding the same frame again on every request. These timings cover rendering and cropping, without measuring SwiftUI layout or a workload with 160 distinct frames.

The shared cache keeps at most 32 decoded frames within an 8 MiB image buffer budget. It keys entries by the source snapshot, stream and exact frame time, and crops each card from the cached frame. The renderer checks that the source snapshot is current before using the cache and again before returning the crop. A changed source discards entries for its URL. The harness verified least-recently-used eviction, byte accounting, and rejection of a warm cache entry after the source was replaced at the same URL. A request using the replacement's index returned a fresh crop.

## Tile scan backends

Two native debug CLIs linked optimized TileTrail libraries on an Apple M4 Max. For each fixture and backend, five timed fresh processes followed one warmup. Run order was shuffled within each round. The times include reading and hashing the source, decoding, detector and tracker work, and writing the complete scan with `--sampling every-frame --no-sidecar --output`. Other builds were running on the host.

| Input and layout | CPU before | CPU after | GPU-required before | GPU-required after |
| --- | ---: | ---: | ---: | ---: |
| 144-frame synthetic gallery, `--gallery-grid 5x5` | 139 ms | 121 ms | 304 ms | 232 ms |
| Same gallery, `--feed-layout 5x5` | 115 ms | 104 ms | 260 ms | 202 ms |
| Jitsi gallery recording, `--feed-layout auto` | 693 ms | 631 ms | 1,148 ms | 773 ms |

The complete analysis matched across both builds and backends for each row after removing backend diagnostics. The hinted gallery contained 3,600 visible regions and 40 content identities. The fixed grid had the same number of regions and 25 positional identities. Jitsi yielded 2,160 regions and 12 tracks. All three reported observed coverage throughout. On the hinted gallery, adaptive sampling produced 56 observations and sparse sampling produced 48, with identical events and coverage across CPU and Metal.

The GPU-required path uses Metal for sampling. For automatic feed layouts, the same dispatch now calculates each sample's horizontal and vertical seam votes and inset-corner evidence. It returns them in the spare byte of the existing four-byte sample. Detector workers share the GPU measurement buffers and process different frames concurrently after readback. The decoder can release a hardware surface as soon as its reduced RGB sample is ready and batch up to 32 reduced samples. CPU was the fastest backend for each timed fixture and remains the automatic choice.
