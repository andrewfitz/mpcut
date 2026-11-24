# cutcaches and saved work

**A cutcache is disposable.** With MPCut closed, you can delete every new-format `.cutcache` file by hand. When you reopen the project with its media and saved companions, every transcript, decision and unfinished edit must still be there. The cost of deletion is time spent rebuilding indexes, previews or automatic analysis. Recovery must require zero recognition-provider calls and zero repeated editorial decisions.

## What goes in the file

| Feature | Inside a recording’s `.cutcache` | Saved work outside cutcaches |
| --- | --- | --- |
| Indexes and previews | Audio packet and video frame indexes, seek tables, thumbnails, waveform peaks and envelopes | Original media, edit timeline, relink evidence carried by the project |
| Silence | Measured audio levels, automatic threshold and detected silent spans | Manual threshold, changed boundaries, accepted trims and cuts |
| Scenes | Unreviewed detector boundaries, grouping suggestions, restartable scan progress | Names, manual markers, corrections and the precise source ranges or report those choices refer to |
| Tiles | Automatic geometry and tracking observations, preview images, restartable detector checkpoints | A pending human review and the scan it refers to, corrected boxes, renamed or merged feeds, accepted layouts, switches and privacy decisions |
| Transcripts | Rebuildable search indexes, timeline projections and activity measured again from available audio | **All transcripts**, whether imported, generated, attached or awaiting attachment. Preserve exact words, times, speakers, provenance, supplied observations and all corrections. |
| Rendering | Intermediate renders that MPCut can recreate from durable inputs and settings | Published movies, ISO exports, subtitles, explicit scan reports and other files requested by the user |

**The first human decision can change what must be saved.** An automatic scene scan can be thrown away. If you name its third scene “Wide shot,” MPCut must save the name *and what it names*. A later detector might split that scene in two. Before acknowledging the edit, save its source identity, exact boundaries and any group membership the edit depends on. If the existing representation requires the original report, save that report. Apply the same rule to an unfinished Tiles review, a corrected silence boundary and any privacy mask. A pointer into a deletable file is insufficient. [Scene names and reports](../Sources/MPCutCore/SidecarAnalysis.swift) · [Tiles review storage](../Sources/MPCutApp/TilesPendingReview.swift) · [Tiles acceptance](../Sources/MPCutCore/ParticipantProjectAcceptance.swift)

## What an interview project looks like

- `Camera.mov.cutcache`, `Host.wav.cutcache` and `Guest.wav.cutcache` can each hold the rebuildable work for their own source. The camera file holds both its video and embedded-audio indexes. Two projects can reuse a recording’s cutcache.
- `Interview.cut` keeps the existing project format, timeline, bindings, accepted edits, relink evidence and retained history. `Interview.cut.transcripts/` keeps the exact transcript assets used by the project and its history. `Interview.cut.tile-review/` keeps unfinished review choices and the evidence needed to resume them. An untitled project uses its durable draft storage. Save As, excerpt and recovery carry the relevant assets automatically.
- A completed recognition result is saved work from the moment the provider returns it, even before a project attaches it. Persist a verified result in the durable job or transcript store before releasing provider output. Retrying a job may reuse that result. Detach, clearing cutcaches, or an age-based scratch cleanup must never discard its only durable copy. A project may share an immutable result by digest and still have its own edits. Activity supplied by a provider or needed to interpret a saved transcript travels with it. Only activity that can be recreated locally from durable inputs is eligible for cutcaches. [Transcript assets](../Sources/MPCutCore/TranscriptStore.swift) · [Stored transcript form](../Sources/MPCutCore/TranscriptStoredForm.swift) · [Recognition storage](../Sources/MPCutCore/TranscriptRecognitionCache.swift)
- Preserve recording-wide edits made outside a project. A scene name or manual threshold currently shared by two projects must remain shared. Provide a durable recording-annotations store keyed to the recording and stream, reachable by standalone CLI and GUI. Project-specific overrides belong to the project. Use distinct names and paths for annotation storage and cutcaches, and carry referenced annotations with a project transfer. The cache disk must never be the only location of saved work.

There is no need for a project cutcache to hold attachments or review edits. A future project-level search or render index would qualify as a cutcache only if deleting it passes the same test.

## Cutcache format and placement

Use versioned SQLite files for new `.cutcache` writes. A small header identifies the owner and schema. Named sections identify the source generation, stream or render inputs, algorithm version, options, encoding, decoded length and checksum as applicable. Keep exact timestamps, sample counts, packet positions, priming and gaps. Publish dependent sections atomically so the reader always sees a coherent index or complete scan. A scene clock can serve a scene scan independently of the full edit/export index. Keep restartable work pinned while a worker is using it. An interrupted run can resume or start again. [Media index](../Sources/MPCutCore/SidecarIndex.swift) · [Scene attempts](../Sources/MPCutCore/SidecarSceneAttempts.swift)

Use compact representations first and compress sections independently. Keep packet runs, packed frame rows and lossless waveform packing. Store encoded thumbnails directly. Use LZFSE when it saves space and raw bytes when smaller. Benchmark time-range chunks for long waveforms and dense scans so a visible range can load without decoding an entire recording. Allocate optional tables when first used. Durable transcripts keep their existing compact format and byte digest. Their storage and compression can be optimized independently of the cutcache format. [Section encoding](../Sources/MPCutCore/SidecarPayload.swift) · [Transcript format](TRANSCRIPTS.md)

The three Settings choices govern **only new cutcaches**. **Next to media** writes beside the recording. **In project folder** writes to the project’s managed cache directory. **On cache disk** writes collision-safe keys under one folder for all projects. Continue to look in all three places and validated previous locations. Select the freshest *compatible* section using its source evidence and revision. A newer timestamp cannot make another recording or partial result valid. Replacing one mic can invalidate its waveform and silence results while preserving camera analysis. Changing an edit can invalidate project projections without disturbing source measurements. A changed recording can flag a saved correction for review, but cannot erase or rewrite the correction. [Placement](../Sources/MPCutCore/SidecarLocations.swift) · [Copy selection](../Sources/MPCutCore/SidecarCopies.swift) · [Refresh evidence](../Sources/MPCutCore/MediaRefreshEvidence.swift)

**Clear cutcaches…** previews only disposable bytes. Skip files in use and recheck ownership before deletion. A new-format cutcache can be removed whole. An unavailable cache disk can make the first reopen slower but must never make an imported transcript, manual threshold or unfinished review unavailable. Turning off cutcaches must still allow importing, editing, saving and reopening all of them.

## Existing files and migration

The current `.cutdb` format mixes rebuildable data with scene names, thresholds, recognition results and archived sections. Its existing whole-file removal option therefore cannot be applied to an unclassified legacy file. Keeping old files readable does not require renaming them. [Current format](../Sources/MPCutCore/AnalysisSidecar.swift) · [Legacy cleanup](../Sources/MPCutCore/SidecarCacheCleaner.swift)

1. Classify data by meaning across current and archived generations. Track exact dependencies, including the report behind a name, activity required by a recognition result, retained history and in-progress reviews. Treat unrecognized records as data to preserve. Keep read-only opens free of migrations.
2. On explicit save or migration, stage durable copies under the proper recording, project or job owner. Verify digests, bindings and range identities, commit and reopen them through the normal reader before marking a transfer complete. Preserve concurrent edits and allow retry after disk-full, unplug or crash. A missing owner or unresolved conflict keeps the original intact. For Save As, retain staged Tiles reviews until all destination bindings are published. [Project save guard](../Sources/MPCutCore/ProjectDiskRevision.swift) · [Pending review transfer](../Sources/MPCutApp/TilesPendingReview.swift)
3. Direct all new writes through the same ownership rules in GUI, CLI, MCP and the standalone provider. During transition, legacy cleanup can remove positively identified rebuildable sections after accounting for references. Keep a mixed, unknown, or unverified database out of whole-file deletion. Ship whole-file clearing for the new format after the deletion tests pass.

## Size measurements and acceptance

A local CLI measurement used ten minutes of 48 kHz mono audio with repeating sound and silence, encoded as PCM WAV and 96 kb/s-target AAC. Each file was indexed, then built again with audio analysis enabled. These are file lengths and SQLite section payload lengths from that run.

| File | Media | Index-only database | Index plus audio analysis | Two waveform sections |
| --- | ---: | ---: | ---: | ---: |
| WAV | 57,600,078 B | 94,208 B | 282,624 B (0.49% of media) | 182,834 B |
| AAC | 4,973,493 B | 94,208 B | 438,272 B (8.81% of media) | 336,491 B |

For the AAC file, the packed audio packet table occupied **27 bytes**, the detailed waveform **277,337 bytes**, and overview peaks **59,154 bytes**. The index-only database contained 2,893 bytes of section payloads. Its remaining space includes the SQLite tables, indexes and page allocation. Short files can easily have databases larger than the media. For example, the repository’s 5,373-byte ProRes fixture has a 94,208-byte database. These examples do not establish which section dominates any particular user's recording.

In the ProRes fixture, 23 SQLite pages of 4,096 bytes hold 2,606 bytes of section values. Creating optional scene tables and indexes lazily is worth measuring alongside waveform compression. Report database bytes, per-section stored bytes, SQLite overhead and duplicate files in Settings and CLI inspection. Report project data separately from reclaimable space.

| Test | Pass condition |
| --- | --- |
| Delete **every** new cutcache with the app closed, disconnect the cache disk, reopen | Imported, generated and unattached transcripts survive in their proper stores. Names, thresholds, corrected boxes, pending reviews, cuts and undo/redo survive. A provider spy records zero calls. Waveforms and thumbs regenerate on request. |
| Name a scene, change a silence boundary and correct a tile, then remove the cache and rerun a detector that returns different boundaries | The saved edits retain their original source ranges and meaning. A mismatch prompts review. |
| Create two projects from the same media, give each different review choices, Save As and reopen with empty cutcaches | Each project recovers its own choices. Shared recording annotations remain available. The project format and offline document print/merge still work. |
| Migrate a legacy database with recognition, manual settings, archived data and an unknown section. Interrupt before and after durable publication. | A retry completes without duplicate edits or lost data. Unknown data survives. Clearing never destroys the only copy. |
| Read each of three write locations under each of three settings, including same-named recordings, corrupt or stale copies and concurrent GUI/CLI usage | All nine combinations return compatible data or rebuild. Each requested index is internally consistent. A live worker cannot republish data after clear. |
| Compare compressed and uncompressed reads for audio, video, variable timing, silence, scenes and dense Tiles scans | Exact decoded values and resulting edit/export boundaries match. Measure cold build, warm reads, peak memory and stored bytes before adopting new encodings. |

Build both XCTest bundles and run them muted on Backstage’s hidden display. Include a desktop reopen after manual deletion and CLI/MCP opens against the same fixture. The defining acceptance test is that all saved work survives the complete absence of cutcaches.
