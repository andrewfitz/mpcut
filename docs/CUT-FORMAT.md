# MPCut project files

A `.cut` file contains one editable timeline, its transcript assets, recording annotations and unfinished Tiles reviews. MPCut saves one UTF-8 JSON object. To move a project, copy the document and its linked recordings and images. MPCut can rebuild a recording’s SQLite `.cutcache` from the media.

Sequence, still and multicam timelines use schema version 9. Opening a document with an earlier version reports an unsupported version. To validate a saved project, expand it with `mpcut project document print interview.cut > interview.json` and validate the result against the version 9 schema. The command also accepts standard input with `-` and works offline. [Project JSON Schema](schema/cut-v9.schema.json)

Timeline times are seconds stored as strings. Writers emit reduced fractions or integers. Readers also accept exact decimals and clock times. Reduced numerators and positive denominators must fit signed 64-bit integers. Relative paths resolve from the folder containing the document. Opening a symbolic link to a project uses the target document’s folder. A relative media path that traverses `..` requires its preceding directory to exist so MPCut can resolve symlinks to the intended recording. Spaces and `#` are literal path characters.

## Media snapshot

The optional root `media_snapshot` stores descriptions and content evidence for referenced paths. Version 1 uses an `entries` array. Each entry has a `path`. Snapshot timing fields use integer `numerator` and `denominator` members. Readers preserve unknown entry fields and can open a project with no snapshot. A transcript fingerprint identifies the source generation used to collect the accompanying evidence. `evidence_sha256` is the SHA-256, in lowercase hex, of the recording's content evidence as JSON with sorted keys: digests of each stream's configuration, packets and timing, with the container's format, origin and duration. MPCut writes it only when that evidence covers every audio and video stream. Relink uses the two values to confirm that a file is the same recording before updating a binding.

A missing snapshot entry means the reader has less evidence for locating that source. Saved layouts preserve the snapshot as written.

## Saved reference table

When the root contains `refs`, expand the document using these rules. The table leaves `schema_version` unchanged.

- A string `"~KEY"` refers to a string in `refs`. The referenced string is literal text. `"~~example"` represents the literal `"~example"`.
- An object `{"~": "KEY"}` refers to an array or object in `refs`. Expand references within that value recursively. MPCut writes these object references inside `history`.
- Copy `media_snapshot` as written and remove `refs` from the expanded document.

MPCut derives each key from the first 50 bits of the SHA-256 of the value's expanded JSON, encoded using `0123456789abcdefghjkmnpqrstvwxyz`. The writer uses sorted object keys and omits formatting whitespace when computing the hash. It writes a fixed last entry, `"~": ""`, so adding a reference leaves the previous last entry's line intact. A merge can leave unused entries or duplicate copies of an identical entry. Conflicting entries under one key and missing references are errors.

A Replace edit can store `transcript_bindings` on its undo or redo step. Each change identifies an existing binding by `attachment_id` and `track_id` and carries its `before` and `after` values in the direction of that step. Applying it updates only a matching binding. An attachment added after the edit survives undo.

## Version control

A project is one text file that Git, a text editor and MPCut can each change.

**Layout.** MPCut sorts field names and derives reference keys from their values. The edit has one field to a line. Each undo step, each recording in `media_snapshot` and each `refs` entry takes one line. A change to one clip changes a few lines, and an unchanged project saved again writes the same bytes.

**Editing as text.** Change the clips and other edit fields directly. A `file` can be a plain path or a `"~KEY"` reference; a new clip needs an `id` no other clip has. Leave `history`, `media_snapshot` and `refs` as they are, or delete `history`. Check the result with `mpcut project inspect --project FILE --json`.

**History follows the edit.** An undo step describes its change by position in the timeline it was made on. A saved `history` therefore carries `base`, a key formed like a `refs` key from the document without `history`, `media_snapshot`, `embedded_assets` and `refs`. When the edit no longer matches, as after a change made in the text or a merge, MPCut opens the project with an empty history and the next save starts a new one. `base` belongs to the saved layout: the expanded document has none, and a history without one is read as it is.

**Merging.** Branches whose projects were changed only as text merge as any text does. Each save by MPCut also rewrites the `history` line and can add a recording line, so two branches saved by MPCut conflict in those lines under Git's own merge. Register MPCut's merge once in each clone:

```sh
git config merge.mpcut.driver "mpcut project merge %O %A %B"
echo '*.cut merge=mpcut' >> .gitattributes
```

Git then runs `mpcut project merge` for each project. It merges the edit line by line, combines the media snapshot recording by recording and collects embedded assets by digest. The merged edit starts a new history. When both branches changed the same clip, or each added clips in the same place, it leaves the project as plain JSON with Git's conflict markers around those lines only. A clone without the `git config` line uses Git's own merge.

`mpcut project document print FILE` writes the expanded project as readable JSON, with each path written out in full.

Embedded payloads travel with the project in version control. Linked media remain separate files.

## Sequence

```json
{
  "format": "mpcut",
  "schema_version": 9,
  "kind": "sequence",
  "clips": [
    {"id": "opening", "file": "media/camera.mov", "from": "1001/30000", "to": "2"},
    {"id": "insert", "file": "media/camera.mov", "from": "0", "to": "1"}
  ]
}
```

Array order determines playback order. Each occurrence has a unique, nonblank ID and its own half-open source interval. Source start must be nonnegative and end must exceed start. A clip begins immediately after the previous clip. An empty array represents an empty timeline.

For clips with replaced audio, `file` points to the playable replacement media. Optional `original_file` identifies the original recording. Optional `track_ordinal` identifies the zero-based audio track ordinal. Optional `replacement_names` maps track ordinals (decimal JSON object keys) to display names.

A sequence can save named source intervals in `source_selects`, including intervals from files absent from `clips`. Select IDs are unique within the list. Both the ID and name must be nonblank. Each range uses a half-open interval in the file’s own clock. Its paths resolve relative to the project.

```json
"source_selects": [
  {"id": "reaction", "name": "Reaction shot", "range": {"file": "media/reaction.mov", "from": "5/2", "to": "4"}}
]
```

## Still soundtrack

A still-only sequence with an explicit `still_format` can attach one recording in the optional root `still_soundtrack` field.

```json
"still_soundtrack": {
  "id": "cover-recording",
  "file": "Recordings/voice.wav",
  "track_ordinal": 0,
  "from": "0",
  "to": "48001/48000"
}
```

The clip ID identifies the attachment in Project Media and history. The path resolves relative to the project, and `track_ordinal` selects a zero-based audio track within that file. The half-open source interval begins at program zero. Image changes and moves preserve this mapping. Preview and export intersect the recording with the program or selected range. When picture extends beyond the recording, the remaining interval is silent. When picture ends earlier, export trims the soundtrack at the selected program end.

Fitting one image to this example sets its duration to `48001/48000` seconds. Fitting or entering a duration between picture grid points in a soundtrack project sets `exact_duration: true` on the insert. Dragging the image edge uses the project's frame grid. Detaching the soundtrack keeps the authored image duration.

Undo and redo store an attachment change as a `still_soundtrack` list delta. An empty list removes the attachment. Media snapshots can retain the recording's identity and technical description for relink. Timeline interchange reports the omission of an attached soundtrack when the destination cannot represent it.

## Multicam

```json
{
  "format": "mpcut",
  "schema_version": 9,
  "kind": "multicam",
  "reference_angle_id": "wide",
  "group_range": {"from": "0", "to": "20"},
  "angles": [
    {
      "id": "wide",
      "file": "media/wide.mov",
      "audio_stream_index": 1,
      "group_coverage": {"from": "0", "to": "10"},
      "additional_recordings": [
        {"id": "wide-restart", "file": "media/wide-2.mov", "offset": "12", "audio_stream_index": 1, "group_coverage": {"from": "12", "to": "20"}}
      ]
    },
    {"id": "close", "file": "media/close.mov", "offset": "1/2"}
  ],
  "audio_sources": [{"id": "boom", "file": "media/boom.wav"}],
  "audio": {"mode": "fixed", "source_id": "boom", "audio_stream_index": 0},
  "switches": [{"group_time": "0", "angle_id": "wide"}, {"group_time": "6", "angle_id": "close"}],
  "assembly": [{"from": "0", "to": "4"}, {"kind": "group", "from": "0", "to": "4", "angle_id": "close"}]
}
```

* The group starts at zero. Source IDs are unique across camera angles, their additional recordings and external audio. The reference angle and each switch use camera angle IDs. The first switch is at zero. Subsequent switches increase strictly and precede the group end.
* Source time equals group time minus the source's signed sync offset. The default offset is zero. The optional name labels a source.
* A camera can specify an explicit half-open `group_coverage` range for its first file. When a camera has `additional_recordings`, every file on the angle needs its own coverage. Coverage starts at or after the file’s offset. File ranges on the same angle cannot overlap. Gaps between files remain gaps, and a switch can stay on the angle across file boundaries. External audio sources use the single-file format.
* The audio policy selects a fixed source and stream, follows each angle’s selected stream, mixes the selected lanes, or specifies silence. Stream numbers are zero-based absolute media stream indices. In Fixed, Follow and None, a switch may pin its interval’s audio with an `audio` object containing `source_id` and `audio_stream_index`. The next switch resumes the project policy unless it has its own override. Mix preserves switch overrides and routes its lanes continuously through picture switches.
* Without an assembly the entire group plays once. An assembly lists one or more half-open ranges within the group in playback order. Ranges can repeat, overlap or move backward. A plain `{"from":"0","to":"4"}` occurrence uses the group’s camera switches. A `kind: "group"` occurrence with an `angle_id` uses that camera’s picture for the whole interval. All occurrences use the group’s audio decisions.

The schema checks document shape. MPCut also validates source references, timeline ranges, ordering, identifier uniqueness and numerical bounds.

### Mix lanes and track bindings

Set `audio` to `{"mode":"mix"}` and provide a nonempty `mix_lanes` array in playback and export track order. A camera target follows the configured streams on the camera’s successive recordings. A recording target pins one recording or external source and one absolute audio stream. The target’s `kind` distinguishes the camera ID from the identical ID of its first recording. Each lane has a unique ID, a nonblank label and a palette slot from 0 through 7. Multiple channels in one stream share a lane. Two lanes cannot resolve to the same source, stream and placement.

```json
"audio": {"mode":"mix"},
"fixed_audio": {"source_id":"boom","audio_stream_index":0},
"mix_lanes": [
  {"id":"wide-mic","target":{"kind":"camera","angle_id":"wide"},"label":"Wide mic","color_slot":0},
  {"id":"boom-mic","target":{"kind":"recording","source_id":"boom","audio_stream_index":0},"label":"Boom","color_slot":3}
]
```

`fixed_audio` remembers the Fixed selection in other modes. When present in Fixed mode, it must match the source and stream in `audio`. Store inactive Mix lanes in the same `mix_lanes` field. Both settings survive mode changes.

A track replacement binds an original camera recording and stream to a stream on a project `audio_sources` entry. The binding applies to every route that selects the original stream. Assign each binding a unique ID and bind each original stream at most once. The replacement uses the camera recording’s group offset plus the binding’s signed rational `relative_offset`. A camera clap at local time 12 and a replacement clap at local time 2 give a relative offset of `"10"`. If recorded coverage runs out, `keep_original` uses available scratch audio there and `leave_uncovered` records a gap. A replacement used by several camera recordings can have a different offset in each binding. To also route the same file directly in a Fixed selection, switch override, or Mix lane, give the direct route its own source ID.

```json
"audio_replacements": [
  {
    "id":"wide-lav",
    "original":{"source_id":"wide-restart","audio_stream_index":1},
    "replacement":{"source_id":"lav","audio_stream_index":0},
    "relative_offset":"10",
    "uncovered":"keep_original"
  }
]
```

This binding uses an `audio_sources` entry with ID `lav`.

## Still placements

Insert a card in a sequence’s `clips` or a multicam project’s `assembly` with the following item.

```json
{"kind":"still","still":{"id":"card-1","asset_id":"title","duration":"2","cadence":"1/30","framing":{"mode":"fit","background":"#000000"}}}
```

- A linked image in `still_assets` has an `id`, `file`, `display_name`, and `fingerprint` (the file’s SHA-256 digest as hexadecimal). Paths resolve from the project directory. Multiple placements can refer to one asset ID. Keep or relink the image file when moving the project.
- A generated color gap in `still_assets` has just two fields, for example `{"id":"pause","kind":"gap"}`. Each gap is a still insert that refers to this ID. Its `duration` sets the spacing and its `framing.background` sets the solid color. Several gaps can share one ID and have different colors or durations. The project is portable without an image file for these gaps.
- `still_replacements` holds picture-only placements with `id`, `asset_id`, and `framing`. A sequence placement has `fragments` containing `{"clip_id":"opening","range":{"from":"0","to":"1"}}` records in each underlying clip’s source clock. A multicam placement has one `group` range in group time, such as `{"from":"0","to":"1"}`. Source clips and camera switches stay in the project.
- `framing` has a `fit` or `fill` mode and a hex RGB `background` such as `#000000`. An optional `crop` has exact rational strings for normalized `x`, `y`, `width`, and `height`.
- `duration` and `cadence` are exact seconds strings. Cadence is the duration of each full sample. Still-only and constant-rate timelines require whole samples. On a variable-rate timeline, an insert may end with a shorter sample when the MOV-family clock represents its duration exactly.
- An optional `program_color_policy` records `version`, `transfer`, `primaries`, `matrix`, `range`, `viewing_conditions`, `diffuse_white_nits`, and `rendition_policy_version`. Rendition policy 2 shows a gain-map image on an SDR program as its SDR base; policy 1 showed its HDR rendition tone-mapped to SDR. MPCut opens a policy 1 project with policy 2, which changes only those images, and saves it as 2. A still-only sequence specifies `still_format` with `width`, `height`, `cadence`, `codec`, and `container`.

See the [still image guide](STILL-IMAGES.md) for authoring commands and export behavior.

## Transcripts

A sequence or multicam document can carry a `transcripts` object. Its stream offsets, sequence clock origins and import origins encode seconds as objects with signed 64-bit `numerator` and positive 64-bit `denominator` fields. Each attachment binds a transcript to its media streams. Named selects, wording corrections, speaker changes and source anchors belong to the project. Subtitle cues retain cue-level precision.

An attachment’s `asset.sha256` selects an entry from the root `embedded_assets.transcripts` object. The value is a version 4 transcript document. It contains the words, speakers, provenance and any activity frames the provider supplied. Sample-timed imports retain their exact bounds as rational seconds on the track’s source clock. [Stored transcript schema](schema/transcript-document-v4.schema.json) · [Transcriberrr result schema](schema/transcript-result-v1.schema.json)

Each embedded asset’s key is the lowercase SHA-256 of the canonical JSON written by its asset encoder, using sorted keys, compact separators and the original array order. A project writes each referenced digest once across the edit and its retained history. The reader checks the digest and the references. Copying or renaming the project preserves these assets.

The attachment revision changes when the transcript data used for editing changes. A word-based edit must also match the timeline revision and the selected result identity. Undo and redo restore changes to words and speakers through the `transcript_authoring` history field. All timeline revisions share the current attachment list, so a detached transcript stays detached when the editor undoes a timeline edit. An external timeline export reports transcript metadata as a conversion loss. [Transcript and history schema](schema/cut-v9.schema.json)

## Edit history

A desktop save can include an optional `history` object. The current timeline is always readable directly from the root. Each of the two optional arrays, `undo` and `redo`, starts at the current timeline and proceeds outward, nearest step first. The next undo restores the state described by `undo[0]`. The named action describes the edit being undone or redone. Each new step records its origin as `user` or `agent`. Steps from older files without an origin display as `unknown`. Editors retain at most 500 steps across both branches and can select a lower limit. The closest states on each side take priority, with undo winning ties. An empty history is omitted on save.

Each step contains an `action` of 1–1024 Unicode code points and only the timeline fields that change from the preceding state on that branch. A changed scalar or object field holds its replacement value. A changed array lists its new contents in playback order. Each entry is either a literal clip, source, switch or range, or a pair `[start, count]` copying consecutive entries from the preceding state's same array. The zero-based copy ranges must fit that array and cannot overlap. An empty assembly delta restores playback of the entire group. Relative media paths throughout history use the document's own directory.

Sequence history uses `clips` and multicam history uses `assembly` for ordered entries. A literal has the same layout as its corresponding timeline item, including any occurrence angle override. Each literal in an `angles` delta includes the angle’s additional recordings. Changes to `source_selects`, `still_assets`, `still_replacements` and `transcript_authoring` use the same literal-or-copy array encoding. Changes to `program_color_policy` and `still_format` use zero entries for an absent value or one entry for a present value.

Changes to `mix_lanes` and `audio_replacements` also use literal-or-copy arrays. A `fixed_audio` delta uses zero entries to clear the remembered selection or one entry to set it.

For example, if the current timeline has three clips, a history step `{"action":"Move Clip","clips":[[1,2],[0,1]]}` restores the second and third clips followed by the first. The project stores the media paths and time ranges once for this move. Conversion to another editor uses the current timeline. Export destinations and automatic analysis caches also respect recordings referenced by saved undo and redo steps, including offline originals and replacement audio. For example, if an offline recording has the name a cache would use, MPCut skips that recording’s conflicting cache and continues editing.

## Recording annotations

The optional `analysis_annotations` object holds project-specific recording decisions. A named scene view carries its report with the original source-clock ranges and scene membership. A manual silence threshold identifies the recording and stream and accepts fractional dBFS values. The saved evidence identifies the stream content or the full file by SHA-256. Two projects using the same recording can retain different decisions.

`pause_reviews` stores protected spans, retained silence durations and manual markers. Each entry names the occurrence when applicable and carries the source evidence and exact time it was reviewed against. These choices can appear in undo and redo history.

### Participant geometry and composition

Version 9 sequence and multicam documents may include a `participants` object. Its `people` array holds durable person IDs, display names, optional ISO audio bindings and transcript speaker references scoped to their attachment. Each entry in `sources` carries source-relative, half-open appearance spans with normalized top-left display bounds and a separate coverage map. An appearance ID may recur in adjacent spans when bounds change. Multiple simultaneous appearances may name the same person. The project embeds accepted geometry so it travels with the edit when its analysis cache is removed.

`appearance_overrides` pin a person to an appearance on a source-time interval. The optional `render` plan contains a canvas, a default shot and optional timed shots, audio delivery and participant redactions. Group-time shots apply to every use of that part of the group. An output-time shot can target an individual assembly occurrence. Source corrections and participant masks apply to every occurrence. See the [project schema](schema/cut-v9.schema.json) for field names and accepted values.

### Tiles layouts, treatments and feed angles

The project stores `tile_layouts` on sequence clips, `group_tile_layouts` on the multicam group, and `tile_layouts` on multicam assembly occurrences with stable IDs. Layout ranges are half-open in the clip's source clock or multicam group clock. An occurrence layout takes precedence over the group layout. An explicit Original on an occurrence clears the group layout there. Sequence clips own their layouts independently, including clips cut from the same recording.

Each entry in `participants.pending_reviews` names its target picture source, its linked recording and the `scan_sha256` of an immutable scan in `embedded_assets.tile_scans`. Two multicam sources can use the same file and retain distinct review choices. The review stores names, merges, exclusions and grid corrections separately from the scan. Accepting the review publishes the geometry and layouts to the edit. The document retains its scan while a pending review or retained history refers to it.

A layout span stores the range and layout along with any ordered `slots`. An arranged slot can identify the destination tile in `destination_tile_id` and use target `empty` to leave a position blank. A feed's `treatment` lives on its entry in `participants.people` and applies in every layout, including Original. The `participants.tile_output` settings carry canvas, audio and unresolved-privacy policy. Migrated compositions can retain legacy `render` data for the participant command compatibility projection.

An unassigned legacy presentation becomes a feed with its own stable ID. Its `legacy_presentation` records the original `source_id`, `appearance_id` and initial `name`. The legacy participant commands use that record to return untouched shares as presentation appearances and preserve their original IDs on apply.

A geometry source can store compact `scan_events`, `count_hints`, `historical_participant_ids` and `privacy_confirmations`. A confirmation refers to a feed, source-time range and the geometry's media and analysis identity. The confirmation's `review_digest` identifies the accepted geometry, review state and treatment. A multicam angle's `feed_angle` object points to its parent picture source and feed. `speaker_angles` links transcript voice references to angle IDs.

Multicam history can edit `group_tile_layouts` and `speaker_angles` with the existing literal-or-copy array encoding. A conversion between sequence and multicam uses a `timeline` snapshot on the history step, optionally with `transcript_bindings`. That step stores any transcript authoring with the timeline, and the document retains the shared transcript attachments. [Version 9 JSON Schema](schema/cut-v9.schema.json)
