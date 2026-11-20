# Using MPCut

## Make your first cut

1. Open MPCut and choose **Add Clips**. Select one or more recordings from the same camera settings.
2. Drag the clips into playback order. Press Space to preview the join.
3. To shorten a clip, drag its leading or trailing edge. To remove a section in the middle, seek to its start and click **Mark In** (I). A bracket appears at the playhead and the timeline shows its **In** time. Seek to the end and click **Mark Out** (O). Press **Delete** to remove the shaded range, **Esc** to clear the marks, or **⌘Z** to undo an edit.
4. Choose **Export** to write all retained footage in timeline order. To save one or more marked sections as separate files, add them to the **Export Queue**. Closing the window discards the timeline and queue.

## Edit a sequence

Add clips with **⌘O** or drop them at the desired position in the timeline. Click the time ruler to seek. Drag a clip to move it or drag an edge to trim. The filmstrip grows taller for portrait video and fits each entire frame, including footage stored sideways with a rotation tag. Each filmstrip shows the full source. Faded footage is excluded from playback and export. Drag the same handle back across the faded frames to restore them, or press Esc during a drag to cancel it. The ruler and duration measure the kept footage. The time beside a moving handle shows its position in the source. By default, handles land on individual video frames. The left handle previews the first retained frame. The right handle previews the last retained frame and shows the exclusive end time. Enable **Snap to Keyframes** beside the zoom slider to place new trims, splits and deletions on verified copy boundaries. Switching it on preserves existing cuts.

If the file declares its duration, you can start watching or scrubbing while MPCut indexes the video and audio. The filmstrip fills across the visible timeline during indexing, then updates thumbnails using verified frame times. Frame stepping, trimming, and export become available when indexing finishes. Use **Cancel** in the status bar to cancel the import.

Drag the playhead on the time ruler to hear short sections of sound as you move. Drag left to hear the samples in reverse. Releasing the mouse stops the sound at the selected position. Open **Preview Audio** (the speaker in the toolbar) to mute playback, set the monitoring volume, or turn off just **Play audio while scrubbing**. Export audio is controlled separately in the export sheet.

Beside Play, the inner arrows step one frame, the next pair jump by keyframe, and the outer pair jump by scene. Click **Scan for Scenes** below the timeline or choose **Playback → Scan for Scenes** to start a background scan. Colored ticks and view labels appear as MPCut finds cuts. Scene navigation stays disabled until the scan finishes and there are cuts or joins to jump between. Then use the outer buttons or **Shift–← / Shift–→**. You can continue editing or cancel from the status bar.

After analysis, the status bar shows the current scene and estimated recurring view within the source. Matching shots get the same lettered label and color. Click the status label or choose **Playback → Rename Current View** to apply a name such as “Wide” to every matching shot in the current session. A blank name restores the default. A camera punch-in can form a separate view. Camera movement, changed lighting and similar compositions can affect grouping. Gradual dissolves and single-frame flashes are outside the hard-cut target.

**Clear Marks** beside Delete clears both marks. Hover over Undo or Redo to see which edit it will affect. Use the magnifying-glass buttons beside the zoom slider to change the timeline scale, or **Fit** to see the full sequence. The thumbnail-size button beside **Snap to Keyframes** switches between Small and Large. The same setting is in **View → Large Timeline Thumbnails**.

Press **J** to play backward, **K** to pause, and **L** to play forward. Repeating J or L increases the speed to 2×, 4× and 8×. Changing direction starts at 1×. Reverse playback is silent. Dragging the playhead still plays short audio previews in either direction.

| Action | Shortcut |
| --- | --- |
| Play or pause | Space |
| Shuttle backward / pause / shuttle forward | J / K / L |
| Step one frame | ← / → |
| Jump by keyframe | Option–← / Option–→ |
| Jump by scene | Shift–← / Shift–→ |
| Mark the beginning and end of a range | I / O |
| Split at the playhead | ⌘B |
| Remove the marked range or selected clip | Delete |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Clear marks | Esc |
| Export movie | ⌘E |
| Add marked range to export queue | ⇧⌘A |
| Open export queue | ⇧⌘E |

## Export several ranges from the timeline

Mark a range with **I** and **O**, then press **⇧⌘A** or click the add-range button beside **Mark Out**. MPCut queues those source ranges and clears the marks so you can set the next pair. A queued range can cross clips and captures the footage as it was arranged when you added it.

Open **File → Export Queue** or press **⇧⌘E** to review or remove entries. Choose one export mode and container for the batch, then select an output folder. Smart Trim is the default. Each range produces a separate numbered file in queue order. If preflight finds a problem with a range or destination, the batch stops before writing. Use an empty folder to export the same queue again.

## Choose an export mode

Press **⌘E** to choose a mode, container and filename in one save sheet. A new session starts with **Smart Trim**. The sheet checks the current timeline as you change settings.

| Mode | When to use it |
| --- | --- |
| **Smart Trim** | Keep the exact cut and copy as much of the source as possible. The sheet shows the durations copied and encoded. |
| **Lossless Copy** | Copy compatible video and audio without encoding, including when changing containers. For an unsafe cut, **Review Cuts…** shows proposed boundaries and the change in total duration. **Apply to Timeline** lets you preview or undo those changes before exporting. |
| **Re-encode** | Convert every retained video frame using the Mac’s hardware encoder. Choose H.264 or HEVC in MP4, MOV or MKV, or ProRes in MOV or MKV. |

Re-encode starts with MP4, H.264, Balanced and Auto audio. H.264 and HEVC offer Smaller File, Balanced and High Quality. ProRes offers 422 LT, 422 and 422 HQ. **Auto** copies audio when the export can preserve it exactly. When conversion is necessary, it uses AAC or, for ProRes, PCM. You can also explicitly choose Copy Original, AAC, PCM (MOV or MKV), or Remove Audio. Check the per-track actions, output dimensions and warnings in the sheet. For example, converting 10-bit SDR to H.264 reduces it to 8-bit.

## Cut between keyframes

Use the frame steppers, handles or marks to choose the cut, then export with **Smart Trim**.

MPCut copies complete, independently decodable sections and encodes the frames needed at each cut edge. For example, if the last clean boundary is at 4:55 and the chosen end is 4:58, the final three seconds can be encoded and appended to the copied footage. If both cuts are inside the same group of dependent pictures, the whole selected range may need encoding. MPCut measures the video bytes per second in the source picture groups around each cut and uses that local bitrate as the encoder target. A new keyframe carries its own overhead, so very short edits can take more bytes per second. Only encoded edges incur generation loss. Source files stay intact and audio keeps its existing copy and trim rules.

Smart Trim supports progressive 8-bit 4:2:0 SDR footage with even dimensions and a verified starting frame. H.264 Baseline, Constrained Baseline, Main, and High profiles and HEVC Main in compatible MOV/MP4 files use the Mac’s hardware encoder. H.264 Smart Trim requires at least 192 × 96 pixels so the hardware encoder can match the coded dimensions at each splice. MOV files containing multiple compatible sample descriptions use copy mode. AV1 Main in WebM or MKV requires dimensions of at least 64 × 64 and a Mac with hardware AV1 decoding. The bundled SVT-AV1 software encoder handles its cut edges. ProRes already supports frame cuts in copy mode.

## Automate an export

The bundled executable is `/Applications/MPCut.app/Contents/Helpers/mpcut`. An agent can invoke that absolute path with a system-only PATH, or use a symlink named `mpcut` in its command path. From a source checkout, use `dist/MPCut.app/Contents/Helpers/mpcut`.

```sh
mpcut=/Applications/MPCut.app/Contents/Helpers/mpcut
"$mpcut" inspect --json --keyframes "Take 1.mov"
"$mpcut" export --output "Assembly.mov" \
  --clip "Take 2.mov" --from 2 --to 8 \
  --clip "Take 1.mov"
```

Run `mpcut help --json` to discover the installed version, export modes, codecs, quality values, audio actions and snapping options. Use `inspect --json --frames --from 2 --to 3 FILE` to list **every** indexed source picture in that half-open interval, including pictures between keyframes. Use `--keyframes` for the smaller access-point list. A frame’s `time` object can be sent verbatim as a clip’s `from` or `to`. Use the next picture’s time as the exclusive end, or use the reported media duration to keep the final picture.

Supply clips in playback order or use an explicit `order`. Each `from` is inclusive and each `to` exclusive, relative to the start of its own file. Omit either to use the corresponding file edge. Use decimal seconds, a clock time such as `00:03:14.250`, or a fraction such as `1001/30000`. Repeat a filename on the command line or use a shared top-level `file` in JSON for ranges from the same recording.

For an agent, send one JSON request on stdin. A dry run checks the request and returns the resolved ranges and duration. Remove `--dry-run` to write the movie.

```sh
"$mpcut" export --stdin --json --dry-run <<'JSON'
{
  "output": "assembly.mov",
  "clips": [
    {"file": "second.mov"},
    {"file": "first.mov", "from": "2"}
  ]
}
JSON
```

Single-movie exports default to `--mode copy` when no explicit order is supplied. Pass `--mode smart` or its alias `--smart-trim` to permit edge encoding. This example preflights a cut near 8.5 seconds, snapping to the nearest available frame boundary.

```sh
"$mpcut" export --json --dry-run --smart-trim --snap nearest \
  --output "take-cut.webm" --clip "take.webm" --to 8.5
```

When a segment needs encoding, its `encodedEdges` entries give the source-relative `from` and exclusive `to` timestamps, the `frameCount`, and the target video bitrate in bits per second (`targetBitRate`). A segment without encoded edges can be copied throughout.

To preflight a complete hardware conversion, choose the codec, quality and audio. The output extension selects the container.

```sh
"$mpcut" export --json --dry-run --mode encode \
  --video hevc --quality balanced --audio auto \
  --output "Assembly.mp4" --clip "Take 1.mov" --from 3 --to 8
```

JSON requests accept `mode`, `video`, `quality`, `audio` and `snap` at the top level. Set `snap` to `exact` (default) or `nearest`. For export decisions, use the dry-run report for the whole request, since compatible audio boundaries and joins also matter. Video choices are `h264`, `hevc` and `prores`. Choose `smaller`, `balanced` or `high` for H.264/HEVC, and `422-lt`, `422` or `422-hq` for ProRes. Audio choices are `auto`, `copy`, `aac`, `pcm` and `remove`.

Exact boundaries are the default. For Copy and Smart Trim, submit one of the suggested times or pass `--snap nearest` to authorize snapping. Re-encode uses exact source-frame times, including on variable-frame-rate footage. JSON results go to standard output, progress goes to standard error, and errors return a nonzero exit status. Choose a fresh destination path. Control-C cancels the operation.

### Rearrange and join ranges into one movie

For one recording, pass the ranges in playback order as a comma-separated list:

```sh
mpcut rearrange input.mp4 --output reordered.mp4 '23:01-26:12, 03:02-04:03'
```

The section from 23:01 to 26:12 plays first because it appears first in the list. Add `--dry-run --json` to see the resolved cuts and copied and encoded durations. This shorthand uses Smart Trim and snaps to nearby valid boundaries by default. Pass `--snap exact` to require the supplied times to land exactly on supported cuts. Each start is inclusive and each end is exclusive.

For multiple source files or structured requests, use `export` with an explicit clip order:

List the ranges once and supply their new order as one-based clip numbers. The following request writes the third range first, then the first and second. It defaults to Smart Trim and writes one output movie. A clip can override the shared `file` with its own path.

```sh
mpcut export --stdin --json <<'JSON'
{
  "file": "input.mp4",
  "output": "reordered.mp4",
  "clips": [
    {"from": "10", "to": "15"},
    {"from": "22", "to": "28"},
    {"from": "40", "to": "45"}
  ],
  "order": [3, 1, 2]
}
JSON
```

Use `--order 3,1,2` with repeated `--clip` flags or a JSON request. Omit a number to skip that range and repeat a number to include it again. Add `--dry-run` to see the applied order, resolved segments, and copied and encoded durations before writing. An explicit `--mode` or JSON `mode` overrides the Smart Trim default.

## Detect scenes and recurring views

`mpcut scenes --json montage.mov` emits a report without writing video. Each entry has a one-based scene `number`, exact rational `start` and `end` times, approximate `startSeconds`, and the first picture's absolute stream timestamp in `startPTS`. Starts are inclusive and ends exclusive. Similar scenes share the same integer `view` ID and lettered `viewLabel` (A, B, … Z, AA). The `views` list maps each view to its scene numbers in source order. The report also includes the source path and duration, time base, and view count.

Create the destination directories first. To scan once and reuse the same report:

```sh
mpcut scenes --json montage.mov > scenes.json
mpcut scenes --stdin --json --export-to shots < scenes.json
mpcut scenes --stdin --json --export-to views --group-by view --dry-run < scenes.json
mpcut scenes --stdin --json --export-to views --group-by view < scenes.json
```

The default export writes one Smart Trim file per scene, such as `montage-scene-003-A.mp4`. **`--group-by view`** writes one movie per view, such as `montage-view-001-A.mp4`, by joining matching scenes in source order. Pass `--container mp4` to select a compatible container explicitly. Use a filename in place of `--stdin` and the redirection to scan and export with one command.

Export JSON lists the view label, original scene numbers, output path, and resolved segments for each movie. A dry run validates every output before writing. Existing destinations are protected. Smart Trim checks whether each cut and join can preserve the source streams. The ordinary `bulk` command also accepts the report's exact timestamps if an agent needs to build a custom set of outputs.

## Try the CLI with the included fixture

From a source checkout with the app built, this example keeps the first three frames of the included 29.97 fps ProRes clip. The temporary directory gives the export a fresh destination on every run.

```sh
mpcut=dist/MPCut.app/Contents/Helpers/mpcut
source_clip=Tests/MPCutAppTests/Fixtures/ProRes-2997.mov
export_dir=$(mktemp -d)
"$mpcut" --version
"$mpcut" inspect --json --keyframes "$source_clip"
"$mpcut" export --json --dry-run --output "$export_dir/three-frames.mov" \
  --clip "$source_clip" --to 1001/10000
"$mpcut" export --json --output "$export_dir/three-frames.mov" \
  --clip "$source_clip" --to 1001/10000
```

In JSON inspection results, `media.frames[].canStart` identifies verified start points. A keyframe marker alone can still depend on earlier pictures. Export results include the effective `segments`, `duration`, and `container`. Times are returned as integer numerator/denominator pairs. The dry run checks audio and destination constraints as well as video boundaries.

### Export several timestamp ranges with one command

`mpcut bulk` accepts one source file, an existing destination folder, and an ordered list of ranges. Each range uses an inclusive start and an exclusive end. Use clock times, decimal or rational seconds, or the timestamp objects returned by `inspect --frames`.

```sh
mpcut bulk --stdin --json --dry-run <<'JSON'
{
  "file": "camera-a.mp4",
  "outputDirectory": "exports",
  "ranges": [
    {"from": "00:00:10", "to": "00:00:15"},
    {"from": "00:01:00", "to": "00:01:10"},
    {"from": "00:02:30", "to": "00:02:42"}
  ]
}
JSON
```

Remove `--dry-run` to write the files. Smart Trim is the default and uses exact frame boundaries. Use the dry run to check each output in the `outputs` array. Existing destinations stop the batch before writing. A write failure after export starts reports the one-based `failedRange` and the `outputs` that completed. You can set a shared `mode`, `container`, and, for re-encode, `video`, `quality`, and `audio`.

## Media support

MPCut inspects container contents. MOV, MP4, and WebM are primary targets, including H.264, HEVC, ProRes 422/4444, and WebM VP8/VP9/AV1. The engine also probes local Matroska, transport stream, AVI, and MXF footage. Matching codec settings, dimensions, color information, audio layout, safe boundaries, and a compatible output container determine whether a particular edit can be copied. The CLI's dry run checks the actual files and requested edit. RAW video is excluded. PCM audio in a camera MOV stays linked to the picture.

### Cut and playback behavior

- **WebM or MKV to MP4.** Opus can include decoder startup samples and padding at the end. When copying the track to MP4 would change the audible range, use MKV for lossless audio or choose Re-encode with Auto audio to convert it to AAC.
- **MOV/MP4 with AAC.** Frame-aligned edits can fall inside an AAC packet. MPCut preserves packets needed to start the decoder and records their audible ranges in the movie's edit list. It also preserves explicit silent intervals and can reopen exports to trim across earlier joins. An AAC track that ends before the picture without an explicit silent edit can be preserved in a whole-file copy. A trim or join reaching that untracked interval reports an unsafe boundary. Some readers expose additional samples when extracting raw audio across internal joins.
- **WebM.** Matching silent clips can be cut and joined at verified video boundaries. Whole-file copies support VP8/Vorbis, VP9/Opus, and AV1/Opus. A single continuous Opus range can be trimmed at either end when the audio timing and video cut points are verified. MPCut copies earlier audio packets for decoder startup and records how many samples the player should skip. Adjacent ranges from one source can also be combined. An independent Opus or Vorbis stream carries decoder history that a discontinuous WebM join cannot reset reliably. MPCut reports this case before export. Hardware preview is tested separately, so an unsupported preview codec can still be copied.
- **Camera timecode.** For supported MOV timecode tracks, the output starts at the first retained frame's source timecode and runs continuously through the assembled sequence. If audio starts before the first picture, a whole-file MOV or MP4 copy with timecode can leave the last pictures without timecode. MPCut flags that case during preflight. A trim that removes the audio lead can still qualify.
