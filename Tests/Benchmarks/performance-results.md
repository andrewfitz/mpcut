# MPCut performance pass — November 2026

Measurements use the current checkout on Apple silicon. Parallel development and background builds made elapsed time noisy. Each row names the timing boundary; a phase improvement applies only to that phase. The preserved pre-pass release CLI had SHA-256 93bc4adfff46cc0c21f76909768acdd54b906d1bca797c6c1f1057757aa57fa3. Its exact source revision was unverified. Focused before/after comparisons also used paired builds of the affected production functions.

## Focused comparisons

| Workload | Before | After | Verification and scope |
| --- | ---: | ---: | --- |
| Save conflict check on a 64 MiB archive | 134.5 MiB peak RSS | 70.0 MiB peak RSS | Separate check processes including the fixture mapping. Streaming SHA-256 retained the exact-byte conflict check, including equal-size replacements. |
| Still preview, 1080p SDR pixel packing | 3.99 ms | 1.29 ms | Actual pixel-buffer getter, median across five trials. Row bytes, padding, format and attachments checked. PQ was 3.57 → 1.24 ms. |
| AAC copy, 150 reordered one-second selections | 471.3 ms | 397.6 ms | Native packet writer, eight alternating warm pairs. Byte-identical MP4s. Reading source edit metadata once also passed the multi-edit input case. |
| MCP bridge, 2 MiB ordinary JSON result | 32.0 ms / 24.28 MB allocated | 13.7 ms / 8.46 MB allocated | Local socket request through construction of the SDK result. Excludes final SDK stdout serialization. Size rejection checked separately. |
| Transcript edit affected-occurrence lookup | 270.46 ms | 0.112 ms | 500 short ranges in a 50k-item timeline, isolated Swift, seven alternating samples. Verified ordered IDs and interval boundaries. |
| Cached offline recognition provider status | 276.3 ms | 11.2 ms | Provider process completion notification, 12 paired runs. The status response was identical. Speech inference is a separate workload. |
| Narrow timeline waveform redraw | 85 µs | 1.8 µs | 32-point dirty region at 1×. At 2×, 158 → 3.0 µs. Core Graphics pixel parity checked. |
| Two-hour multicam sync, six tracks with missing bins | 47.58 ms CPU | 34.73 ms CPU | Matcher phase, exact result JSON. All-valid tracks took 50.79 → 41.34 ms. The short 70-second fixture was essentially flat. |

## Multicam Mix measurements

These paired measurements cover the November 23 Mix pass on Apple silicon. Preview mixer timings exclude input decoding and the audio device. Export timings include writing the output file.

| Workload | Before | After | What was checked |
| --- | ---: | ---: | --- |
| Plan eight continuous lanes across 12,000 picture switches | 57.2 ms | 10.1 ms | Median of five debug runs. The plan retained 12,000 picture intervals and one continuous span per lane. |
| Route those eight lanes for silence analysis across 12,000 picture intervals | 135.39 ms | 2.53 ms | Nine paired debug runs with indexed PCM. Both produced eight audio routes. |
| Mix eight stereo lanes at 48 kHz for 15 minutes of program time | 494.6 ms | 297.7 ms | Optimized CoreMedia mixer, 1,024-frame input blocks, median of five runs. PCM and presentation timestamps matched on the comparison clips. |
| Mix four six-channel lanes at 48 kHz for 10 minutes | 610.3 ms | 416.4 ms | Same mixer benchmark. Four stereo lanes at 44.1 kHz took 901.3 and 898.4 ms respectively. |
| Export four stereo 48 kHz lanes across six reordered 95-second selections to one stereo PCM WAV | 2.170 s | 1.810 s | Three alternating runs per build. All six 570-second WAV files had identical SHA-256 hashes. |
| Suggest replacement sync against 10 minutes of stereo 48 kHz AAC with a two-minute PCM replacement | 265.4 ms CPU | 40.3 ms CPU | Optimized builds with indexed media, sidecar reads disabled and the reference waveform already in memory. Eight alternating runs per path produced byte-identical reports and the same two-second offset. |

A decoded waveform window shared by two of eight visible lanes now invalidates the two consumers. A media refresh still invalidates all eight. A repeated visibility report skips rebuilding the visible surface set when the lane and outstanding work are unchanged.

The desktop preview benchmark used four 320×180 H.264 cameras at 25 fps, two mono and two stereo PCM tracks at 48 kHz, and a picture switch every four seconds. Median paused seek time was 3.73 ms over 15 seeks. Median switch lag on the playback clock was 4.76 ms over 14 switches, and the three-second steady run submitted all 75 expected frames. Separately, the production audio reader decoded and mixed all 2,880,000 frames of the 60-second program in 77 ms on a warm run. Forty 80 ms forward and reverse scrub requests took 1.71 ms median and 2.61 ms at the 95th percentile to produce the audio.

With four 1080p H.264 cameras carrying 48 kHz AAC, median seek and switch lag were both 7.25 ms. The steady 25 fps run again submitted all 75 expected frames. Copying that 40-second edit with all four audio tracks to a 70.4 MB MP4 took 79 ms in the prior packaged release and 81 ms in the optimized release (warm medians of three). All five stream payload hashes matched. On the 60-second PCM project, the optimized packaged app exported separate tracks in 71 ms, mono in 212 ms, and stereo in 250 ms. The corresponding prior release timings were 75 ms, 238 ms, and 284 ms. All three comparisons matched picture and audio stream hashes.

## Held still with lossless audio

The signed macOS package used its bundled CLI and FFmpeg to render the same 1920×1080 SDR cover image with a 48 kHz, 24-bit stereo WAV. Each movie used MOV, H.264 and ALAC in Smart Trim. Cadence used the same settings at 24 fps. Elapsed time covers one export after preflight, including final verification and publication. Other release checks ran in parallel.

| Program and picture timing | Elapsed | Video packets | Video bytes | Audio bytes | Container bytes | Total bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 seconds, held | 1.16 s | 1 | 70,812 | 1,534,701 | 1,922 | 1,607,435 |
| 5 minutes, held | 1.40 s | 1 | 70,812 | 46,029,567 | 15,682 | 46,116,061 |
| 1 hour, held | 49.07 s | 1 | 70,812 | 552,357,254 | 172,306 | 552,600,372 |
| 10 seconds, cadence | 1.83 s | 240 | 638,787 | 1,534,701 | 2,914 | 2,176,402 |

Each dry run reported the planned video packet count and left the destination unwritten. After publication, `output_bytes` equaled the filesystem length in all four cases. Video and audio bytes are sums of packet payload sizes. Container bytes are the remainder. Every held video packet was a sync sample that started at zero and lasted for the full program. All three held files decoded to the same RGB image. The full decoded stereo PCM matched the source at 24-bit precision in each case.

The 10-second held file saved 568,967 bytes (26.1%) compared with cadence, including an 88.9% reduction in video payload. Audio payload was the same. For the hour-long export, the earlier staged path created 1,382,400,000 bytes of raw PCM and reached 1,935,072,137 sampled staging bytes. The packaged direct WAV path showed zero raw PCM staging bytes and peaked at 1,105,272,509 sampled staging bytes. Packet counts, payload sizes and decoded samples matched between paths.

## Experiments that did not justify a change

- A GPU buffer pool made isolated allocation cheaper, but median forced SDR rendering across 30-frame blocks went from 71 to 138 ms in a noisy end-to-end comparison. The prototype was removed.
- Timeline mapping alternatives produced regressions or changes within noise. The existing implementation was retained.
- The CLI launch experiment attributed roughly 1.7 ms to bypassing the Swift entry path. Entry and linkage were left as measured.
- Energy telemetry was unavailable without additional privileges. Host thermal state and device-wide I/O cannot attribute energy to MPCut.

## Application and workflow checks

- A debug CLI exported 124 out-of-order program-frame requests across two 720p H.264 cameras. A single matched run took 21.24 → 1.85 s for review JPEGs and 28.59 → 2.33 s at full size. Request order, frame selection and manifests matched after normalizing the output directory. All full-size decoded RGB hashes matched. One review frame showed a small RGB difference also seen when repeating the baseline. Cancellation after staging a frame left the destination unpublished.
- A late half-second 4K60 reencode with source audio removed took 2.13 → 1.69 s across six alternating debug CLI runs. All 30 output frame hashes and timestamps matched. Removing unnecessary preroll retained damaged-input handling in the focused tests.
- In the integrated debug XCTest with 2,001 persisted transcription jobs, discovery and status handling occupied the foreground for 2.699 s before the change. Moving discovery off the main actor cut foreground time to 0.475 ms. The candidate finished discovery in 1.311 s across five alternating repetitions. The matching job record was identical. This fixture measures discovery, not whole-app launch.
- The synthetic multi-track audio fixture went from 17 helper launches to seven by writing silence directly. The comparison verified all 8,008 samples. The still-sound and multicam audio conversion suites passed.

Reopening 5,000 clips with 190 history states took 2.546 → 2.223 CPU seconds. Reopening 30,000 clips with 32 states took 2.980 → 2.702 CPU seconds. The paired loader harness used the production archive path and verified the current state and both ordered history branches. These measurements exclude interactive undo and preview.

Packaging now strips local and debug symbols from the two staged Swift executables. On the same release artifact this reduced installed regular-file bytes from 130,363,470 to 106,848,446 (22.43 MiB saved, 18.04%). The compressed ZIP fell from 73,677,017 to 70,217,503 bytes (3.30 MiB, 4.70%). Exported symbols, imports and Mach-O UUIDs matched. The build products and their dSYMs stay available for debugging. The signed stripped app passed launch, CLI and headless checks.

For a 32-tile burst with one cancelled request, filmstrip persistence went from 31 SQLite commits to four. In 30 debug XCTest repetitions per variant, median time from releasing a competing writer to the final durable tile went from 115.4 to 19.7 ms. Encoded bytes, eviction order, same-stamp source replacement and cancellation passed. During offscreen dirty paints the timeline also reduced median main-thread CPU from 0.331 to 0.225 ms and p95 from 1.111 to 0.424 ms across three alternating pairs.

Transcript pagination illustrates the difference between a faster algorithm and a faster interface. With 28,800 words and 4,800 hits, generating a subsequent page took 4.778 → 0.507 ms in isolation. In the matched debug app, the median Accessibility action-to-matching-label time across pages was 82.47 → 80.76 ms. First-result latency was 41.93 → 41.88 ms. The visible interaction was essentially flat under this workload.

## Combined verification

The signed debug app completed the MCP quote workflow from discovery through export and reinspection. The test verified the camera switch, exact audio samples and timing report. A separate four-angle CLI export verified all 4,500 copied picture packets, exact timestamps, 8,640,000 audio samples and 20 review images. These are correctness checks.

The debug app suite exercised 594 tests with six conditional skips. Two classes initially failed to launch the unsigned debug CLI helper; after signing it, all 14 export-rule parity tests and 18 file-job tests in those classes passed. The separately signed core test bundle ran 423 tests with 17 conditional skips and zero failures. The Go race suite and seven Python packaging checks passed. These counts describe the compiled test artifacts. Concurrent multicam audio feature changes also altered the working tree during verification.

The combined checkout subsequently completed a development build of both the desktop and CLI. Its recompiled multicam CLI also passed the updated audio-lane benchmark, with the same 4,500 verified packets, 8,640,000 verified audio samples and 20 JPEGs. A later whole-suite rebuild encountered an independently changing multicam sync API. Optimized package builds also saw CLI consumers ahead of the Core module. The full current-tree release candidate and release-to-release end-to-end timings remain unverified. The distribution size comparison above isolates the packaging change on the same signed release inputs.
