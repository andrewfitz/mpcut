# MPCut release notes

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
