# MPCut release audit

Reviewed the native editor, both hardware-preview paths, media inspection, cut planning, packet writing, CLI, and standalone app build. The design review covered the empty window, an assembled sequence, keyboard navigation, and the save workflow.

| Area | Corrected behavior | Evidence |
| --- | --- | --- |
| Interface | The empty window offers one import action. The loaded editor uses a native toolbar, named edit controls, and visible trim grips. | Reviewed running app windows with footage and exercised the controls through macOS accessibility. |
| Editing | Exact sequence offsets drive frame stepping at joins. Equal marks protect the selected clip from accidental deletion. Undo restores the marked edit. | Editor model tests with a fractional-frame-rate ProRes fixture, plus live reorder, trim, split, delete, undo, export, and cancellation. |
| Preview | Native and fallback players share cut times. Seeking accounts for the source video origin, decoder preroll, and the exclusive end of a trim. | Hardware playback on an M4 Max using H.264, HEVC Main10, VP9 and AV1. Additional checks covered rotated VFR footage, rapid seeks, and audio timing. |
| Export | Reordered VFR pictures respect the presentation duration. MOV copies retain audio that leads or extends beyond the picture. AAC edit lists retain supported silent intervals across export and reimport. | Compared packet hashes, decoded frames, audio samples, and timestamps. Checked an original Canon EOS 6D recording and an iPhone camera recording. |
| Compatibility | The app checks WebM alpha at cut points, distinguishes RGB AVC, and detects reordered language tracks. Dry run checks timecode and destination clock limits. | Fixtures include transparent VP9, RGB AVC, swapped audio tracks, RAW exclusion, and ranges the target container cannot express. |
| Automation | Unknown JSON fields identify the offending key and clip before export. | Tested direct arguments, JSON stdin, nonzero source timestamps, and interrupted input and export. |
| Packaging | The relocated arm64 app loads its bundled media libraries with a system-only PATH. | Verified the signature, library paths, and a relocated CLI export. A simulated signing failure preserved the previous bundle. |

## Playback and editing performance

Measured on an M4 Max. The figures below isolate different operations and use different fixtures.

| Operation | Before | After | Scope |
| --- | ---: | ---: | --- |
| Prepare six timeline cut-boundary lists | 119.53 ms | 2.91 ms | Indexed 108,000-frame ProRes source. Median of seven warm runs, excluding indexing. |
| Seek to a keyframe in paused AV1 preview | 489 ms | 3 ms | One seek to 5.733 s in a 1080 × 1920 WebM. Median of five warm decoder runs. The decoder went from 173 pictures and 286 audio buffers to one picture and zero audio buffers. |
| Inspect keyframes from the CLI | 277.9 MB | 57.3 MB | Median peak resident memory over three runs on 108,000 ProRes frames. |
| Write twelve one-second ranges from a ten-minute VP9 WebM | 69.6 ms | 7.48 ms | Writer only. Median of five warm runs with identical output packet payloads and timestamps. |

The portrait UI check used red and blue bands at opposite ends of the source frame. Both bands remained visible across the filmstrip for native portrait H.264, rotation-tagged H.264 and portrait AV1, including a minimum-window-size check on H.264. The previous filmstrip cropped both bands. An AppKit test also moved the playhead through 60 updates without invalidating the filmstrip. In the running app, removing the first 1.25 seconds of an eight-second portrait clip produced a 162-frame, 6.750-second H.264 movie.

In a Re-encode test with 768 consecutive one-frame ranges from one 320 × 96 source, sharing a decoder across adjacent ranges reduced peak resident memory from 1.54 GB to 115 MB. The export took 2.95 s before and 1.14 s after in one comparison. Decoded video frame hashes and timestamps matched. This test measures the cost of keeping many adjacent splits in an edit.

A 12-second 3840 × 2160 H.264 test pattern at 30 fps was converted to HEVC with Balanced quality and audio removed. On the M4 Max, process CPU time for the CLI and its children fell from 4.32 s to 0.39 s. Elapsed time was 4.07 s before and 4.12 s after. Values are medians of three alternating runs after warming both builds. The encoder received VideoToolbox surfaces directly, and the decoded frame hashes matched across all 360 frames. Additional checks covered full-range black and white levels, a 10-bit PQ ramp, and a rotation-tagged source with non-square pixels.

On a four-second 1280 × 720 H.264/AAC MOV, Re-encode reduced intermediate media from 1,497,008 bytes to zero when keeping all audio. A two-second trim reduced staging from 713,943 bytes to 18,890 bytes. Both comparisons matched the previous build’s compressed audio payloads, timestamps and decoded samples. Native and WebM preview checks compare forward and reverse stereo samples and exercise mute, gain and stopping through the audio engine’s offline output.

## Reproduce the release checks

MPCut 1.1.0 passed 47 Swift tests. The signed app bundle also passed 102 integration tests. The Smart Trim suite checks frame order at splices, copied video and audio payloads, source-derived edge bitrates, and output size on low-bitrate AV1 footage. Conversion tests decode hardware H.264, HEVC and ProRes outputs and check picture order, VFR timing, portrait orientation, linked audio, cancellation and unavailable encoders. The scene suite checks exact scene reports, reuse without rescanning, and Smart Trim exports grouped by view. The audio checks include silent MOV edits and six-channel AAC ordering.

Selecting the seventh clip in an eight-clip 29.97 fps timeline landed at exactly 2.4024 s. Splitting there preserved the existing join. A six-second portrait WebM with Opus preroll converted to HEVC/AAC MP4 with 180 video frames and 288,000 decoded samples per channel. Additional checks covered alpha in HEVC, QuickTime Animation, PNG and FFV1, plus MKV duration after copying a cropped Opus track.

A pointer drag in the running editor placed the same right handle at 3.292 s with snapping off and 4.000 s with snapping on. The preview showed the last retained frame in each case. A separate GUI export kept 191 of 192 frames. Reviewing a proposed Lossless Copy adjustment and undoing it restored the original cut.

Run on Apple Silicon with the Xcode tools, CMake, pkg-config, Python 3, and FFmpeg CLI tools. Development builds also use the FFmpeg development libraries described in the README.

```sh
swift test
./scripts/build-app.sh
codesign --verify --deep --strict dist/MPCut.app
python3 Tests/Integration/media_regression.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/audit_writer.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/smart_trim.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/export_modes.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/scenes.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/reencode.py dist/MPCut.app/Contents/Helpers/mpcut
```

## Qualification limits

Runtime testing used macOS 27.0.1. The binaries target macOS 14. The app checks preview support on the actual Mac. Discontinuous Opus or Vorbis joins, unsupported timecode alignments, and unrepresentable audio intervals return errors before writing. When a clip starts at its first coded AAC packet, the player has no earlier packets to initialize the decoder. On one such join, AVFoundation produced a brief change in the decoded waveform while preserving sample count and timing.

The UI design follows Apple's guidance on content-focused windows, toolbars, and keyboard access. The running editor was checked with two clips and a marked range in both Light and Dark appearances. [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) · [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
