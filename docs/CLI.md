# MPCut command-line guide

Create an editable rough cut, revise a saved assembly, or shorten pauses in an ordinary sequence with the [headless editing guide](HEADLESS.md).

Use `mpcut` to inspect and edit recordings, render saved projects, and review the results from scripts. If the executable is inside the desktop app and you have not added it to your PATH, use its full path, for example `/Applications/MPCut.app/Contents/Helpers/mpcut`.

| I want to… | Start here |
| --- | --- |
| Find installed commands or check the version | [Help and version](#help-and-version) |
| Identify streams, cut points, or still-image metadata | [Inspect media and projects](#inspect-media-and-projects) |
| Cut or join an edit, extract tracks, or replace audio | [Render one output](#render-one-output) |
| Review or edit a saved project’s export settings | [Set project export options](#set-project-export-options) |
| Export several separate clips | [Export a batch](#export-a-batch) |
| Find, review, and shorten pauses | [Find pauses and shorten recordings](#find-pauses-and-shorten-recordings) |
| Detect cuts and recurring views | [Find scenes and export clips by view](#find-scenes-and-export-clips-by-view) |
| Export review JPEGs or read an audio waveform | [Review picture and sound](#review-picture-and-sound) |
| Reuse scans or check for changed source files | [Save analysis and refresh sources](#save-analysis-and-refresh-sources) |
| Review camera angles or render a multicam assembly | [Work with multicam projects](#work-with-multicam-projects) |
| Create or edit a timeline with stills or gaps | [Work with still images](#work-with-still-images) |
| Search speech and edit by words | [Work with transcripts](#work-with-transcripts) |
| Move an editable timeline to or from another editor | [Convert and hand off projects](#convert-and-hand-off-projects) |
| Pass file lists, exact times, and structured requests | [List files](#list-files) and [Script MPCut](#script-mpcut) |

## Help and version

```sh
mpcut --help
mpcut help export clips join
mpcut export clips join --help
mpcut help export clips join --json
mpcut help manual
mpcut --version --json
```

Global `mpcut help --json` includes command references and export option lists. A single-topic request returns a smaller reference. `mpcut help multicam` includes a project template.

`mpcut --version` prints the release version. Its JSON form and the completed MCP `cli_version_read` job return:

| Field | Meaning |
| --- | --- |
| `version` | Release version. Multiple builds can share it. |
| `build_id` | Mach-O UUID of the running CLI binary slice. It stays the same when that binary is copied or signed. |
| `project_schema_versions` | Saved-project versions this build reads and writes. The current build supports only schema 9. |
| `detector_capabilities` | Availability flags for this build and host. |

`detector_capabilities` reports `tile_trail` for meeting detection, `auto_feed_layout` for automatic generic feed detection, `gallery_grid` for meeting gallery hints, and `adaptive_sampling` for TileTrail's adaptive scanning. `standalone_fixed_grid` covers explicit grids without TileTrail. `auto_backend` and `cpu_only_backend` include that fallback. `gpu_required_backend` reports whether TileTrail can initialize its GPU backend on this host. A standalone fixed grid accepts only `auto` and `cpu-only`.

From a source checkout with a built app, keep the first three frames of the included 29.97 fps ProRes clip. The temporary directory gives the media and export fresh paths on each run.

```sh
cli=dist/MPCut.app/Contents/Helpers/mpcut
work=$(mktemp -d)
cp Tests/MPCutAppTests/Fixtures/ProRes-2997.mov "$work/source.mov"
"$cli" media inspect --json --keyframes "$work/source.mov"
"$cli" export clips join --json --dry-run --clip "$work/source.mov" --to 1001/10000 \
  --output "$work/three-frames.mov"
"$cli" export clips join --json --clip "$work/source.mov" --to 1001/10000 \
  --output "$work/three-frames.mov"
```

A dry run of `export project render --project FILE --output MOVIE --dry-run --json` returns a `plan_token`. To render the exact project and settings that were reviewed, pass that value with `--plan-token TOKEN` on the render. Repeat preflight after `stale_render_plan`.

## Inspect media and projects

```sh
mpcut media inspect --json interview.mov
mpcut media inspect --json --keyframes interview.mov
mpcut media inspect --json --frames --from 2 --to 3 interview.mov
mpcut media inspect --json --audio-packets --stream 1 --from 2 --to 3 interview.mov
mpcut media inspect --json title.png
mpcut project inspect --project interview.cut --json
```

- Read `media.streams` to identify a stream by its absolute, zero-based `index`. Read `copy` for compatible containers and `tier` for the best export mode the indexed selection can support with all tracks and exact boundaries. With all tracks selected, a default movie inspection reads the cut index even when individual frames are omitted. Selecting only audio or only video omits `tier`.
- Use `media.frames[].time` as your picture time and the next picture time as its exclusive end. `can_start` and `can_end` report verified boundaries. Use a dry run to check the full edit with the selected tracks.
- `--audio-packets` uses the selected audio stream or the first audio stream by default. PCM indexes may summarize contiguous packets.
- Project inspection reports ordered sequence clips or multicam group intervals, resolved source paths, coverage and issues. Projects with stills also expose assets and placements. Bare image inspection reports size, color and HDR information.

Use `timeline range map` for every occurrence intersecting a source or program interval. Set `--space` to `source`, `sequence`, `group` or `assembly` as appropriate, and supply exact `--from` and `--to` times. A source query can use `--file` to identify the recording, and `--occurrence-index` limits a query to one occurrence. Use `history compare` with `--before-project` and `--project` to compare two saved project states.

```sh
mpcut timeline range map --project interview.cut --space sequence --from 4 --to 7 --json
mpcut history compare --before-project review.cut --project interview.cut --json
mpcut history compare --project interview.cut --history-index 0 --json
mpcut history restore-copy --project interview.cut --history-index 0 --out-project earlier.cut
```

For a mask or tile edit, inspect `participant_changes` in the comparison. It identifies the physical source, affected tile and source-clock interval or point. Sample the corresponding occurrence in the rendered program to check the picture. Use `project document print` to see the retained undo and redo steps. History index zero selects the oldest retained state. The number of undo steps gives the saved cursor. Restore Copy writes a new project with the cursor at the selected state and carries forward both history branches.

For a saved sequence, `project edit` accepts `source_select_save`, `source_select_remove` and `source_ranges_apply` operations. The apply operation takes sequence `from` and `to` and ordered `ranges`. Use equal bounds to insert. A range can specify `file`, `from` and `to` or reference a saved `select_id`. [Sequence format](CUT-FORMAT.md#sequence)

### Edit multicam audio

Use `project edit --stdin --json` to save a new project with an ordered list of edits. Supply `project_path`, a new `out_project` and `operations`. Set the lane list before activating Mix when you want to choose specific recordings or streams.

```sh
mpcut project edit --stdin --json <<'JSON'
{
  "project_path": "interview.cut",
  "out_project": "interview-mix.cut",
  "operations": [
    {"action":"mix_lanes_set","lanes":[
      {"id":"wide-mic","target":{"kind":"camera","angle_id":"wide"},"label":"Wide mic","color_slot":0},
      {"id":"close-mic","target":{"kind":"camera","angle_id":"close"},"label":"Close mic","color_slot":1}
    ]},
    {"action":"audio_set","mode":"mix"},
    {"action":"audio_replacement_set","id":"close-lav",
     "original":{"source_id":"close","audio_stream_index":1},
     "path":"lav.wav","replacement_source_id":"lav","replacement_stream_index":0,
     "relative_offset":"1/2","uncovered":"keep_original"}
  ]
}
JSON
```

This example assumes cameras `wide` and `close` have streams assigned and both recordings are available. The external recording starts half a second after camera `close` on its local clock. To use an existing external project source, provide a `replacement` object with `source_id` and `audio_stream_index` in place of the import fields. `audio_replacement_remove` takes the binding `id`. The `leave_uncovered` option leaves gaps where the replacement has insufficient coverage. [Mix lane and track binding format](CUT-FORMAT.md#mix-lanes-and-track-bindings)

`audio_set` also accepts `follow`, `none` and `fixed`. Fixed takes `source_id` and `audio_stream_index`, or restores the remembered Fixed selection when both are omitted. Mix starts with the configured camera streams if its lane list is empty. In `project create`, an `angles` entry can specify `audio_stream_index` to configure that camera’s stream.

Check an external recording against a specific original scratch stream before writing its binding.

```sh
mpcut multicam sync suggest --project interview.cut --reference-source-id close \
  --reference-stream 1 --replacement lav.wav --replacement-stream 0 --json
```

Review `metadata_relative_offset` and `waveform_relative_offset` when the report has matching evidence. An optional `--seed TIME` centers the waveform search on a known relative offset. Supply the chosen exact offset as `relative_offset` in `audio_replacement_set`.

Add `--program` to check coverage across the entire cut for an external program replacement. In this mode `--reference-stream` is optional. To apply the confirmed alignment, submit an `audio_set` operation with `mode: "replace"`, `path`, a new `replacement_source_id`, `replacement_stream_index`, `reference_source_id` and `relative_offset`. MPCut uses the replacement as the Fixed soundtrack and clears switch overrides in the saved copy.

## Set project export options

```sh
mpcut project output read interview.cut --json
mpcut project output set interview.cut --width 1080 --height 1920 --frame-rate 30000/1001 \
  --background 0x101010 --audio-mode program --unresolved-privacy cover --out-project portrait.cut --json
```

The read returns the effective canvas, soundtrack and unchecked-coverage policy in `output.settings`. When the canvas follows the source, `output.has_stored_canvas` is false. Set accepts partial edits and records one undo step when settings change. Use `--in-place` to update the original file. A still-only timeline accepts dimensions and frame rate here. Use the [still soundtrack commands](#work-with-still-images) to manage its attached audio.

## Render one output

Use `export project render` for a saved project, `export clips join` for an ordered edit or track extraction, and `export soundtrack replace` to substitute audio. Use `export ranges join` for a compact one-source range list.

```sh
mpcut export project render --project interview.cut --output finished.mov --dry-run --json
mpcut export clips join --clip interview.mov --from 1 --to 3 \
  --clip interview.mov --from 8 --to 10 --order 2,1,2 \
  --output select.mov --snap nearest --dry-run --json
mpcut export ranges join interview.mov --output reordered.mov '8-10,1-3' --dry-run --json
```

Each `--from`, `--to`, or `--ranges` applies to the preceding `--clip`. Omitted endpoints use the edges of that source. Clip order is the order supplied unless you pass `--order` or `--order-file`. Order entries are one-based and may omit or repeat clips. Rerun the request without `--dry-run` to render with those settings.

Use `cut_map.occurrences` in the JSON result to trace each retained use through the export, including repeated uses and adjacent uses combined into one render segment. [Export results and cut maps](EXPORT-MODES.md)

`--space-clips source` fills forward gaps with black and silence between chronological ranges from the same source or multicam group. A fixed duration such as `--space-clips 1/2` sets the same spacing between each pair of clips in playback order. For constant-rate footage, use a duration on the frame cadence. Use `--space-clips 0` to clear clip spacing for a saved project's render. Generated gaps default to Smart Trim and require retained camera picture to copy unless you select Re-encode.

### Choose a mode, container and tracks

- `--mode smart` uses Smart Trim. It copies eligible material and encodes supported picture boundaries as needed. Full movie edits and multicam projects default to Smart Trim. `--mode copy` requests lossless packet copy. `--mode encode` permits conversion. The destination extension selects the container. [Export rules](EXPORT-RULES.md)
- Export and bulk use exact boundaries by default. `export ranges join` defaults to nearest for video, with Smart Trim for picture with sound. On eligible copy or Smart Trim requests, `--snap nearest` authorizes boundary movement. Encode uses exact boundaries. Saved multicam switch times are validated exactly.
- `--tracks all|video|audio` selects tracks. For an ordinary file edit, `--tracks audio --audio-stream INDEX` selects one audio stream to write. The explicit single-type selections use stream copy, with audio conversion available through `export clips join` or `export ranges separate` in encode mode.
- With encode, choose `--video h264|hevc|prores` and a matching `--quality`. H.264 and HEVC use `smaller`, `balanced`, or `high`. ProRes uses `422-lt`, `422`, or `422-hq`. For a movie, `--audio` accepts `auto`, `copy`, `aac`, `pcm`, or `remove`. For audio-only conversion, omit video and quality settings. Audio-only conversion also supports `mp3`, `flac`, and `opus`. Project Smart Trim can also use `--audio aac` or `--audio pcm` where applicable.

```sh
mpcut export clips join --clip interview.mov --tracks audio --audio-stream 1 \
  --output dialogue.m4a --dry-run --json
mpcut export clips join --clip interview.mov --tracks video --output picture.mov --dry-run --json
mpcut export clips join --clip interview.mov --mode encode --video hevc --quality balanced \
  --audio auto --output encoded.mp4 --dry-run --json
mpcut export soundtrack replace --clip interview.mov --mode copy --replace-audio processed.wav \
  --replace-track 1 --replacement-stream 0 --output new-mix.mov --dry-run --json
```

The track extraction example assumes AAC on stream 1. For compatible PCM, try WAV. Soundtrack replacement preserves the source's track selection and substitutes a matching-duration stream before cuts or joins. If you omit the replacement indices, each input uses its first audio stream. The flag binds to the first source, including repeated uses. A JSON edit can specify replacement per clip.

For multicam projects, `--audio-output separate_tracks` is the default and delivers lanes in project order. `downmix_mono` and `downmix_stereo` render the combined sound as one track. Set the same choice with `audio_output` in a JSON export request. The audio action is independent of picture mode. `--audio copy` preserves each eligible lane, `--audio auto` copies eligible lanes and renders the others, and `--audio aac` or `--audio pcm` renders all selected sound in that codec where the container supports it. `--audio remove` omits sound. A downmix requires a render action.

An `export clips join` request can repeat and reorder group ranges from the same Mix project while keeping its audio lanes. Render the project first if you need to join it with a different project or recording. The same restriction applies when joining a project that combines visible still replacements with synced audio replacement. Use `--audio remove` or `--tracks video` to join picture from inputs with different lane layouts.

```sh
mpcut export project render --project interview-mix.cut --output separate.mov --dry-run --json
mpcut export project render --project interview-mix.cut --mode copy \
  --audio-output downmix_stereo --audio pcm --output combined.mov --dry-run --json
```

Review `plan.audio_lanes` for source spans and output ranges and top-level `audio_lanes` for delivery actions before writing. `project inspect` reports lane mapping in `inspection.mapping.audio_lanes` and replacement coverage in group time for each entry in `inspection.audio_bindings`. Match errors with `lane_id` to the lane IDs in those reports.

## Export a batch

Create the output directory first. Use `--subfolder` to place the batch beneath it and `--base-name` to change the filename prefix. Output numbers follow range order.

```sh
mkdir -p clips
mpcut export ranges separate interview.mov --ranges selects.csv --output clips \
  --subfolder Review --base-name Interview --dry-run --json
```

Use the `outputs` array to review planned filenames and boundaries. A dry run checks all destinations before writing. If writing later fails, `outputs` lists completed items and `failed_range` gives the one-based failed range. Use the same export mode and selection options as for an ordinary clip export.

## Find pauses and shorten recordings

```sh
mpcut silence scan --min-pause-seconds 2 --padding-per-side-seconds 0.2 --max-blip-seconds 0.30 \
  --json interview.mov > pauses.json
mpcut silence plan --input pauses.json --output shortened.mov --dry-run --json
mpcut silence scan --project interview.cut --min-pause-seconds 2 --padding-per-side-seconds 0.2 --json
```

MPCut calibrates the threshold per track. Use `--threshold-db` to set it explicitly. `--min-pause-seconds` defaults to 1.5 seconds and `--padding-per-side-seconds` defaults to 0.2 seconds of silence on each side of a cut. `--max-blip-seconds` defaults to 0.06 seconds and can be set to zero. For a single file, `--stream` chooses the detection track, and `--waveform N` includes peak-dBFS bins. For example, `--padding-per-side-seconds 0.2` targets 0.4 seconds of retained silence across an interior join. Check the resolved removal in the report for the actual boundaries.

Read `pauses`, `removals`, and retained `clips` in the report. To protect a pause, remove that entry from the saved single-source report's `pauses` array. Keep the rest of the report when replaying. It records the source identity, detection threshold, `min_pause_seconds`, `max_blip_seconds` and `padding_per_side_seconds`. You can also supply your own explicit pause ranges with `--pauses-file`. On replay, pass `--padding-per-side-seconds` to change the silence retained on each side. Run a new scan to change detection settings.

For a sequence or multicam project, repeat `--retain-pause ID=SECONDS` to override the total retained duration of individual pauses. Read each pause’s `requested_retained_seconds` and `retained_seconds` to see the request and the duration after alignment. In a project scan or plan without an output, repeat `--take-boundary TIME` to add exact sequence or assembly boundaries to the report’s `take_candidates`.

A multicam project scan analyzes the routed program audio in assembly order. If it has no assembly, the scan uses the whole group range. Mix treats an interval as silent only when all selected lanes are silent. Use `silence plan --output FILE` to review the shortened program and `silence export --output FILE` to write it. Both preserve inserted stills and accept the multicam `--audio-output` and `--audio` delivery choices. Export modes are `smart` and `copy`.

To keep a reviewed multicam pause across future edits, use `silence pause protect --project interview.cut --out-project protected.cut --protect-pause ID` with the same detector settings used for the scan. If the reviewed timeline, audio routing, source evidence or detection settings have changed, scan again and review the new ID. Use `silence room-tone calibrate` to save thresholds from a group or assembly interval containing the room tone.

## Find scenes and export clips by view

```sh
mpcut scenes scan --json interview.mov > scenes.json
mpcut scenes scan --project interview.cut --all-sources --progress jsonl --json
mkdir -p shots
mpcut scenes export --input scenes.json --export-to shots --group-by view --dry-run --json
```

The file report includes `scenes` with timings and view labels. `views` groups scenes with recurring compositions. A file scan takes a source window with both `--from` and `--to`. A project scan defaults to all referenced video sources. Choose `--clip-id ID` for a sequence clip's source interval or `--camera-id ID` for one multicam recording.

Scans default to `--policy reuse`. Use `--policy resume` to continue a replacement scan or `--policy restart` to start a replacement. A restart can carry an `--operation-id` for retries. `--progress none|stderr|jsonl` controls progress output. Cancelling leaves scan coverage available for resumption when sidecar saving is enabled.

To name a recurring view, run a full-source project scan and take the recording path, report ID and view ID from the same result. Run `scenes view rename --project interview.cut --out-project named.cut --source MEDIA --report-id REPORT_ID --view ID --name Wide`. Pass an empty name to restore the default. Export the recording’s report to use its saved labels in filenames.

For export, replay the saved file report or pass the file and `--scenes-file LIST`. Keep a report subset in source order if you only want selected scenes. `--group-by scene` writes individual files and is the default. `--group-by view` joins each view's scenes in source order. Create the destination directory before exporting. `--container`, `--subfolder`, `--base-name` and `--tracks` control the outputs.

## Review picture and sound

```sh
mpcut review frames export --select scenes --sample midpoint --limit 12 --output overview interview.mov
mpcut review frames export --preset full --at 3/2 --output detail interview.mov
mpcut review frames export --project interview.cut --clock assembly --at 3/2 --output program-review
mpcut waveform envelope read --stream 1 --from 2 --to 2.1 --columns 1024 --json interview.mov
```

`review frames export` writes JPEGs and `manifest.json` to a new directory. File review defaults to scene midpoints. Use `--select non-silent` for audio-driven ranges, with optional stream and detector settings. Explicit times supplied through repeated `--at` or an `--at-file` list go directly to those pictures. The review preset limits the long edge to 640 pixels. Full uses display resolution. Add `--format png` or `--format tiff` for lossless frames in place of the default JPEGs. Both keep the decoded R′G′B′ values, with 16 bits per channel when the source has more than 8, and embed the profile that describes them: sRGB, Rec. 709, Display P3, or BT.2100 PQ or HLG. A PQ or HLG source is written as its HDR signal. The JPEG holds the tone-mapped SDR rendition in sRGB. Still placements and generated gaps on a program clock are written as 16-bit sRGB. The manifest reports `format` for PNG and TIFF.

Frame manifests use `schema_version` 2. Read `frame_time`, `frame_pts` when available, and `file` for each source frame. For single-source footage, `clip_from` and `clip_to` give frame-aligned export bounds. Multicam projects with tile processing default to the assembly clock. With either assembly or group time, they return one rendered program frame per request and `frame_time` on that clock. Other multicam projects default to the group clock and return a row per angle, including gaps. Use the assembly clock to review the edited program, including visible stills. Recording gaps in the selected angle export black frames marked `generated_gap`. For a sequence project, use the sequence clock.

`waveform envelope read` reads signed minimum and maximum sample amplitudes per bin from one audio stream. It defaults to the entire source, the first audio stream and 1,024 columns. Set `--columns` from 1 through 65,536.

## Save analysis and refresh sources

```sh
mpcut analysis sidecar build --only index,audio --json interview.mov
mpcut analysis sidecar inspect --json interview.mov
mpcut analysis sidecar build --project Edit.cut --only audio interview.mov
mpcut project media refresh --project interview.cut --deep --progress stderr --json
```

MPCut and the CLI share the storage choice in **Settings → Analysis**. The default is `FILE.cutcache` beside the media. Supply `--project Edit.cut` to build in project-folder mode or to include that project in a lookup. A configured cache disk serves every project. Inspection searches every available location. Its `read_location` identifies the primary inventory, `read_locations` lists all copies contributing to it, and `write_location` names the selected destination when available. Bare `analysis sidecar build FILE` saves the editing index, available scene analysis, and audio analyses. `--only` or `--only-file` chooses sections. `analysis sidecar inspect` reads the inventory and reports source generations, stale reasons and persisted scene attempts when available. Use `--no-sidecar` to bypass automatic cache reads and writes during analysis. For a manual save, it can force fresh analysis. The inspection result lists each copy’s database size, section payloads, SQLite overhead and reclaimable bytes under `cache_copies`. It reports `duplicate_copies` and, when you supply a saved project, its `project_bytes`.

```sh
mpcut analysis cache settings --json
mpcut analysis cache configure --mode disk --folder /Volumes/Cache --json
mpcut analysis cache preview --folder /Volumes/Recordings --project Edit.cut --json
mpcut analysis cache clear --folder /Volumes/Recordings --project Edit.cut --select "$clear_token" --confirm --json
```

Storage mode can be `media`, `project` or `disk`. Disk mode keeps the configured folder when you omit `--folder`. The preview searches the chosen folder and its subfolders. Use `--location media|project|disk` to filter copies and `--project` to protect the saved project and its retained media references. Pass only the desired `clear_token` values to `clear` with the same options and a separate `--select` for each copy. If a selected cache changed or became unavailable, preview the folder again. The clear result reports removed paths, skipped paths and reclaimed bytes.

`refresh` checks referenced source identity and reindexes changed files. `--deep` verifies contents even when file identity matches. The `sources` report includes preserved analysis and references that need review. The `media` report lists project references and their current availability. Refresh reads the saved project and updates analysis.

## Find and relink project media

```sh
mpcut project media list interview.cut --json
mpcut project media locate interview.cut --folder /Volumes/Archive --json
mpcut project media locate interview.cut --folder /Volumes/Archive --apply-matches --out-project found.cut
mpcut project media relink interview.cut --from camera.mov --to relocated/camera.mov --in-place
mpcut project media relink interview.cut --map-prefix /Volumes/Shoot=/Volumes/Archive --out-project moved.cut
mpcut project media leave-offline interview.cut --source camera.mov --in-place
mpcut project media revert moved.cut --source /Volumes/Archive/camera.mov --out-project reverted.cut
mpcut project media replace interview.cut --source camera.mov --with alternate.mov --conform trim --json
mpcut project media replace interview.cut --source camera.mov --with alternate.mov --conform trim --allow-loss --out-project edited.cut
```

List and Locate show paths used by the current edit. Add `--include-history` to include paths used only in retained undo and redo states. Use a listed path or the absolute location of the old file in `--from` or `--source`. Candidates and prefix folders resolve from the working directory. Repeat `--from` and `--to` to pair several paths by their order, or repeat `--map-prefix` for several roots. Relink changes the path in the current edit and retained history. `still asset relink` uses the same operation and identifies the old image path by asset ID.

Locate searches the selected folder and its subfolders. With `--apply-matches`, it applies unique verified or matched candidates. Review ambiguous, different and pending candidates in the result. For a batch, `sources` reports the outcome of each mapping and `out_project` names the file when a write succeeds.

Leave Offline marks a current media reference as intentionally offline and excludes it from Locate. Revert restores a previous location when every current and retained use still traces to the original relink. The list reports whether Revert is available.

Replace previews the ripple report when you omit a destination. To apply, choose `--in-place` or a new `--out-project` path. The default conform mode `trim` trims uses that overrun the candidate. Use `--conform keep` to preserve their timeline timing. When a use is entirely out of range, `--allow-loss` removes it in trim mode or retains it offline in keep mode. Use `--loss remove` or `--loss keep-offline` to select that behavior explicitly.

Use `--use-id ID` to replace one use from `affected_use_ids`. Repeat `--stream-map OLD=NEW` to map selected audio streams by absolute index. The report includes candidate streams and unresolved mappings. Use `--clock source-timecode` to preserve source timecode when available and `--shared-time-of-day` to confirm an inferred common clock. Multicam replacement accepts `--replacement-offset TIME` or `--resync timecode|waveform`. Still replacement accepts `--reset-crop`. Existing transcript bindings are kept for review by default. Use `--transcript retranscribe` to remove affected bindings before transcribing the replacement.

## Work with multicam projects

Create or save a multicam project in the app, or use the template from the CLI. If you have `jq`, the following writes the template to a fresh `edit.cut`. Edit its paths, selected audio stream, range and switches for your recordings.

```sh
mpcut help multicam --json | jq '.project_template' > edit.cut
mpcut project inspect --project edit.cut --json
mpcut review frames export --project edit.cut --clock group --at 1 --at 3 --output angle-review
mpcut export project render --project edit.cut --output finished.mov --dry-run --json
```

The project stores offsets that place source time zero on the group clock. Its first switch starts at the group range start. Audio can use a fixed microphone, follow the active angle, be disabled or use per-switch overrides. Use `--tracks video` for a picture-only export. `--require-camera-copy` permits generated stills while requiring all retained camera picture to copy. [Project format](CUT-FORMAT.md)

`mpcut multicam sync suggest --project edit.cut --json` reports candidate offsets from available timestamps and waveform matches, with drift evidence when enough audio matches are available. The primary recording on the reference camera is used by default. Use `--reference-source-id` to choose another recording on that camera, `--source-id` to analyze a single target, or `--metadata-only` to skip audio matching.

To evaluate a proposed camera switch, call `mpcut multicam switch coverage --input proposal.json --json` with `project_path`, `angle_id` and exact `group_time`. Read the picture and audio status, missing group ranges and audio routes for the interval through the next switch. In a `project edit` request, use `angle_set` with the assembly `index` and `angle_id` to override picture on one replay. Use `angle_clear` with the index to restore the group switches.

To add another recording to an existing angle, use the `add_recording` operation with `angle_id`, `path` and exact `group_start`. In MOV, MP4 or M4V, Re-encode can fill a selected recording gap with timed black and retain the routed microphone. Copy and Smart Trim report `recording_gap_requires_encoding`. An encoded result lists `generated_picture_gaps` in output time. Angle review manifests use `recording_id` to identify the file providing a sampled picture.

Direct project export uses the saved assembly in playback order, or the entire group range if there is no assembly. To address the original group clock, put a project clip in an edit request, for example `{"clips":[{"project_path":"edit.cut","from":"2","to":"4"}],"output":"excerpt.mov"}`. Group clips include visible picture replacements. Export the saved assembly for inserted stills.

When a multicam boundary fails, read `error.multicam` and `error.nearest`. If `multicam.switch_group_time` identifies a switch, use the suggested time for that switch. For `multicam.edge`, use the one-based `range_number`, its `boundary` (from or to), and `group_time`. The diagnostic includes `source_id` and the affected `source_range`, `group_range`, and `assembly_range`. In a mixed edit list, `range_number` identifies the input clip. The group clock of an ordinary file clip is its source clock. Recheck the edit after changes because earlier adjustments can affect later output timing.

## Edit camera feeds and recorded calls

Run `mpcut help tiles` to find commands for scanning a recording, correcting assignments and delivering synchronized movies. Automatic scanning requires a TileTrail-enabled build. Inspection and delivery can start from accepted tiles in a saved project.

```sh
mpcut tiles scan gallery.mov --output gallery-scan.json --progress stderr --json
mpcut tiles inspect gallery-scan.json --issues --json
mpcut tiles preview gallery-scan.json --at 00:00:12 --output gallery.png
mpcut tiles accept --project interview.cut --source-id gallery --scan gallery-scan.json --out-project reviewed.cut
mpcut tiles accept --project reviewed.cut --clear-count-hints --in-place
mpcut tiles feeds list reviewed.cut --json
```

The scan summary's `issues` lists count mismatches. Its `review_issue_count` gives the number of entries in `tiles inspect SCAN.json --issues`, including uncertain matches, coverage gaps and layout changes. The receipt from `tiles accept` gives the corresponding count for the edited recording in the project.

Feed decisions about one tile share a `group_id` and report their `group_count`, in `tiles inspect --issues` and in the issues of `tiles export-isos`. An issue's `feed_id` is the scan's own feed for the tile, and `candidate_feed_ids` lists the earlier feeds it may be. To keep the tile on its own feed, run one `tiles link --tile-id ID --feed-id OWN` with no `--from` or `--to`. If it is the same person as an earlier feed, first fold the own feed into it with `tiles feeds merge --feed-id OWN --into-feed-id EARLIER`, then link the whole tile to `EARLIER`. Either settles the whole group. Each issue keeps its own range, so `--on-uncertain blank` still covers only the flagged frames.

`--at`, and the bounds of a tile correction, refer to the recording's source clock. Use `--source-id ID` when a project contains several tile recordings. Edits to a saved project require `--out-project FILE` or `--in-place`.

When the linked TileTrail supports incremental checkpoints, a tile-only scan with `--output` can resume from its most recent committed checkpoint. Rerun with the same input, options and output path. An interrupted scan keeps its checkpoint next to the requested output. A scan that finds incomplete coverage saves its report, including the affected intervals. Legacy resume files and scans that include scenes use decoded replay to reconstruct the tracker.

To deliver every eligible feed from a source, use the one-shot command. To deliver a subset, make a plan with a `--feed-id` for each selected feed, then render that plan.

```sh
mpcut tiles export-isos gallery.mov --output Gallery-ISOs --progress jsonl --json
mpcut tiles angles plan --project reviewed.cut --feed-id HOST_ID --output host-plan.json
mpcut tiles angles render --plan host-plan.json --output Host-ISO
mpcut tiles angles verify Host-ISO --json
```

Each ISO preserves time while its feed is offscreen. A raw recording can supply a common mix. A separate microphone requires a binding in the reviewed project. A transcript speaker binding cannot supply isolated audio.

If preflight needs a decision, the job exits 3 and returns `status: "needs_review"` alongside `review_project_path`, `issues`, and `suggested_next_command`. For raw input the review project is created beside the destination in a private folder. Open or inspect that project and resolve its issues. To revise a count expectation, run `tiles accept` with `--expected-feeds` or `--max-visible-tiles`. Use `--clear-count-hints` to remove both expectations. Both edits preserve the accepted tiles and feed IDs without rescanning. Then pass the project to `export-isos` with the same destination. Use `--resume` to reuse the matching finished files from an interrupted delivery. Use `--on-uncertain blank` to cover eligible uncertain intervals and `--no-meeting-mix` to omit the shared mix. `angles verify` checks the delivery against its manifest.

A full `tiles inspect` report on a project includes `layouts` in timeline order. Each sequence clip has a row, including clips with an empty layout list. Multicam reports include the group and each assembly occurrence. Use `--at` or a source-time range to see the scopes and layouts applicable to the selected recording at those times.

To draw tiles by hand, start with `mpcut tiles feeds add edit.cut --name Guest --in-place --json`. Use the returned `feed_id` with `tiles box add --feed-id` for a new box or `tiles link --feed-id` for an existing box. A feed belongs to the project and appears in a recording's feed list once a tile there is assigned to it.

Use `tiles layout list` to find a clip or multicam occurrence. For a sequence, address a layout with `--clip-id` in source time. For multicam, use `--group` or `--occurrence-id` in group time. A feed's treatment applies wherever that feed appears, including outside the selected layout range.

Arranged layouts map feeds to tile positions. A range that crosses gallery changes is split into layout spans at each change. Every destination must resolve to a unique tile throughout the requested range. If a smaller gallery loses a position, the command returns `unmappable_tile_layout` with the destination, recording and source time and leaves the project unchanged. Set separate ranges with destinations visible in each gallery.

```sh
mpcut tiles layout list reviewed.cut --json
mpcut tiles layout set reviewed.cut --clip-id CLIP_ID --layout solo --feed-id HOST_ID --in-place
mpcut tiles feeds treatment reviewed.cut --feed-id GUEST_ID --treatment blur --in-place
mpcut tiles angles use reviewed.cut --all --out-project angles.cut
mpcut tiles switches propose angles.cut --attachment-id TRANSCRIPT_ID --voice-angle SPEAKER_ID=ANGLE_ID --json
```

`angles use` creates angles that reference the original recording. A single recording can retain multiple audio tracks. When multiple recordings contribute sound, sequence conversion supports one selected track per recording. A sequence with multiple audio tracks continuing across recordings needs to keep its existing timeline to preserve track continuity.

`switches propose` reports proposed cuts. Apply the chosen cuts as ordinary multicam switches.

### Review pending Tiles

Start with a project saved while a Check Tiles review was pending. The example uses a source ID of `gallery`. Substitute your source ID, or omit `--source-id` when the project has just one pending review. The response includes `feed_ids`, `choices` and `review_token`. To stage a change, start with the returned choices object and edit the relevant fields. Staging replaces the entire object, including names, unchecked feeds, merges and grid corrections.

```sh
mpcut tiles pending read meeting.cut --source-id gallery --json > pending.json
jq '.choices' pending.json > choices.json
```

Edit `choices.json` using the reported feed IDs, then stage it in a new project. Inspect the choices in that copy before accepting them.

```sh
mpcut tiles pending stage meeting.cut --source-id gallery --choices "$(cat choices.json)" --review-token "$(jq -er '.review_token' pending.json)" --out-project staged.cut --json
mpcut tiles pending read staged.cut --source-id gallery --json > staged-review.json
```

After approval, run `mpcut tiles accept --project staged.cut --source-id gallery --review-token "$(jq -er '.review_token' staged-review.json)" --out-project accepted.cut`. To discard a pending review, use `tiles pending discard` with its current token. If you get `stale_tile_review`, read the pending choices again. The same workflow is available through the `tiles_file_pending_*` and `tiles_editor_pending_*` tools. [Tiles editing guide](PARTICIPANTS.md)

### Existing participant commands

Run `mpcut help participants --json` to see the existing participant commands and their request fields.

For projects that fit the legacy format, `participants project inspect` returns the familiar roster, source geometry and timed shots, and `participants project apply` accepts that JSON. Projects with clip layouts that cannot be translated to timed shots, arranged layouts, grids of more than four cells, screen-share feeds or live feed angles return `unsupported_legacy_participant_edit` and leave the project file untouched.

```sh
mpcut participants scan --file gallery.mov --output gallery-scan.json --progress stderr --json
mpcut participants scan --file switcher.mov --feed-layout 2x2 --sampling every-frame --output angles.json --json
mpcut participants project accept --project interview.cut --source-id gallery --analysis-file gallery-scan.json --out-project reviewed.cut
mpcut participants render export --project reviewed.cut --output interview-two-up.mov --json
mpcut participants angles take --input angle-take.json --json
```

A scan uses the meeting profile unless `--feed-layout auto` or a grid such as `2x2` selects feeds. Sampling defaults to `adaptive`. Choose `every-frame` to verify every frame before a redaction, or `sparse` for exploratory review. `participants angles list` returns the virtual angles for a project. `angles take` switches to one at an output time, and `angles plan` and `angles render` write aligned angle media with a multicam project. [Feed and participant guide](PARTICIPANTS.md)

## Work with still images

```sh
mpcut still project create --out-project title.cut --image title.png \
  --width 1920 --height 1080 --rate 30 --codec h264 --container mov --frames 60 --json
mpcut still picture replace --project sequence.cut --image title.png --clock sequence \
  --from 8 --to 12 --out-project covered.cut --json
mpcut still placement insert --project edit.cut --image title.png --clock assembly \
  --at 0 --frames 60 --rate 30 --out-project titled.cut --json
mpcut still placement list --project titled.cut --json
```

- `still project create` makes a still-only project from an image or `--gap`. Supply dimensions, frame rate and a duration or frame count. The default codec and container are H.264 and MOV. `--codec` also accepts `hevc`, `prores` or `jpeg`, and `--container` accepts `mp4`, `m4v` or `mkv`. To fit one image to a recording, pass `--soundtrack FILE --fit-soundtrack` in place of a duration.
- `still soundtrack attach` adds a recording to a still-only project. Use `still soundtrack fit` to fit the single image to the recording’s exact audible duration. Use `still soundtrack detach` to keep the picture timing and remove the soundtrack.
- `still placement insert` and `still picture replace` accept a new `--image` or an existing `--asset ID`. A replacement preserves underlying audio and duration on the sequence or group clock. An insert adds time and silence on the sequence or assembly clock. Use `timeline gap insert` for an empty interval. Use `--fit`, normalized crop fields, `--background '#RRGGBB'`, and `--color sdr|pq|hlg` where applicable.
- `still placement list` reports assets, placements, and visible fragments. `still placement update` changes placement timing, framing, or the referenced asset. It can duplicate placements or detach a selected fragment with `--fragment-index N --detach-id ID`. Fragment indices are zero-based.
- `still asset relink` locates the same image at a different path. Use `project media replace` to preview a different image. `still placement remove` deletes a placement. `timeline clips space` adds gaps between consecutive clips using source timing, a fixed duration, or a fixed frame count. Use duration zero to clear spacing.
- Write changes with `--out-project FILE` or explicit `--in-place`. With `--project -`, save mutations to a named output. [Still-image workflows](STILL-IMAGES.md)

```sh
mpcut timeline clips space --project sequence.cut --source-timing --out-project spaced.cut --json
mpcut still asset relink --project titled.cut --asset ASSET_ID --image archive/title.png \
  --out-project relinked.cut --json
mpcut still placement remove --project relinked.cut --placement PLACEMENT_ID \
  --out-project clean.cut --json
```

Replace `ASSET_ID` and `PLACEMENT_ID` with IDs from `still placement list`. For timing and fragment edits, see `mpcut still placement update --help`.

For a still render, `--still-timing held` writes one independently decodable sample per visible hold. Use `--still-timing cadence` for the authored frame schedule. In Smart Trim or Re-encode, set the delivery codec with `--video`. An explicit `--container` must agree with the output extension. Compatible lossless audio choices are `--audio alac`, `--audio flac` and `--audio pcm`. The JSON request fields are `still_timing`, `video`, `container`, and `audio`. [Still image guide](STILL-IMAGES.md#export-the-program)

## Work with transcripts

```sh
mpcut transcript provider capabilities --json
mpcut transcript tracks list --project interview.cut --json
mpcut transcript job prepare --project interview.cut --job-directory ./jobs --json
mpcut transcript words search --project interview.cut --space current_cut --query 'expected benefit' --json
```

Use `transcript provider capabilities` to check for a Transcriberrr helper that supports MPCut session schema 1. Use `transcript tracks list` to inventory streams and `transcript job prepare` to stage the job. Use `transcript job run --job-id UUID` in the same job directory, then `transcript attachment import` its result by path or job ID. Use `transcript job status`, `transcript job cancel`, and `transcript job retry` to manage sessions.

Use `transcript attachment inspect`, `transcript words read`, `transcript words search`, and `transcript words locate` to interpret attachments and find words in source, group, or current-cut time. `transcript attachment bind` and `transcript attachment detach` manage attachments. `transcript words compare`, `transcript script align`, and `transcript words suggest` review possible edits. `transcript words correct` updates transcript metadata or text. `transcript words select` resolves word or gap boundaries. `transcript edit plan` produces a reviewable edit, `transcript edit apply` executes the reviewed plan, and `transcript excerpt queue` saves a named excerpt project for later rendering. `transcript export` writes text, JSON, SRT or VTT. For structured options, use `mpcut transcript words search --input REQUEST.json` or `--stdin`. [Transcript workflows](TRANSCRIPTS.md)

Filter multicam transcript tracks, attachment coverage or word occurrences with `--lane-id ID` or `lane_id` in structured requests. Use lane IDs from `project inspect`. A current-cut word heard on several Mix lanes identifies its primary lane and reports the other lanes in `heard_on_lane_ids`.

## Convert and hand off projects

```sh
mpcut project convert interview.fcpxml --output imported.cut --json
mpcut project convert interview.cut --to premiere --output interview.prproj --json
mpcut project convert interview.cut --to resolve --output interview.drp --json
mpcut project resolve export --project interview.cut --output interview.fcpxml --json
```

`mpcut project merge BASE OURS THEIRS` merges two branches of a project for Git and replaces OURS with the result. It merges the edit line by line and the media snapshot by recording, and leaves undo history out. Register it with `git config merge.mpcut.driver "mpcut project merge %O %A %B"` and the `.gitattributes` line `*.cut merge=mpcut`. Exit status 1 means both branches changed the same lines, and OURS then holds plain project JSON with conflict markers, or that the merged project cannot be opened, and OURS then holds the merged text. See [version control](CUT-FORMAT.md#version-control).

`mpcut project document print interview.cut` expands the saved references to produce readable JSON, with one field of the edit to a line. Use that output for schema validation. It reads hand-written projects, and standard input when given `-`. [Project format and schema validation](CUT-FORMAT.md)

`project convert` works with MPCut `.cut`, Resolve `.drp` and `.drt`, Premiere `.prproj`, and Final Cut Pro `.fcpbundle`, `.fcpxml` and `.fcpxmld`. The input and output extensions select adapters. `--to cut|resolve|premiere|fcp` checks the chosen destination format. Native operations can require the editing app. Use `--allow-loss` to accept reported approximations. For a Premiere delivery, `--allow-loss --flatten-multicam` keeps selected picture and sound while discarding alternate angles.

`project resolve export` writes an editable FCPXML timeline. Use `project resolve import` to write it and import it into the active Resolve project. For an ordinary file edit, use `--clips LIST --output FILE.fcpxml` or an edit request through `--stdin` or `--input`. Keep source media and generated `Audio` or `Sources` folders available. Render projects with still edits to media when you need the generated pictures preserved. [Resolve handoff](../README.md#export-a-project-to-davinci-resolve) · [Premiere interchange](PREMIERE.md)

## List files

Use UTF-8 CSV or JSON files. Quote paths with commas or quotes according to CSV rules. For exact times use quoted fractions or rational objects in JSON.

| Option | CSV | JSON array |
| --- | --- | --- |
| `export ranges join --ranges`, `export ranges separate --ranges`, `export clips join --clip … --ranges` | `from,to` keep ranges or one `time` per split point | `[{"from":"1","to":"3"}]` or `[1,3]` |
| `export clips join --clips`, `project resolve export --clips` | One path per line, or header beginning with `file` or `project_path` and optional `from,to` columns | `["intro.mov","talk.mov"]` or `[{"file":"talk.mov","from":"1","to":"3"}]` |
| `export clips join --order-file` | One clip number per line, optional `order` header | `[2,1,2]` |
| `review frames export --at-file` | One timestamp per line, optional `time` header | `[0,"1/2","00:03"]` |
| `analysis sidecar build --only-file` | One section per line, optional `section` header | `["index","audio"]` |
| `scenes export --scenes-file` | Header `start,end,view` with optional `number` | `[{"start":0,"end":1,"view":1}]` |
| `silence plan --pauses-file` | `from,to` ranges in source order without overlaps | `[{"from":"1","to":"2"}]` |

A clip’s `--ranges` file can contain CSV or JSON. Its times are relative to the clip in-point. For `export ranges join`, pass inline pairs as a positional argument or a file with `--ranges FILE`. Use `--at-file`, `--order-file`, and `--only-file` for other lists.

## Script MPCut

- Paths in flags and request files resolve relative to the working directory. Paths stored in a named `.cut` resolve from the project directory. Commands that accept `--project -` resolve paths in that streamed project from the working directory. Quote shell paths with spaces and use `./` for a filename starting with a dash. Use fresh output paths with existing parent directories.
- Ranges include their start and exclude their end. CLI times accept seconds, `MM:SS`, `HH:MM:SS`, and fractions such as `1001/30000`. Preserve exact times in edit JSON as strings or objects such as `{"numerator":1001,"denominator":30000}`.
- With `--stdin`, send one UTF-8 JSON object and close stdin. `export clips join` and `export ranges separate` require `--json` with `--stdin`. Use `--input FILE.json` as the file equivalent for those commands and for `resolve`, `silence`, `scenes`, and transcript operations. `scenes` and `silence` can replay the reports they produce. With `--json`, consume one response object on stdout and drain stderr separately for progress and diagnostics.
- Exit status `0` means success, `1` operation failure, `2` invalid CLI arguments or request, `3` an ISO delivery that needs review, and `130` cancellation. Inspect `error.code`, `error.message`, `error.nearest` and `error.alternatives` when present. `error.segment` identifies the one-based input clip or saved multicam assembly range. `failed_range` identifies a one-based batch range.
- For `unsafe_boundary`, use the reported boundary or preflight an allowed mode or snap change. For `unsupported_container`, choose a compatible extension for the selected tracks. For `output_exists`, choose a fresh destination. For `source_changed`, rescan before replaying a report.

An edit request takes `output` and either a top-level `project_path` or a nonempty array of clips. An optional top-level `file` supplies the default source for file clips. A batch request takes `file`, `output_directory`, and `ranges`.

```sh
mpcut export clips join --stdin --json --dry-run <<'JSON'
{"file":"interview.mov","clips":[{"from":"1","to":"3"},{"from":"8","to":"10"}],"order":[2,1],"snap":"nearest","output":"assembly.mov"}
JSON

mkdir -p clips
mpcut export ranges separate --stdin --json --dry-run <<'JSON'
{"file":"interview.mov","output_directory":"clips","ranges":[{"from":"1","to":"3"},{"from":"8","to":"10"}],"snap":"nearest"}
JSON
```

Use unique JSON keys. If you supply an option in both a flag and the JSON object, its values must agree. For a script that controls an open desktop editor, use the live tools described in the [MCP agent guide](MCP-AGENT-GUIDE.md).
