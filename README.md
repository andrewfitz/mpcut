# MPCut

Trim, remove a section, or join matching camera clips on an Apple Silicon Mac. By default, MPCut copies the retained picture and audio samples into a new movie without re-encoding. Turn on **Smart Trim** for a frame-accurate cut between keyframes on compatible footage. MPCut encodes the frames needed at each cut and copies the rest. One timeline holds the edit until you export and close the window.

**[Download MPCut for Apple Silicon](https://github.com/andrewfitz/mpcut/releases/latest)** · [Usage and keyboard shortcuts](docs/USAGE.md) · [Release notes](CHANGELOG.md)

The download is version 1.0.0. To try Smart Trim and reversible trim handles before the next release, [build the app from source](#build-from-source).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/timeline-dark.jpg">
  <img src="docs/images/timeline-light.jpg" alt="MPCut showing two clips on the timeline, a marked range, and the preview above it." width="900">
</picture>

## Install and make a cut

1. Download the macOS arm64 ZIP from the release, expand it, and drag **MPCut.app** into Applications.
2. Click **Add Clips** or drop matching files into the window. Drag clips into order and trim their edges. To remove a section, mark its start with **I**, its end with **O**, and press **Delete**.
3. Click **Export** and choose a new filename. Your source files stay intact.

MPCut targets macOS 14 or later on Apple Silicon. This release is ad-hoc signed and has no Apple notarization ticket. macOS may ask for approval on first launch. [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445)

## Formats

| Footage | Editing behavior |
| --- | --- |
| ProRes MOV | Cut on video frames, including standard 422 and 4444 profiles. Linked PCM or AAC audio is checked at each boundary. |
| H.264 and HEVC in MOV or MP4 | Copy at verified boundaries. Smart Trim can hardware-encode the cut edges of compatible footage. |
| VP8, VP9 and AV1 in WebM | Copy compatible streams. Smart Trim can software-encode AV1 cut edges. Discontinuous joins with Opus or Vorbis audio have limits. |
| Other local video | Probe MKV, MPEG-TS, AVI, MXF, and other formats. The streams, chosen ranges, and destination determine eligibility. |

Clips in a sequence need matching codec settings, dimensions, color information, and audio layout. Hardware preview depends on the stream and the Mac. RAW video, including ProRes RAW, and standalone audio editing are outside the supported formats. [Detailed media support](docs/USAGE.md#media-support)

## Smart Trim performance

On an M4 Max, Smart Trim exported a 46-second selection **7.1× faster** than a full AV1 re-encode. The source was a 51.63-second, 1080 × 1920, 30 fps WebM (9.09 MB). Both exports kept the same range from 0:03 to 0:49, used the same AV1 encoder preset and copied the Opus audio. Times are medians of three runs after warm-up.

| Export | Elapsed time | Output size | Video encoded |
| --- | ---: | ---: | ---: |
| Smart Trim | 2.82 s | 8.38 MB | 6 s |
| Full re-encode | 20.02 s | 9.61 MB | 46 s |

All 1,200 frames in the middle matched the source byte-for-byte. Smart Trim encoded the 180 edge frames using the video bitrate measured around each cut. Those frames averaged 92.9/100 VMAF against the decoded source, compared with 93.5 for the same frames in the full re-encode. New keyframes can increase the size of very short cuts. The speedup depends on how much of the selection can be copied.

## Command line

The app includes a headless CLI for scripts and agents. With MPCut in Applications, this example checks a two-clip join in playback order.

```sh
mpcut=/Applications/MPCut.app/Contents/Helpers/mpcut
"$mpcut" --version
"$mpcut" export --json --dry-run --output "Assembly.mov" \
  --clip "Take 2.mov" --clip "Take 1.mov"
```

Omit `--dry-run` to write the movie. Add `--smart-trim` to permit encoding at video cut edges. For trims, supply per-clip timestamps as decimal seconds, clock time, or exact fractions. The CLI also accepts a JSON edit on stdin. [CLI examples](docs/USAGE.md#automate-an-export)

## Build from source

On an Apple Silicon Mac with the Xcode command-line tools, CMake, and pkg-config installed, run these commands from the repository root. The first build downloads and verifies the pinned FFmpeg and SVT-AV1 sources. The resulting bundle includes the native app, CLI, and required media libraries.

```sh
./scripts/build-app.sh
open dist/MPCut.app
```

For development, install Homebrew FFmpeg and pkg-config, then run `swift test`. The media integration suites also use Python 3 and the FFmpeg CLI tools. [Test commands and qualification limits](AUDIT.md#reproduce-the-release-checks)

## Verified on Apple Silicon

On an M4 Max Mac Studio, the GUI and CLI produced byte-identical files for the same three-source timeline edit. An export from three original ARRI ALEXA XT recordings retained all 769 expected ProRes packets and 1,476,480 stereo PCM sample frames in sequence. Tests also covered all six supported ProRes profiles, H.264 and HEVC splice boundaries, and hardware preview of VP9 and AV1 WebM.

A warm-cache benchmark assembled 6.49 GB of 4K ProRes 4444 footage in a median 4.40 s across three runs. A buffered read/write copy of the same number of bytes on the same internal SSD took 3.83 s. The benchmark reused one clip and did not force a storage flush. Performance varies with media, cache state, and storage.

The release includes FFmpeg notices, corresponding source, and the build recipe. The screenshot uses MDN’s flower sample. [FFmpeg notice](packaging/FFmpeg-Notice.txt) · [Sample footage](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/video#try_it)
