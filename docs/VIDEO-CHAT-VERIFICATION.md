# Recorded video calls in MPCut

## What the checks cover

TileTrail analyzes decoded frames. MPCut owns the project, corrections, transcript and audio bindings, preview, editing and delivery. Source coordinates are normalized to the displayed picture, and source observations use rational presentation timestamps. A participant can have multiple visible appearances. Offscreen and camera-off time can retain both the participant's output slot and their audio.

| Workflow | Evidence |
| --- | --- |
| Detection and re-entry | The Rust gallery tests have known source rectangles, identities, camera states, swaps, returns and change times. The real recording scorer measures annotated rectangles and camera state on selected frames of public video. |
| Scan through export | The CLI integration test scans a ProRes gallery through FFmpeg, accepts the generated IDs into a project, follows a seat swap and checks the decoded output picture. |
| Original gallery and reframed delivery | Pixel checks cover masking a simultaneous stage view and thumbnail, a one-frame return, opaque coverage over unresolved frames, repeated occurrences and two separate cameras with recording gaps. |
| Audio | Integration checks compare the first sample of a late-start ISO with its expected position and count the meeting mix across the rendered angles. |
| Transcript and monitor | The macOS Accessibility test drives the Participants inspector on an overlapping exchange. It checks which roster entries are speaking, which boxes are visible, and the independently pinned selection. |
| Virtual participant angles | The take test follows the original gallery, switches between participants and returns to the gallery. Save/reopen, frame timestamps, audio policy and occurrence scope are checked. |

The desktop run captured the [two speaking participants and the guest's simultaneous appearances](images/participant-overlapping-speakers.png) and the [two-up preview with the guest offscreen](images/participant-pair-preview.png). It also scanned the source, sought to a layout marker at exactly one second, canceled a reconciliation review and reopened the saved project.

The real corpus measures geometry at an intersection-over-union threshold of 0.50, with one prediction per reference match. There are only two labeled frames per excerpt. This sample cannot estimate error rates across a platform, a whole meeting or a redacted deliverable. Editors should confirm identities, duplicate appearances and bounds on the material they deliver. Sparse samples may miss a brief appearance.

## Private Zoom archive evaluation, November 24, 2026

The archive contained 64 recordings from 63 sessions totaling 146.9 hours. Four reviewers labeled frames at 6%, 30%, 55%, 80% and 95% of each recording before seeing detector output. They labeled 1,154 participant tiles across 310 of 320 samples. Three-person layouts accounted for 194 of those 310 frames. The remaining ten samples had ambiguous camera or shared-content geometry and were excluded. The reference rectangles include pillarboxing inside a tile. Recordings and per-frame annotations are kept outside the repository.

The scorer pairs each predicted participant rectangle with at most one reference rectangle. A match requires intersection over union of at least 0.75. Precision measures how many predicted boxes matched. Recall measures how many reference boxes were found. An exact frame has every reference box matched and zero extra predictions. Screen-share regions are scored separately from participant tiles. The evaluation also records a held-out group of 30 whole sessions with 146 scorable frames from 150 samples. The five probes per recording measure sampled geometry. Tracking through layout changes requires continuous video and is tested separately.

These measurements use MPCut’s reduced-resolution reader and TileTrail’s default meeting profile. The earlier detector and the updated detector received the same frames.

| Recordings | Detector | Precision | Recall | Exact frames |
| --- | --- | ---: | ---: | ---: |
| All | Before | 987/1,377 (71.7%) | 987/1,154 (85.5%) | 176/310 (56.8%) |
| All | Updated | 1,129/1,167 (96.7%) | 1,129/1,154 (97.8%) | 294/310 (94.8%) |
| Held-out sessions | Before | 461/650 (70.9%) | 461/535 (86.2%) | 75/146 (51.4%) |
| Held-out sessions | Updated | 516/551 (93.6%) | 516/535 (96.4%) | 133/146 (91.1%) |

Two continuous excerpts exercised layout changes. The share-to-gallery excerpt matched all participant boxes on 296 of 299 frames before and after the update. The change from three cameras to four improved from 170 to 276 exact frames out of 300. Across the two excerpts, 1,584 of 1,636 labeled adjacent tile pairs retained a matching box and a consistent track ID. The other 52 pairs lacked matching geometry. On a separate three-camera excerpt the updated detector kept three IDs throughout all 75 frames. The previous detector created 28 IDs.

An additional end-to-end check used a short moving excerpt from each recording. The frame at 55% of each original call was an exact decoded RGB match to its labeled probe. On these frames MPCut’s adaptive GPU scan matched 222 of 225 reference tiles, with five extra boxes. It returned the exact layout in 58 of 61 scorable excerpts. Three reference frames had ambiguous geometry. These excerpts overlap the fixed-frame sample above.

Shared content remains harder to distinguish from a camera. Of four labeled sample frames with a confirmed share and known camera geometry, the detector identified the main pane as a share in two. Nine of the ten excluded frames also appeared to contain a share or sidebar. The geometry scores do not establish meeting-wide identity, camera-state or screen-share classification accuracy.

The frozen detector was also checked against the public suites below. At their IoU threshold of 0.50, both versions matched 4/20 boxes on the first independent set and 2/4 on the final-only set. The improvements on the private Zoom archive therefore should not be extrapolated to other conferencing layouts. All 949 synthetic gallery boxes matched on CPU and Metal. In the dense gallery case, the revised rectangles included more gutter pixels, reducing mean IoU from 0.983 to 0.972 and increasing the largest edge error from 1.75 to 5.5 pixels.

## Earlier detector and independent recordings

These earlier measurements used TileTrail 0.1.0, commit `f1cdfb6292f7860ee7a3ca46c9c64e25fe480d7b`, C ABI 1. The app used the same Rust tracker for CPU and Metal analysis.

| Evaluation set | Correct boxes / labeled boxes | Extra boxes | Mean IoU among matches |
| --- | ---: | ---: | ---: |
| Zoom/Jitsi development video | 54 / 54 | 4 | 0.971 |
| Separate Meet/Teams development video | 30 / 30 | 0 | 0.970 |
| Meet/Teams development gallery screenshots | 55 / 55 | 0 | 0.964 |
| Original independent Meet, Teams and Zoom recordings | 4 / 20 | 12 | 0.987 |
| Two additional sessions reserved until the final build | 2 / 4 | 2 | 0.994 |

The original independent set scored Meet 2/2, Teams 0/8 and Zoom 2/10. The Zoom matches were the live webcam in a strip that also contained camera-off cards. The final-only set scored Meet 2/2 and Teams 0/2 on webcam-plus-share layouts. The first independent set had already been scored before a separate development round. The two final-only sessions were first scored after code freeze. Both Teams misses matter for real edits. Inspect the source and add or correct missing boxes before relying on extraction, speaker highlighting or privacy masks.

The source recordings, rights, hand labels and per-clip counts are included in TileTrail's `validation/real`, `validation/platform-dev` and `validation/temporal` directories. The eight short platform-development videos and four gallery screenshots measure different capabilities. Screenshots only test geometry and camera state.

All six generated clips produced identical final CPU and Metal results apart from backend diagnostics. All 949 boxes matched, with zero extras. Of 58 expected events, 50 had confirmed matches on the exact frame. Two expected identity returns remained unresolved, and 26 observations carried provisional identity links. A separate H.264 interview passed all 76 box checks, all seven edit events and both returns.

On the real Jitsi reflow, timed matches for the initial, first accuracy and final builds were 4 → 1 → 7 of 14 for dense sampling and 5 → 2 → 12 of 12 for sparse sampling. The final sparse matches all carried uncertainty. Dense analysis missed both brief camera-state events and produced 12 extra events during a stable window. The real Zoom thumbnail strip produced 24 → 22 → 1 extra event in its stable interval, and the final tracker preserved all 21 annotated identity pairs.

The final linked MPCut CLI scanned a three-second public Jitsi recording, accepted a generated participant ID without corrections and rendered 36 frames at 264×320 and 12 fps. The accepted crop overlapped both hand labels at 0.974 IoU. At the two labeled times, mean luma error was 10.00 and 9.73 on a 0–255 scale relative to the intended tile. The nearest competing tile scored 55.96 and 56.93. All presentation timestamps matched. [Reproduction test](../Tests/Integration/participant_e2e_real.py)

## Platform and consumer checks

The final Rust and C consumers produced eight byte-identical CPU results across native macOS ARM64, Linux ARM64 in Docker, translated Linux x86-64, and Windows x86-64 GNU executables under Wine 10. The macOS Python and separately compiled Swift consumers matched the Rust result. An independent Cargo project built offline from the packaged crate. Rust 1.87.0 passed 52 CPU checks and 53 all-feature checks on macOS, including real Metal device loss and CPU recovery. Native Windows/MSVC and hosted CI have no execution result for this release. Automatic GPU selection is enabled on Apple Silicon macOS. Other platforms use the portable CPU path.

## Independent implementation reviews

- Fresh Sol reviewers exercised the Rust geometry and tracker, the query and C interfaces, the Swift frame tap, editing history and desktop state, and the publication paths. Their fixes included rotation-sensitive features, small-tile histogram counts, sparse coverage boundaries, exact GPU retry points, declared color range, ISO offsets, and blocking ordinary export paths that could bypass a saved mask.
- The Astra accuracy pass added evidence for gallery seams, partial strips, avatars and returning identities. Separate Astra reviewers then checked the combined implementation across the library, ABI, Swift scan/cache, compositor, GUI and project workflows. Regression fixtures reproduced incorrect confirmation on shared backgrounds, disappearance of a valid screen share, writes to a missing camera's path, stale source clocks, and an appearance pin incorrectly removed outside an edited interval. The final reviews included the additional Meet and Teams development changes.
- The final performance checks used release comparisons, decoded output pixels, exact source times, saved JSON byte comparisons and measured process memory. The GPU table, repeated-avatar stress and one-hour results below include workloads that regressed.

## Accuracy of the first frozen detector

The initial revision was `ddec86e`. The first Astra accuracy pass froze revision `d9798c1` before opening the independent samples. Each row below compares those two revisions on identical inputs.

| Sample | Initial → first frozen revision |
| --- | --- |
| Zoom and Jitsi development, 10 hand-labeled frames | 26 → 54 of 54 participant boxes, 24 → 4 extra boxes, 52.0% → 93.1% precision. Matched camera state was correct on 18/26 → 54/54. |
| Separate Google Meet, Microsoft Teams and Zoom sessions, 6 hand-labeled frames | 3 → 2 of 20 boxes, 22 → 14 extra boxes, 15% → 10% recall. The frozen build found 0/2 Meet, 0/8 Teams and 2/10 Zoom boxes. |
| Four generated development clips | All 654 boxes, roles and camera states correct on the frozen revision. Twenty ambiguous observations of camera-off cards remained provisional. Confirmed events matched 37 of 43 expectations. |
| Two unseen generated layouts | All 295 boxes matched on the frozen revision. The reflow test recovered one of two returns and 11 of 13 events. The share strip linked all 12 simultaneous stage/thumbnail appearances and matched both expected events. |

CPU and Metal produced identical synthetic analyses apart from their backend diagnostics. The temporal scorer uses separate real excerpts and measures identity and event timing directly. On the first frozen build, dense Jitsi identity continuity improved from 47 to 63 of 80 pairs when provisional associations were included. Only 28 of those 63 were certain. Correctly timed events fell from 4 to 1 of 14. Zoom continuity improved from 1 to 19 of 21 pairs including provisional links, while 22 extra events remained during the stable thumbnail view. These results show why a good rectangle score alone cannot validate speaker tracking or scene cuts.

## Performance measurements

The following pairs isolate the first optimization pass on an Apple M4 Max. Each pair used the same input and produced the same analysis or edit decisions. Concurrent compilation affected wall time. CPU time is the time consumed by the process. Peak RSS measures process memory.

| Workload | Before | After |
| --- | ---: | ---: |
| Rust CPU interview, 528 frames | 2.445 s | 1.378 s |
| Rust CPU gallery, 624 frames | 7.156 s | 4.985 s |
| Rust CPU stage and share, 540 frames | 3.815 s | 2.143 s |
| Rust CPU speech control, 288 frames | 0.985 s | 0.560 s |
| Metal interview, 88 frames | 3.503 s | 3.234 s |
| Metal gallery, 104 frames | 5.506 s | 5.976 s |
| Metal stage and share, 90 frames | 3.863 s | 3.832 s |
| Metal speech control, 48 frames | 2.091 s | 2.113 s |
| Metal Jitsi gallery, 60 frames | 4.458 s | 4.765 s |
| Native sparse 1080p scan, 60 s of video | 51.45 s wall / 2.68 s CPU | 28.78 s wall / 1.62 s CPU |
| Swift validation of 2,000 timed shots, 20 repetitions | 22.65 s wall / 0.74 s CPU | 0.54 s wall / 0.03 s CPU |

The sparse scan converted 1,800 → 300 frames and submitted the same 300 frames to TileTrail. Peak RSS was 46.45 → 46.89 MB. The shot validator used 9.22 → 11.22 MB. Rust CPU peak RSS changed by less than 0.16 MiB across the four tests. Metal peak RSS fell by 2.8–5.9 MiB, and packed 1080p RGB upload fell from 6.22 to 0.83 MB per frame. Metal wall time regressed in three of the five isolated comparisons. [MPCut benchmark setup](../Tests/Benchmarks/participants.md)

On those same five 960×540 Metal inputs, the largest sampled value of `MTLDevice.currentAllocatedSize` fell from 4.33 to 1.50 MiB. The profiler sampled resource allocations at several points in each frame. Transient allocations between samples and systemwide driver memory are outside that measurement.

The final maintenance pass also tested workloads that short clip scans miss.

| Workload | Before | After |
| --- | ---: | ---: |
| Public C snapshot, 60,000 four-tile frames, median peak RSS | 130.55 MiB | 104.45 MiB |
| Same snapshot, complete push and JSON | 20.225 s | 20.208 s |
| JSON serialization alone in that run | 1.172 s | 1.440 s |
| Strict validation of a 76.0 MB report, process CPU / peak RSS | 2.63 s / 158.61 MB | 0.51 s / 82.53 MB |
| Render geometry index, 43,200 lookups, elapsed / peak RSS | 1.09 s / 23.84 MB | 0.40 s / 12.32 MB |
| Monitor index including setup, 900 ordered / shuffled seeks | 73.77 / 96.03 ms | 2.35 / 6.11 ms |
| Metal workspace, 200 alternating landscape and square frames | 200 allocations / 0.958 s | 2 allocations / 0.647 s |

The C snapshot comparison produced identical 75,290,014-byte payloads. The monitor index used approximately 0.7–1 MB more process memory. A 256 MiB source verification previously stalled the main actor for 359 ms. Moving the hash to a worker reduced the median main-actor delay to 0.20 ms.

## Initial and final release binaries

On the same M4 Max, five alternating pairs ran six loops of each 960×540 packed RGB workload against the initial release build and final detector. The timer includes analyzer initialization, frame reads, analysis and snapshot construction. Input decoding and output encoding are outside this timer. CPU and Metal use the same host frames. The recordings above provide the separate accuracy comparison.

| Workload | Elapsed seconds, initial → final | Process CPU seconds, initial → final | Peak process RSS MiB, initial → final |
| --- | ---: | ---: | ---: |
| CPU interview | 0.094 → 0.060 | 0.098 → 0.065 | 8.53 → 8.53 |
| CPU gallery | 0.285 → 0.121 | 0.288 → 0.126 | 9.50 → 9.14 |
| CPU stage and share | 0.190 → 0.084 | 0.179 → 0.084 | 8.97 → 8.53 |
| CPU speech control | 0.055 → 0.032 | 0.059 → 0.036 | 8.41 → 8.41 |
| GPU interview | 1.243 → 0.119 | 0.267 → 0.138 | 34.55 → 31.95 |
| GPU gallery | 1.868 → 0.633 | 0.589 → 0.297 | 35.09 → 34.05 |
| GPU stage and share | 1.745 → 0.550 | 0.516 → 0.205 | 35.00 → 31.95 |
| GPU speech control | 0.858 → 0.393 | 0.293 → 0.130 | 34.83 → 33.44 |

Every measured median elapsed time decreased. CPU analysis was faster than Metal on all four host-RGB workloads, including the final gallery. MPCut still prefers Metal in automatic mode on Apple Silicon. CPU-only mode is available for these workloads. Earlier isolated Metal changes produced mixed results, as the table above records.

A stress test deliberately permuted similar avatar cards on every frame. The tracker retained provisional candidates for review. At 1,000 frames and 64 cards, the follow-on accuracy changes raised peak RSS from 75.6 to 96.9 MiB and elapsed time from 1.47 to 1.93 seconds. This workload produced 4,060 track records. Full observation history grows with scan length and ambiguity.

## One-hour recording and project portability

The linked CLI decoded a one-hour 384×256, 30 fps H.264 gallery loop on CPU and sampled five frames per second. It decoded all 108,000 frames and stored 18,000 observations. On the same detector, the original and bounded-memory writers took 105.56 → 86.95 seconds wall and 39.22 → 33.95 seconds of process CPU. Peak RSS fell from 1,314,422,784 to 794,542,080 bytes (39.6%). The saved file and stdout matched the same 85,537,861-byte report byte for byte. The writer uses a temporary spool when writing only to stdout. An earlier detector used 706.9 MiB for a smaller 76.0 MB report on the same file. Concurrent host workloads differed between runs.

The final report retained 16 participant IDs and 735 appearance IDs. One participant acquired 719 uncertain entry/leave events around the ten-second source loop boundaries, despite all sampled observations containing 16 regions. The repeated compressed input tests duration and exposes identity jitter. Sparse coverage remained inferred for the whole hour.

Acceptance with the bounded-memory writer build took 5.17 seconds and produced a 385,347-byte project with 1,458 saved appearance intervals. Reopening from another folder with a relative media path took 0.12 seconds and reproduced the accepted participant data without a sidecar. This relocation used a hardlink. A separate copy/reconciliation test verified the different-inode case. [Full-hour fixtures, checksums and measurements](../Tests/Benchmarks/participants-hour.md)

## Test entry points

The TileTrail-linked Swift build passed all 82 focused checks. A full MPCut run enumerated 1,140 tests with no failures and 23 opt-in skips. The subsequently frozen shipping source contains 520 core and 633 desktop tests, including 23 opt-in skips. A focused run on the audio retry correction passed all 59 included checks. It covered a recording restored at its original path and refusal to use a different inode. The linked CLI passed 11 end-to-end movie and project cases, four layout cases and the frame-level privacy suite. The standalone MCP worker exercised all 11 participant operations. The desktop accessibility run verified the exact marker seek, reconciliation cancel, explicit binding suggestions, competing ISO names and reopening the saved edit. These results are distinct from the detector's held-out accuracy.

- [Participant editing and export](PARTICIPANTS.md)
- [CLI media checks](../Tests/Integration/participant_e2e.py), [frame-by-frame privacy checks](../Tests/Integration/participant_privacy.py), [MCP checks](../Tests/Integration/participants_mcp.py), and [desktop checks](../Tests/Integration/participant_gui.py)
- TileTrail provides its fixture generator, scorers, annotated media attribution and paired benchmark measurements in its own repository. Run `cargo test --locked --all-features` on an Apple Silicon Mac to include the Metal device-loss check.
