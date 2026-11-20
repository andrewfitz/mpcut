# MPCut

**A native macOS video cutter for Apple Silicon.** Trim clips, remove sections, arrange matching recordings, and export one movie or a batch of clips. The desktop app defaults to **Smart Trim**, which copies compatible video packets and encodes only the cut edges that need it. MPCut keeps the timeline and export queue for the current session, and your source files stay intact.

**[Download MPCut](https://github.com/andrewfitz/mpcut/releases/latest)** · [Full usage guide](docs/USAGE.md) · [Release notes](CHANGELOG.md)

> This README describes **MPCut 1.1.0**. Build from source for Smart Trim, scene scanning, bulk export, and the `rearrange` command. The latest published ZIP is **v1.0.0**. [Build instructions](#build-from-source) · [Published release](https://github.com/andrewfitz/mpcut/releases/tag/v1.0.0)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/timeline-dark.jpg">
  <img src="docs/images/timeline-light.jpg" alt="MPCut showing two clips on the timeline, a marked range, and the preview above it." width="900">
</picture>

## Install

MPCut requires **macOS 14 or later on Apple Silicon**. Download the arm64 ZIP, expand it, and move **MPCut.app** into Applications. To verify the download, put `SHA256SUMS.txt` next to the ZIP and run `shasum -a 256 -c SHA256SUMS.txt`. The published app is ad-hoc signed, so macOS may ask for approval on the first launch. [Release and downloads](https://github.com/andrewfitz/mpcut/releases/latest) · [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445)

## Edit on the timeline

1. **Add clips.** Use **Add Clips** or drop files onto the timeline. Drag matching recordings into playback order. For files with usable duration metadata, the viewer and timeline open while frame and audio indexing runs in the background. Visible thumbnails fill in progressively.
2. **Trim or remove footage.** Drag either handle to trim. Excluded footage stays visible and faded, and you can drag the handle back to restore it. Press **⌘B** to split at the playhead. To remove a section, press **I** at its start, **O** at its end, and **Delete**. Use **Esc** to clear the marks or **⌘Z** to undo an edit.
3. **Choose how to export.** Press **⌘E** to export the retained timeline as one movie. To save several selections as separate files, mark each range with **I** and **O**, then press **⇧⌘A** to queue it. Open **Export Queue** with **⇧⌘E** to review the ranges, choose shared settings, and export numbered files.

The filmstrip supports landscape, portrait, and rotation-tagged footage. Use the zoom controls, **Fit**, and the Small/Large thumbnail button to adjust the timeline. The same size control is in **View → Large Timeline Thumbnails**. Click the time readout to jump to a specific time. **Snap to Keyframes** is optional and places new cuts on verified lossless-copy boundaries.

| Preview action | Shortcut |
| --- | --- |
| Play or pause | Space |
| Shuttle backward, pause, or shuttle forward | J / K / L |
| Move one frame | ← / → |
| Jump to a keyframe | Option–← / Option–→ |
| Jump to a scene after scanning | Shift–← / Shift–→ |

Repeated **J** or **L** presses step through 2×, 4×, and 8× shuttle speeds. Reverse shuttle runs silently. Dragging the playhead plays short audio previews in either direction. The toolbar speaker controls monitoring volume, mute, and scrub audio. The **File**, **View**, **Sequence**, and **Playback** menus expose the same actions. [Desktop controls and shortcuts](docs/USAGE.md#edit-a-sequence)

## Find camera cuts and recurring views

Click **Scan for Scenes** below the timeline or in the **Playback** menu. The scan runs in the background, and MPCut adds colored markers as it finds hard cuts. The scene buttons and Shift–arrow shortcuts activate after the scan when there are cuts or joins to navigate.

Similar shots share a view label such as **A**, **B**, or **AA**. Click the view name in the status bar to give every matching shot a name like **Wide** or **Close-up** for the current session. View groups are estimates based on the picture. A digital punch-in can create a separate view.

Some scene cuts land on existing keyframes. In the multicam fixture, 11 of 12 detected cuts landed on a verified keyframe boundary. In *Tears of Steel*, 59 of 138 detected cuts did. Smart Trim copies video at safe edges. A zero `encodedDuration` in a CLI dry run means the entire video selection can be copied. The export checks audio boundaries separately. [Scene detection benchmark](docs/SCENE-BENCHMARK.md) · [Scene export workflows](#scan-and-export-scenes)

## Export modes

| Mode | What it does |
| --- | --- |
| **Smart Trim** | Keeps the selected frame boundaries and copies compatible packets. It encodes the video edges that need it and reports how much footage will be copied and encoded. |
| **Lossless Copy** | Copies compatible video and audio without encoding. It can switch to another compatible container by remuxing. **Review Cuts** previews proposed changes when a cut is unsafe. |
| **Re-encode** | Converts the retained video with the Mac’s H.264, HEVC, or ProRes hardware encoder. Choose a quality preset and audio handling. |

For Re-encode, H.264 and HEVC can go in MP4, MOV, or MKV. ProRes can go in MOV or MKV. Audio options include Auto, Copy Original, AAC, PCM where supported, and Remove Audio. Auto preserves original audio when the destination and edit support it. [Export settings and limits](docs/USAGE.md#choose-an-export-mode)

## Supported media

| Footage | Editing behavior |
| --- | --- |
| ProRes MOV | Cut on video frames, including standard 422 and 4444 profiles. Linked PCM or AAC audio is checked at each boundary. |
| H.264 and HEVC in MOV or MP4 | Copy at verified boundaries. Smart Trim can hardware-encode the cut edges of compatible footage. |
| VP8, VP9, and AV1 in WebM | Copy compatible streams. Smart Trim can software-encode AV1 cut edges on Macs with hardware AV1 decoding. Discontinuous joins with Opus or Vorbis audio have limits. |
| Other local video | Probe MKV, MPEG-TS, AVI, MXF, and other formats. The streams, chosen ranges, and destination determine eligibility. |

Joining requires matching codec settings, dimensions, frame rate, color information, and audio layout. PCM and AAC audio embedded in supported video files can be preserved. MPCut supports standard ProRes 422 and 4444 families. RAW video, including ProRes RAW, and standalone WAV are outside its supported inputs. [Detailed media support](docs/USAGE.md#media-support) · [Smart Trim requirements](docs/USAGE.md#cut-between-keyframes)

## Command line

The app includes the headless `mpcut` CLI for scripts and agents. With MPCut installed in Applications, set the path once for the examples below. From a source build, the executable is at `dist/MPCut.app/Contents/Helpers/mpcut`.

```sh
mpcut=/Applications/MPCut.app/Contents/Helpers/mpcut
"$mpcut" help --json
"$mpcut" inspect --json --keyframes input.mp4
"$mpcut" inspect --json --frames --from 2 --to 3 input.mp4
```

Use `--frames` for exact presentation timestamps and `--keyframes` for keyframe markers and verified start points. Times accept `MM:SS`, `HH:MM:SS`, decimal seconds, or exact fractions. JSON requests also accept the rational time objects returned by inspection. Each start is inclusive and each end is exclusive. Add `--dry-run --json` to validate cuts and inspect `copiedDuration` and `encodedDuration` before writing.

### Rearrange ranges into one movie

```sh
"$mpcut" rearrange input.mp4 --output reordered.mp4 '23:01-26:12, 03:02-04:03'
```

The list sets playback order. `rearrange` uses Smart Trim and snaps to nearby valid boundaries by default. Use `--snap exact` to require the supplied times. For multiple recordings or programmatic edits, use `export` with repeated `--clip` flags or a JSON request. The optional one-based `order` list lets an agent reorder, repeat, or skip ranges.

```sh
"$mpcut" export --stdin --json --dry-run <<'JSON'
{
  "file": "input.mp4",
  "output": "assembly.mp4",
  "clips": [
    {"from": "10", "to": "15"},
    {"file": "alternate.mp4", "from": "3", "to": "8"},
    {"from": "40", "to": "45"}
  ],
  "order": [3, 1, 2]
}
JSON
```

Remove `--dry-run` to export. An explicit order defaults to Smart Trim. An ordinary `export` defaults to Lossless Copy. Use `--mode smart`, `--mode copy`, or `--mode encode` to choose explicitly. [CLI command and JSON reference](docs/USAGE.md#automate-an-export)

### Export multiple ranges as separate files

```sh
mkdir -p exports
"$mpcut" bulk --stdin --json <<'JSON'
{
  "file": "input.mp4",
  "outputDirectory": "exports",
  "ranges": [
    {"from": "00:10", "to": "00:15"},
    {"from": "01:00", "to": "01:10"}
  ]
}
JSON
```

`bulk` defaults to Smart Trim and writes one numbered file per range. It checks all ranges and destinations before writing and protects existing files. For one combined movie, use `rearrange` or `export`. [Bulk export options](docs/USAGE.md#export-several-timestamp-ranges-with-one-command)

### Scan and export scenes

```sh
"$mpcut" scenes --json montage.mp4 > scenes.json
mkdir -p by-scene by-view
"$mpcut" scenes --stdin --json --export-to by-scene < scenes.json
"$mpcut" scenes --stdin --json --export-to by-view --group-by view < scenes.json
```

The first command writes only a JSON report with exact timestamps, scene numbers, and recurring-view labels. Both exports reuse the saved report. The first export writes one file per scene. The second joins matching scenes in source order, creating one movie per view. To scan and export in a single command, give `scenes` the source filename with `--export-to`. [Scene report fields and dry runs](docs/USAGE.md#detect-scenes-and-recurring-views)

### Re-encode with hardware

```sh
"$mpcut" export --json --mode encode --video hevc --quality balanced \
  --audio auto --output converted.mp4 --clip input.mp4
```

The output extension selects the container. Use `--video h264`, `hevc`, or `prores` and a quality preset that matches the codec. For a container change with compatible streams, use `--mode copy` to remux. JSON results go to standard output and progress goes to standard error. Errors return a nonzero exit status. [Codec, quality, and audio options](docs/USAGE.md#automate-an-export)

## Hardware and performance

MPCut uses VideoToolbox for hardware video decoding where supported, and Metal for filmstrip scaling and rotation. Compatible frames can go from the hardware decoder to the encoder directly. Lossless Copy and the copied parts of Smart Trim move compressed packets without decoding and encoding them again.

### Smart Trim performance

In a test on an M4 Max, the CLI assembled the ranges `23:01-26:12, 03:02-04:03` from a 2.5-hour file. It copied about **249 seconds of video** and encoded **2.68 seconds** at the edges.

In a separate FFmpeg benchmark on the same Mac, Smart Trim handled a 46-second selection **7.1× faster** than a full software AV1 re-encode. Both runs used the same AV1 encoder preset and copied the Opus audio from the same 1080 × 1920 WebM. Times are medians of three warm runs.

| Export | Elapsed time | Output size | Video encoded |
| --- | ---: | ---: | ---: |
| Smart Trim | 2.82 s | 8.38 MB | 6 s |
| Full re-encode | 20.02 s | 9.61 MB | 46 s |

The 1,200 copied pictures matched the source byte-for-byte. MPCut targets the source bitrate around each encoded edge. The 180 edge pictures averaged 92.9/100 VMAF against the decoded source, compared with 93.5 for the same pictures in the full re-encode. Results depend on the source and how much of the selection is safe to copy.

## Build from source

On an Apple Silicon Mac with the Xcode command-line tools, CMake, and pkg-config installed, run these commands from the repository root. The first build downloads and verifies the pinned FFmpeg and SVT-AV1 sources. The resulting bundle includes the native app, CLI, FFmpeg executable and required media libraries.

```sh
./scripts/build-app.sh
open dist/MPCut.app
```

Use `./scripts/build-app.sh /Applications` to install the source build there for the CLI examples above.

For development, install Homebrew FFmpeg and pkg-config, then run `swift test`. The integration suites also use Python 3 and the FFmpeg CLI tools. [Test commands and qualification limits](AUDIT.md#reproduce-the-release-checks)

## Verified on Apple Silicon

On an M4 Max Mac Studio, the GUI and CLI produced byte-identical files for the same three-source timeline edit. An export from three original ARRI ALEXA XT recordings retained all 769 expected ProRes packets and 1,476,480 stereo PCM sample frames in sequence. Tests also covered all six supported ProRes profiles, H.264 and HEVC splice boundaries, and hardware preview of VP9 and AV1 WebM.

A warm-cache benchmark assembled 6.49 GB of 4K ProRes 4444 footage in a median 4.40 s across three runs. A buffered read/write copy of the same number of bytes on the same internal SSD took 3.83 s. The benchmark reused one clip and did not force a storage flush. Performance varies with media, cache state, and storage.

The release includes FFmpeg notices, corresponding source, and the build recipe. The screenshot uses MDN’s flower sample. [FFmpeg notice](packaging/FFmpeg-Notice.txt) · [Sample footage](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/video#try_it)
