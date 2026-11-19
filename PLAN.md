# MPCut v1 implementation plan

A single-session, Apple Silicon–only utility for joining and trimming matching video clips. Drop files, arrange them on one timeline, check the cuts, and export one movie. The window holds the edit in memory. Closing it ends the session.

## Release scope

Ship two native arm64 entry points, a Mac app and a headless CLI. Each produces one movie from an ordered sequence of compatible source ranges. Editing is nondestructive. The app keeps the timeline in memory and writes only the exported movie.

| Video family | Input and output | Audio carried with the video | Video cut positions |
| --- | --- | --- | --- |
| H.264 or HEVC | MP4 or MOV | AAC | Verified stream-copy boundaries |
| ProRes 422 Proxy, LT, 422, HQ | MOV | Linear PCM or AAC | Any video frame |
| ProRes 4444, 4444 XQ | MOV | Linear PCM or AAC | Any video frame, preserving alpha when present |
| VP8, VP9, AV1 | WebM | Opus or Vorbis | Verified stream-copy boundaries |

Qualify these targets using real camera and web recordings, including silent clips. PCM support covers audio embedded in MOV. Exclude RAW video, including ProRes RAW and ProRes RAW HQ. Keep the interface to one sequence with linked audio and hard cuts.

### Other local video files

Let Finder and the CLI pass any local video file to the bundled FFmpeg build for probing. Detect the actual container and streams from the contents. Apply the RAW exclusion across all containers. Probe additional formats such as Matroska (MKV), MPEG-TS/M2TS, AVI, and MXF through this same path.

Determine support per operation. For export, check that an available muxer can carry the streams and required metadata, that the clips match, and that the requested ranges can be spliced safely. For a single whole-file remux, validate the source stream start and end without requiring an interior cut. Use the source container by default where writable. If its writer is unsuitable, offer a verified compatible container such as MKV in the destination picker, or accept a compatible output extension from the CLI. Report unsupported track or boundary handling before writing. Extend codec-specific boundary validation as representative files qualify. [FFmpeg formats](https://ffmpeg.org/ffmpeg-formats.html)

For GUI preview, test hardware video decoding of the actual stream on this Mac and availability of audio playback for its tracks. If preview is unavailable, explain why and keep eligible copy operations available. CLI inspection, dry runs, and exports work without opening a preview decoder. Report copy eligibility separately from preview status. A headless inspection can report preview as unchecked.

## One window

- A large viewer sits above one zoomable timeline. Show clip names, cut boundaries, keyframe ticks, the current time, and the assembled duration.
- Drop one or several Finder files onto the timeline. Dropping at the end appends them. Dropping between clips shows an insertion marker. Drag any clip or split segment to reorder it. Neighbors close up automatically, and audio travels with its video.
- Drag an edge to trim, split at the playhead, or mark a range with I/O and delete it. Undo works throughout the session. Space plays the assembled timeline through joins. Arrow keys step by frame, Option–Arrow jumps by keyframe, and clicking the time readout allows precise navigation.
- Scrub to any displayed frame. Trim handles and splits snap to verified stream-copy boundaries and show the effective time and picture before the edit is applied. Preview and export use the same ordered source ranges.
- Export opens a destination picker. Default to the container selected by the compatibility check. Show progress and cancellation. Finish by moving the completed file into place.

## Command-line automation

Ship an arm64 `mpcut` executable that runs headless. Bundle it at `MPCut.app/Contents/Helpers/mpcut`. With the app installed in Applications, agents can invoke `/Applications/MPCut.app/Contents/Helpers/mpcut` directly. Examples below assume the helper is on PATH. Both the GUI and CLI call the same native compatibility checker, boundary resolver, and packet writer. A CLI request describes the kept ranges in output order and lasts for one invocation.

```sh
mpcut export --output assembly.mov \
  --clip C.mov --from 00:00:02 --to 00:00:08 \
  --clip A.mov \
  --clip B.mov --from 00:00:10
```

Each `--clip` starts a segment. Times refer to elapsed presentation time in that source, relative to its beginning. Start is inclusive and end is exclusive. Omitted bounds mean the start or end of the file. Repeat a file with different ranges to remove a middle section. Accept decimal seconds, HH:MM:SS with optional fractional seconds, and exact rational seconds such as 1001/30000.

For programmatic use, `mpcut export --json --stdin` reads one UTF-8 JSON object with an `output` path and an ordered `clips` array. Each clip has a `file` path and optional `from` and `to` timestamp strings. Resolve relative paths from the working directory. Direct arguments and JSON use identical semantics. For example, an agent can send this request to `mpcut export --stdin --json --dry-run` and repeat it without `--dry-run` to export.

```json
{
  "output": "assembly.mov",
  "clips": [
    { "file": "C.mov", "from": "2", "to": "8" },
    { "file": "A.mov" },
    { "file": "B.mov", "from": "10" }
  ]
}
```

- `mpcut inspect --json A.mov` reports streams, duration, and time bases. Add `--keyframes` to request frame access points with exact rational timestamps.
- `export --dry-run --json` resolves compatibility and requested boundaries, reports effective ranges and total duration, and writes no movie. Exact cuts are the default. An unsafe cut returns a structured error with the affected segment, boundary, and nearest valid choices. An agent can resubmit its chosen range or explicitly request `--snap nearest` with ties resolved toward the earlier valid time. Reject empty or inverted ranges.
- In JSON mode return one result object on stdout, including effective ranges on success and a stable error code on failure. Send progress to stderr. Return zero for success and nonzero for failure. Run without prompts, reject the entire request on an incompatible input, preserve existing destination files by default, and clean up incomplete output on failure or cancellation.

## Matching clips

The first accepted clip establishes the sequence format. Check each additional file on drop. Compare coded and displayed dimensions, orientation, codec configuration, frame timing, bit depth, chroma format, color primaries, transfer function, matrix, range, HDR signaling, and audio track configuration including codec, sample rate and channel layout. Accept compatible camera output with different durations or bitrates. Reject unsupported track combinations and identify the actual mismatch, for example “Clip 3 is HLG. This sequence is SDR.” Other matching files in the drop can be added.

## Media path

Build the window in SwiftUI and ship all binaries for arm64. Use VideoToolbox with required hardware video decoding for playback, scrubbing, and visible thumbnails. Present decoded pixel buffers with GPU-backed display. Qualify supported formats on actual Apple Silicon hardware. Keep seeking responsive by canceling superseded requests and indexing in the background.

Use bundled FFmpeg demuxing and muxing libraries to read retained compressed video and audio packets, map their timestamps onto the assembled timeline, and write a single output. Keep this path independent of preview decoding. Avoid intermediate clip files and full-file thumbnail scans.

For ProRes, require matching profiles and alpha configuration across clips. Each video frame is independently coded, so trims and splits can land on any video frame. Copy the original samples, including 4444 alpha, and preserve color tags. For GUI preview, request hardware decoding when creating the VideoToolbox session. [Apple ProRes white paper](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf)

Resolve source ranges using rational timestamps. Validate independent decode starts and dependencies at outgoing cuts, including reordered frames. Map the source audio presentation clock to the same cut as video, including track offsets. For PCM, slice at sample boundaries and derive output sample counts from cumulative rational timeline positions so rounding stays within one sample across repeated cuts. For packetized audio, copy the packets needed for the selected audible interval, accounting for codec delay, preroll, and end padding. Use container timing or discard metadata only where the muxer and reference players can represent that interval at the specific join. If an exact edit would play unintended audio, omit intended audio beyond sample rounding, or accumulate drift, report the affected track and return verified joint audio/video boundaries when available. Include the effective per-track intervals in dry-run results. Preserve orientation and color metadata. Reject a boundary or combination when a clean splice cannot be established.

For compatible MOV and MP4 timecode tracks, start the export at the source timecode of the first retained picture. Timecode runs continuously across the exported timeline, including reordered ranges and source changes. Preserve drop-frame counting when the source uses it. Reject other destinations or timecode descriptions when the writer cannot represent the exported timecode.

## Build order and acceptance checks

1. **Packet-copy prototype.** Start with three matching camera originals. Assemble C–A–B, trim A, and remove the middle of B. Verify clip order, the pictures immediately before and after each join, audio sync through the final frame, and source sample identity after accounting for container framing. Exercise long-GOP footage and ProRes 422 HQ with PCM.
2. **Headless CLI.** Expose inspection, dry run, and export through the shared engine. Verify that argument and JSON requests produce the same result, including repeated ranges from one source. Test an unsafe timestamp, an incompatible clip, an existing destination, and cancellation. Each failure must identify the cause and leave the destination intact.
3. **Mac app.** Build the complete drop–arrange–trim–export workflow around the same engine. Recreate the CLI sequence by dragging clips and using the timeline. Play across each join and confirm that GUI and CLI exports contain the same retained samples with the same timing.
4. **Format and speed qualification.** Test the release matrix, including one-frame ProRes trims, 4444 alpha, PCM alignment, color tags, and orientation. Check that an incompatible clip is identified on drop. On long 4K camera recordings, measure time to first picture, seek latency, and export throughput. Compare throughput with copying the same volume of data on the same storage. Record the Mac, codec, and drive with each result. Verify hardware video decoding during preview and zero video decode or encode calls during export.

### Required regression cases

- Place audio markers immediately before and after cuts at 30000/1001 fps. Repeat cuts across PCM, AAC, and WebM Opus clips. Decode the exported movie for testing and compare marker positions with the continuous timeline at the first join and the last. Check decoder priming at interior joins. Test a requested interval the container cannot represent.
- Include H.264 and HEVC open-GOP footage with reordered pictures. Exercise both safe and unsafe starts and ends. Decode accepted exports in a fresh player and compare the displayed frames to the intended source sequence around every splice. Resubmit each suggested alternative and verify it succeeds and matches the GUI snap point.
- Exercise WebM with VP9/Opus, VP8/Vorbis, and AV1/Opus, plus MKV and MPEG-TS samples. Record which combinations pass whole-file copy, interior cuts, multi-file joins, metadata retention, seeking in the exported movie, and hardware preview. Include a readable file that the selected output muxer cannot carry.
- From a clean shell with the GUI closed and the helper off PATH, run inspect, dry run, and export using the installed absolute path. Repeat with hardware preview unavailable and confirm that valid stream copies still complete.

The first deliverable is a command-line export of three real camera clips with verified picture and audio at both joins. This establishes the timing and compatibility behavior the timeline will expose.

[VideoToolbox hardware decoder requirement](https://developer.apple.com/documentation/videotoolbox/kvtvideodecoderspecification_requirehardwareacceleratedvideodecoder) · [FFmpeg stream copy](https://ffmpeg.org/ffmpeg.html#Streamcopy)
