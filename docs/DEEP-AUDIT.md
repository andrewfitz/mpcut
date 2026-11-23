# CLI, desktop and performance audit

November 21, 2026 · Apple Silicon · macOS 27.0.1

## Plan and scope

1. Inventory first-party Swift, C and Objective-C targets, the package manifest, build and packaging scripts, tests and benchmarks. Review ordinary and multicam editing from the CLI and desktop, including indexing, preview, analysis, project storage and export.
2. Run the existing suites against an isolated copy while other work settles. Preserve existing changes to Resolve interchange and damaged-picture handling. Reconcile the review against the newer source before editing.
3. Reproduce findings through the affected entry point. Use generated media, constrained file-descriptor limits, SQLite contention and fake helper processes to exercise failure paths. Check damaged input, cancellation and destination preservation.
4. Profile frame and packet inspection, boundary planning, native demux and decode, filmstrips, desktop indexing, playback, and export. Compare media samples, timestamps, report bytes or analysis markers wherever an optimization could change results.
5. Build both executables and the packaged application. Run core and desktop tests, opt-in performance fixtures, every CLI integration script, and the packaging publication check.

## Changes

| Area | Fixes and regression coverage |
| --- | --- |
| CLI | Reordered edits honor replacement audio only for selected sources. Waveforms use the selected audio stream's clock, including sound after the last picture. Large inspect reports spill to temporary storage and use a binary search for window bounds. Tests cover JSON byte identity and downstream pipe closure. |
| Sidecars and indexes | New databases and repairs preserve neighboring journal files. Reads check database ownership before SQLite can replay a foreign journal. Ordinary imports avoid building a second index for a delayed multicam clock. Multicam requests share the conversion and retain it when the cache budget permits. |
| Audio and video export | AAC edit lists distinguish media ticks from PCM samples. Sample-aligned edits survive whole and partial copies, and fractional samples are rejected. Indexed MP3 cuts use validated sparse anchors for CBR and VBR recordings, with fresh inspection for unsupported sidecars. Multi-edit AAC extraction stops after completing the selected tracks. |
| Re-encode | Repeated compatible ranges share a decoder. Larger assemblies use bounded batches, stream-copy the encoded pictures into the result and encode the joined AAC track once. Tests verify reordered pictures, timestamps, PCM, cancellation and scratch cleanup with a 64-descriptor limit. Batch boundaries can introduce fresh GOPs. |
| Native media analysis | Scene demux skips unrelated streams. Silence analysis stops at the requested end. JPEG extraction rejects decoder-flagged concealed pictures. Smart Trim detects frame-level ambient viewing metadata on edges. Preview seeks handle negative fractional origins. |
| Ordinary desktop editor | Keyframe preparation and costly drag validation move off the main thread for large sources. Drag completion validates the newest request before recording one undo action. Whole-source JPEG export stays available in a leading picture gap. A running scene scan respects changes to the automatic sidecar preference. |
| Preview and filmstrip | Fallback playback observes presentation timestamps at startup and after damaged groups. Off-grid still requests recover after a clean keyframe. Optional thumbnail persistence no longer blocks the decoder on an SQLite writer. Linked movie soundtracks remain audible across preview backends. |
| Multicam | Copy alternatives account for picture and sound clocks, uninterrupted joins and microphone changes. The search rejects incompatible sample phases before validating the program. Marks, cuts and endpoint camera/scene selection respect the active assembly occurrence. Playback avoids repeated full-timeline searches. Picture-only re-encode accepts an offline soundtrack. Project saving respects the reader's size limit, and quit waits for pending view and room-tone metadata writes. |
| Resolve interchange | Export checks the identity of imported sources before publication. Embedded audio coverage extends past a camera's last picture when selected as a master. MPEG program streams without timecode can export. Cancellation and a helper deadline preserve the saved FCPXML on a stalled handoff. Tests cover drop-frame timecode and Broadcast WAV sample references. |
| Packaging and benchmarks | The bundled FFmpeg cache checks headers and license files required for distribution. Uncached multicam benchmark runs explicitly disable sidecars and verify that no indexes appeared. |

## Before and after

| Workload | Before | After | Verification |
| --- | ---: | ---: | --- |
| One-second MP3 crop at 29:50, preflight and writing | 137,088 packet reads | 128 | Identical MP3 and all 44,100 decoded samples |
| 100 ms multi-edit AAC extraction from three minutes of audio | 8,484 packet reads | 9 | Identical decoded PCM |
| 128 bulk ranges from 18,000 pictures, median debug CLI CPU time | 1.776 s | 0.440 s | All ten plans byte-identical |
| JSON inspection of 90,000 frames, peak RSS | 86.5 MiB | 66.2 MiB | Identical 16,250,492-byte report |
| JSON inspection of 70,314 audio packets, peak RSS | 80.6 MiB | 67.5 MiB | Identical 12,837,083-byte report |
| Ordinary index for a delayed 4,500-frame movie, accounted cache storage | 577,030 bytes | 288,515 bytes | Multicam still receives the shifted clock |
| Scene detection on a 69.2 MB MOV with twelve stereo PCM tracks, median of three runs | 0.895 s | 0.452 s | Identical scene markers |
| Six late, one-second PCM WAV cuts, conversion helper experiment | 1.190 s | 0.309 s | Identical decoded samples |
| Six late MP3 conversion ranges, end-to-end | 2.77 s | 1.41 s | Identical decoded program soundtrack |

Wall-clock measurements were taken on a shared machine. Packet-read counts, byte comparisons and accounted cache sizes are reproducible independently of machine load. Previous multicam preflight measurements labeled uncached included automatic index reuse. [Corrected benchmark and fixture](MULTICAM-BENCHMARK.md)

## Verification and limits

All 310 integration tests passed across the 25 CLI suites against the packaged executable. The shared-destination packaging test passed, and strict recursive code-signature verification succeeded.

The final Swift run passed 62 core tests and 269 desktop tests with the optional benchmarks enabled. The four-camera preview submitted all 75 expected steady-playback pictures. All four 1080p filmstrip sources used hardware decoding. Rendering 24 tiles took 231 ms in parallel and 285 ms sequentially. The warm pass took 0.47 ms. The eight-session startup test also completed.

In the signed app, macOS accessibility drove Next Frame, Split at Playhead and Undo Split Clip on a ProRes source. A separate launch opened the four-camera project. Resolve interchange tests checked generated FCPXML and extracted audio. A fake helper exercised cancellation and timeout without modifying a live Resolve project.

The scene benchmark produced identical reports on all six inputs, including 4K HEVC Main10 and ProRes, and software-decoded FFV1. Wall times varied in both directions. Fresh and sidecar-backed analysis reports also matched for video and standalone audio.

Large successful keyframe gestures validate off the main thread. Some failed-edit diagnostics and final checks for marked-range deletion still run there. The packaged app targets macOS 14, and this run exercised macOS 27.0.1.

## Repeat the checks

Run on Apple Silicon with the development dependencies from the README. The multicam benchmark guide documents the optional fixture environment variables for desktop playback, startup and filmstrips.

```sh
set -e
./scripts/build-app.sh dist/audit
app="$PWD/dist/audit/MPCut.app"
export MPCUT_FFMPEG_HELPER="$app/Contents/Helpers/ffmpeg"
swift test
codesign --verify --deep --strict "$app"
for suite in Tests/Integration/*.py
do
    python3 "$suite" "$app/Contents/Helpers/mpcut"
done
python3 Tests/Packaging/test_build_publication.py
```
