# MPCut release audit

Reviewed the native editor, both hardware-preview paths, media inspection, cut planning, packet writing, CLI, and standalone app build. The design review covered the empty window, an assembled sequence, keyboard navigation, and the save workflow.

| Area | Corrected behavior | Evidence |
| --- | --- | --- |
| Interface | The empty window offers Add Clips and Add as Multicam. The loaded editor uses a native toolbar, named edit controls, and visible trim grips. | Reviewed running app windows with footage and exercised the controls through macOS accessibility. |
| Editing | Exact sequence offsets drive frame stepping at joins. Equal marks protect the selected clip from accidental deletion. Undo restores the marked edit. | Editor model tests with a fractional-frame-rate ProRes fixture, plus live reorder, trim, split, delete, undo, export, and cancellation. |
| Preview | Native and fallback players share cut times. Seeking accounts for the source video origin, decoder preroll, and the exclusive end of a trim. | Hardware playback on an M4 Max using H.264, HEVC Main10, VP9 and AV1. Additional checks covered rotated VFR footage, rapid seeks, and audio timing. |
| Export | Reordered VFR pictures respect the presentation duration. MOV copies retain audio that leads or extends beyond the picture. AAC edit lists retain supported silent intervals across export and reimport. | Compared packet hashes, decoded frames, audio samples, and timestamps. Checked an original Canon EOS 6D recording and an iPhone camera recording. |
| Compatibility | The app checks WebM alpha at cut points, distinguishes RGB AVC, and detects reordered language tracks. Dry run checks timecode and destination clock limits. | Fixtures include transparent VP9, RGB AVC, swapped audio tracks, RAW exclusion, and ranges the target container cannot express. |
| Automation | Unknown JSON fields identify the offending key and clip before export. | Tested direct arguments, JSON stdin, nonzero source timestamps, and interrupted input and export. |
| Packaging | The relocated arm64 app loads its bundled media libraries with a system-only PATH. | Verified the signature, library paths, and a relocated CLI export. A simulated signing failure preserved the previous bundle. |

## Timeline and analysis sidecar follow-up

| Reproduced defect | Verification |
| --- | --- |
| Deleting a marked range or trimming to the playhead could move a freely placed cut to a distant snap target. Grabbing the playhead off-center could move it on mouse-down. | Editor and AppKit gesture tests check the resulting clip bounds, filmstrip geometry and playhead position. |
| A quick reopen or quit could race queued metadata writes. A later manual save could overwrite newer view names or thresholds from another editor. | Two-editor and immediate-reopen tests check the values read back from disk. |
| Concurrent repairs could drop completed sidecar sections, and a lower-resolution waveform could replace a finer overview. | Concurrent writer tests check the final section inventory and waveform resolution. |
| A four-second WebM could get a scene report ending at its one-second preview estimate. Some fresh scans never reported completion. | Scene tests compare the report to the indexed duration and check progress through completion. |
| A transient just before 60 ms in a 48 kHz Matroska file appeared in different waveform and silence-analysis bins. | A generated impulse checks the decoded sample position. Legacy-cache tests check which results need recomputing. |
| A first Re-encode preflight or CLI waveform query could discard its index, forcing a subsequent operation to read the source again. | Cold-start tests query the resulting sidecar and check the explicit cache bypass. |

The audited build passed 147 Swift tests and 205 CLI integration cases. In the packaged app, a 2 h 26 min movie reached 8,192× timeline zoom. Command-W returned the same window to the file picker. Reopening reused its index and left the scene inventory empty until a scan was requested.

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

## Waveform and pause editing

The pause-edit audit covered source-to-timeline mapping, threshold changes, copy-safe edge selection, and AAC presentation edits. The desktop tests exercise seeking and scrubbing a shortened waveform, reviewing successive joins, forward playback skipping, and undo. They also cover an unchanged pause across a straight split, protection after its detected edges move, and equal In/Out marks.

On an M4 Max, the release CLI indexed a one-hour synthetic H.264/stereo AAC MP4, detected 359 pauses, and emitted a 512-column waveform in 1.10 seconds, the median of three warm runs. The 44.8 MB input used a static 320 × 96 picture at 25 fps and 48 kHz audio. Larger video streams and slower storage can change scan time.

A five-minute H.264/PCM test recording contained 30 qualifying pauses. Lossless Copy removed 60 seconds. All 6,000 retained video packet hashes matched the source in order. The CLI tests compare the decoded PCM on two linked tracks with the retained source samples in both Smart Trim and Lossless Copy. A separate test reopens an edited AAC MOV and checks all 400 waveform bins against the native decoder, including the movie’s explicit silent intervals.

Automatic calibration selected −84 dBFS for a 30-second synthesized speech recording and −28 dBFS for the same speech mixed with fan hum and noise. Both yielded five pauses, including one uninterrupted pause around an isolated 20 ms click. The audit also checked a short utterance surrounded by room tone, an unusually quiet introduction, and repeated clicks. With automatic calibration enabled, the signed CLI processed the one-hour fixture above and emitted a 512-column waveform in 1.00 seconds on the median of three warm runs.

## Shared sidecars and JPEG review

On the 12:14 H.264 *Tears of Steel* recording, the signed CLI built the edit index, scene cuts, and audio analysis in 3.30 s. The sidecar occupied 676 KiB. These query timings include startup and JSON output. Each value is the median of three alternating runs after warm-up on the M4 Max. Each pair returned identical JSON.

| Query | Fresh analysis | With sidecar |
| --- | ---: | ---: |
| All 139 scenes | 2.805 s | 0.012 s |
| Frame index for the first second | 0.071 s | 0.019 s |
| Silence report | 0.475 s | 0.020 s |
| Silence report and 512 waveform bins | 0.476 s | 0.021 s |

The 12-image JPEG overview covered the full recording in 353 KB. On a separate montage, two ranges selected from a JPEG manifest and placed in reverse order produced a 113-frame Smart Trim movie. All 113 compressed picture hashes matched the requested source ranges in order. The desktop smoke test exercised Settings, both scan controls, saving, and reopening the media with its completed analyses.

To repeat the sidecar measurements on local footage, run `python3 Tests/Benchmarks/analysis_sidecar.py dist/MPCut.app/Contents/Helpers/mpcut /path/to/video.mov`. The benchmark builds a sidecar next to a temporary copy of the input.

## Standalone audio and track copy

On a one-hour 48 kHz stereo AAC recording (41.4 MB), the signed CLI built a 3.5 MiB analysis sidecar in 1.96 s. Generating 1,024 signed waveform columns took 0.988 s fresh and 0.013 s with the sidecar. A 100 ms detail window halfway through the file took 0.021 s with the saved index. Fresh and cached JSON matched for both queries. Timings include process startup and use the median of three alternating runs after warm-up on the M4 Max. Reproduce with the sidecar benchmark above using an audio input.

In the running app, a 44.1 kHz, 24-bit WAV displayed a 10 ms waveform window while the timeline showed the complete recording. Saving the WAV from the native export panel preserved all 529,200 stereo sample pairs. Another editor test restored a sidecar, reordered audio, queued a range across the join, and matched all 1,054 output samples per channel to the source.

Independent CLI tests compared stream packet hashes and decoded samples. A mixed sound edit using audio from a movie and a standalone WAV preserved all 13,230 expected stereo sample pairs. Replacing one track in a multilingual recording preserved the target track’s 375 ms start offset, the other audio track, and the encoded video. The replacement tests also compare native AAC presentation after reordering and inspect retained stream language and disposition.

Across 84 standalone MP3 cuts at different sample rates and bitrates, 80 preserved the compressed audio packets and decoded to the requested samples. Four VBR cuts required more decoder history than the MP3 gapless header can represent and were rejected. A playback audit compared 205 seek windows across original and cropped MP3s, including MPEG-2, MPEG-2.5, and 8 kbps recordings. The editor's decoder matched the reference stereo samples throughout.

## Independent audit of editing and analysis

The waveform checks compare individual PCM samples across decoder packet boundaries and at one-sample gaps. On a 659 MiB one-hour PCM WAV, reading a one-second waveform window halfway through the file took 30 ms with a validated byte seek, compared with 295 ms using the generic seek. Both returned byte-identical JSON over eight paired runs on the M4 Max. The scene checks compare full-range H.264 and MJPEG versions of the same luminance changes. JPEG checks use two different pictures with the same presentation timestamp and a third with a unique timestamp. An ambiguous request returns an error before the image directory is published. The uniquely timed picture still exports.

A separate end-to-end check used a movie with two stereo PCM tracks. It compared a saved silence report with fresh analysis, replayed its retained ranges, checked reordered samples byte for byte, and verified that the non-silent JPEGs fell within their manifest ranges. After audio replacement, the original video packets and untouched soundtrack packets matched by SHA-256, and the replacement decoded to the supplied samples.

The packaged CLI’s per-command help was checked against its command index. All 38 help examples ran against generated movie, standalone audio, and multicam project fixtures. A separate export test fed the filesystem path from an inspection report directly into an edit request and verified a filename containing spaces. The bundled manual was read through a CLI symlink. On a fresh launch, the accessibility check found **Add Clips…** and **Add as Multicam…** side by side. Choosing two camera files from the multicam button opened setup and created both camera lanes. The Help menu exposed the user guide and release notes. Opening **About MPCut** through the running app’s menu showed the matching 1.2.0 version, guide, release notes, credits, and CLI-path control.

## Editor windows and progressive opening

The signed app opened two multicam documents in separate windows. With the second window active, Mark In and Undo changed only its edit. Closing that window preserved the first project’s marks, undo state, and playhead. Opening media from a multicam window created a separate ordinary timeline. Reopening an existing project selected its open window.

Tests cover publication of a saved project before media inspection finishes, decoding a picture with a provisional clock, and source identity checks before exact export. A hosted timeline test uses native drag events to trim and reorder repeated assembly ranges, then verifies the edit and undo. The eight-session startup benchmark records model construction, first-picture times, peak process memory, and idle CPU. [Startup benchmark and measurement limits](docs/MULTICAM-BENCHMARK.md#mixed-session-startup)

## Multicam export and playback

The multicam fixtures exercise a continuous external WAV, following each camera’s microphone, per-marker overrides, delayed AAC, and repeated highlights. The tests compare decoded samples and video packet payloads, check the exact output timestamps, and verify that a preflight failure leaves the destination untouched. A separate four-camera benchmark measures preflight, export, and aligned frame review. [Multicam benchmark](docs/MULTICAM-BENCHMARK.md)

In the desktop editor, a two-camera project switched at exactly 2 and 4 seconds, saved, closed and reopened. Its desktop and CLI Smart Trim exports were byte-identical. Independently decoding the result verified all 200 pictures and all 384,000 samples of the fixed master WAV. The signed app also exported H.264/AAC after Re-encode preflight, preserving both camera changes. Sound-only WAVE export reproduced every master sample.

## Release audit regressions

- An audio-only movie export with AC-3 was checked against its requested end even when the soundtrack extended beyond the picture. Matroska PCM and FLAC tests measured the last ten samples of a 44,111-sample source, including after an index reload. A separate AAC test compared the converted range against a continuous decode on a millisecond container clock.
- Desktop track selection and queued exports were exercised across compatible movies with different absolute audio-stream positions. The decoded WAV samples identify which microphone was actually exported.
- Multicam tests reopened a project through a directory symlink, relinked a missing recording, switched from an omitted interval into assembly preview, and split the active occurrence of a repeated range. Each suggested switch time was preflighted against the retained occurrences.
- Picture checks compared the selected frame's PTS with the displayed frame on a delayed ProRes MOV, review JPEG detail on anamorphic FFV1, and hardware/software color on equivalent untagged pictures. The build test ran two checkouts with one publication destination and verified that the second preserved the first checkout’s active stage.

The multicam desktop audit reproduced a blank fourth large filmstrip using four full-length H.264 recordings. The corrected editor displayed the fourth recording during indexing and after all four indexes completed. In the signed build, clicking Camera 4 at 0.100 seconds created a switch there. Split created adjacent assembly ranges at the same time. Undo restored the opening camera and the original range in their respective checks. Dragging the track divider preserved the timeline’s right edge, and Zoom and Fit doubled and restored the ruler width. The silence controls shortened two pauses by 3.1 seconds, and Undo restored the assembly. The CLI tests include a continuous pause across different microphones, repeated assembly occurrences, uncovered audio, and fractional-frame cuts with copied 48 kHz audio.

The fresh multicam audit compared fixes against the previous code. It reproduced silent replacement of a queued camera recording during indexing, an unintended camera switch just before the exclusive group endpoint, and seeks landing in the wrong occurrence of a repeated range. Separate media tests verified byte-identical copies of healthy audio tracks alongside damaged tracks and exact PCM samples after seeking in 44.1 and 48 kHz Matroska exports. Routed silence tests used a microphone switch just before a speech onset and a short isolated noise surrounded by quiet. The former preserved speech and the latter remained a single pause. Desktop checks covered cancelling and retrying a silence scan, releasing idle filmstrip decoders, and closing a project during export.

## Reproduce the release checks

MPCut 1.2.0 passed 302 Swift tests with both desktop performance tests enabled, 281 CLI integration tests, and the shared-destination packaging test. The Smart Trim suite checks frame order at splices, copied video and audio payloads, source-derived edge bitrates, and output size on low-bitrate AV1 footage. Conversion tests decode hardware H.264, HEVC and ProRes outputs and check picture order, VFR timing, portrait orientation, linked audio, cancellation and unavailable encoders. The scene suite checks exact scene reports, reuse without rescanning, and Smart Trim exports grouped by view. The audio checks include silent MOV edits and six-channel AAC ordering. The sidecar and JPEG suites exercise shared writes, stale sources, interrupted exports, variable frame timing, rotation, and changes in picture size.

Selecting the seventh clip in an eight-clip 29.97 fps timeline landed at exactly 2.4024 s. Splitting there preserved the existing join. A six-second portrait WebM with Opus preroll converted to HEVC/AAC MP4 with 180 video frames and 288,000 decoded samples per channel. Additional checks covered alpha in HEVC, QuickTime Animation, PNG and FFV1, plus MKV duration after copying a cropped Opus track.

A pointer drag in the running editor placed the same right handle at 3.292 s with snapping off and 4.000 s with snapping on. The preview showed the last retained frame in each case. A separate GUI export kept 191 of 192 frames. Reviewing a proposed Lossless Copy adjustment and undoing it restored the original cut.

In the running app, a split from the same 12.000 s playhead landed at 11.367 s with **Snap To → Scenes** and 13.000 s with **Snap To → Silence**, matching the CLI reports. Tests also exercised a trimmed clip with a hidden scene, repeated footage after reordering, undo after removing the last clip, and changing the active audio track.

Reverse shuttle was checked using a different frequency sweep in each stereo channel on H.264/AAC MOV and VP9/Opus WebM. The tests rendered the actual audio output at 1×, 2×, 4× and 8× over a reordered join. They measured playback direction and channel identity, checked for 4 ms dropouts, compared the picture clock to the rendered samples, and exercised seeking, mute and switching to forward playback.

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
python3 Tests/Integration/silence.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/sidecar.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/frames.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/audio_tracks.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/audio_copy_edges.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/replace_audio.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/waveform.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/reencode.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/multicam.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/multicam_audio_convert.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/multicam_fidelity.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/multicam_frames.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/audit_fixes_cli.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/audit_fixes_probe.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/audit_fixes_writer.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/audit2_multicam_cli.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/audit2_multicam_core.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/audit2_probe.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Packaging/test_build_publication.py
```

## Qualification limits

Runtime testing used macOS 27.0.1. The binaries target macOS 14. The app checks preview support on the actual Mac. Discontinuous Opus or Vorbis joins, unsupported timecode alignments, and unrepresentable audio intervals return errors before writing. When a clip starts at its first coded AAC packet, the player has no earlier packets to initialize the decoder. On one such join, AVFoundation produced a brief change in the decoded waveform while preserving sample count and timing.

Third-party players differ in their handling of gapless playback metadata. On one reordered AAC file, AVFoundation rendered the intended 107,110 samples and FFmpeg rendered 443 fewer. On lower-rate MP3 fixtures, Apple's native readers could ignore the gapless bounds on both the original and the export. The editor uses its bundled decoder for standalone MP3 playback.

The UI design follows Apple's guidance on content-focused windows, toolbars, and keyboard access. The running editor was checked with two clips and a marked range in both Light and Dark appearances. [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) · [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
