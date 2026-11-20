# Using MPCut

## Make your first cut

1. Open MPCut and choose **Add Clips**. Select one or more recordings from the same camera settings.
2. Drag the clips into playback order. Press Space to preview the join.
3. To shorten a clip, drag its leading or trailing edge. To remove a section in the middle, seek to its start and click **Mark In** (I). A bracket appears at the playhead and the timeline shows its **In** time. Seek to the end and click **Mark Out** (O). Press **Delete** to remove the shaded range, **Esc** to clear the marks, or **⌘Z** to undo an edit.
4. Choose **Export** to write all retained footage in timeline order. Marks select a range for deletion. To keep just one section of a clip, trim its two handles to the desired start and end before exporting. Select a compatible container in the save panel and give the output a new name. Closing the window discards the timeline.

## Edit a sequence

Add clips with **⌘O** or drop them at the desired position in the timeline. Click the time ruler to seek. Drag a clip to move it or drag an edge to trim. Each filmstrip shows the full source. Faded footage is excluded from playback and export. Drag the same handle back across the faded frames to restore them, or press Esc during a drag to cancel it. The ruler and duration measure the kept footage. The time beside a moving handle shows its position in the source. ProRes permits a picture cut on each video frame. With Smart Trim off, interframe video cuts snap to boundaries that preserve the surrounding pictures’ decoding dependencies.

Beside Play, the two inner arrows step one frame. The outer skip buttons jump to the previous or next keyframe.

| Action | Shortcut |
| --- | --- |
| Play or pause | Space |
| Step one frame | ← / → |
| Jump by keyframe | Option–← / Option–→ |
| Mark the beginning and end of a range | I / O |
| Split at the playhead | ⌘B |
| Remove the marked range or selected clip | Delete |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Clear marks | Esc |
| Export movie | ⌘E |

## Cut between keyframes

Turn on **Smart Trim** in the toolbar, then use the frame steppers, handles, or marks to choose the cut. Playback and export follow the kept range. The export panel shows how many video frames require encoding and their combined duration.

MPCut copies complete, independently decodable sections and encodes the frames needed at each cut edge. For example, if the last clean boundary is at 4:55 and the chosen end is 4:58, the final three seconds can be encoded and appended to the copied footage. If both cuts are inside the same group of dependent pictures, the whole selected range may need encoding. MPCut measures the video bytes per second in the source picture groups around each cut and uses that local bitrate as the encoder target. A new keyframe carries its own overhead, so very short edits can take more bytes per second. Only encoded edges incur generation loss. Source files stay intact and audio keeps its existing copy and trim rules.

Smart Trim supports progressive 8-bit 4:2:0 SDR footage with even dimensions and a verified starting frame. H.264 Baseline, Constrained Baseline, Main, and High profiles and HEVC Main in compatible MOV/MP4 files use the Mac’s hardware encoder. H.264 Smart Trim requires at least 192 × 96 pixels so the hardware encoder can match the coded dimensions at each splice. MOV files containing multiple compatible sample descriptions use copy mode. AV1 Main in WebM or MKV requires dimensions of at least 64 × 64 and a Mac with hardware AV1 decoding. The bundled SVT-AV1 software encoder handles its cut edges. ProRes already supports frame cuts in copy mode. To switch Smart Trim off, every current cut must qualify for copying.

## Automate an export

From the repository root use `dist/MPCut.app/Contents/Helpers/mpcut`. The examples below use the installed app.

```sh
mpcut=/Applications/MPCut.app/Contents/Helpers/mpcut
"$mpcut" inspect --json --keyframes "Take 1.mov"
"$mpcut" export --output "Assembly.mov" \
  --clip "Take 2.mov" --from 2 --to 8 \
  --clip "Take 1.mov"
```

Supply clips in playback order. Each `from` is inclusive and each `to` exclusive, relative to the start of its own file. Omit either to use the corresponding file edge. Use decimal seconds, a clock time such as `00:03:14.250`, or a fraction such as `1001/30000`. Repeat a filename to use several ranges from the same recording.

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

Pass `--smart-trim` on either form of the export command to permit edge encoding. This example preflights a cut near 8.5 seconds, snapping to the nearest available frame boundary.

```sh
"$mpcut" export --json --dry-run --smart-trim --snap nearest \
  --output "take-cut.webm" --clip "take.webm" --to 8.5
```

When a segment needs encoding, its `encodedEdges` entries give the source-relative `from` and exclusive `to` timestamps, the `frameCount`, and the target video bitrate in bits per second (`targetBitRate`). A segment without encoded edges can be copied throughout.

Exact boundaries are the default. An unsafe timestamp returns a structured error. Submit one of the suggested times or pass `--snap nearest` to authorize snapping. JSON results go to standard output, progress goes to standard error, and errors return a nonzero exit status. Choose a fresh destination path. Control-C cancels the operation.

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

## Media support

MPCut inspects container contents. MOV, MP4, and WebM are primary targets, including H.264, HEVC, ProRes 422/4444, and WebM VP8/VP9/AV1. The engine also probes local Matroska, transport stream, AVI, and MXF footage. Matching codec settings, dimensions, color information, audio layout, safe boundaries, and a compatible output container determine whether a particular edit can be copied. The CLI's dry run checks the actual files and requested edit. RAW video is excluded. PCM audio in a camera MOV stays linked to the picture.

### Cut and playback behavior

- **MOV/MP4 with AAC.** Frame-aligned edits can fall inside an AAC packet. MPCut preserves packets needed to start the decoder and records their audible ranges in the movie's edit list. It also preserves explicit silent intervals and can reopen exports to trim across earlier joins. An AAC track that ends before the picture without an explicit silent edit can be preserved in a whole-file copy. A trim or join reaching that untracked interval reports an unsafe boundary. Some readers expose additional samples when extracting raw audio across internal joins.
- **WebM.** Matching silent clips can be cut and joined at verified video boundaries. Whole-file copies support VP8/Vorbis, VP9/Opus, and AV1/Opus. A single continuous Opus range can be trimmed at either end when the audio timing and video cut points are verified. MPCut copies earlier audio packets for decoder startup and records how many samples the player should skip. Adjacent ranges from one source can also be combined. An independent Opus or Vorbis stream carries decoder history that a discontinuous WebM join cannot reset reliably. MPCut reports this case before export. Hardware preview is tested separately, so an unsupported preview codec can still be copied.
- **Camera timecode.** For supported MOV timecode tracks, the output starts at the first retained frame's source timecode and runs continuously through the assembled sequence. If audio starts before the first picture, a whole-file MOV or MP4 copy with timecode can leave the last pictures without timecode. MPCut flags that case during preflight. A trim that removes the audio lead can still qualify.
