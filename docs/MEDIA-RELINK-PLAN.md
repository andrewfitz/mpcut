# Missing media, relink and replace

**Proposed behavior.** A project always opens, even if its recordings are gone. Missing media appears in red wherever it is used. One **Project Media** list shows every file the project references and its status. From there the editor can locate a moved file or a whole moved folder, or replace a source with different footage. Replace previews its effect on the timeline before it applies. The ordinary sequence editor, still placements, replacement audio, multicam cameras and microphones, transcripts, the CLI and MCP all share one engine.

Code references name the symbol first. `EditorModel.swift` changes often, so its line numbers are omitted; other line numbers are as of 2026-11-23.

## Where MPCut stands today

| Area | Current behavior | Gap |
| --- | --- | --- |
| Opening a sequence project | Two failure points. `EditorModel.checkedFiles` throws `missing_source` for a `..` path whose parent folder is gone (via `CutProject.checkedSourceURL`, `CutProject.swift:639-642`). Then any source that fails to index aborts the open in `importFiles(projectClips:)` with *Couldn't Open Project* / `import_incomplete`. Undo/redo into an offline state falls through `cachedSegments` to the same `importFiles` and fails with *Couldn't Restore*. | Can't open a project to fix it, and can't undo past a missing file. |
| Opening a multicam project | Opens: `MulticamEditorModel.openProject` installs the project with empty media and then loads sources one by one, so missing files only produce per-source issues and an orange hatch (`MulticamEditorModel.swift:536-588`, `:1159`; `MulticamTimeline.swift:1066`). Multicam history entries hold path-based projects. | Orange means both "offline" and "needs review". |
| Offline after open | `ProjectMediaWatcher` and **Refresh Project Media** fill `EditorModel.offlineMedia`. A file that vanishes after open keeps its full `IndexedSource` and is only flagged. `mediaReviewIssue` then drives the " · Needs review" label, the "Unavailable" preview slate (`monitoredPreview`), scene detection (`sceneRequests`), filmstrips (`Timeline.swift:1273`, via `clip.mediaIssue`), waveform and silence analysis (`syncWaveforms` / `silenceMedia`), `jpegSourceAtPlayhead` and the export sheet (`chooseExport`). `source_needs_review` is thrown at 11 sites in 4 files: `EditorModel` ×2, `MCPOutputs.swift` ×5 (`:421-740`), `MCPReviewFrame.swift:256,308`, `MulticamJPEGExport.swift:35,120`. | The watcher is off by default and only watches current timeline clips (`updateMediaWatcher`). There's no red state and no relink for sequence clips. |
| Relink | Multicam source **Relink…** checks only the media type and that the selected audio streams exist (`MulticamEditorModel.swift:713-770`). Stills "relink" overwrites the SHA-256 fingerprint without comparing it (`StillProjectEditing.swift:171`, `MCPStills.swift:331`), so it is really a replace. | Doesn't check the new file is the same media, works one file at a time, and offers no folder search. Offset, coverage and replacement offsets aren't rechecked. |
| What a `.cut` stores per source | A path only, relative to the project. No identity or media description. | Without the file there's nothing to show (duration, tracks) and nothing to match a candidate against. |
| Content evidence | `<media>.cutdb` lives next to the media (`AnalysisSidecar.swift:41`) and usually **travels with it** on a Finder move; it tolerates device-number changes (`:133-138`). Its stamp history can include generations later marked `content_changed` (`SidecarManifest.swift:150-154`), so an old stamp there doesn't prove current content. Persisted `SourceIdentity` omits the change time (`Probe.swift:305-320`), so an in-place rewrite with restored mtime matches it. Stills store a full-file SHA-256 (`StillImage.swift:122`). Payload evidence (`MediaRefreshEvidence`) comes from the ordinary packet scan for H.264, HEVC, WebM and PCM WAV (`probe.c:1168-1218`), and is persisted in the `.cutdb` (`SidecarManifest.swift:14,72`). ProRes MOV uses a fast index path that produces none unless a deep probe forces it (`probe.c:1168`). The WAV fast path (`:1038-1046`) runs only for audio-analysis probes (`CutEngine.inspectForAudioAnalysis`). | A candidate probe can establish content equality. A sidecar can pass `currentStamp` after a same-size rewrite with restored mtime. |
| Transcripts | The binding fingerprint is `inode:size:mtime` (`TranscriptStore.swift:267`). `sourceStatus` reports *offline*, *changed* or *unverified* (`:111-119`). Pause protections apply when the fingerprint is nil or equal (`:769`). | A same-volume move keeps protections; a cross-volume copy reads *Changed*. |
| Interchange | FCPXML/Resolve fail with `missing_source` (`ResolveExport.swift:189`). Premiere export stats each file and fails locally (`PremiereTimeline.swift:46-54`). FCP metadata resolves `original_file` with `checkedMediaURL`, which accepts a missing leaf file, so a missing original can be written silently (`ResolveExport.swift:105-108`, `CutProject.swift:639-645`). FCPXML import of a missing still writes the fingerprint `unverified-fcpxml-<ref>` (`FCPInterchange.swift:227`). | Needs a preflight scoped to what the requested output depends on. |

The app has no entitlements and isn't sandboxed, so it can read any folder the user picks; macOS privacy prompts still apply to Desktop, Documents, removable and network volumes. Saving with offline media already works and keeps the stored path: `documentWriter` relativises each path with `relativeMediaPath`, which resolves the nearest existing ancestor (`CutProject.swift:354-380`), and the save collision check tolerates missing sources (`CutProject.swift:612-634`). Canonicalising a path on a stale network mount can block, so save and undo share the detection work's per-volume status (Phase 1.4).

## Relink and Replace

| | **Relink** | **Replace** |
| --- | --- | --- |
| Meaning | The same recording at a new location | Different media in place of a source (re-render, re-export, another take) |
| How it's decided | The match outcomes in Phase 3 | The candidate is compared property by property (ripple table) |
| Scope | Every reference to the path: timeline, stills, participants, transcripts and every retained undo/redo state. Queued exports keep their pinned snapshots and are marked affected. | From a clip, **this occurrence** by default; from a Project Media row, the user picks **this use** or **all uses**. |
| History | **Not an undo step.** A forward path map is applied to the current state and to every retained undo/redo state, and the document is marked dirty. Project Media offers **Revert to Previous Location** while every use of the destination can be traced to that relink. Undo and redo never pass through a broken path. | An ordinary undoable edit ("Replace Source File"). |
| Derived data | Kept. Only transcript bindings and anchors tied to the verified source generation qualify for re-stamping (Phase 3). | Invalidated, except authored data the user opts to keep. |

Every relink first checks the candidate against all affected uses. **Verified** and a manually picked **Match** can then proceed without another confirmation. Folder matches go through batch review, ambiguous rows require a choice, and **Different** offers Replace.

## Ripple table for Replace

The engine compares the candidate with the old source's snapshot entry and gives each difference one outcome. The replace sheet lists them before **Apply**. Without a snapshot entry (projects saved before Phase 0 with the old file gone), it compares only against what the project itself records: the furthest `to`, `track_ordinal`, and picture or audio kind where known.

| Property | What depends on it | Outcome |
| --- | --- | --- |
| Duration shorter than the furthest use | Clip `to`, source selects, still replacement fragments, multicam spans and `coverage`, working copy `duration >= lastCut` | **Warn + conform.** Clips that overlap the new end are trimmed to it (default) or left out of range and red. Clips that **start** beyond the new end can't be trimmed (`to > from`, `CutProject.swift:215`), and still fragments can exceed the new extent independently (`StillReplacementEditing.swift:54-60`). These are listed as *lost*, and the user must choose (remove, or keep offline) before apply. Show the change in timeline duration. |
| Start time / origin / timecode | Clip times relative to `info.origin`, multicam `offset`, transcript `sequenceClockOrigin` | **Warn.** Keep source-relative times by default. Offer **Keep source timecode** when both files have comparable embedded timecode or Broadcast Wave clocks. Map each old endpoint to its clock reading and then back to a source-relative time on the candidate. Use the stream start and exact clock scale from `MulticamSync.stamp`, confirm a shared time-of-day clock for mixed clock kinds, and check the resulting ranges before Apply. For multicam, offer **Re-sync** (waveform or timecode) and show the old and new offset. |
| Frame rate / keyframes | Snapped cut boundaries, Smart Trim joins | **Warn.** Cuts keep their exact times. List cuts that no longer fall on a frame or safe boundary, and say which export modes still work. |
| Audio stream count or order | Sequence `track_ordinal`, multicam stream index and channel, mix lanes, replacement audio, transcript `streamIndex`, still soundtrack track count | **Block** if a selected stream disappears, unless the user maps it in a small stream-mapping table (old stream → new stream, matched by layout, language and name). **Warn** on a reorder that this mapping resolves. |
| Media type (picture ↔ audio-only) | Picture lanes, stills, multicam camera vs mic | **Block.** |
| Codec, dimensions, rotation, color | Stream-copy compatibility (`checkCompatibility`) | **Warn.** "Copy export unavailable; re-encode required." Doesn't block. |
| Still aspect ratio / content | Normalized crop, fill/fit, SHA-256 fingerprint | **Warn.** Show the old and new framing side by side when the old image is still available; offer **Reset crop**. Re-stamp the fingerprint on apply. |
| Transcript | Bound words | **Warn.** The transcript becomes *Changed*; offer **Keep (unverified)** or **Re-transcribe**. |
| Participants | Accepted geometry, appearance overrides, audio bindings, camera slots and redactions | **Warn and reconcile.** Show affected decisions using `ParticipantReconciliation`. Carry accepted geometry to a copy only when its content and feed layout satisfy the existing reconciliation rules. A different take requires review of affected privacy treatments before participant export. |

## Phase 0 — Snapshot in v4 before it freezes

Schema v4 is unreleased (CHANGELOG *Unreleased*: "open from v3 and save as v4"), and `cut-v4.schema.json` closes every object. Adding the snapshot after release costs a v5 bump, and released builds can't open v5 projects. A snapshot is also worthless for projects saved before it exists. Ship this on its own, first.

- **Shape:** a top-level `media_snapshot: {version, entries}` key, beside `history` and outside every `CutProject` state, so it stays out of history deltas and undo equality. Add it to both top-level allowlists (`CutProject.swift:119-122`, `MulticamProject.swift:335-345`) and both schema branches.
- **Entries are open objects.** Readers preserve unknown entry fields on rewrite and ignore an unknown `version`, so later fields (ProRes evidence, `ignored`, `previous_path`) don't need another schema bump. This deliberately breaks the reject-unknown convention for this one object.
- **Snapshot contents.** Store the path, size, mtime, duration, origin, frame rate, dimensions, stream summary (kind, codec, channels, language), and the source-clock mapping when available (clock kind and reading at source-relative zero in exact units). Store the `SourceIdentity.transcriptFingerprint` of the indexed generation alongside `MediaRefreshEvidence` comparison fields or a versioned digest over those fields from the same probe. Exclude filesystem identity from the content comparison. A writer with only stamp-matched cache data can save descriptive fields and omit new proof. Stills use their full-file SHA-256. Current and retained history paths are eligible for snapshot entries.
- **Every writer.** `encodedArchive` writes the bare project when history is empty or no step fits the budget (`CutHistory.swift:254-256`, `:298`), and `CutProject.save(to:)` / `MulticamProject.save(to:)` (`CutProject.swift:322`, `MulticamProject.swift:422`) do the same. Apply the same snapshot writer and size policy to all three branches and both `save(to:)` paths. Carry it on the loaded value and make it a **required argument of the save funnel**, so the compiler finds every writer (about 25 load sites in 14 files, 11 in `MPCutCLI/main.swift`). The GUI writes entries from live `MediaInfo` and keeps the previous entry for offline sources. The CLI, MCP file tools, `project convert` and interchange importers preserve existing entries and add entries only for paths they probed.
- **Size.** Preserve the current edit and the undo/redo steps selected by the existing archive budget. Fit whole snapshot entries into the remaining space under both the snapshot cap and the 64 MiB document limit, including the JSON wrapper. Give current paths priority over history-only paths, using stored-path order within each group. Omit the optional snapshot when no entry fits. Every writer checks the final encoded size before publishing (`ProjectFile.diskBytes`).
- **History format.** Before v4 freezes, include the optional per-binding history change needed by Replace (Phase 4) in the schema and bounded history codec. Readers apply it in both directions and can open projects that lack it.
- **Tests.** Round-trip untouched and history-only entries through every writer. Fill both history branches near 64 MiB and compare retained steps with a snapshot-free save. Cover partial and empty snapshots, reopening at the limit, and a reused path whose new evidence and fingerprint must come from the same generation.
- Update `docs/CUT-FORMAT.md`, `docs/schema/cut-v4.schema.json` and the v3 → v4 read path. v3 files have no snapshot and open anyway.

## Phase 1 — Open anything

1. **Open with unresolved sources.** Both failure points (`checkedFiles` with a missing `..` parent, and indexing in `importFiles(projectClips:)`) produce an unresolved source instead of rejecting. The same applies to undo/redo into a state with a missing file, and to draft recovery, which uses the same `ProjectSessions.openProject` path (`ProjectDraft.swift:333-334`, `ProjectSessions.swift:567`). `import_incomplete` remains only for real format errors in a present file, and those open unresolved with the error text. Saved ranges past the end of a present but changed file (`project_clip_range`, `project_audio_track`) open marked **Needs review**.
2. **An enum, not a fake `MediaInfo`.** A clip records no picture/audio lane (`CutProject.swift:6-30`), so a synthetic stream is a guess: a fake picture stream selects the still-review canvas, and a synthetic PCM index satisfies `hasFullEditIndex` without packets (`Probe.swift:195-199`). Instead:
   - `EditorSegment.source` becomes `resolved(IndexedSource)` or `unresolved(UnresolvedSource)`. Only `id`, `url`, `name` and replacement metadata are common. `UnresolvedSource` holds the stored path, the snapshot entry if any, and the known kind (from the snapshot or `track_ordinal`).
   - The compiler then flags every `source.media`, `frames` and `duration` read (about 150 in `EditorModel.swift`; `IndexedSource` is private to that file, so the sweep is contained). That sweep is the main Phase 1 work.
   - `segments`, `offsets` and `timelineClips` are index-parallel, so unresolved clips stay in `segments`. `EditorSegment.init` takes an explicit end for unresolved sources (today it defaults from `source.duration`).
   - `PreparedEdit` is built from resolved segments only and takes container, `isMixed`, audio tracks and tier from the first **resolved** one. That makes export of a selection that avoids offline clips well defined.
   - Preview accepts an unresolved clip as a timed, silent slate.
   - **One offline predicate:** unresolved, or in `offlineMedia`. Both behave the same everywhere, including refusing trim and split, regardless of when the file vanished.
   - Test audio-only, unknown-kind, offline-first and all-offline timelines.
3. **One status enum** shared by both editors and every surface: `online`, `indexing`, `offline`, `checking` (volume not answering), `changed`, `needsReview`, `ignored` (user chose **Leave Offline**; stored in the snapshot entry). Each state has a Phase 2 treatment.
   - Two walkers produce reference lists and both need extending: `MediaRefreshProject.swift:57-123` and the editor's own walker beside `updateMediaWatcher`.
   - Add still assets (both editors, **excluding gaps**, whose `file` returns a built-in image path, `StillProject.swift:123-135`), source selects, transcript bindings including speaker-reference anchors (`TranscriptAuthoredRecord.speakerReference`, `TranscriptAuthoring.swift:188`), and `stillAudioReference` (`StillProject.swift:437`). `original_file` is already walked (`MediaRefreshProject.swift:81`). Include participant-only uses in both editors’ lists. Sequence participant references are paths. Multicam participant references resolve through source IDs.
   - Missing transcript JSON assets are not media: route them to the existing `TranscriptStore.recover` (`TranscriptStore.swift:446`).
   - An offline `original_file` behind an online working copy is informational: a grey note, not red.
   - Paths that appear only in history aren't checked or listed. They turn red if the user undoes into them, and Locate works there.
4. **Detection.** Reuse `ProjectMediaWatcher`'s stamp mode instead of adding a second checker. It already re-checks on activation, mount and unmount (`ProjectMediaRefresh.swift:166-171`). Make that cheap check always on and extend it from timeline clips to stills and originals. Per-file `DispatchSource` watching stays opt-in, as today.
   - Today the watcher runs on the main actor, walks parents with `fileExists`, opens descriptors there, and waits for two whole-set stamp passes (`ProjectMediaRefresh.swift:174-199,239-262`). A stat on a stale SMB mount can block indefinitely.
   - So: move ancestor lookup and descriptor opening off the main thread, publish each volume's results independently, allow at most one outstanding probe per unresponsive volume, and mark its sources `checking`.
   - Undo and redo stat synchronously today (`EditorModel.currentSource`, called from `cachedSegments`). They must consult the cached per-volume status and never stat a volume marked `checking`.
5. **What offline clips allow.** Move, delete, reorder, rename, relink and replace. Not trim or split, which need frame and keyframe grids. The 11 `source_needs_review` sites and the `mediaReviewIssue` consumers refuse with a link to Project Media. Interchange export runs an offline preflight for the dependencies of the requested output and lists what's missing.

## Phase 2 — Visuals

- **Colors.** Red means offline, orange means needs review. Add shared constants (`EditorDesign.swift` holds only bar chrome today). The export tier badge already uses red for *unavailable* and orange for *re-encode* (`TimelineTierGate.swift:223-226`), and the playhead is red, so offline is identified by a **diagonal hatch plus icon**, not by color alone.
- **Per state:** `offline`: red hatch over a dark fill, red border, `exclamationmark.triangle.fill` before the name, "Media Offline" in place of thumbnails and waveform. `checking`: grey hatch, "Checking…". `indexing`: thumbnails withheld, progress sweep. `changed` and `needsReview`: thumbnails kept, orange edge and badge. `ignored`: grey hatch, no badge, not counted in alerts.
- **Ordinary timeline** (`Timeline.drawClip`, `Timeline.swift:1105`). Tooltips include the issue text and the stored path.
- **Multicam timeline:** switch the existing hatch (`MulticamTimeline.swift:1066`) to red for missing files; keep orange for "track index unavailable" and coverage problems. Same for `MulticamTierBadge`.
- **Preview slate:** `PreviewSurface.unavailable` shows a full-frame **Media Offline** slate (red bar, file name, last known path, **Locate…** button) over an offline clip. Audio-only sources show the same in the waveform area. During playback the slate is held for the clip's duration and audio is silent.
- **Status bar:** the existing "Media needs review" menu (`EditorView.swift:296`) becomes a red **"3 files offline"** button (orange when only review is needed), opening Project Media.
- **Stills:** offline assets show a red placeholder thumbnail and a slate in the program review, replacing the " (offline)" name suffix.
- **Accessibility:** every state has an icon and text, and VoiceOver reads "Media offline: <name>".

## Phase 3 — Relink

**Project Media list.** It's the home for batch work, since the ordinary editor has no media pool. It's a sheet or inspector tab in both editors (multicam extends its Sources tab) listing each referenced file once: name, kind icon, status, used-by count ("4 clips, 1 transcript"), duration and stored path. Filter by **Offline / Needs review / All**. Row actions: **Locate…**, **Replace Source File…**, **Leave Offline**, **Revert to Previous Location** (when every destination use qualifies), **Reveal in Finder** and **Show Uses** (selects the clips).

**Entry points**
- File menu: **Relink Offline Media…** next to Refresh Project Media, ⇧⌘L (unbound; plain L is shuttle-forward in the key handler, `EditorView.swift:369`, and doesn't conflict).
- Clip context menu: **Locate Media…**, **Replace Source File…**, **Reveal in Finder**, **Show in Project Media**. Add a context menu to the multicam timeline too. The wording avoids clashing with Replace Source Audio, Replace Picture and Replace Track Audio.
- The preview slate's **Locate…** button and the status bar button.
- On open, if anything is offline, a non-blocking banner: "4 files are offline. **Relink…** **Not now**".
- **Working copies:** if a clip's working file (from Replace Source Audio, `docs/USAGE.md:398`) is missing, offer **Locate Working Copy**. The clip only records the replacement's basename and ordinal, which isn't enough to rebuild it from `original_file`.

**Locate…** One panel (`NSOpenPanel`, opened in the last folder that resolved something) accepts a **file or a folder**.
- **A file.** Picking a candidate confirms the editor’s choice. Probe it and run the shared apply checks below before committing. After a successful relink, infer a prefix remap (for example, `/Volumes/Shoot_A/Day1/` → `/Volumes/Archive/2026/Shoot_A/Day1/`) and try it for the other offline paths.
- **A folder:** walk it once (subfolders included) and match each offline path by, in order: the same relative path under the folder, then the same name and size, then the same name, duration and stream layout.
- Names compare case-insensitively with NFC/NFD normalisation, and a volume remounted as "Name 1" is recognised. Same-name, different-extension files are never matched.
- Both paths end in one review sheet: "Found 11 more." One row per offline path with candidate path, start timecode, duration, confidence and an **Include** checkbox. **Relink** applies the checked rows; unaffected rows stay offline.

**Match outcomes** (shared by Locate, the review sheet, CLI and MCP).
- **Match:** a unique candidate whose name, size, duration and stream layout agree. Pre-checked in the review sheet.
- **Ambiguous:** two or more equally good candidates. Unchecked until the user picks one.
- **Apply checks.** For each manual, folder, prefix, CLI or MCP mapping, validate media type, selected streams and every range that the forward map would affect in the current edit and retained history. Include selects, still replacement fragments, working copies, and multicam spans with their offsets and coverage. Run these checks even when the old snapshot has no digest. A shortfall goes to Replace preview with the affected uses and loss choices before any path is rewritten.
- **Different** covers an incompatible use or conflicting content evidence. Offer **Replace Source File…** and report the reason per candidate.
- **Verified** requires a matching full-file SHA-256 for a still, or complete candidate evidence that passes `MediaRefreshEvidence.verifiesSameFileContents` against the saved source evidence. Use a fresh candidate read, or cached evidence with an independently checked file generation captured when those bytes were read (including change time). Today’s `.cutdb` stamp and section checksum alone cannot establish this. Pin the candidate identity across the read and recheck it at commit. When the old source has complete proof, collect comparable candidate evidence before applying any Match. A read failure leaves the row pending and a proven mismatch vetoes it.
- None of the cheap signals is proof: a `.cutdb` stamp history can include generations later marked `content_changed`, persisted `SourceIdentity` omits the change time, and payload equality without timing and layout misses audio changes (`MediaRefreshEvidence.swift:70-95`). Test each of these counterexamples, plus same-size sibling WAVs, before any re-stamping ships.
- **Without a snapshot entry**, use the file name and recorded ranges to propose a Match. A still can also be Verified against its existing full-file SHA-256. Treat an `unverified-fcpxml-…` placeholder as missing evidence.
- **Partial batches:** if a row fails at apply (the file vanished, a veto), apply the rest and report the failures.

**Mechanics** (`CutProject.mapMediaPaths` is private, and `CutProjectMedia.paths` in `CutHistory.swift:16-48` is a read-only index, so neither rewrites anything)
- This needs a new rename path. `installMediaRefresh` is the model for walking segments and history, but it deliberately reinstalls media under the **old** `source.url` and keeps `originalURL` (`forRefreshAlias`), so an alias can't rename.
- Apply a **forward map only** (old path → new path) to the current state and every retained undo/redo state. Affected `.live` history entries (`HistoryContents`, which hold `IndexedSource`, not paths) are converted to `.document` with paths mapped. This is correct because `HistoryEntry.project` is built from `documentClips`. It discards cached indexes, so undo after a relink re-imports from the new path. History on disk is dependent deltas with bounded materialization (`CutHistory.swift:343-355,663-685`); test save/reopen with both paths present.
- **Revert to Previous Location.** When the destination has no independent uses, record `previous_path` and the identities of the uses rewritten across the current edit and both history branches. At Revert, re-enumerate those states and require every destination use to belong to that relink. An independent import, another mapping to that destination in the same batch, or missing provenance disables Revert. Persist the provenance with the snapshot entry so reopening or omitting the entry cannot enable an unsafe reverse map.
- Re-key URL- and UUID-keyed state: `refreshBaselines`, `offlineMedia`, `incompatibleMedia`, `refreshReviewStreams`, scene reports, the `SourceIndexLoader` cache and `savedMediaPaths`.
- Rewrite clip `file` and `original_file`, source selects, still assets (not gaps), multicam `angles`, `additionalRecordings`, `audioSources`, `stillAssets`, `stillAudioReference`, transcript `binding.file`, speaker-reference anchors and correction anchors, and the snapshot entries.
- In every sequence state, use `ParticipantProject.mapSourcePaths` for accepted geometry, appearance overrides, participant audio selections and camera slots in the render plan. In multicam, map the recording file behind the source ID. Check accepted geometry against the candidate using the existing participant reconciliation rules.
- **Transcripts.** After a Verified relink, advance a binding or authored anchor to the candidate fingerprint only if its non-nil `sourceFingerprint` equals the old fingerprint paired with the verified snapshot evidence. Preserve its confirmation flag. A missing or different fingerprint keeps its prior value. Apply the rule separately to each attachment binding, speaker reference and correction anchor, including retained history.
- **Queued exports:** keep their pinned snapshots. Today, ordinary ranges are invalidated by `range.media.keys`, which omits still-asset images in a queued `stillProject`. Multicam invalidates by `queued.project.sources` (`MulticamEditorModel.swift:2710-2712`), which omits the queued project's `stillAssets` and any source with an unresolved `..` (`:1346-1349`). One invalidated range blocks the whole run (`queuedMediaRefreshIssue`; `MulticamBulkQueue.swift:310,350`). Instead, enumerate dependencies from each queued snapshot, mark affected entries by ID, and offer **Replan** or **Remove** per entry; unaffected entries still run.
- **Sidecar:** reuse candidate analysis according to the verification rules above. Migrating authored sections (silence overrides, scene view names) from an orphaned old `.cutdb` is deferred: `AnalysisSidecar(source:)` needs the source's identity to open, and generation updates check evidence and filter overrides by verified stream (`SidecarManifest.swift:110-159`).
- **Indexing:** a relinked file without a current `.cutdb` needs a full index, which can take minutes. Its clips show *indexing* with progress and cancel, and can be moved or deleted meanwhile.
- **Concurrency:** `canRefreshProjectMedia` rejects `isBusy`, sidecar saves, an MCP trim and open alerts, but knows nothing about relink's own search and indexing jobs. Use multicam's request-ID and commit checks (`MulticamEditorModel.swift:748-757`): at apply, revalidate the project revision, candidate identity and affected uses, and discard stale callbacks.

Multicam's existing "Relink Source" and the still relink tools (`still_editor_asset_relink`, `still_file_asset_relink`, CLI `still asset relink`) are folded into this engine. A still whose new file fails the SHA-256 check becomes a Replace.

## Phase 4 — Replace

- **Replace Source File…** on a clip, a Project Media row or a multicam source. Choose a file; the engine probes it and shows the ripple table with defaults, and highlights affected clips on a mini timeline.
- Scope as in the table above: from a clip, this occurrence by default (a new source entry for that clip); from a Project Media row or multicam source, the user picks.
- Multicam: replacing a camera or mic offers **Re-sync** via the existing sync analysis (as in `MulticamTrackReplacementView`) and shows the offset change. Replacement audio `relativeOffset`s are rechecked.
- Commit the timeline, conformed ranges, participant changes and transcript edits as one “Replace Source File” action. An occurrence-only replacement preserves a source binding shared by the remaining uses. For a replacement that changes attachment bindings, record each affected attachment ID, track ID and its before/after binding values. `CutHistory.Step` currently stores only `transcriptAuthoring`, and sequence undo restores only `transcriptState.authoring`. Extend live undo/redo and saved history to apply the binding changes by ID to the current attachments and advance the transcript revision. This preserves attachments completed after Replace. Include binding paths in rebasing, relink and history media protection.

## Phase 5 — CLI and MCP parity

| Surface | Addition |
| --- | --- |
| CLI | `mpcut project media list <project> [--json]`; `project media relink <project> --from <old> --to <new>` and `--map-prefix <old>=<new>`; `project media locate <project> --folder <dir> [--apply-matches] [--json]`; `project media replace <project> --source <path> --with <file> [--conform trim\|keep] [--allow-loss]`. Each writes a new output, or updates the project in place with `--in-place`. `still asset relink` becomes an alias. |
| MCP (live) | `project_editor_media_list`, `project_editor_media_relink` (one, many or prefix), `project_editor_media_locate` (a job with a receipt that returns candidates; apply is a separate call), `project_editor_media_replace` (returns the ripple report and requires `confirm: true`). `multicam_source_edit action=relink` and `still_editor_asset_relink` become aliases. |
| MCP (file) | `project_file_media_*` equivalents, matching `project_file_media_refresh`; `still_file_asset_relink` becomes an alias. |
| Refresh | `project_*_media_refresh` reports the shared status enum, including stills, selects, transcripts and `original_file`. |

Each new tool needs an `MCPResources/*.json` descriptor, a dispatch handler, a capability in `MCPLocalControl.swift`, and updates to `docs/MCP-REFERENCE.md`, `docs/MCP-COVERAGE.md`, `scripts/mcp-reference.py`, `mcp/main_test.go` and `Tests/Packaging/test_public_contracts.py`.

## Later

- **Background evidence for ProRes MOV**, so ProRes relinks can be Verified and re-stamp transcripts.
- **Export with offline clips:** "Export without offline clips" (or with a slate) instead of refusing.
- **Migrating authored sidecar data** from an orphaned `.cutdb`.
- **A pre-open locate step** before the project window appears.
- Considered and dropped: bookmarks (no help on another machine, and still need verification), partial content hashes (payload evidence covers the sibling-WAV case), Spotlight search, and matching renamed files by size alone (a per-file Locate covers it).

## Docs and tests

- **User docs:** a "Missing and moved media" section in `docs/USAGE.md` (states, Locate, Replace), `docs/CUT-FORMAT.md` for the snapshot, `docs/CLI.md`, the agent guide and the CHANGELOG.
- **Fixtures:** projects referencing moved, renamed, deleted, shortened, re-encoded and stream-reordered files, plus same-size sibling WAVs, for sequence, still, multicam and transcript-bound sources. Include a project moved to another machine with all media under a new root.
- **Core tests:** snapshot round trips through every writer branch, including empty history, over-budget history and `save(to:)`; unknown entry fields preserved; relink forward map across every reference kind and every retained history state; Revert offered only when safe; each match outcome and each proof counterexample; ripple outcomes for each table row, including lost clips; transcript fingerprint re-stamped only when Verified.
- **App tests:** open, undo and draft recovery with offline files; the compiler-driven sweep for unresolved sources; `PreparedEdit` with an offline first clip; export of a selection avoiding offline clips; every `source_needs_review` site; detection on activation and volume events; a stale network mount that doesn't hang the UI, undo, or other volumes; queued exports with affected and unaffected entries.

| Regression | Expected result |
| --- | --- |
| Save a project near 64 MiB with populated undo and redo stacks. Repeat with room for one snapshot entry and then none. | Each file reopens with the same history as a snapshot-free save. Only complete entries that fit are written. |
| Rewrite a WAV in place with different samples, identical size and restored mtime. Leave its original sidecar beside it. | A fresh read detects the mismatch and vetoes relink. |
| Bind a transcript to take A, replace the file at that path with take B, save B’s evidence, then locate a verified copy of B. | A’s binding and authored anchors retain A’s fingerprint. Bindings for B advance and retain their confirmation state. |
| Relink a sequence with participant geometry, appearance overrides, stream bindings and camera slots, including uses reachable only through undo. Then preview Replace with a different take. | Every path follows the move after save/reopen and undo/redo. Replace lists affected participant decisions and redactions. |
| In a legacy project, locate a 10-second candidate for a source with a cut at 40 seconds. Repeat with a prefix mapping and a history-only cut. | Each affected row reports the shortfall before commit. The editor can inspect the loss in Replace. |
| Replace all uses of a transcript-bound sequence source, then finish another transcript job. Undo and redo live and after save/reopen. | The edited clip and its binding move together in both directions. The later attachment survives. |
| Relink A to B, independently import B, then undo that import so B’s independent use exists only in redo. | Revert stays disabled, including after save/reopen. With only the original mapped uses it is available. |
| Replace media with the same presentation origin and a source clock starting ten seconds later. | **Keep source timecode** maps a cut at 40 seconds to 30 seconds. Source-relative mode keeps 40 seconds. An absent or incomparable clock offers only source-relative placement. |

## Order and size

| Step | Contents | Depends on | Rough size |
| --- | --- | --- | --- |
| 1 | **Phase 0** snapshot and transcript-binding history format | — | Medium (every writer branch, both allowlists), urgent before v4 ships |
| 2 | **Open anything:** unresolved sources, red clips and slate, status enum, detection, export refused only for selections touching offline clips, save/reopen/undo tests | — (uses the snapshot when present) | Large |
| 3 | **Locate** (file or folder, prefix remap, review sheet) for all formats, plus the **Project Media** list | 2 | Large |
| 4 | **Replace** with the ripple table | 3 | Large |
| 5 | **CLI/MCP** parity | trails each step | Medium |

Step 3 is what a user moving a project to another machine needs on day one: one Locate of the media root resolves everything. Step 2 alone already helps every existing project, including those saved without a snapshot.

## Open decisions

1. **Relink history model.** *Recommended:* not an undo step; rewrite the path in every retained state, with **Revert to Previous Location** in Project Media for a wrong pick. The alternative records relink as an ordinary undo step without rewriting history, but then every undo past the relink turns the timeline red again.
2. **Snapshot contents for v4.0.** *Recommended:* the minimal set listed in Phase 0, in open entry objects, so ProRes evidence and other fields can be added later without a schema bump. The alternative freezes a fuller, closed set now, which locks in fields before their design is settled.
3. **Replace strictness.** *Recommended:* block only media-type changes and unmapped missing audio streams; warn and conform everything else with a default the user can change. The stricter alternative blocks any duration shortfall or frame-rate change.
