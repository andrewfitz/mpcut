# MPCut release notes

## Unreleased

- **Frame-accurate Smart Trim.** Cut between keyframes on compatible progressive 8-bit SDR video. MPCut uses hardware encoding for H.264 and HEVC edges in MOV or MP4, and software encoding for AV1 edges in WebM or MKV on Macs with hardware AV1 decoding. The export panel shows how many frames need encoding and their combined duration.
- **Source-matched edge bitrate.** Each edge targets the video bitrate measured in nearby source frames, including when the file has no bitrate tag. On a 46-second AV1 cut, Smart Trim took 2.82 s and produced 8.38 MB. A full re-encode took 20.02 s and produced 9.61 MB. [Benchmark conditions](README.md#smart-trim-performance)
- **CLI preflight.** Pass `--smart-trim --dry-run --json` to see each edge’s timestamps, frame count, and target bitrate before exporting.
- **Reversible trim handles.** The filmstrip keeps excluded footage visible and faded. Drag either handle back to restore frames.
- **Timeline navigation.** Dedicated buttons step through frames or jump between keyframes. In and Out marks show their times on the timeline. Pressing Delete with only one mark set prompts for the other mark and protects the selected clip.
- **Faster thumbnails.** Filmstrips reuse indexed frames, skip audio decoding, and share cached thumbnails across split clips.
- Updated the app icon.

## 1.0.0

First public release for Apple Silicon Macs running macOS 14 or later.

- **Edit on one timeline.** Add and reorder compatible recordings, trim clip edges, split at the playhead, and delete a marked range. The timeline includes frame stepping, keyframe navigation, and editable time.
- **Export without re-encoding.** Copy retained video and audio samples into a new file. MPCut checks clip compatibility, cut boundaries, and the output container. Standard ProRes supports cuts on every picture. H.264 and HEVC require verified splice points.
- **Preview on the Mac.** The app uses hardware decoding when the Mac supports the video stream. Eligible exports can also run headlessly.
- **Automate edits.** The bundled `mpcut` CLI inspects files, accepts ordered clips and exact timestamps, reads JSON on stdin, and supports dry runs. Use `mpcut --version` to identify the installed release.

### Installation

Download `MPCut-1.0.0-macOS-arm64.zip`, expand it, and move MPCut.app into Applications. To verify the download, place `SHA256SUMS.txt` beside the ZIP and run `shasum -a 256 -c SHA256SUMS.txt` in that directory. The app is ad-hoc signed and has no Apple notarization ticket.

### Compatibility

Joining requires matching streams. RAW video and standalone WAV files are excluded. PCM embedded in supported movies is preserved. WebM supports whole-file copies and verified cuts, with restrictions on discontinuous Opus and Vorbis audio. Runtime qualification used an M4 Max on macOS 27.0.1.
