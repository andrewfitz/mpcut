# Multicam editing proposal

Multicam editing shipped in MPCut 1.2.0. For the startup controls, project JSON format, and one-command export, see the [multicam user guide](USAGE.md#edit-a-multicam-project).

This document records the original design for start-aligned recordings, hard camera switches, one output picture, and one selected output soundtrack. Its use cases include a two-camera interview with a continuous lav mic, an event that follows each camera’s microphone, and an agent assembling highlights from several angles of a demonstration.

## The editing experience

1. Choose **Add as Multicam…** and select the camera files. Confirm their names, order, and opening camera in a small setup sheet. Each recording starts at group time zero. Audio-only files can supply the master soundtrack. Adding an angle later preserves existing switches.
2. See one filmstrip per camera, a common ruler, a switch-marker lane, and the main preview. Across each interval, the selected filmstrip is bright and labeled **On air**. The others are dimmed and remain readable. Hatching identifies times outside a recording. A separate labeled audio lane shows which track will be heard.
3. Seek or play, then press **1–9** or click a camera’s switch button to take that angle at the playhead. All angles, including 10 and above, are available by name. Clicking the filmstrip itself seeks. While paused, the other angles can show the frame at the same time before the editor commits a switch.
4. A switch stays active until the next marker. Switching on an existing marker updates it. Drag a marker to retime it, or delete it to extend the previous selection. The opening selection is editable and stays at zero. Choosing the same angle can still change its microphone. Preserve explicit marker decisions in the project, including pins that currently match the default audio. Coalesce redundant spans only in the resolved export. Each change supports undo/redo.
5. Export the whole group, or mark, trim, split, and reorder ranges from it. Keep the switches editable when a range is reused. In multicam mode **Save Project** (⌘S) writes the same versioned document the CLI reads. Keep **Save Analysis Sidecars** as a separate named command. Offer Save, Discard, and Cancel before closing a changed project. Per-source analysis continues to live in the existing sidecars.

## Time and sound

- Use a single group clock expressed in exact rational seconds. Source zero means the beginning of the recording’s presentation timeline. Embedded picture offsets, audio delays, priming, and variable frame timestamps still matter. Provide a manual offset per source for cameras started a few frames apart. A positive offset places source zero later on the group ruler. Sync suggestions provide metadata and waveform evidence for manual offset changes.
- At creation, persist a reference angle and a group range from zero to the opening camera’s duration. Changing the first switch or reordering camera rows leaves both intact. Changing a source offset moves its coverage under the existing markers. Frame nudges use that source’s indexed presentation times. Keep group zero fixed. Show the full extent of all angles, allow the group end to be extended, and use assembly ranges to trim the program’s in and out points. A shorter unused angle never shortens the group. If selected picture or sound runs out, show the uncovered interval and offer a switch, another audio source, or a shorter range. Export requires coverage for the selected streams.
- **Fixed master** is the proposed default when the opening camera has sound. Pick any camera track or external recording. Its samples run continuously through picture-only switches. On setup, show the selected source and absolute stream index. If the opening camera has no sound, offer the next available source or an explicit video-only output.
- **Audio follows camera** switches to each angle’s assigned microphone. Assign streams by source, because stream index 1 can mean different things on different cameras. A marker may override the policy for its interval, for example camera B’s picture over camera A’s lav. The next marker resumes the group policy unless it has its own override. Missing sound generates a visible coverage issue. Distinguish a missing source or a recorder ending early from a valid presentation edit that contains silence. Preserve declared delays and intentional silent intervals when the destination can represent them. Report the affected interval if it cannot.
- Group-time switches and output assembly are separate. A highlight reel can use 30–40 seconds, then 5–10 seconds, from the same group. Start times are inclusive and end times exclusive. A switch exactly at the start of a retained range takes effect on its first frame. Picture and master audio both follow those ranges. The master stays continuous through camera changes within a range and makes a real audio edit at an assembly jump. Preview, export, and the JSON plan must agree on both mappings.

## Sync suggestions

In the multicam **Sources** inspector, choose **Suggest Sync…** to compare other sources with the reference camera. **Analyze** reads embedded camera timecode or Broadcast Wave sample references. Enable **Compare audio waveforms and check drift** when the sources recorded the same sound. Review each offset and click its **Apply** button to make an undoable edit. The reference camera keeps its current offset.

`mpcut multicam sync suggest --project FILE --json` analyzes all other sources. Use `--source-id ID` to limit the report or `--metadata-only` to skip audio analysis. In a live editor, `multicam_sync_suggest` returns the evidence and the project revision. Apply a reviewed value with the existing source offset edit.

- Confirm that devices shared a clock and the timestamps refer to the same recording day. A comparison between camera timecode and a Broadcast Wave time-reference assumes both use the same time-of-day clock. Missing timestamps have no numeric fallback, while a recorded timestamp of zero is valid. Metadata does not establish drift or resolve date rollover.
- Waveform matching compares up to five windows per baseline at 20 ms resolution. It searches within 30 seconds of the current or metadata-based alignment and uses the assigned audio stream or the first usable stream. Silence, repetitive audio, and weak matches may yield no result.
- The waveform suggestion uses the earliest reliable window. Drift is the measured offset change between the earliest and latest reliable windows if they are at least 30 seconds apart. A zero reports agreement at waveform resolution. Offset edits shift source starts and preserve playback speed.

## Export contract

There are three integration changes. The current `ClipRequest` and desktop `PreviewRange` each carry one source URL. The packet writer takes a segment list and an export-wide audio selector. A fixed external mic or per-switch mic therefore needs independent picture and sound mappings through planning, playback and muxing. Calling the current writer once per marker could split a continuous master or repeat AAC priming. The new core planner should resolve picture and sound into independent lists of source ranges on the same output clock. Merge adjacent ranges when the selected source, stream, source time and output time are continuous. Apply coverage, boundary and container checks to the tracks requested for output. A video-only export can omit a missing mic. An audio-only export of a fixed WAV can ignore an unsafe camera cut. Reuse the existing frame index, audio clocks, Smart Trim eligibility checks, and packet-copy checks. The desktop and CLI should call the same planner and writer.

| Mode | Multicam behavior |
| --- | --- |
| Smart Trim, default | Validate the selected camera streams. Copy complete safe video ranges and encode only necessary supported edges. Attempt audio stream copy independently and identify the exact audio joins that cannot be copied. |
| Lossless Copy | Verify both the outgoing end and incoming start at each switch, plus any real audio splice. Offer a nearby jointly valid time when available. Moving a switch requires an explicit edit or snap choice. |
| Re-encode | Offer this mode only when the conversion planner supports every selected source and the requested output. The current encoder also checks multi-source compatibility. Mixed frame rates, dimensions or color spaces require a defined normalization path before the app can offer conversion. Preserve eligible audio. Any audio conversion must be authorized by the chosen policy. |

Matching codec names alone do not establish compatibility. Check the selected video profiles, dimensions, frame timing, codec configuration, color/orientation metadata, and destination constraints. Ignore an unused camera microphone when a separate master is selected. Report a missing frame, incompatible stream, or unsafe splice against its angle, stream, switch time, and affected output interval. Do not silently move a cut, omit audio, convert the entire recording, or accumulate timing error.

**Switch timing.** Track the group marker, each source’s presentation time (`group time − source offset`), and the output time after assembly. Record a live switch against the displayed program playback clock when the input arrives. A slow thumbnail or preview decode must not shift the recorded switch. The reference angle supplies GUI frame-step positions wherever it has coverage. Beyond its coverage, step on the selected angle’s indexed frames. At an exact marker, the incoming angle is active. To preview a source at time `t`, show the frame whose presentation interval contains `t`. Holding that picture for preview establishes neither an exact source boundary nor a copy-safe start.

Preserve typed CLI times exactly. For an exact export, check the outgoing end, incoming start and any real audio splice at the **same group instant**. Never round the two cameras independently. At 25 fps, two cameras offset by 10 ms can have no shared frame boundary anywhere. Smart Trim can encode a GOP edge at a supported frame cut. Creating a fractional frame or retiming an entire angle is a different operation. If no joint time exists, report that fact and offer adjustment of the offset or a supported conversion. When a nearby valid switch exists, preview its effective time before applying it. A fixed mic needs no packet or sample boundary at a picture-only switch.

## CLI and project format

Proposed CLI entry points reuse familiar commands. The project contains the angle list, stable IDs, offsets, master track or follow policy, and time-ordered switch decisions. Paths in a saved project resolve relative to the project file. Relative paths in a request sent through stdin retain the existing working-directory convention. Reordering rows or renaming a camera must preserve decisions made against its ID.

```json
{
  "format": "mpcut",
  "schema_version": 3,
  "kind": "multicam",
  "reference_angle_id": "wide",
  "group_range": {"from": "0", "to": "40"},
  "angles": [
    {"id": "wide", "file": "wide.mov", "offset": "0"},
    {"id": "close", "file": "close.mov", "offset": "0"}
  ],
  "audio": {"mode": "fixed", "source_id": "wide", "audio_stream_index": 1},
  "switches": [
    {"group_time": "0", "angle_id": "wide"},
    {"group_time": "12", "angle_id": "close"},
    {"group_time": "20", "angle_id": "wide"}
  ],
  "assembly": [{"from":"30","to":"40"},{"from":"5","to":"10"}]
}
```

This 40-second group saves a 15-second highlight reel. Export uses the ordered `assembly` when present, otherwise the full group range. Stream 1 is the wide camera’s microphone. Twelve and twenty seconds are example switch times. The source index and preflight determine whether they are usable on a particular recording.

For a follow-camera edit, set the project’s `audio` to `{"mode":"follow"}` and assign each angle its preferred `audio_stream_index`. An individual switch can hold a microphone while changing picture.

```json
{"group_time":"12","angle_id":"close","audio":{"source_id":"wide","audio_stream_index":1}}
```

For a separate recorder, declare `"audio_sources":[{"id":"lav","file":"lav.wav","offset":"0"}]` and choose `{"mode":"fixed","source_id":"lav","audio_stream_index":0}`. A source ID must be unique across both lists. The app should write these same records when a user makes the equivalent choices in the GUI.

```sh
mpcut help multicam --json
mpcut inspect --project interview.cut --json
mpcut export --project interview.cut --mode smart --output interview.mov --dry-run --json
mpcut export --project interview.cut --mode smart --output interview.mov --json
```

- Discovery should include a minimal editable JSON template and examples for fixed, follow, and overridden audio. Validate unknown angle IDs, repeated IDs, conflicting switches at the same instant, missing files, unavailable streams, and out-of-range decisions. Require a selection at the group start and strictly increasing switch times before the exclusive end. Write project changes atomically. Reject unsupported schema versions before editing or saving.
- Inspection should return angle coverage, indexed stream choices, and effective picture/audio intervals in group time. Export preflight should also return output time, original source time and stream IDs, packet-copy versus encode actions, and proposed timing alternatives. The existing explicit track-selection flags select stream copy. Preserve that contract and report a conflict if a project request explicitly asks for both single-type output and encoding under those flags.
- For an explicit ordered request such as `{"clips":[{"project":"interview.cut","from":"12","to":"20"}],"output":"answer.mov","mode":"smart"}`, a clip selects exactly one of `file` or `project`. A project clip always addresses original group time, even when the document has a saved assembly. A bare `export --project` renders the saved assembly. The GUI should distinguish editing a group switch (all occurrences update) from trimming an occurrence in the assembly (only that occurrence changes).
- For visual review, extend frame export to return aligned JPEGs for every available angle at requested group times. Its manifest should include group time, angle ID, actual source frame time, and availability. An agent can compare framings, write switches, and inspect the resulting program without decoding every angle continuously. Scene and silence analysis stay source-specific and map onto the group clock.
- Store reusable indexes, thumbnails, waveforms, and detections in the existing per-recording sidecars. Save manual sync, switches, and the audio policy explicitly in the project. Offer relinking if a source moves and revalidate timing if it changes.

## Delivery and acceptance

1. **Core, project and CLI.** Implement the model, clock mapping, dry run and writer with a fixed master first. Then add follow-camera and per-marker overrides. First prove a wide → close → wide cut with an uninterrupted external mic and incompatible unused camera mics. Verify output pictures, decoded audio samples, copied payload hashes where applicable, and reported encoded edges.
2. **Desktop editor.** Add setup, synchronized filmstrips, labeled selection and audio lanes, switching during play, scrubbing, undo, manual offsets, and project save/reopen. Compare GUI exports against CLI exports from the same saved decisions. Generate thumbnails only for visible ranges, reuse sidecars, and decode the program angle for ordinary playback. Measure four-camera seek and switch latency, dropped frames, and memory before offering simultaneous live previews.
3. **Assembly and agent review.** Support reordered/repeated group ranges and aligned JPEG review. Exercise a camera that ends early, missing mic, fixed external WAV, per-marker audio overrides, delayed AAC, mismatched codecs, off-grid switches, VFR, and fractional frame rates. Check long timelines for drift and a failed preflight for actionable errors and no output file.

A practical acceptance test uses four angles and a separate WAV. Switch cameras at least twenty times, keep one continuous master over those switches, then rearrange two highlights. The CLI plan, editor preview, and exported media must identify the same picture and sound at every join. On a copy-safe fixture the selected compressed packets should match their sources; on an eligible off-keyframe fixture only the predicted video edges should be encoded.

Additional release checks:

- At 30000/1001 fps and 48 kHz, five frame periods equal exactly 8,008 audio samples. Place picture switches at individual frames and verify the uninterrupted master against an independent decode. At a real audio cut, validate that specific codec, sample boundary and container.
- Reopen a saved project after reordering camera rows and changing its opening selection. Its reference, stored duration, master source, and highlight order must survive. Repeat a range and verify a group switch appears in both occurrences while an occurrence trim affects only one.
- Cancel or encounter a changed source during export. Leave the prior project and any destination created by another process intact, clean up partial media, and return a structured CLI diagnostic. Verify old single-source requests and their export-mode defaults still work.
