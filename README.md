# MPCut

**MPCut edits video and audio on Apple Silicon Macs.** Trim a recording, rearrange clips, or export several cuts as separate files. The default video mode, **Smart Trim**, copies the original video and re-encodes frames around a cut when needed. Each export goes to a new file.

**[Download MPCut](https://github.com/andrewfitz/mpcut/releases/latest)** · [Make your first cut](docs/USAGE.md#make-your-first-cut) · [User manual](docs/USAGE.md) · [CLI guide](docs/CLI.md) · [Agent guide](docs/MCP-AGENT-GUIDE.md) · [Headless editing](docs/HEADLESS.md) · [Release notes](CHANGELOG.md)

> This README describes the **2.0.0 source build**. Check **MPCut → About MPCut** or run `mpcut --version` to identify your installed build. The downloads page lists the published versions. [Build from source](#build-from-source) · [Downloads](https://github.com/andrewfitz/mpcut/releases)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/timeline-dark.jpg">
  <img src="docs/images/timeline-light.jpg" alt="MPCut showing two clips on the timeline, a marked range, and the preview above it." width="900">
</picture>

## What you can edit

| Task | Workflow |
| --- | --- |
| Cut a recording or assemble selects | [Name and apply source ranges](docs/USAGE.md#edit-a-sequence), [apply a CSV cut list](docs/USAGE.md#apply-csv-cut-points-to-a-clip), or [inspect and revise queued excerpts](docs/USAGE.md#export-several-ranges-from-the-timeline). |
| Edit an interview by ear or by word | [Audition and shorten pauses](docs/USAGE.md#find-and-shorten-pauses), [find another reading, assemble quotes or export captions](docs/TRANSCRIPTS.md). |
| Switch cameras and route sound | [Align cameras, mix microphone tracks, sync replacement audio and build a multicam assembly](docs/USAGE.md#edit-a-multicam-project). |
| Add artwork or leave space between clips | [Cover picture while sound continues, insert a silent card or add timed gaps](docs/STILL-IMAGES.md). |
| Edit a camera multiview or recorded call | [Detect feed boxes, extract a camera or compose a two-up interview](docs/PARTICIPANTS.md). |
| Recover missing or moved recordings | [Relink offline media, search a folder or replace a source file with a preview of the changes](docs/USAGE.md#missing-and-moved-media). |
| Find shots or compare angles | [Detect scene changes and recurring views](docs/USAGE.md#detect-scenes-and-recurring-views) or [export review JPEGs](docs/USAGE.md#review-a-recording-with-jpegs). |
| Edit or replace a soundtrack | [Trim audio on the waveform, extract individual tracks, convert a recording or return a processed mix](docs/USAGE.md#edit-audio-and-export-tracks). |
| Deliver media or an editable project | [Choose a copy or encoding mode](docs/EXPORT-MODES.md), [exchange timelines with another editor](#convert-projects), or [automate exports from the CLI](docs/CLI.md). |

## Install

MPCut requires **macOS 14 or later on Apple Silicon**. Download the arm64 ZIP, expand it, and move **MPCut.app** into Applications. To verify the download, put `SHA256SUMS.txt` next to the ZIP and run `shasum -a 256 -c SHA256SUMS.txt`. The published app is ad-hoc signed, so macOS may ask for approval on the first launch. [Release and downloads](https://github.com/andrewfitz/mpcut/releases/latest) · [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445)

The **Help** menu opens the bundled **MPCut User Guide** (⌘?) and **Release Notes** offline. **MPCut → About MPCut** also shows the installed version, documentation, credits, and a **Copy CLI Path** button.

## Control open projects from an agent

Edit from Claude Desktop, ChatGPT Desktop (Work and Codex), Grok or Grok Bot using the MPCut connector for your host. [Desktop setup and example editing requests](docs/DESKTOP-PLUGINS.md)

Open **Settings → General → Automation** and enable local MCP control. Configure your agent’s stdio server to launch `/Applications/MPCut.app/Contents/Helpers/mpcut-mcp` or the helper from the app bundle you have open. Ask the agent to list open projects, inspect the timeline and split a specific clip. Edits use the GUI’s native history, including its retention limit. Turn off the setting to end access. **Help → MPCut Agent Guide** opens the instructions offline. [Setup and use cases](docs/MCP-AGENT-GUIDE.md) · [Tool reference](docs/MCP-REFERENCE.md)

## Edit on the timeline

1. Choose **File → Add Clips…** (⌘O) and select a recording.
2. Press **I** at the start of an unwanted passage and **O** at its end. Press **Delete**, then play across the join. **⌘Z** undoes the edit.
3. Choose **File → Save Project** (⌘S) to keep the editable timeline. Choose **File → Export Media…** (⌘E) to write the finished movie.

For a worked example with before-and-after pictures, see [Make your first cut](docs/USAGE.md#make-your-first-cut).

## Convert projects

Use **File → Import External Project…** or **File → Export Project**, or use `mpcut project convert` with a new output path. Both entry points use the same converters. The output extension identifies the file to create.

```sh
mpcut project convert Interview.cut --to resolve --output Interview.drp
mpcut project convert Interview.drp --to cut --output Reopened.cut --allow-loss --json
mpcut project convert Interview.cut --to premiere --output Interview.prproj
mpcut project convert Interview.fcpxmld --to cut --output Imported.cut
mpcut project convert Interview.cut --to fcp --output Interview.fcpxml
```

| Extension | What opens it | Conversion requirements |
| --- | --- | --- |
| `.cut` | MPCut | A versioned JSON document containing an ordered sequence or multicam project, saved in a compact, compressed layout. MPCut also opens plain JSON written by hand. [Project format and schemas](docs/CUT-FORMAT.md). Media files are referenced by path. |
| `.drp`, `.drt` | DaVinci Resolve | Resolve writes and reads its native project or timeline through its local scripting API. |
| `.prproj` | Adobe Premiere Pro | Adobe Premiere Pro and the MPCut Premiere bridge handle the native project. [Install the panel](docs/PREMIERE.md#install-the-panel). |
| `.fcpxml`, `.fcpxmld` | Final Cut Pro and compatible editors | MPCut reads and writes timeline interchange XML directly. |
| `.fcpbundle` | Final Cut Pro | Native library conversion requires Final Cut Pro and an interactive host step. |

Conversion handles one edit at a time and requires every referenced recording to be online. Relink missing media in **File → Project Media…** or with `mpcut project media` first. Resolve can retain editable multicam angles. Premiere can retain switchable angles for two to four aligned cameras at a common frame rate that cover the full group. To bring that edit back through Premiere’s sequence XML, flatten a copy in Premiere or choose `--flatten-multicam --allow-loss` when exporting from MPCut. The flattened sequence retains the assembled picture cuts and selected microphone tracks. Reading a Resolve archive requires loss approval because its timeline exchange can omit host-specific effects, grades and project settings. Final Cut library import asks you to export the chosen project as XML in Final Cut. Review reported limitations before retrying a conversion with `--allow-loss`. Keep referenced recordings and generated audio files alongside your projects. For an editable XML handoff to an existing Resolve project, see the workflow below.

## Export a project to DaVinci Resolve

Choose **File → Send Timeline to DaVinci Resolve via FCPXML…** in either editor. Choose a new `.fcpxml` file and leave **Open timeline in the current Resolve project** checked to import it immediately. Direct import requires an open Resolve project and local external scripting enabled. For manual import, use **File → Import → Timeline** in Resolve.

```sh
mpcut project resolve import --project interview.cut --output interview.fcpxml
mpcut project resolve import --stdin < ordered-edit.json
```

The multicam timeline retains synchronized cameras, angle switches, microphone choices and the saved assembly order. Ordinary timelines retain source trims, repeated clips and replacement working copies. Resolve uses the reference camera’s frame rate, the first video clip’s rate for ordinary edits, or 24 fps for audio-only edits. Cumulative cut positions round to that frame grid.

Keep the source recordings and any companion **Audio** or **Sources** directories. MPCut writes separate PCM files for independently routed streams in a multistream recording. The CLI also keeps working movies when an edit request supplies replacement audio. Double-click a multicam segment on Resolve’s Edit page to see the synchronized angles. [Close angle](docs/images/resolve-multicam-close.jpg) · [Wide angle](docs/images/resolve-multicam-wide.jpg) · [Replacement tracks](docs/images/resolve-replaced-tracks.jpg)

## Supported media

| Media | Editing behavior |
| --- | --- |
| Standalone PCM WAV/AIFF/CAF and AAC in M4A | Edit on the sample timeline, inspect the signed waveform, and copy the selected audio. |
| ALAC, FLAC, MP3, Opus and Vorbis audio | Inspect, analyze, and copy compatible streams. Available cuts depend on packet boundaries, decoder history, and the selected container. |
| ProRes MOV | Cut on video frames, including standard 422 and 4444 profiles. Linked PCM or AAC audio is checked at each boundary. |
| H.264 and HEVC in MOV or MP4 | Copy at verified boundaries. Smart Trim can hardware-encode the cut edges of compatible footage. |
| VP8, VP9, and AV1 in WebM | Copy compatible streams. Smart Trim can software-encode AV1 cut edges on Macs with hardware AV1 decoding. Discontinuous joins with Opus or Vorbis audio have limits. |
| Other local video | Probe MKV, MPEG-TS, AVI, MXF, and other formats. The streams, chosen ranges, and destination determine eligibility. |

Lossless Copy and Smart Trim require matching streams at joins. For ordinary movie clips with different codecs, dimensions or frame rates, choose **Re-encode**. The first clip sets the canvas, other pictures fit inside it, and each frame keeps its timing. SDR, PQ and HLG each require a separate timeline. [Mixed timeline rules](docs/EXPORT-RULES.md#mixed-timelines)

PCM and AAC audio embedded in supported video files can be preserved. MPCut supports standard ProRes 422 and 4444 families. Standalone audio recordings use the same timeline and CLI. RAW video, including ProRes RAW, is outside the supported inputs. [Detailed media support](docs/USAGE.md#media-support) · [Smart Trim requirements](docs/USAGE.md#cut-between-keyframes)

## Command line

The app includes the headless `mpcut` CLI for scripts and agents. With MPCut installed in Applications, set the path once for the examples below. From a source build, the executable is at `dist/MPCut.app/Contents/Helpers/mpcut`.

```sh
mpcut=/Applications/MPCut.app/Contents/Helpers/mpcut
"$mpcut" help --json
"$mpcut" help export clips join --json
"$mpcut" media inspect --json --keyframes input.mp4
"$mpcut" media inspect --json --frames --from 2 --to 3 input.mp4
```

The installed CLI carries its own reference and offline user guide (`mpcut help manual`). `mpcut help --json` returns `commands`, indexed by name, and shared `conventions`. Use `mpcut help review frames export --json` for one command’s syntax, defaults, result fields, and examples, or `mpcut export clips join --help` for text. The `export clips join` and `export ranges separate` topics also provide editable JSON request templates in `stdin_example`. **About MPCut** includes a **Copy CLI Path** button for installations outside Applications. [CLI guide by task](docs/CLI.md) · [Agent quick start and I/O contract](docs/USAGE.md#use-the-cli-from-an-agent)

Use the inspection report’s top-level `file` as the source path for an edit. Use `--frames` for exact presentation timestamps and `--keyframes` for keyframe markers and verified start points. Times accept `MM:SS`, `HH:MM:SS`, decimal seconds, or exact fractions. JSON requests also accept the rational time objects returned by inspection. Each start is inclusive and each end is exclusive. Add `--dry-run --json` to validate cuts and inspect `copied_duration` and `encoded_duration` before writing.

To keep the elapsed time between ranges from one recording, add `--space-clips source` to an export. To put two seconds of black and silence between every pair of clips, use `--space-clips 2`. Both options require camera packet copy by default. The same timing choices are available in **Sequence → Space Clips…** and through MCP. [Clip spacing and examples](docs/STILL-IMAGES.md#leave-space-between-clips)

For examples with a saved project, a single recording or an ordered list of ranges, see the [CLI guide](docs/CLI.md).

## Hardware and performance

MPCut uses VideoToolbox for hardware video decoding where supported, and Metal for filmstrip scaling and rotation. Compatible frames can go from the hardware decoder to the encoder directly. Lossless Copy and the copied parts of Smart Trim move compressed packets without decoding and encoding them again.

Video frame indexing, sidecar index serialization, and CLI frame and packet reports process batches across up to eight workers and merge them in source order. JPEG exports decode in timeline order and encode up to four pictures at once, with smaller batches for larger pictures. Long FLAC waveform and silence scans use frame-threaded decoding. When building a sidecar, the CLI can also analyze up to four independent audio tracks concurrently.

### Smart Trim performance

In a test on an M4 Max, the CLI assembled the ranges `23:01-26:12, 03:02-04:03` from a 2.5-hour file. It copied about **249 seconds of video** and encoded **2.68 seconds** at the edges.

In a separate FFmpeg benchmark on the same Mac, Smart Trim handled a 46-second selection **7.1× faster** than a full software AV1 re-encode. Both runs used the same AV1 encoder preset and copied the Opus audio from the same 1080 × 1920 WebM. Times are medians of three warm runs.

| Export | Elapsed time | Output size | Video encoded |
| --- | ---: | ---: | ---: |
| Smart Trim | 2.82 s | 8.38 MB | 6 s |
| Full re-encode | 20.02 s | 9.61 MB | 46 s |

The 1,200 copied pictures matched the source byte-for-byte. MPCut targets the source bitrate around each encoded edge. The 180 edge pictures averaged 92.9/100 VMAF against the decoded source, compared with 93.5 for the same pictures in the full re-encode. Results depend on the source and how much of the selection is safe to copy.

## Build from source

On an Apple Silicon Mac with the Xcode command-line tools, CMake, pkg-config and Python 3 installed, run these commands from the repository root. The first build downloads and verifies the pinned FFmpeg, SVT-AV1, LAME and Opus sources. The resulting bundle includes the native app, CLI, MCP helper, FFmpeg executable and required media libraries. The Go module pins the helper’s SDK and toolchain. If the pinned Go version is unavailable, the build downloads and verifies the pinned Apple Silicon toolchain into the checkout’s build cache.

```sh
./scripts/build-app.sh
open dist/MPCut.app
```

Use `./scripts/build-app.sh /Applications` to install the source build there for the CLI examples above.

To enable automatic feed detection, fixed multiview grids and meeting analysis, use the Apple Silicon macOS TileTrail **0.4.0** C ABI v1 build and set `MPCUT_TILETRAIL_PREFIX` to the extracted directory when running `swift build`, `swift build --build-tests`, or `scripts/build-app.sh`. Run the resulting macOS test host through Backstage as described in AGENTS.md. The directory contains `include/tiletrail.h`, `lib/libtiletrail.a`, and `LICENSE`. The app and CLI link the analyzer statically. The 0.1.0 library supports the meeting profile. Adaptive scans skip unchanged stretches only with a TileTrail build that supports coarse pushes; otherwise they analyze every frame. Standard builds run from a standalone MPCut checkout with analysis disabled. See the [feed and participant editing guide](docs/PARTICIPANTS.md).

For development, install Homebrew FFmpeg and pkg-config, then run `swift test`. The integration suites also use Python 3 and the FFmpeg CLI tools. [Test commands and qualification limits](AUDIT.md#reproduce-the-release-checks)

To launch MPCut without sound, for example when an agent or test drives it, set `MPCUT_MUTED=1` in its environment. A muted MPCut plays no preview, scrub or reverse audio and none of its own alert sounds, while playback still advances as usual. The preview's saved volume and mute settings are unchanged. MPCutAppTests runs muted.

## Verified on Apple Silicon

On an M4 Max Mac Studio, the GUI and CLI produced byte-identical files for the same three-source timeline edit. An export from three original ARRI ALEXA XT recordings retained all 769 expected ProRes packets and 1,476,480 stereo PCM sample frames in sequence. Tests also covered all six supported ProRes profiles, H.264 and HEVC splice boundaries, and hardware preview of VP9 and AV1 WebM.

A warm-cache benchmark assembled 6.49 GB of 4K ProRes 4444 footage in a median 4.40 s across three runs. A buffered read/write copy of the same number of bytes on the same internal SSD took 3.83 s. The benchmark reused one clip and did not force a storage flush. Performance varies with media, cache state, and storage.

The release includes FFmpeg notices, corresponding source, and the build recipe. The screenshot uses MDN’s flower sample. [FFmpeg notice](packaging/FFmpeg-Notice.txt) · [Sample footage](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/video#try_it)
