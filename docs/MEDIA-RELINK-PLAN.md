# Missing media, relink and replace

**Proposed behavior.** A project always opens, even if its recordings are gone. Missing media appears in red wherever it is used. One **Project Media** list shows every file the project references and its status. From there the editor can locate a moved file, search a folder for missing originals, or replace a source with different footage. Each action previews its effect on the timeline before it applies. The ordinary sequence editor, still placements, replacement audio, multicam cameras and microphones, transcripts, the CLI and MCP all share one engine.

## Where MPCut stands today

| Area | Current behavior | Gap |
| --- | --- | --- |
| Opening a sequence project | Two failure points. `checkedFiles` throws `missing_source` for a `..` path whose parent folder is gone (`EditorModel.swift:546`, `:553-565`; `CutProject.swift:639-642`). Then any source that fails to index aborts the open with *Couldn't Open Project* / `import_incomplete` (`EditorModel.swift:1726-1729`, also `:1762`). Undo/redo into an offline state falls through `cachedSegments` (`:3168`) to the same `importFiles` and fails with *Couldn't Restore*. | Can't open a project to fix it, and can't undo past a missing file. |
| Opening a multicam project | Opens: `openProject` installs the project with empty media and then loads sources one by one, so missing files only produce per-source issues and an orange hatch (`MulticamEditorModel.swift:536-588`, `:1159`; `MulticamTimeline.swift:1066`). Multicam history entries hold path-based projects, so rewriting paths across its history is simpler than in the sequence editor. | Orange means both "offline" and "needs review". |
| Offline after open | `ProjectMediaWatcher` and **Refresh Project Media** fill `offlineMedia`. `mediaReviewIssue` (`EditorModel.swift:6694`) then drives the " · Needs review" label, the "Unavailable" preview slate (`:4936`), scene detection (`:1988`), filmstrips (`Timeline.swift:1273`, via `clip.mediaIssue`), waveform and silence analysis and so silence snapping (`EditorModel.swift:5161`), JPEG at the playhead (`:3348`) and the export sheet (`:3818`). `source_needs_review` is thrown at 11 sites in 4 files, including `MCPOutputs.swift:421-740`, `MCPReviewFrame.swift:256/308` and `MulticamJPEGExport.swift:35/120`. | The watcher is off by default and only watches current timeline clips (`EditorModel.swift:6634`). There's no red state and no relink for sequence clips. |
| Relink | Multicam source **Relink…** checks only the media type and that the selected audio streams exist (`MulticamEditorModel.swift:713-770`). Stills "relink" overwrites the SHA-256 fingerprint without comparing it (`StillProjectEditing.swift:171`, `MCPStills.swift:331`), so it is really a replace. | Doesn't check the new file is the same media, works one file at a time, and offers no search. Offset, coverage and replacement offsets aren't rechecked. |
| What a `.cut` stores per source | A path only, relative to the project. No bookmark and no identity. `SourceIdentity` uses the inode, so it fails for a copied or restored file. | Without the file there's nothing to show (duration, tracks) and nothing to match a candidate against. |
| Content evidence | `<media>.cutdb` lives next to the media (`AnalysisSidecar.swift:41`) and usually **travels with it** on a Finder move. A move on the same volume keeps device, inode, size and mtime, and the sidecar tolerates device-number changes (`:133-138`). The sidecar also keeps a stamp history, but entries marked `content_changed` (`SidecarManifest.swift:150-154`) mean an old stamp in a candidate's history does **not** prove the candidate still has that content. Persisted `SourceIdentity` omits the change time (`Probe.swift:305-320`), so an in-place rewrite with restored mtime matches it. Stills already store a full-file SHA-256 (`StillImage.swift:122`). Payload evidence comes free with the ordinary packet scan (H.264, HEVC, WebM and other scanned formats, `probe.c:1168-1176,1213`), but the ProRes MOV fast index path skips the scan and produces none unless a deep probe forces it (`probe.c:1168`). The PCM WAV fast path (`:1038-1046`) runs only for audio-analysis probes (`CutEngine.inspectForAudioAnalysis`, `CutEngine.swift:55-60`), so an ordinary editor index of a WAV does produce evidence, unless the source was first loaded from an analysis-only sidecar. It is persisted in the `.cutdb` (`SidecarManifest.swift:14,72`). | Strong *ranking* signals exist; strong *proof* of same content is rarer than it looks. |
| Interchange | FCPXML/Resolve fail with `missing_source` (`ResolveExport.swift:189`). Premiere export stats each file and fails locally with "Relink the source to a regular media file" (`PremiereTimeline.swift:46-54`). FCP metadata resolves `original_file` with `checkedMediaURL`, which rejects an unresolved `..` but accepts a missing leaf file, so a missing original can be written silently (`ResolveExport.swift:105-108`, `CutProject.swift:639-645`). FCPXML import of a missing still writes the fingerprint `unverified-fcpxml-<ref>` (`FCPInterchange.swift:227`). | Needs a preflight scoped to what the requested output actually depends on, with a link to Project Media. |

The app has no entitlements and isn't sandboxed, so it can read any folder the user picks. macOS privacy prompts still apply to Desktop, Documents, removable and network volumes, including during automatic probing and Spotlight queries. `relativeMediaPath` already handles paths whose folders are gone (`CutProject.swift:354`). Saving with offline media already works and keeps the stored path: the writer relativises each path with `relativeMediaPath`, which resolves the nearest existing ancestor (`EditorModel.swift:704-740`, `CutProject.swift:354-380`), and the save collision check skips or canonicalises missing sources without requiring them (`CutProject.swift:612-634`). One risk remains: canonicalising a path on a stale network mount can block, so save inherits the detection work's per-volume timeout.

## Two separate operations

| | **Relink** | **Replace** |
| --- | --- | --- |
| Meaning | The same recording at a new location | Different media in place of a source (re-render, re-wrap, re-export, another take) |
| Verification | The strict rule in Phase 3. Anything weaker is a Replace. | The candidate is probed and compared property by property (ripple table) |
| Scope | Every reference to the file across the timeline, stills, transcripts and retained undo/redo states. Queued exports keep their pinned snapshots and are marked affected (Phase 3). | Depends on the entry point: a clip command defaults to **that occurrence**; a Project Media row requires an explicit choice (**this use** / **all uses**). |
| History | One undoable **"Relink N Files"** step that records the exact affected references and their before-values (not a path-wide inverse map: if an unrelated clip already used the new path B, mapping B → A on undo would hijack it). Undo restores only those references and says that it takes them offline again. Marks the document dirty. | An ordinary undoable edit ("Replace Source File") |
| Derived data | Carried forward: transcript fingerprint, authored sidecar data, analysis sections that still verify | Invalidated, except authored data the user opts to keep |

Relink is bookkeeping, so it should be fast and batchable, and silent only when the match is certain. Replace is an edit and must show what it changes. A candidate that is *probably* the same (for example, re-wrapped) is applied as a Replace whose ripple table happens to have no rows.

## Ripple table for Replace

The engine compares the candidate with the old source's snapshot and gives each difference one outcome. The replace sheet lists them before **Apply**.

| Property | What depends on it | Outcome |
| --- | --- | --- |
| Duration shorter than the furthest use | Clip `to`, source selects, still replacement fragments, multicam spans and `coverage`, working copy `duration >= lastCut` | **Warn + conform.** Clips that overlap the new end are trimmed to it (default) or left out of range and red. Clips that **start** beyond the new end can't be trimmed (`to > from`, `CutProject.swift:215`) and still fragments can exceed the new extent independently (`StillReplacementEditing.swift:54-60`); list these as *lost* separately and require an explicit choice (remove, or keep offline) before apply. Show the resulting change in timeline duration. |
| Start time / origin / timecode | Clip times relative to `info.origin`, multicam `offset`, transcript `sequenceClockOrigin` | **Warn.** Options: keep source-relative times (default) or keep timecode-relative times by shifting `from/to` by the origin difference. For multicam, offer **Re-sync** (waveform or timecode) and show the old and new offset. |
| Frame rate / keyframes | Snapped cut boundaries, Smart Trim joins | **Warn.** Cuts keep their exact times. List cuts that no longer fall on a frame or safe boundary, and say which export modes still work. |
| Audio stream count or order | Sequence `track_ordinal`, multicam stream index and channel, mix lanes, replacement audio, transcript `streamIndex`, still soundtrack track count | **Block** if a selected stream disappears, unless the user maps it in a small stream-mapping table (old stream → new stream, matched by layout, language and name). **Warn** on a reorder that this mapping resolves. |
| Media type (picture ↔ audio-only) | Picture lanes, stills, multicam camera vs mic | **Block.** |
| Codec, dimensions, rotation, color | Stream-copy compatibility (`checkCompatibility`) | **Warn.** "Copy export unavailable; re-encode required." Doesn't block. |
| Still aspect ratio / content | Normalized crop, fill/fit, SHA-256 fingerprint | **Warn.** Show the old and new framing side by side; offer **Reset crop**. Re-stamp the fingerprint on apply. |
| Transcript | Bound words | **Warn.** The transcript becomes *Changed*; offer **Keep (unverified)** or **Re-transcribe**. |

## Phase 0 — Snapshot in v4 before it freezes

Schema v4 is unreleased (CHANGELOG *Unreleased*: "open from v3 and save as v4"). Readers reject unknown fields, so the snapshot must go into v4 now or it costs a v5 bump, and released builds can't open v5 projects. It's also worthless for projects saved before it exists. Ship this independently of everything else.

- **Where:** at the `Document` level beside `history` (`CutHistory.swift:381`), not in each `CutProject` state, so it stays out of history deltas and undo equality. One entry per distinct path, **including paths that appear only in history states**. But `Document` shares the project's top-level decoder and both sequence and multicam reject unknown keys there (`CutProject.swift:119-122`, `MulticamProject.swift:335-345`), and the writer builds a fresh `Document` (`CutHistory.swift:289`). So: add the optional key to both top-level allowlists and both schema branches (`cut-v4.schema.json:32,69,227,274`), and thread the snapshot through the editor load result, drafts, Save As/rebase and every file-tool write. Test untouched and history-only entries across each round trip, a size bound, and a path reused for different media.
- **What:** stored path, file name, size, mtime, `SourceIdentity` fields, duration, origin, frame rate, dimensions, timecode, and per stream: kind, codec, channels, language. Also a **partial content hash** (SHA-256 of the first and last 1 MB), which is cheap at index time and helps rank same-size sibling files such as multitrack-recorder WAVs. It's a ranking signal only, never proof. Include `MediaRefreshEvidence` payload hashes when a deep probe has produced them. Stills use their existing full-file SHA-256.
- **Writers:** the GUI writes it from live `MediaInfo` and keeps the previous entry for offline sources. The CLI, MCP file tools, `project convert` and interchange importers must preserve existing entries and probe new paths, or omit an entry rather than guess.
- **Optional bookmark** (base64) per entry. A bookmark follows the file ID, or the path after an in-place re-render, so a bookmark match still has to pass verification. Resolve with `withoutUI` and `withoutMounting`.
- Update `docs/CUT-FORMAT.md`, `docs/schema/cut-v4.schema.json` and the v3 → v4 read path. v3 files have no snapshot and open anyway.

## Phase 1 — Open anything

1. **Placeholders in the sequence editor.** Both failure points (`checkedFiles` with a missing `..` parent, and indexing in `importFiles(projectClips:)`) produce an **offline source** instead of rejecting. The same applies when undo/redo restores a state with a missing file, and to draft recovery, which uses the same `ProjectSessions.openProject` path (`ProjectDraft.swift:333-334`, `ProjectSessions.swift:567`). MPCut has no window state restoration. `import_incomplete` remains only for real format errors in a present file, and those open as offline with the error text too. Saved ranges past the end of a *present* but changed file (`project_clip_range`, `project_audio_track`) also open, marked **Needs review**.
2. **An unresolved-source type, not a fake `MediaInfo`.** A sequence clip stores an ID, path, range, optional `track_ordinal`, `original_file` and `replacement_names`, but no picture/audio lane discriminator (`CutProject.swift:6-30`), so any invented stream is a guess. A fake picture stream can select the still-review canvas (which only tests `hasVideo`), and a synthetic PCM audio index satisfies `hasFullEditIndex` without packets (`Probe.swift:195-199`). The `MediaInfo` init also force-unwraps an audio stream for picture-less sources (`:276`). So:
   - Model an editor source as resolved (`IndexedSource` with real `MediaInfo`) or **unresolved** (stored path, authored ranges, the known kind when the snapshot or `track_ordinal` gives it, and the Phase 0 snapshot if any). Draw unresolved clips from their authored ranges.
   - Require resolved `MediaInfo` at the entry points: reader, edit planner (`PreparedEdit`, `EditorModel.swift:184-205`), tier calculation, analysis, preview, still review (`:3338-3340`), JPEG (`:3342-3361`) and the export sheet (`:3818`). An unresolved source never reaches code that reads streams or frames, so no flag audit across 68 `hasFullEditIndex` call sites is needed.
   - Export of a selection that touches no unresolved clip still works.
   - Test audio-only, unknown-kind, offline-first and all-offline timelines.
3. **One source-status model** shared by both editors: `online`, `offline`, `indexing` (found, index in progress), `changed`, `needs review`. Two walkers produce reference lists and both need extending: `MediaRefreshProject.swift:57-123` and `EditorModel.swift:6648-6663`. Add still assets (both editors, **excluding gaps**, whose `file` returns a built-in image path, `StillProject.swift:123-135`), source selects, transcript bindings including speaker-reference anchors (`TranscriptAuthoredRecord.speakerReference`, `TranscriptAuthoring.swift:188`), and `stillAudioReference` (`StillProject.swift:437`). Missing transcript JSON assets are not media: route them to the existing `TranscriptStore.recover` (`TranscriptStore.swift:446`), not to relink. `original_file` is already walked (`MediaRefreshProject.swift:81`).
   - An offline `original_file` behind an online working copy is **informational**: a grey note, not red.
   - **History-only** references are listed separately and don't count toward "N files offline".
4. **Detection.** Reuse `ProjectMediaWatcher`'s stamp mode rather than adding a second checker. It already re-checks on activation, mount and unmount (`ProjectMediaRefresh.swift:166-171`). Make that cheap stamp check always on, and extend it from timeline clips to stills, originals and history-only paths. Keep per-file `DispatchSource` watching (instant red while the app is in front) opt-in, as today. Today the watcher runs on the main actor, walks parents with `fileExists`, opens descriptors there, and waits for two whole-set stamp passes (`ProjectMediaRefresh.swift:174-199,239-262`). A stale SMB mount can block a `stat` indefinitely. So: move ancestor lookup and descriptor opening off the main thread, **publish each volume's results independently**, allow at most one outstanding probe per unresponsive volume, and add explicit *checking* and *unreadable* outcomes so one dead mount never holds up the rest.
5. **What offline clips allow.** Move, delete, reorder, rename and relink/replace. Trimming and splitting need frame and keyframe grids (`IndexedSource.frameBoundaries`) that placeholders don't have, so they wait until the file is found. The 11 `source_needs_review` sites and the `mediaReviewIssue` consumers listed above refuse with a link to Project Media. Interchange export runs an offline preflight first and lists what's missing.

## Phase 2 — Visuals

- **Colors.** Red means offline, orange means needs review. Add shared constants (there's no `EditorDesign` type today; `EditorDesign.swift` holds only bar chrome). Red and orange are already used by the export tier badge for *unavailable* and *re-encode* (`TimelineTierGate.swift:223-226`), and red for the playhead. So the offline state is identified by a **diagonal hatch plus icon**, not by color alone, and the tier badge keeps its meaning.
- **Ordinary timeline** (`Timeline.drawClip`, `Timeline.swift:1105`): offline clips get a red diagonal hatch over a dark fill, a red border, an `exclamationmark.triangle.fill` badge before the name and a "Media Offline" label in place of thumbnails/waveform. *Indexing* clips show a progress sweep. Needs-review clips keep their thumbnails with an orange edge and badge. Tooltips include the issue text and the stored path.
- **Multicam timeline**: switch the existing hatch (`MulticamTimeline.swift:1066`) to red for missing files; keep orange for "track index unavailable" and range coverage problems. Same for `MulticamTierBadge`.
- **Preview slate**: `PreviewSurface.unavailable` shows a full-frame **Media Offline** slate (red bar, file name, last known path, **Locate…** button) when the playhead is over an offline clip. Audio-only offline sources show the same in the waveform area. During playback the slate is shown for the clip's duration and audio is silent, as today.
- **Status bar**: the existing "Media needs review" menu (`EditorView.swift:296`) becomes a red **"3 files offline"** button when anything is offline (orange when only review), opening Project Media.
- **Stills**: offline assets show a red placeholder thumbnail and a slate in the program review, replacing the " (offline)" name suffix.
- **Accessibility**: never color-only. Every state has an icon and text, and VoiceOver reads "Media offline: <name>".

## Phase 3 — Relink

**Project Media list** (new). It's the home for batch work, since the ordinary editor has no media pool. It's a sheet or inspector tab in both editors (multicam extends its existing Sources tab) listing each referenced file once: name, kind icon, status chip, used-by count ("4 clips, 1 transcript"), duration and stored path. Filter by **Offline / Needs review / All**, with history-only references in a separate group. Selecting rows enables **Locate…**, **Search Folder…**, **Replace Source File…**, **Reveal in Finder** and **Show Uses** (selects the clips on the timeline).

Entry points:
- File menu: **Relink Offline Media…** next to Refresh Project Media (⇧⌘L, which is unbound; plain L is shuttle-forward in the key handler, `EditorView.swift:369`, and doesn't conflict).
- Clip context menu: **Locate Media…**, **Replace Source File…**, **Reveal in Finder**, **Show in Project Media**. Add a context menu to the multicam timeline too. The wording avoids clashing with the existing Replace Source Audio, Replace Picture and Replace Track Audio commands.
- The preview slate's **Locate…** button and the status bar button.
- On open, if anything is offline, a non-blocking banner: "4 files are offline. **Relink…** **Not now**". Not a modal.
- **Working copies:** if a clip's working file (from Replace Source Audio, `docs/USAGE.md:398`) is missing, offer **Locate Working Copy**. The clip only records the replacement's basename and ordinal (`EditorModel.swift:3735-3738`), which isn't enough to rebuild it from `original_file`. Offer **Rebuild** only once a complete replacement recipe is stored and its inputs are available.

**Verification rule** (used everywhere: Locate, prefix auto-resolve, Search, CLI, MCP). Cheap signals **rank** candidates; only proof of same content applies without asking. None of the cheap signals is proof. The candidate's `.cutdb` stamp history can include generations later marked `content_changed`. Persisted `SourceIdentity` omits the change time, so an in-place rewrite with restored mtime still matches. A same-length edit in the middle of a PCM file defeats first/last-MB hashes. Payload equality without timing, padding, layout and audible bounds misses audio changes (`MediaRefreshEvidence.swift:70-95`).

- **Ranking signals:** same `SourceIdentity`; the snapshot's stamp in the candidate's `.cutdb` history (and not superseded by `content_changed`); same name (case and Unicode normalised), size, mtime, duration, origin, start timecode and stream layout; partial content hash.
- **Verified** (applies without asking) requires a **unique** candidate plus one of: a matching whole-file digest (stills already have SHA-256), or complete ordered-stream evidence that `MediaRefreshEvidence.verifiesSameFileContents` accepts, covering payload, clocks, presentation and layout. The ordinary editor index produces payload evidence for packet-scanned formats, including H.264, HEVC, WebM and PCM WAV, so the Phase 0 snapshot stores it and those relinks can be Verified without an extra read. That covers same-size sibling WAVs, the likeliest false match. ProRes MOV uses a fast index path with no evidence (`probe.c:1168`). For ProRes, either compute evidence once in the background after indexing and store it in the snapshot, or accept that it relinks as Probable. `verifiesSameFileContents` (`MediaRefreshEvidence.swift:176-187`) compares duration, origin, format, index issues and every stream's payload, timing and packet-layout digests, codec configuration, padding, channel layout, sample rate, start, time base and display geometry, which covers what proof needs.
- **Veto:** a known digest or payload mismatch rules a candidate out, whatever the weaker signals say.
- **Probable:** strong ranking signals but no proof, or two equally good candidates. Asks first, showing the differences with a side-by-side frame or waveform. A batch of Probable matches can be confirmed with one click. If confirmed, it relinks, but derived data is treated as unverified: transcripts become *unverified* and lose pause protections, and analysis is re-checked by refresh.
- **Different:** offers **Replace Source File…** with the ripple table.
- Test every counterexample above (stale sidecar history, restored mtime, middle edit, sibling WAVs) before any automatic transcript re-stamping ships.

**Locate (one file).** An `NSOpenPanel` filtered to media types, opened in the last folder that resolved something. It applies the rule above.

**Auto-resolve the rest.** After any successful locate, infer a folder remap (old prefix → new prefix, e.g. `/Volumes/Shoot_A/Day1/` → `/Volumes/Archive/2026/Shoot_A/Day1/`) and try it for every other offline file. Compare names case-insensitively and with NFC/NFD normalisation, and allow for a volume remounted as "Name 1". Show "Found 11 more in the same place. **Relink all**" (Verified ones apply; Probable ones are listed for one confirmation). Same-name, different-extension files are never matched automatically.

**Search Folder…** Choose a folder (and optionally include subfolders, default on). A background job walks it once, matching each offline source in tiers:
1. Bookmark resolution (Phase 0), if stored.
2. Same relative path under the chosen folder.
3. Same name and size.
4. Same name, duration and stream layout (re-wrapped copies; at most *Probable*).
5. Same size and duration with a different name (renamed): only offered, never auto-applied.

Every tier still has to pass the verification rule to be pre-checked. Results come back as a review table, one row per offline source: candidate path, start timecode, duration, confidence (Verified / Probable / Ambiguous with a picker), **Include** checkbox. Only unique Verified rows are pre-checked; equally good candidates stay unchecked until the user picks one. Finding candidates never implies permission to apply them. A **Leave offline** choice per source suppresses repeated alerts for media that is deliberately absent. When the old snapshot has payload hashes, included rows are deep-probed before apply, with progress and cancel. Spotlight (`NSMetadataQuery` on `kMDItemFSName`) is an optional fast first pass, with the walk as the reliable fallback. **Partial batches:** if a row fails at apply (the file vanished, or hashes don't match), apply the rest and report the failures.

**Mechanics** (`CutProject.mapMediaPaths` is private, and `CutProjectMedia.paths` in `CutHistory.swift:16-48` is a read-only index, so neither rewrites anything):
- This needs a new rename path. `installMediaRefresh` (`EditorModel.swift:6742`) is the model for walking segments and history, but it deliberately reinstalls media under the **old** `source.url` and keeps `originalURL` (`forRefreshAlias`, `:6854-6856`), so an alias can't perform a rename. Affected `.live` history entries (which hold `IndexedSource`/`MediaInfo`, not paths, `:884-918`) are converted to `.document` with paths mapped. History is stored as dependent deltas with bounded materialization (`CutHistory.swift:343-355,663-685`), so test save/reopen with both the old and new path present in history.
- Record each affected reference (kind, owner ID, field, before-value) in the undo entry, so undo restores exactly those and nothing that independently uses the new path.
- Re-key URL- and UUID-keyed state: `refreshBaselines`, `offlineMedia`, `incompatibleMedia`, `refreshReviewStreams`, scene reports, the `SourceIndexLoader` cache and `savedMediaPaths`.
- Rewrite clip `file` and `original_file`, source selects, still assets (not gaps), multicam `angles`, `additionalRecordings`, `audioSources`, `stillAssets`, `stillAudioReference`, transcript `binding.file`, speaker-reference bindings and correction anchors, and the Phase 0 snapshot entries.
- Re-stamp the transcript `sourceFingerprint` only on a Verified relink, so pause protections survive.
- **Queued exports:** keep their pinned snapshots. Refresh invalidates ordinary ranges by `range.media.keys` (`EditorModel.swift:6768-6770`), which holds only clip files and `stillAudioReference` (`:3207-3214`) and so omits still-asset images in a queued `stillProject`. Multicam invalidates by `queued.project.sources` (`MulticamEditorModel.swift:2710-2712`), which omits the queued project's `stillAssets` and any source whose path has an unresolved `..` (`:1346-1349`). One invalidated range also blocks the whole queue run (`EditorModel.swift:3287-3290`, `:6689-6692`; `MulticamBulkQueue.swift:310,350`). Instead, enumerate dependencies from each queued snapshot, mark affected entries by ID, and offer **Replan** or **Remove** per entry. Unaffected entries still run. Cover still-only, multicam and mixed batches.
- **Sidecar:** if the candidate already has a current `.cutdb`, use it. Migrating authored sections (silence overrides, scene view names) from an orphaned old `.cutdb` is **deferred**. `AnalysisSidecar(source:)` needs the source's identity to open, and existing generation updates check expected evidence, filter overrides by verified stream and carry scenes conditionally (`SidecarManifest.swift:110-159`); re-sealing a checksum proves none of that. A later version can verify archived bytes against the old stamp, map authored values to proven streams and views, and write in a conflict-checked transaction.
- **Indexing cost:** a relinked file without a current `.cutdb` needs a full index, which can take minutes for a long recording. Clips show *indexing* with progress and cancel, and are usable for move/delete meanwhile.
- **Concurrency:** `canRefreshProjectMedia` already rejects `isBusy` (import, export, refresh, bulk queue and more), sidecar saves, an MCP trim and open alerts (`EditorModel.swift:6613-6617`, `:1335-1339`), but it knows nothing about a relink's own search and indexing jobs. Use multicam's request-ID and commit checks (`MulticamEditorModel.swift:748-757`): at apply, revalidate the project revision, candidate identity and affected uses, and discard stale callbacks from search, indexing or refresh.

Multicam's existing "Relink Source" and the still relink tools (`still_editor_asset_relink`, `still_file_asset_relink`, CLI `still asset relink`) are folded into this engine. A still whose new file fails the SHA-256 check becomes a Replace.

## Phase 4 — Replace

- **Replace Source File…** on a clip, a Project Media row or a multicam source. Choose a file; the engine probes it and shows the ripple table with the default resolution for each row and the affected clips highlighted on a mini timeline.
- Scope: from a clip, **this occurrence** (default, creates a new source entry for that clip); from a Project Media row or multicam source, the user must pick **this use** or **all uses**.
- Multicam: replacing a camera or mic offers **Re-sync** via the existing sync analysis (as in `MulticamTrackReplacementView`) and shows the offset change. Replacement audio `relativeOffset`s are rechecked.
- Applied as one undoable "Replace Source File" edit through `apply(... action:)` / multicam `edit()`. Undo restores the old path and all conformed ranges.

## Phase 5 — CLI and MCP parity

| Surface | Addition |
| --- | --- |
| CLI | `mpcut project media list <project> [--json]` (status per source and its uses); `project media relink <project> --from <old> --to <new>` and `--map-prefix <old>=<new>`; `project media search <project> --folder <dir> [--apply-verified] [--json]`; `project media replace <project> --source <path> --with <file> [--conform trim|keep] [--allow-loss]`. Relink and replace write a new output, or update the project in place with `--in-place`. `still asset relink` becomes an alias. |
| MCP (live) | `project_editor_media_list`, `project_editor_media_relink` (one or many, or prefix), `project_editor_media_search` (a job with a receipt that returns candidates; apply is a separate call), `project_editor_media_replace` (returns the ripple report and requires `confirm: true` to apply). `multicam_source_edit action=relink` and `still_editor_asset_relink` stay as aliases routed to the new engine. |
| MCP (file) | `project_file_media_*` equivalents, matching `project_file_media_refresh`; `still_file_asset_relink` becomes an alias. |
| Refresh | `project_*_media_refresh` reports the new status model, including stills, selects, transcripts and `original_file`. |

Each new tool needs: an `MCPResources/*.json` descriptor, a dispatch handler, a capability in `MCPLocalControl.swift`, and updates to `docs/MCP-REFERENCE.md`, `docs/MCP-COVERAGE.md`, `scripts/mcp-reference.py`, `mcp/main_test.go` and `Tests/Packaging/test_public_contracts.py`.

## Later

- **Export with offline clips:** offer "Export without offline clips" (or with a slate) instead of refusing outright.
- **A pre-open locate step:** offer "Locate missing media" before the project window appears. Not a substitute for placeholders, since it still needs an "open anyway" path.

## Docs and tests

- **User docs**: a "Missing and moved media" section in `docs/USAGE.md` (red vs orange, relink, search, replace), `docs/CUT-FORMAT.md` for the v4 snapshot, `docs/CLI.md`, the agent guide and the CHANGELOG.
- **Fixtures**: projects that reference moved, renamed, deleted, shortened, re-encoded and stream-reordered files, plus same-size sibling WAVs, for sequence, still, multicam and transcript-bound sources.
- **Core tests**: v3 → v4 read and round-trip with offline sources and snapshots, including history-only paths; each verification-rule branch, including sibling WAVs rejected; prefix inference with case, normalisation and "Name 1" volumes; relink and its recorded-reference undo across every reference kind, including a new path already used by an unrelated clip; ripple outcomes for each table row; transcript fingerprint re-stamped only on a Verified relink; each verification counterexample (stale sidecar history, restored mtime, middle edit, sibling WAVs).
- **App tests**: open, undo and draft restore with offline files; unresolved sources rejected at every reader, planner, analysis and preview entry point; export of a selection that avoids offline clips; every `source_needs_review` site; detection on activation and volume events; a stale network mount that doesn't hang the UI or hold up other volumes; queued exports with affected and unaffected entries.

## Order and size

| Phase | Depends on | Rough size |
| --- | --- | --- |
| 0 Snapshot in v4 | — | Medium (two allowlists, schema branches, every writer), and urgent before v4 ships |
| 1 Open anything | — (uses the snapshot when present) | Large: unresolved sources, entry-point guards, status model, detection |
| 2 Visuals | 1 | Medium |
| 3 Relink (list, locate, search, engine) | 1 | Large |
| 4 Replace (ripple table) | 3 | Large |
| 5 CLI/MCP | 3, 4 (can trail each phase) | Medium |

**Ship in this order:**
1. **Phase 0 on its own**, as a format change, before v4 freezes.
2. **Open anything (sequence):** offline open with authored ranges preserved, red clips and slate, export refused only for selections that touch offline clips, and save/reopen/undo tests. This helps every existing project, including those saved without a snapshot.
3. **Single-file Locate for stills**, where the stored SHA-256 already gives proof, then for video and audio whose ordinary index already yields payload evidence (H.264, HEVC, WebM, WAV), then ProRes once background evidence exists.
4. **Prefix batches, Search Folder and Project Media**, after the collision and persistence tests for relink undo pass.
5. **Replace**, then **CLI/MCP** parity trailing each step.

## Open decisions

1. **Replace strictness.** *Recommended:* only block media-type changes and unmapped missing audio streams. Warn and conform everything else with a default the user can change. The stricter alternative blocks any duration shortfall or rate change.
2. **Background evidence for ProRes MOV.** *Recommended:* yes. After indexing, read ProRes files once at low priority to compute payload evidence and store it in the snapshot. That costs one full read of what are often the largest files, but without it they can never relink silently. The alternative leaves ProRes as Probable, needing a confirmation every time. (Per-file watching stays opt-in, as today.)
3. **Probable matches.** *Recommended:* one confirmation for a whole batch, with differences listed per file. The alternative asks per file, which is safer but tedious after a whole drive is renamed.
