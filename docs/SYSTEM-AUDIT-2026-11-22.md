# MPCut system audit, 22 November 2026

This pass covered the macOS editor, command-line interface, MCP server and native worker, project and transcript storage, FFmpeg probing and writing, export, interchange, and packaging. Thirty Astra agents reviewed the working tree. It already contained substantial uncommitted work and changed during verification. The comparisons below use local debug builds.

## Performance measurements

Each figure is the median process CPU time from three alternating runs per executable on the same Mac. Other builds were running on the host.

| Workload | Previous debug build | Audit build | Result check |
| --- | ---: | ---: | --- |
| Export 48 JPEGs from one still placement | 5.76 s | 0.21 s | All 48 SHA-256 digests and frame manifests matched |
| Scan 360 repeated one-second clips in media containing 600 pauses | 1.07 s | 0.08 s | All previous pause fields matched. The new report also contained the expected retained durations and take candidates |

The still exporter reuses the rendered JPEG for repeated requests. Sequence pause scans avoid building unused edits and search only the intervals that can overlap each clip. Bulk preflight, repeated-source project rendering and repeated audio-track selection showed no clear speedup in the measured cases.

On the debug editor timeline, 2,000 range-drag updates across 50,000 clips took 20.8 ms in total. With ten clips visible and the selection overlay rasterized on every update, the same event count took 891 ms. In an eight-session startup check, median time to edit readiness was 9.8 ms for four regular sessions and 5.7 ms for four multicam sessions. These are single-build measurements.

In a separate two-hour, 172,800-frame A/V import test, the first clip appeared in 73 ms, the first thumbnail tile in 749 ms, and the full index in 4.52 seconds. For a three-minute, four-camera sequence, median seek latency was 6.89 ms and median camera-switch lag was 3.75 ms. The benchmark accounted for all 75 expected frames.

## Fixes covered by the audit

| Area | User-visible effect or failure addressed |
| --- | --- |
| Sequence editor | Splitting or deleting a marked range through an inline still preserves the intended edit and one-step undo. Refreshing source media after a still updates the correct timeline item and history snapshots. |
| Multicam editor | Slow playback advances through a leading audio gap. Queueing a pause take retains each overlapping assembly range. Scene analysis includes every recording on the selected logical camera. |
| Timeline and transcript UI | Waveform drawing is limited to the dirty rectangle. Reverse word selections handle equal start times. Active mark buttons and transcript selections use the system primary text color against their selection fill. |
| Project lifecycle | Dropped Finder aliases resolve to recordings. Closing an untitled window with an active transcription job preserves its recovery state. |
| CLI | JSON scene lists identify unknown fields. Multicam pause shortening retains pinned cameras and protected dialogue. Still placement and nested export account for occurrence overrides, recording offsets and coverage. |
| MCP | File worker startup and shutdown are bounded. Nullable numeric arguments enforce range and type constraints. Closing an editor window cancels analysis across its project generations. Frame metadata distinguishes the physical recording from the logical camera. |
| Media and export | Conversion propagates cancellation before publishing. Multicam fallback planning preserves interruptions. Warm tier evaluation checks current source identity. Partial-frame still inserts retain cadence validation while whole-frame inserts skip the full recording scan. |
| Transcript processing | Cancellation is checked during preparation, recognition and activity encoding. Projection avoids scanning every audio segment for every word. WebVTT cues with STYLE or REGION identifiers survive import. |
| Interchange | Premiere XML import validates independent microphone trims and reconstructs sequences that alternate audio-only recordings with picture. Host conversion reports the omission of named source selects. |
| Packaging | Failed helper builds preserve previous connector archives. The offline manual includes the Grok setup and its referenced plugin files. |

Integration testing found three additional failures. An export could block on progress output when the caller stopped reading stderr. CAF conversion could swap the side and rear surround channels on 7.1 audio. Pause shortening could give two clips the same document ID, preventing recovery saves and undo. Regression checks exercised the full pipe, decoded speaker identity with FFmpeg and Core Audio, and undo after shortening.

## Integration verification

- The combined XCTest run reported 982 tests, 15 conditional skips and zero failures. All 15 conditional cases subsequently passed with their fixtures enabled. They included four GUI and tier benchmarks, five transcript benchmarks, two spoken-media extraction tests, and four offline tests using the installed Transcriberrr helper and local models. After normalizing equivalent absolute source paths for live range mapping, 18 focused tests and the complete live MCP suite passed on the updated build.
- The signed debug app passed all 18 live MCP subtests and the separate Settings test. The tests exercised native Undo and Redo menu items, queue order, cut movement prompts, two-window targeting, waveform amplitudes, recording gaps, file export, cancellation, saved history and local-control settings.
- Native Accessibility automation exercised transcript import, search, word seeking, correction, undo, save/reopen, multicam source binding, camera switching and exporting a saved quote selection. The headless worker also completed file operations with the editor closed.
- The Go MCP package passed an uncached race-detector run. The packaged catalog check verified 205 advertised tool descriptors and three offline documentation resources.
- CLI and media integration covered 125 audio cases, 49 still-image cases, 33 multicam cases, 30 writer and Smart Trim cases, 28 sidecar and scene cases, and 17 mixed-format timeline cases. These are suite counts with overlap between categories. Counts include focused reruns on corrected executables.
- Project conversion and Resolve export passed 17 integration cases. Premiere panel syntax and its request contract passed. Native Premiere and Resolve UI round trips and the remote Grok account connection were outside this verification.
- The CLI inventory matched 174 documented command paths. Seven packaging tests passed, including preservation of existing archives after an injected build failure.

Independent edits continued during the pass. Verification used isolated source snapshots, private app bundles, and temporary projects. The repository's installed distribution and a clean release build have different dependency and signing configurations from these debug builds.
