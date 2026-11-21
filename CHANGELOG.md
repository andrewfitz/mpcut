# MPCut release notes

## 1.2.0

- **Multiple editor windows.** Use **File → New Project Window** (⌘N) to open another editor. Each window keeps its own timeline, playhead and edit history. File and editing commands follow the active window. Reopening a multicam project brings its existing window forward. [Working with several windows](docs/USAGE.md#work-with-several-editor-windows)

- **Multicam projects.** Choose **Add as Multicam…** on the startup screen or in the File menu. Adjust source offsets, switch camera angles on a shared ruler, choose a fixed master or follow-camera sound, and trim and reorder group ranges into an assembly. Watch and scrub available sources as their exact indexes load. Save and reopen the edit as JSON. Render the assembly or whole group directly with `mpcut export --project edit.multicam.json --output program.mov --json`. The project resolves relative media paths from its own directory. Smart Trim is the default, and an optional `--dry-run` checks the edit before writing. [Multicam editing](docs/USAGE.md#edit-a-multicam-project)
- **Multicam editing and review.** Shuttle and scrub the program, jump to keyframes, scenes or pauses, and compare camera angles with JPEGs at the playhead or at every switch. Preview, protect or shorten pauses in the program soundtrack. Queue selections or retained takes as separate files, or set a new program soundtrack. [Desktop multicam editing](docs/USAGE.md#edit-a-multicam-project)
- **Multicam timeline and controls.** Resize the timeline and track-name column, switch angles with numbered buttons immediately after Mark In and Mark Out, and split an assembly range at the playhead from either preview. Camera thumbnails can start filling while sources are indexing. **Scan for Silence** opens the controls for the routed program soundtrack, and pause navigation follows repeated assembly occurrences. [Multicam controls](docs/USAGE.md#edit-a-multicam-project)
- **CLI reference and offline help.** `mpcut help COMMAND --json` and `mpcut COMMAND --help` describe inputs, outputs, defaults, and examples for each command. Global JSON help includes a command map and the shared I/O contract. Export and bulk help include editable JSON request templates, and multicam help includes a project template. The **Help** menu opens the bundled user guide (⌘?) and release notes. **MPCut → About MPCut** shows the installed version, documentation, credits, and a **Copy CLI Path** button.
- **Audio-only editing and monitoring.** Open recordings in the waveform viewer and timeline. Inspect down to 10 ms, trim, split, reorder, and queue ranges. Forward playback, reverse shuttle, and scrubbing follow the displayed standalone audio track. In movies, the filmstrip now has a progressive waveform underneath.
- **Silence editing.** The app and `mpcut silence` calibrate the noise floor per recording and track and bridge isolated noise blips. Scan, jump, skip, protect, audition or shorten pauses with padding, or queue the retained takes. Replay report JSON to produce a joined export. Linked sample rates and audio that outlasts the picture are accounted for.
- **Routed project silence.** Use `mpcut silence --project PROJECT --json` to scan the saved multicam assembly in playback order using its program soundtrack. Use `--output` to export retained ranges or add `--dry-run` to check the cut plan and destination. [Routed project audio examples](docs/USAGE.md#scan-and-shorten-routed-project-audio-from-the-cli)
- **Track extraction and replacement.** Export video only, audio only, or one soundtrack using stream copy. Replace a matching soundtrack in a whole movie while preserving its offset, picture and other audio tracks. Supported MOV chapter lists are retained. Container and priming constraints are checked before writing.
- **Analysis and visual review.** `waveform` returns a signed envelope for an exact time window. `inspect --audio-packets` exposes compressed packet timing. **Export JPEG Frames…** and `mpcut frames` produce review or full-resolution JPEGs with JSON manifests and frame-aligned clip bounds. Scene and non-silent selections support first frames or midpoints. The CLI can limit batch size and compare all multicam angles at specific group times.
- **Saved analysis and navigation.** The app and CLI automatically save and reuse matching indexes, scene results, waveform data and silence reports in SQLite `.mpcut` sidecars. Desktop saves can include view names and recent filmstrip tiles. Use `mpcut sidecar --status --json` to inspect the inventory. Settings covers sidecar reuse, pause parameters, snapping, monitoring, and movie and JPEG export defaults. **Snap To** supports keyframes, scene changes and silence edges. Reverse shuttle plays backward sound across edits.
- **Performance and accuracy.** Scene scanning pipelines eligible hardware decoding, uses multiple cores for suitable software video, and preserves short shots and full-range luminance changes. Compatible PCM WAV detail reads seek directly to the requested samples. Parallel indexing, sidecar serialization and bounded JPEG encoding keep results in source order. [Scene measurements](docs/SCENE-BENCHMARK.md) · [Verification](AUDIT.md)

## 1.1.0

- Use `mpcut export --order` or a JSON `order` list to select, repeat, and rearrange timestamp ranges into one movie. An explicit order defaults to Smart Trim.
- Use `mpcut rearrange` to Smart Trim a comma-separated list of timecode ranges into one movie. Scene navigation activates after you click **Scan for Scenes** and MPCut finds cuts or joins.
- Analyze hard cuts in the background and jump between scenes with Shift–Left and Shift–Right. Recurring views get matching labels on the filmstrip. Rename a view to label all of its shots at once. Use `mpcut scenes --json` for an exact scene report and `--export-to` to Smart Trim one file per scene or one joined file per view. Saved reports can be reused without rescanning.
- The filmstrip loads from verified frame times after indexing. Small and Large thumbnails are about 50% bigger, with equal-width tiles through the end of each clip.
- J, K and L shuttle backward, pause and shuttle forward. Repeat J or L to increase speed up to 8×. File, View, Sequence and Playback menus expose export modes, editing, navigation and preview controls.
- Queue several marked ranges and export them to separate files with shared settings. The `mpcut bulk` command defaults to Smart Trim and preflights every timestamp range and destination before writing.
- Drag the playhead to hear forward or reverse audio. The speaker control adjusts monitoring volume, mute and scrub sound. Playhead drags within one picture reuse its preview.
- Long clips with usable container timing open the viewer and ruler while MPCut indexes the frames and audio in the background. Playback and scrubbing are available during indexing. Batch imports still make one undo action, and metadata-only file updates no longer trigger a source-change error.
- Re-encode maps eligible whole-file audio directly and stages only sound for compressed audio cuts that need packet trimming.
- The CLI accepts frame timestamps from `inspect --frames` in JSON edits, supports bounded inspection and JSON snapping, and lists its available settings with `help --json`.

- **Apple Silicon acceleration.** Re-encode uses hardware decoding where supported and passes compatible video surfaces directly to the hardware encoder. Standard camera rotations can run on VideoToolbox. Scrubbing reuses recently decoded surfaces, and filmstrips share a Metal rendering context. A stalled hardware encoder startup check times out after 20 seconds.
- **Frame selection.** Selecting a clip at a fractional-rate join and confirming the current time preserve the exact frame. Marking a paused WebM immediately after a seek displays the requested picture. Blocked snapped edits report the issue sooner on long clips.
- **Transparency.** Re-encode checks image-based sources for alpha before export. HEVC with extra picture layers, including HEVC with alpha, can use Lossless Copy at verified boundaries. The app blocks encoding choices that would discard those layers.
- **CLI installation.** Hardware export finds the bundled FFmpeg helper when you launch `mpcut` through a symlink on your PATH.
- **Opus export timing.** Before copying WebM or MKV audio to MP4, MPCut checks whether the destination would expose samples trimmed from the original. Re-encode with Auto audio converts to AAC when needed to preserve the cut.
- **Timeline controls.** Clear In and Out marks from the transport bar. Undo and Redo name the edit they affect. The timeline has buttons to zoom in, zoom out and fit the sequence.
- **Preview and audio fixes.** Stepping across a WebM join displays the intended picture. Re-encoding retains silent sections in edited MOV AAC tracks and preserves 5.1 channel order when the container omits the layout.
- **Lower memory use on split clips.** Re-encode shares a decoder across consecutive ranges of the same recording. Each split still appears in the timeline and CLI export report.
- **Three export modes.** The native save sheet defaults to Smart Trim. Lossless Copy can propose copy-safe cuts for review and undo. Re-encode converts the retained timeline with the Mac’s H.264, HEVC or ProRes hardware encoder and shows the effective audio action for each track. The app includes FFmpeg.
- **Optional keyframe snapping.** Handles, splits and marked deletions use source-frame timing by default. Enable Snap to Keyframes beside timeline zoom for copy-safe edits.
- **Frame-accurate Smart Trim.** Cut between keyframes on compatible progressive 8-bit SDR video. MPCut uses hardware encoding for H.264 and HEVC edges in MOV or MP4, and software encoding for AV1 edges in WebM or MKV on Macs with hardware AV1 decoding. The export panel shows the durations of copied and encoded video.
- **Source-matched edge bitrate.** Each edge targets the video bitrate measured in nearby source frames, including when the file has no bitrate tag. On a 46-second AV1 cut, Smart Trim took 2.82 s and produced 8.38 MB. A full re-encode took 20.02 s and produced 9.61 MB. [Benchmark conditions](README.md#smart-trim-performance)
- **CLI preflight.** Use `--mode copy|smart|encode` from scripts or JSON. Ordinary single-movie exports default to Copy. Bulk and ordered exports default to Smart Trim. Pass `--smart-trim --dry-run --json` to see each edge’s timestamps, frame count, and target bitrate before exporting.
- **Reversible trim handles.** The filmstrip keeps excluded footage visible and faded. Drag either handle back to restore frames.
- **Timeline navigation.** Dedicated buttons step through frames or jump between keyframes. In and Out marks show their times on the timeline. Pressing Delete with only one mark set prompts for the other mark and protects the selected clip.
- **Faster thumbnails.** Filmstrips reuse indexed frames, skip audio decoding, and share cached thumbnails across split clips.
- **Portrait filmstrips.** Vertical footage uses taller thumbnails that show the full picture. Rotation-tagged recordings use their display orientation. Playback moves the playhead independently of the filmstrip, and accessibility actions can trim and restore clip edges.
- **Preview and import.** Paused WebM scrubbing skips audio decoding and holds the correct picture before a keyframe. Video playback can continue with an audio warning. Adding a batch of matching files validates the assembled timeline in one pass.
- **Export accuracy.** Continuous WebM/Opus splits and trims retain their audible duration. MOV exports preserve non-square pixels. Compatible 1080-line HEVC footage supports Smart Trim when the hardware encoder pads its coded height. Join checks now include field order and chroma location.
- **Container metadata and timing.** H.264 and HEVC with reordered frames in MKV retain their presentation order when trimmed or joined. WebM uses the per-video duration tag to resolve final-frame rounding. Compatible MP4 and MKV copies preserve Dolby Vision configuration, and preflight directs packed stereo footage to a container that preserves its eye layout.
- **CLI automation.** Keyframe inspection uses less memory on long files, and an unread progress pipe no longer stalls an export.
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
