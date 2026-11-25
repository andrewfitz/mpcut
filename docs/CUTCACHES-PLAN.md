# cutcaches and saved work

**A cutcache is disposable.** With MPCut closed, you can delete every `.cutcache` file by hand. When you reopen the project with its linked media, every transcript, decision and unfinished edit must still be there. The cost of deletion is time spent rebuilding indexes, previews or automatic analysis. Recovery must require zero recognition-provider calls and zero repeated editorial decisions.

## Schema 9 on-disk layout of a .cut

Use one UTF-8 JSON object. Keep the redesigned document’s `format`, `kind`, `clips` or multicam edit, exact timeline times, `media_snapshot`, `history` and saved `refs` layout. Use schema version **9**. Add a project-wide `embedded_assets` object for immutable data and `participants.pending_reviews` for the editable state of unfinished reviews. This expanded example shows one transcript attachment and one pending review of the same camera recording.

**No backwards compatibility.** Version 9 reads only version 9 projects and the new SQLite cutcaches. Earlier `.cut` schemas, `.cutdb` files, `<project>.cut.transcripts/` and `<project>.cut.tile-review/` directories are not read or migrated. An earlier project gets a clear unsupported-version error. Delete the code that exists only for them: `readableSchemaVersions` 3–8, the `.cutdb` reader and `SidecarCacheCleaner` legacy cleanup, `TranscriptStore`'s companion directory and its publish step in `ProjectFile.writeRevision`, `TilesPendingReview`'s companion and Application Support directories, and the history and keyed-layout branches for older schemas. [Current project format](CUT-FORMAT.md) · [Project schema](schema/cut-v9.schema.json)

```json
{
  "format": "mpcut", "schema_version": 9, "kind": "sequence",
  "clips": [{"id": "opening", "file": "media/Camera.mov", "from": "5", "to": "9"}],
  "transcripts": {
    "attachments": [{
      "id": "interview", "asset": {"sha256": "ae082bd9954aad6f311c3137ba68137ad44dfe2a572a47082410a1d28374d150"},
      "bindings": [{"track_id": "mic", "file": "media/Camera.mov", "audio_stream_index": 1, "offset": {"numerator": 0, "denominator": 1}}]
    }], "authoring": [], "revision": 1
  },
  "participants": {
    "pending_reviews": [{
      "id": "review-1", "source_id": "media/Camera.mov", "file": "media/Camera.mov",
      "scan_sha256": "6acdefeacc175043dca2b7df41e66e172e91e440ef399bd3381f8ab637f21aca",
      "choices": {"analysisIdentity": "scan-1", "names": {"feed-1": "Alex"}, "unchecked": [], "merged": {}, "expectedFeeds": "", "expectedTiles": "", "grids": []}
    }]
  },
  "embedded_assets": {
    "transcripts": {
      "ae082bd9954aad6f311c3137ba68137ad44dfe2a572a47082410a1d28374d150": {
        "schema_version": 4, "clock": "presentation", "approximate_clock": false,
        "tracks": [{"id": "mic", "name": "Camera audio", "origin": "0", "session_start": "0", "coverage": "recognized", "role": "mixed_audio", "provider_activity": [{"start": "5", "end": "251/50", "level": 0.25}]}],
        "speakers": [{"id": "s1", "name": "Alex"}],
        "words": [{"i": "w1", "t": "Hello", "s": "5", "e": "11/2", "p": "s1", "c": 0.93}]
      }
    },
    "tile_scans": {
      "6acdefeacc175043dca2b7df41e66e172e91e440ef399bd3381f8ab637f21aca": {
        "state": "completed", "analysis_identity": "scan-1",
        "source": {
          "stamp": {"bytes": 1000, "modified_seconds": 1, "modified_nanoseconds": 0}, "content_sha256": "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
          "stream": 0, "origin": {"numerator": 0, "denominator": 1}, "time_base": {"numerator": 1, "denominator": 30},
          "duration": {"numerator": 9, "denominator": 1}, "transform": {"rotation": "R0", "pixel_aspect_num": 1, "pixel_aspect_den": 1}
        },
        "configuration": {"backend": "cpu", "sampling": "sparse", "include_scenes": false},
        "analysis": {
          "schema_version": 1, "start": {"numerator": 0, "denominator": 1}, "end": {"numerator": 9, "denominator": 1}, "sampling": "sparse",
          "observations": [{"timestamp": {"numerator": 0, "denominator": 1}, "display": {"rotation": "R0", "pixel_aspect_num": 1, "pixel_aspect_den": 1}, "confidence": 1, "regions": [{"appearance_id": 1, "participant_id": 1, "rect": {"x": 0, "y": 0, "width": 1, "height": 1}, "kind": "video", "role": "primary", "confidence": 1, "identity_confidence": 1, "identity_uncertain": false, "possible_matches": []}]}],
          "tracks": [{"id": 1, "appearance_ids": [1]}],
          "appearances": [{"id": 1, "participant_id": 1, "start": {"numerator": 0, "denominator": 1}, "end": {"numerator": 9, "denominator": 1}}],
          "events": [],
          "coverage": [{"start": {"numerator": 0, "denominator": 1}, "end": {"numerator": 9, "denominator": 1}, "status": "inferred"}],
          "diagnostics": [{"timestamp": {"numerator": 0, "denominator": 1}, "backend": "cpu"}],
          "resume_at": null
        }
      }
    }
  }
}
```

- **Transcript.** `transcripts.attachments[].asset.sha256` resolves to a document in `embedded_assets.transcripts` in the same file. The asset is the latest stored transcript form, version **4**: version 3 (exact text times, one-letter word rows, defaults left out) plus an optional per-track `provider_activity`. Activity a provider supplied cannot be measured again, so it travels with the words. Audio levels MPCut measures itself stay in the cutcache. The LZFSE wrapper is not used inside the project, so the asset is ordinary nested JSON. The attachment binds each track to the recording and audio stream. Project corrections in `transcripts.authoring` address the attachment and its source anchors. Moving a clip changes where its words appear on the timeline. It leaves the source words alone. [Stored transcript form](schema/transcript-document-v4.schema.json)
- **Tiles.** `participants.pending_reviews[].scan_sha256` resolves to the exact reviewed scan in `embedded_assets.tile_scans`. The asset is the existing `ParticipantScanResult` encoding, with the two machine-local fields removed from its source: the path and the inode. Each pending review identifies the project picture source by `source_id` (the recording ID for multicam, the clip’s source path for sequences). Acceptance applies choices to that source even when another source uses the same file. The pending review's `file` carries the path, so relinking never changes an immutable asset. The source stamp, content digest and stream identify the recording. An embedded scan exists only for a pending review. Acceptance publishes the existing `participants.people` and `participants.sources` edits and the applicable clip or group layouts, then drops the review. The scan stays only while undo history still reaches it, so accepted geometry is not stored twice. Project decisions and pending choices can change independently of the scan. The identical display name “Alex” in two features never links them automatically. An explicit transcript speaker reference links a feed to an attachment and speaker ID. [Tiles and feed bindings](CUT-FORMAT.md#participant-geometry-and-composition)
- **Pending reviews are document edits.** Each choice marks the project edited, enters undo, and is covered by autosave and draft recovery like any other edit. Two processes editing the same `.cut` resolve through the existing `ProjectDiskRevision` conflict check. Review state belongs to one project. Two projects reviewing the same recording keep independent choices.
- **References and history.** The embedded key is the SHA-256 of the asset as MPCut's own encoder writes it: sorted keys, compact separators, unchanged array order and Swift's shortest round-trip number text. MPCut is the only writer, so this encoder defines the form; shared fixtures pin it. On load, decode each asset, encode it again and compare digests. Recognition lookup uses the input track evidence and provider settings available before recognition. Map that lookup key to the verified per-track result and activity. The assembled session has its own content digest, including its job ID and fingerprint. A second session can reuse the track while producing a different attachment digest. The project reader's integer-only number check does not apply inside `embedded_assets`. Each asset's own decoder validates its numbers, such as word confidence and tile bounds. Keep per-edit attachment and review IDs stable. The existing short `refs` keys compress repeated values in the saved JSON. Write each asset once, keep assets reachable from the current edit or either history stack, drop the rest on save, and verify every reference on load. Save atomically by writing a complete new file and renaming it. Document print and merge operate without media or cutcaches. A merge unions immutable assets by digest, merges edits by their normal rules and reports competing changes to the same review choice.
- **Disk and cache.** The saved document uses ordinary JSON text, including the embedded payloads. External media are still referenced by path. There are no cutcache paths to repair after changing cache location. A reader can stream large embedded documents and maintain disposable search or waveform indexes elsewhere.

## What goes in the file

| Feature | Inside a recording’s `.cutcache` | Saved work outside cutcaches |
| --- | --- | --- |
| Indexes and previews | Audio packet and video frame indexes, seek tables, thumbnails, waveform peaks and envelopes | Original media, edit timeline, relink evidence carried by the project |
| Silence | Measured audio levels, automatic threshold and detected silent spans | Manual threshold, changed boundaries, accepted trims and cuts |
| Scenes | Unreviewed detector boundaries, grouping suggestions, restartable scan progress | Names, manual markers, corrections and the precise source ranges or report those choices refer to |
| Tiles | Automatic geometry and tracking observations, preview images, restartable detector checkpoints | A pending human review and the scan it refers to, corrected boxes, renamed or merged feeds, accepted layouts, switches and privacy decisions |
| Transcripts | Rebuildable search indexes, timeline projections and activity measured again from available audio | **All transcripts**, whether imported, generated, attached or awaiting attachment. Preserve exact words, times, speakers, provenance, supplied observations and all corrections. |
| Rendering | Intermediate renders that MPCut can recreate from durable inputs and settings | Published movies, ISO exports, subtitles, explicit scan reports and other files requested by the user |

**The first human decision can change what must be saved.** An automatic scene scan can be thrown away. If you name its third scene “Wide shot,” MPCut must save the name *and what it names*. A later detector might split that scene in two. Before acknowledging the edit, save its source identity, exact boundaries and any group membership the edit depends on. If the existing representation requires the original report, save that report. Apply the same rule to an unfinished Tiles review, a corrected silence boundary and any privacy mask. A pointer into a deletable file is insufficient. [Scene names and reports](../Sources/MPCutCore/ProjectAnalysisAnnotations.swift) · [Tiles review storage](../Sources/MPCutCore/PendingTileReview.swift) · [Tiles acceptance](../Sources/MPCutCore/ParticipantProjectAcceptance.swift)

## What an interview project looks like

- `Camera.mov.cutcache`, `Host.wav.cutcache` and `Guest.wav.cutcache` can each hold the rebuildable work for their own source. The camera file holds both its video and embedded-audio indexes. Two projects can reuse a recording’s cutcache.
- `Interview.cut` is one cross-platform UTF-8 JSON file. Put transcript words, exact timings, speakers, provenance, edits, and pending and accepted Tiles reviews directly in the document. Include the reviewed geometry and any detector evidence needed to interpret a decision. Keep each distinct transcript or reviewed result once and reference it from the edit and undo history. Save As, drafts and excerpts use the same document representation. Copying the file carries all project-owned work.
- A completed recognition result is saved work from the moment the provider returns it, even before a project attaches it. Persist a verified result in the durable job or transcript store before releasing provider output. Retrying a job may reuse that result. Detach, clearing cutcaches, or an age-based scratch cleanup must never discard its only durable copy. Once attached, the project contains its own complete result and edits. Activity supplied by a provider or needed to interpret a saved transcript travels with it. Only activity that can be recreated locally from durable inputs is eligible for cutcaches.
  **Recognition durability.** Stored form v3 omitted activity. The following requirements apply before a job can release its provider output.
  1. Write each provider result to the durable job store and verify it. Both job pruning and shared-exchange pruning must retain the last verified result, including after detachment or moving the project before attachment.
  2. Capture native session activity with its source clock during decoding, including standalone imports. Give stored form v4 a per-track `provider_activity` and keep it from attachment onward.
  3. Stop writing provider layouts into cutcache sections. Cutcaches keep only levels MPCut measured itself (`SidecarActivityPacking.pack`).
  [Transcript assets](../Sources/MPCutCore/TranscriptStore.swift) · [Stored transcript form](../Sources/MPCutCore/TranscriptStoredForm.swift) · [Recognition storage](../Sources/MPCutCore/TranscriptRecognitionCache.swift)
- Scene names, manual markers, silence threshold overrides and corrected boundaries are project data in the `.cut`. Use a finite JSON number for a manual threshold in dBFS, allowing fractions in that field in both the current edit and history. With project ownership, two projects on the same recording keep their own decisions, and copying a `.cut` carries all of them. The CLI's `--threshold-db` and similar options apply to that command only and save nothing. Editing a bare recording in the GUI uses an untitled project and its draft.

There is no need for a project cutcache to hold attachments or review edits. A future project-level search or render index would qualify as a cutcache only if deleting it passes the same test.

## Cutcache format and placement

Use versioned SQLite files for new `.cutcache` writes. A small header identifies the owner and schema. Named sections identify the source generation, stream or render inputs, algorithm version, options, encoding, decoded length and checksum as applicable. Keep exact timestamps, sample counts, packet positions, priming and gaps. Publish dependent sections atomically so the reader always sees a coherent index or complete scan. A scene clock can serve a scene scan independently of the full edit/export index. Keep restartable work pinned while a worker is using it. An interrupted run can resume or start again. [Media index](../Sources/MPCutCore/SidecarIndex.swift) · [Scene attempts](../Sources/MPCutCore/SidecarSceneAttempts.swift)

Use compact representations first and compress sections independently. Keep packet runs, packed frame rows and lossless waveform packing. Store encoded thumbnails directly. Use LZFSE when it saves space and raw bytes when smaller. Benchmark time-range chunks for long waveforms and dense scans so a visible range can load without decoding an entire recording. Allocate optional tables when first used. Use structured text for durable transcripts embedded in the project. Preserve source timing and provenance when reading provider results. [Section encoding](../Sources/MPCutCore/SidecarPayload.swift) · [Transcript format](TRANSCRIPTS.md)

The three Settings choices govern **only new cutcaches**. **Next to media** writes beside the recording. **In project folder** writes to the project’s managed cache directory. **On cache disk** writes collision-safe keys under one folder for all projects. Look in all three places. Select the freshest *compatible* section using its source evidence and revision. A newer timestamp cannot make another recording or partial result valid. Replacing one mic can invalidate its waveform and silence results while preserving camera analysis. Changing an edit can invalidate project projections without disturbing source measurements. A changed recording can flag a saved correction for review, but cannot erase or rewrite the correction. [Placement](../Sources/MPCutCore/SidecarLocations.swift) · [Copy selection](../Sources/MPCutCore/SidecarCopies.swift) · [Refresh evidence](../Sources/MPCutCore/MediaRefreshEvidence.swift)

**Clear cutcaches…** previews only disposable bytes. Skip files in use and recheck ownership before deletion. A cutcache can be removed whole. An unavailable cache disk can make the first reopen slower but must never make an imported transcript, manual threshold or unfinished review unavailable. Turning off cutcaches must still allow importing, editing, saving and reopening all of them.

## Large project documents

The schema 9 `.cut` format has **no application-defined file-size ceiling**. A valid project crossing 64 MiB gets the same open, save, autosave, recovery, print and merge behavior as a smaller one. Transcript words, Tiles evidence and editorial changes survive at their recorded precision. Writers preserve every saved asset reachable through the edit and retained history regardless of document size.

Earlier readers and writers used a 64 MiB constant. The history writer also had a reconstruction budget. Replace size-based rejection and truncation across those paths, including reference expansion, the CLI's stdin `inputLimit`, list and CSV readers that default to `MulticamProject.maximumFileSize`, and helper tools. A file too large for available memory fails with an ordinary out-of-memory or I/O error, not a size rule. Process large sections incrementally, reuse repeated values and resolve references lazily where possible. Keep structural validation, cycle detection, cancellation and checked arithmetic. Memory budgets may govern how much data a reader holds at once. If a save runs out of disk space, report the failure and leave the previous complete document intact. [Project I/O](../Sources/MPCutCore/CutProject.swift) · [Reference layout](../Sources/MPCutCore/ProjectKeyedLayout.swift) · [History](../Sources/MPCutCore/CutHistory.swift)

## Size measurements and acceptance

A local CLI measurement used ten minutes of 48 kHz mono audio with repeating sound and silence, encoded as PCM WAV and 96 kb/s-target AAC. Each file was indexed, then built again with audio analysis enabled. These are file lengths and SQLite section payload lengths from that run.

| File | Media | Index-only database | Index plus audio analysis | Two waveform sections |
| --- | ---: | ---: | ---: | ---: |
| WAV | 57,600,078 B | 94,208 B | 282,624 B (0.49% of media) | 182,834 B |
| AAC | 4,973,493 B | 94,208 B | 438,272 B (8.81% of media) | 336,491 B |

For the AAC file, the packed audio packet table occupied **27 bytes**, the detailed waveform **277,337 bytes**, and overview peaks **59,154 bytes**. The index-only database contained 2,893 bytes of section payloads. Its remaining space includes the SQLite tables, indexes and page allocation. Short files can easily have databases larger than the media. For example, the repository’s 5,373-byte ProRes fixture has a 94,208-byte database. These examples do not establish which section dominates any particular user's recording.

In the ProRes fixture, 23 SQLite pages of 4,096 bytes hold 2,606 bytes of section values. Creating optional scene tables and indexes lazily is worth measuring alongside waveform compression. Report database bytes, per-section stored bytes, SQLite overhead and duplicate files in Settings and CLI inspection. Report project data separately from reclaimable space.

With the new schema, the same ProRes index used **40,960 bytes (10 pages)** versus 94,208 bytes (23 pages) in the earlier layout. The two index-only builds in the same folder each held 2,602 bytes of section values. The new file creates scene tables on the first scene attempt or imported attempt, and archive storage on the first generation refresh. The [CLI benchmark](../Tests/Benchmarks/analysis_sidecar.py) checked the fresh and cached reports for the following fixtures. It records cold build wall time, peak resident memory and the median of three timed warm media inspections after a warmup. These debug-build timings are from one machine with concurrent benchmark processes.

| Input | Full automatic cache | Cold build | Cold peak | Warm media inspection |
| --- | ---: | ---: | ---: | ---: |
| 10-minute alternating tone/silence WAV | 53,248 B | 0.76 s | 26.8 MiB | 0.036 s |
| AAC encoding of the same tone | 114,688 B | 0.97 s | 36.6 MiB | 0.074 s |
| ProRes-2997.mov | 40,960 B | 0.27 s | 28.6 MiB | 0.039 s |
| VFR-PTS.mp4 | 40,960 B | 0.16 s | 30.6 MiB | 0.040 s |
| Scene-Cadence-Change.mov | 49,152 B | 0.25 s | 33.5 MiB | 0.034 s |

The isolated [range-read benchmark](../Tests/Benchmarks/cutcache_ranges.py) compares a whole SQLite LZFSE block with independently compressed blocks over the same peak samples or tile observations. It verifies every byte after a full read and after a 100 ms read at the midpoint. On ten minutes of 48 kHz audio with alternating three-second tone and silence, four-second blocks reduced the decoded AAC peak bytes from 120,000 to 800 and the median warm lookup from 0.026 ms to 0.008 ms. The prototype database grew from 12,288 to 73,728 bytes. On a three-second dense Tiles scan with 180 observations, half-second blocks reduced the decoded bytes from 757,030 to 126,445 and the median from 0.056 ms to 0.018 ms. Database size doubled from 16,384 to 32,768 bytes. These nine-read medians measure payload lookup and decompression with the time index in memory. The shipping encoding remains whole-section for these workloads.

| Test | Pass condition |
| --- | --- |
| Delete **every** new cutcache with the app closed, disconnect the cache disk, reopen | Imported, generated and unattached transcripts survive in their proper stores. Names, thresholds, corrected boxes, pending reviews, cuts and undo/redo survive. A provider spy records zero calls. Waveforms and thumbs regenerate on request. |
| Name a scene, change a silence boundary and correct a tile, then remove the cache and rerun a detector that returns different boundaries | The saved edits retain their original source ranges and meaning. A mismatch prompts review. |
| Create two projects from the same media, give each different review choices, Save As and reopen with empty cutcaches | Each project recovers its own review choices, scene names and thresholds. The project format and offline document print/merge still work. |
| Round-trip valid projects immediately below, at and above 64 MiB, plus a substantially larger transcript and dense reviewed geometry | GUI and CLI open, save, recover, print and merge successfully. Verify word counts, exact timings, reviewed boxes, and undo/redo against the inputs. Interrupt a save or exhaust disk space and reopen the prior complete file. |
| Finish recognition, move the project before attachment, age both stores, run maintenance and remove all cutcaches | The job result remains recoverable with zero provider calls. |
| Reuse one mic in a second session with different tracks | The lookup reuses the verified track. The assembled session has its own digest. |
| Save two multicam sources pointing to one recording with a pending review on just one | Reopen and accept. Only the selected picture-source ID receives its choices. |
| Save a −37.5 dB override, edit it, save again and undo after reopening | Both the current and historical values round-trip exactly. |
| Import a standalone native session with nonempty provider activity, delete every cutcache, reopen | Words, times, confidences and provider activity match the import byte for byte after re-encoding. Every embedded digest verifies. |
| Accept a pending Tiles review, then undo past it and redo, saving between steps | The scan is embedded only while the review or history references it. Accepted geometry appears once, in `participants.sources`. |
| Open a schema 8 project and a `.cutdb` file | MPCut reports an unsupported version and changes nothing. |
| Read each of three write locations under each of three settings, including same-named recordings, corrupt or stale copies and concurrent GUI/CLI usage | All nine combinations return compatible data or rebuild. Each requested index is internally consistent. A live worker cannot republish data after clear. |
| Compare compressed and uncompressed reads for audio, video, variable timing, silence, scenes and dense Tiles scans | Exact decoded values and resulting edit/export boundaries match. Measure cold build, warm reads, peak memory and stored bytes before adopting new encodings. |

Build both XCTest bundles and run them muted on Backstage’s hidden display. Include a desktop reopen after manual deletion and CLI/MCP opens against the same fixture. The defining acceptance test is that all saved work survives the complete absence of cutcaches.

The [cache-deletion integration test](../Tests/Integration/cutcache_reopen.py) saves an imported transcript and a fractional silence threshold, deletes the cutcaches, makes the selected cache disk unavailable and reopens two project copies. It checks the CLI, file MCP, the desktop, undo/redo and the provider call count. The [large-project integration test](../Tests/Integration/cutcache_large_reopen.py) exercises draft recovery, autosave, Save As and history on a project over 64 MiB. Both scripts take a packaged MPCut.app or a SwiftPM products directory containing the desktop, CLI and MCP helper.

A 630-second gallery recording scanned at every frame produced 18,900 observations with 16 boxes each. The 87,812,367-byte scan survived CLI print and three-way merge, acceptance, desktop undo, save, reopen and redo with identical canonical bytes. The reopened project retained the feed name, expected feed count and all 16 corrected grid cells. A separate 101,027,228-byte transcript project also survived CLI print, merge and reopen. Forcing a file-size write failure preserved the preceding project byte for byte.
