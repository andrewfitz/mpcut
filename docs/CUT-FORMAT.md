# MPCut project files

A `.cut` file contains one editable timeline in UTF-8 JSON. It references media by path. Opening the document does not require its media's SQLite analysis sidecars (`.cutdb`).

The [version 1 JSON Schema](schema/cut-v1.schema.json) defines both timeline types in their original form. [Version 2](#version-2) adds still-image placements. Readers reject unknown fields, duplicate object keys and unknown versions. The maximum file size is 64 MiB. Times are seconds stored as strings. Writers emit reduced fractions or integers. Readers also accept exact decimals and clock times. Reduced numerators and positive denominators must fit signed 64-bit integers. Relative paths resolve from the folder containing the document. Opening a symbolic link to a project uses the target document’s folder. A relative media path that traverses `..` requires its preceding directory to exist so MPCut can resolve symlinks to the intended recording. Spaces and `#` are literal path characters.

## Sequence

```json
{
  "format": "mpcut",
  "schemaVersion": 1,
  "kind": "sequence",
  "clips": [
    {"id": "opening", "file": "media/camera.mov", "from": "1001/30000", "to": "2"},
    {"id": "insert", "file": "media/camera.mov", "from": "0", "to": "1"}
  ]
}
```

Array order determines playback order. Each occurrence has a unique, nonblank ID and its own half-open source interval. Source start must be nonnegative and end must exceed start. A clip begins immediately after the previous clip. An empty array represents an empty timeline.

For clips with replaced audio, `file` points to the playable replacement media. Optional `originalFile` identifies the original recording. Optional `audioTrack` identifies the zero-based audio track ordinal. Optional `replacementNames` maps track ordinals (decimal JSON object keys) to display names.

## Multicam

```json
{
  "format": "mpcut",
  "schemaVersion": 1,
  "kind": "multicam",
  "referenceAngle": "wide",
  "range": {"from": "0", "to": "20"},
  "angles": [
    {"id": "wide", "file": "media/wide.mov", "audioStream": 1},
    {"id": "close", "file": "media/close.mov", "offset": "1/2"}
  ],
  "audioSources": [{"id": "boom", "file": "media/boom.wav"}],
  "audio": {"mode": "fixed", "source": "boom", "stream": 0},
  "switches": [{"at": "0", "angle": "wide"}, {"at": "6", "angle": "close"}],
  "assembly": [{"from": "6", "to": "10"}, {"from": "0", "to": "4"}]
}
```

* The group starts at zero. Source IDs are unique across camera angles and external audio. The reference angle and each switch identify existing cameras. The first switch is at zero. Subsequent switches increase strictly and precede the group end.
* Source time equals group time minus the source's signed sync offset. The default offset is zero. The optional name labels a source.
* The audio policy selects a fixed source and stream, follows each angle's selected audio stream, or specifies silence. Stream numbers are zero-based absolute media stream indices. A switch may pin its interval's audio with an `audio` object containing `source` and `stream`. The next switch resumes the project policy unless it has its own override.
* Without an assembly the entire group plays once. An assembly lists one or more half-open ranges within the group in playback order. Ranges can repeat, overlap or move backward, preserving the underlying switch decisions.

The schema checks document shape. MPCut also validates source references, timeline ranges, ordering, identifier uniqueness and numerical bounds.

## Version 2

The [version 2 JSON Schema](schema/cut-v2.schema.json) describes still-bearing projects. Set `schemaVersion` to `2`. The root `kind` remains `sequence` or `multicam`. In a sequence, `clips` is still the playback order. Each entry wraps a source clip or an inserted card. In multicam, `assembly` entries wrap a group range or an inserted card. An omitted `assembly` plays the full group.

```json
{"kind":"source","source":{"id":"opening","file":"media/camera.mov","from":"0","to":"2"}}
```

```json
{"kind":"group","group":{"from":"0","to":"2"}}
```

```json
{"kind":"still","still":{"id":"card-1","assetID":"title","duration":"2","cadence":"1/30","framing":{"mode":"fit","background":"#000000"}}}
```

- `stillAssets` holds records with `id`, `file`, `displayName`, and `fingerprint` (the file’s SHA-256 digest as hexadecimal). Paths resolve from the project directory. Multiple placements can refer to one asset ID. Keep or relink the image file when moving the project.
- `stillReplacements` holds picture-only placements with `id`, `assetID`, and `framing`. A sequence placement has `fragments` containing `{"clipID":"opening","range":{"from":"0","to":"1"}}` records in each underlying clip’s source clock. A multicam placement has one `group` range in group time, such as `{"from":"0","to":"1"}`. Source clips and camera switches stay in the project.
- `framing` has a `fit` or `fill` mode and a hex RGB `background` such as `#000000`. An optional `crop` has exact rational strings for normalized `x`, `y`, `width`, and `height`.
- `duration` and `cadence` are exact seconds strings. Cadence is the duration of each full sample. Still-only and constant-rate timelines require whole samples. On a variable-rate timeline, an insert may end with a shorter sample when the MOV-family clock represents its duration exactly.
- An optional `programColorPolicy` records `version`, `transfer`, `primaries`, `matrix`, `range`, `viewingConditions`, `diffuseWhiteNits`, and `renditionPolicyVersion`. A still-only sequence specifies `stillFormat` with `width`, `height`, `cadence`, `codec`, and `container`.

See the [still image guide](STILL-IMAGES.md) for authoring commands and export behavior.

## Edit history

A desktop save can include an optional `history` object. The current timeline is always readable directly from the root. Each of the two optional arrays, `undo` and `redo`, starts at the current timeline and proceeds outward, nearest step first. The next undo restores the state described by `undo[0]`. The named action describes the edit being undone or redone. Editors retain at most 500 steps across both branches and can select a lower limit. The closest states on each side take priority, with undo winning ties. An empty history is omitted on save.

In version 1, each step contains an `action` of 1–1024 Unicode code points and only the timeline fields that change from the preceding state on that branch. A changed scalar or object field holds its replacement value. A changed array lists its new contents in playback order. Each entry is either a literal clip, source, switch or range, or a pair `[start, count]` copying consecutive entries from the preceding state's same array. The zero-based copy ranges must fit that array and cannot overlap. An empty assembly delta restores playback of the entire group. Relative media paths throughout history use the document's own directory.

Version 2 can also store typed history deltas. These use `sequenceItems` or `assemblyItems` for ordered entries and `stillAssets` and `stillReplacements` for placement data. Each uses the same literal-or-copy array encoding. Changes to `programColorPolicy` and `stillFormat` use that encoding with zero entries for an absent value and one entry for a present value. A still edit in either undo or redo can require version 2 even when the current timeline contains only source material.

For example, if the current timeline has three clips, a history step `{"action":"Move Clip","clips":[[1,2],[0,1]]}` restores the second and third clips followed by the first. The project stores the media paths and time ranges once for this move. Conversion to another editor uses the current timeline. Export destinations and automatic analysis caches also respect recordings referenced by saved undo and redo steps, including offline originals and replacement audio. For example, if an offline recording has the name a cache would use, MPCut skips that recording’s conflicting cache and continues editing.

MPCut trims the farthest history first when the combined history would exceed one million reconstructed array entries or the complete document would exceed 64 MiB. A reader checks that the stored deltas contain at most one million array entries in total before decoding their contents. The reconstruction budget counts the clips, angles, audio sources, switches and assembly ranges in each retained state, including unchanged records. This also bounds the memory used to rebase all history paths when a document moves. A project whose current timeline fits can therefore be saved even after a large paste.
