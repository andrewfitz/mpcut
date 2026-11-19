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
| Packaging | The release build works from a checkout with spaces using a system-only PATH. The relocated arm64 app loads its bundled media libraries. | Verified the signature, library paths, and a relocated CLI export. A simulated signing failure preserved the previous bundle. |

## Reproduce the release checks

The audited build passed six Swift tests and 32 integration tests. The integration suites ran against the helper inside the signed app bundle.

Run on Apple Silicon with the Xcode tools, Python 3, and FFmpeg CLI tools. Development builds also use the FFmpeg development libraries described in the README.

```sh
swift test
./scripts/build-app.sh
codesign --verify --deep --strict dist/MPCut.app
python3 Tests/Integration/media_regression.py dist/MPCut.app/Contents/Helpers/mpcut
python3 Tests/Integration/audit_writer.py dist/MPCut.app/Contents/Helpers/mpcut
```

## Qualification limits

Runtime testing used macOS 27.0.1. The binaries target macOS 14. The app checks preview support on the actual Mac. Discontinuous Opus or Vorbis joins, unsupported timecode alignments, and unrepresentable audio intervals return errors before writing. When a clip starts at its first coded AAC packet, the player has no earlier packets to initialize the decoder. On one such join, AVFoundation produced a brief change in the decoded waveform while preserving sample count and timing.

The UI design follows Apple's guidance on content-focused windows, toolbars, and keyboard access. The running editor was checked with two clips and a marked range in both Light and Dark appearances. [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) · [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
