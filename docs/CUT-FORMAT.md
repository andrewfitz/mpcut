# MPCut project files

A `.cut` file contains one editable timeline in UTF-8 JSON. It references media by path. When moving a project, take the referenced recordings, linked images and any sibling `.cut.transcripts` directory. The SQLite analysis sidecars (`.cutdb`) are optional caches.

Native saves use the [version 4 JSON Schema](schema/cut-v4.schema.json) for sequences, multicam projects, edit history, still placements and transcript attachments. MPCut also reads [version 3 documents](schema/cut-v3.schema.json). Opening a version 3 project leaves its file intact. Its next explicit save writes version 4, retaining the assembly, switch overrides, fixed soundtrack selection, attachments and edit history. Mix lanes and track replacements start empty in a version 3 project. Opening a version 1 or 2 document reports an unsupported version and preserves the file. Readers reject unknown fields, duplicate object keys and unknown versions. The maximum file size is 64 MiB. Timeline times are seconds stored as strings. Writers emit reduced fractions or integers. Readers also accept exact decimals and clock times. Reduced numerators and positive denominators must fit signed 64-bit integers. Relative paths resolve from the folder containing the document. Opening a symbolic link to a project uses the target document’s folder. A relative media path that traverses `..` requires its preceding directory to exist so MPCut can resolve symlinks to the intended recording. Spaces and `#` are literal path characters.

## Sequence

```json
{
  "format": "mpcut",
  "schema_version": 4,
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

## Multicam

```json
{
  "format": "mpcut",
  "schema_version": 4,
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
- An optional `program_color_policy` records `version`, `transfer`, `primaries`, `matrix`, `range`, `viewing_conditions`, `diffuse_white_nits`, and `rendition_policy_version`. A still-only sequence specifies `still_format` with `width`, `height`, `cadence`, `codec`, and `container`.

See the [still image guide](STILL-IMAGES.md) for authoring commands and export behavior.

## Transcripts

A sequence or multicam document can carry a `transcripts` object. Its stream offsets, sequence clock origins and import origins encode seconds as objects with signed 64-bit `numerator` and positive 64-bit `denominator` fields. Each attachment binds a content-addressed JSON asset to its media streams. A saved project named `Interview.cut` keeps its transcript assets in `Interview.cut.transcripts/` beside the document. Move that directory with the project. The asset reference includes its SHA-256 and a path relative to the document. Named selects, wording corrections, speaker changes, and their source anchors belong to the project. Imported subtitle cues retain cue-level precision.

After a Finder rename, MPCut looks for each referenced digest in the matching store beside the renamed project. It can also recover the asset from the former sibling store when the former project name is free. Saving moves verified content into the current project's store. If both project names exist, choose the intended store explicitly to recover a copy.

The [Transcriberrr result schema](schema/transcript-result-v1.schema.json) describes the sample-timed JSON accepted by transcript import. MPCut normalizes those samples to rational seconds when it writes the referenced asset. The asset and transcript JSON exported by MPCut use the editor's rational clocks.

The attachment revision changes when the transcript data used for editing changes. A word-based edit must also match the timeline revision and the selected result identity. Authored changes participate in native undo through the `transcript_authoring` history field. An external timeline export reports transcript metadata as a conversion loss. [Transcript and history schema](schema/cut-v4.schema.json)

## Edit history

A desktop save can include an optional `history` object. The current timeline is always readable directly from the root. Each of the two optional arrays, `undo` and `redo`, starts at the current timeline and proceeds outward, nearest step first. The next undo restores the state described by `undo[0]`. The named action describes the edit being undone or redone. Each new step records its origin as `user` or `agent`. Steps from older files without an origin display as `unknown`. Editors retain at most 500 steps across both branches and can select a lower limit. The closest states on each side take priority, with undo winning ties. An empty history is omitted on save.

Each step contains an `action` of 1–1024 Unicode code points and only the timeline fields that change from the preceding state on that branch. A changed scalar or object field holds its replacement value. A changed array lists its new contents in playback order. Each entry is either a literal clip, source, switch or range, or a pair `[start, count]` copying consecutive entries from the preceding state's same array. The zero-based copy ranges must fit that array and cannot overlap. An empty assembly delta restores playback of the entire group. Relative media paths throughout history use the document's own directory.

Sequence history uses `clips` and multicam history uses `assembly` for ordered entries. A literal has the same layout as its corresponding timeline item, including any occurrence angle override. Each literal in an `angles` delta includes the angle’s additional recordings. Changes to `source_selects`, `still_assets`, `still_replacements` and `transcript_authoring` use the same literal-or-copy array encoding. Changes to `program_color_policy` and `still_format` use zero entries for an absent value or one entry for a present value.

Changes to `mix_lanes` and `audio_replacements` also use literal-or-copy arrays. A `fixed_audio` delta uses zero entries to clear the remembered selection or one entry to set it.

For example, if the current timeline has three clips, a history step `{"action":"Move Clip","clips":[[1,2],[0,1]]}` restores the second and third clips followed by the first. The project stores the media paths and time ranges once for this move. Conversion to another editor uses the current timeline. Export destinations and automatic analysis caches also respect recordings referenced by saved undo and redo steps, including offline originals and replacement audio. For example, if an offline recording has the name a cache would use, MPCut skips that recording’s conflicting cache and continues editing.

MPCut trims the farthest history first when the combined history would exceed one million reconstructed array entries or the complete document would exceed 64 MiB. A reader checks that the stored deltas contain at most one million array entries in total before decoding their contents. The reconstruction budget counts timeline items, source records including additional camera files, named source selects, switches, Mix lanes, track bindings, the remembered Fixed selection, still records and transcript authoring records in every retained state, including unchanged records. This also bounds the memory used to rebase all history paths when a document moves. A project whose current timeline fits can therefore be saved even after a large paste.

### Participant geometry and composition

Version 4 sequence and multicam documents may include a `participants` object. Its `people` array holds durable person IDs, display names, optional ISO audio bindings and transcript speaker references scoped to their attachment. Each entry in `sources` carries source-relative, half-open appearance spans with normalized top-left display bounds and a separate coverage map. An appearance ID may recur in adjacent spans when bounds change. Multiple simultaneous appearances may name the same person. The project embeds accepted geometry so it travels with the edit when its analysis cache is removed.

`appearance_overrides` pin a person to an appearance on a source-time interval. The optional `render` plan contains a canvas, a default shot and optional timed shots, audio delivery and participant redactions. Group-time shots apply to every use of that part of the group. An output-time shot can target an individual assembly occurrence. Source corrections and participant masks apply to every occurrence. See the [v4 schema](schema/cut-v4.schema.json) for field names and accepted values.
