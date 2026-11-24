# Tiles stage 0 design

This document specifies the target behavior for the [Tiles plan](FEEDS-PLAN.md). The legacy inventory records the starting point in this checkout. The delivery, migration, and performance criteria describe work to implement and verify in their respective stages.

## Command inventory

The eleven existing entry points come from the CLI dispatch and the app's MCP catalog. Desktop equivalents sometimes cover only part of a file operation. The existing catalog has no participant editor tools. [CLI help](../Sources/MPCutCLI/CommandHelp.swift) · [CLI implementation](../Sources/MPCutCLI/Participants.swift) · [MCP catalog](../Sources/MPCutApp/MCPResources/participants.json)

| Existing CLI | Existing MCP | Existing desktop |
| --- | --- | --- |
| `participants scan` | `participants_file_scan` | Analyze in the participant inspector |
| `participants markers build` | `participants_file_markers_build` | Layout Change Markers from a pending scan |
| `participants project inspect` | `participants_file_project_inspect` | Accepted roster, geometry and composition controls |
| `participants project accept` | `participants_file_project_accept` | Accept Geometry |
| `participants project apply` | `participants_file_project_apply` | Individual edits and Save Composition |
| `participants render plan` | `participants_file_render_plan` | Composition preview and export checks |
| `participants render export` | `participants_file_render_export` | Movie export with a saved composition |
| `participants angles list` | `participants_file_angles_list` | Angles in the composition sheet |
| `participants angles take` | `participants_file_angles_take` | Take at Playhead |
| `participants angles plan` | `participants_file_angles_plan` | — |
| `participants angles render` | `participants_file_angles_render` | — |

Every row below is a target. Within the Tiles namespace a suffix yields `tiles_file_<suffix>` and, from stage 3, `tiles_editor_<suffix>`. File mutations require a destination or explicit in-place editing. Editor mutations require a project handle and revision, commit one undo step, and check the revision again after asynchronous work. Read and export operations do not create undo entries. Source time is relative to the selected video stream's presentation origin. Resolve ambiguous recordings from an explicit source ID.

| CLI under `tiles` | MCP suffix or existing family | Desktop destination | First file stage |
| --- | --- | --- | --- |
| `scan` | `scan` | Find Tiles | 1 |
| `inspect` | `inspect` | Tile spans, markers and Needs a Look | 1 |
| `preview` | `preview` | Explicit Source review | 1 |
| `link` | `link` | Assign tile in Check or Fix | 1 |
| `accept` | `accept` | Use These Tiles | 1 |
| `feeds list` | `feeds_list` | Feed rows | 1 |
| `feeds add` | `feeds_add` | Add Feed for hand-drawn tiles | 6 |
| `feeds inspect` | `feeds_inspect` | Feed lane and details | 1 |
| `feeds rename` | `feeds_rename` | Rename | 1 |
| `feeds mic` | `feeds_mic` | Microphone binding | 1 |
| `feeds voice` | `feeds_voice` | Transcript voice binding | 1 |
| `feeds prefer` | `feeds_prefer` | Preferred box in Fix | 1 |
| `feeds merge` | `feeds_merge` | Merge cards or Same Feed | 1 |
| `feeds split` | `feeds_split` | Split identity or Different Feed | 1 |
| `angles plan` | `angles_plan` | Review Export ISOs plan | 1 |
| `angles render` | `angles_render` | Export ISOs | 1 |
| `angles verify` | `angles_verify` | Export ISOs verification report | 1 |
| `export-isos` | `export_isos` | Export ISOs | 1 |
| `grid correct` | `grid_correct` | Correct grid for a range | 2 |
| `switches propose` | `switches_propose` | Transcript suggestions on switch lane | 2 |
| `feeds treatment` | `feeds_treatment` | Hide or Blur | 3 |
| `feeds confirm` | `feeds_confirm` | Confirm a reviewed feed range or resolve completely verified absence for a whole recording | 3 |
| `layout set` | `layout_set` | Choose layout and contents | 3 |
| `layout list` | `layout_list` | Layout lane | 3 |
| `reconcile` | `reconcile` | Review recording replacement | 3 |
| Existing frame export | Export and review families | Output monitor and frame export | 3 |
| Existing `export project render` | Project render family | Ordinary export | 4 |
| `angles use` | `angles_use` | Use Feeds as Multicam Angles | 5 |
| `box add` | `box_add` | Draw box | 6 |
| `box set` | `box_set` | Correct box | 6 |
| `tile split` | `tile_split` | Split tile at source time | 6 |
| `tile screen-share` | `tile_screen_share` | Mark as screen share | 6 |
| `tiletrail scan` | — | Standalone producer, import via Accept | 2 |
| `tiletrail inspect` | — | Standalone scan inspection | 2 |

The standalone TileTrail program owns decoding at its boundary and records the producing stream, content identity, presentation origin, display transform, sampling configuration, detector revision and observed coverage. An import checks these against the opened media. Legacy MPCut wrappers can continue to be used through their existing identity checks.

## Project data and edits

Extend the native project in two versioned steps. Use strict key validation and keep existing IDs; a new binary opens earlier schemas, and an older binary reports an unsupported format for documents that require the new schema. Save atomically under the native document limit of 64 MiB. Store rational half-open ranges throughout. Canonicalize adjacent equal spans, use ordered change points for geometry, and keep per-frame detector observations and review images outside the document. The project contains the compact accepted result and sufficient evidence references to report review issues without reading a sidecar.

| Stored data | Keys and behavior |
| --- | --- |
| Project-wide feeds | Stable opaque `feed_id`, name, kind, existing mic and transcript identifiers, treatment. Allocate new opaque IDs once and persist them. If short ID prefixes are supported, require an unambiguous prefix and report the full ID. Display names never serve as identity. |
| Tiles and coverage | Per recording, stable `tile_id`, optional feed ID, ordered source-time bounds, display-space normalized rectangles, optional label bounds, role, state and slot. Retain current and historical associations with treated feed identities. Coverage spans distinguish observed, inferred and unknown; issue and confirmation state determine whether observed material is checked. |
| Scan and review | Per recording, producer and media identity, expected-feed count and maximum visible tiles, accepted layout events, pending scan reference, timestamped or recording-wide issues and scoped resolutions. Pending data survives relaunch, is identity-bound and is separate from accepted geometry. Persist artifact fingerprints with relative references where portable; missing pending artifacts keep accepted data usable and show a rescan action. |
| Preferences and grid corrections | Feed/source/range to tile preference, with existing deterministic ranking as fallback. Source/range to corrected grid and slot geometry. Map old to new tracks only when correspondence is unambiguous; retain a review issue otherwise. |
| Privacy confirmations | Feed, source, range, media identity, scan identity and geometry/assignment revision. Confirmation of a range does not assert a treatment can be drawn without a known rectangle. |
| Sequence layouts | Clip ID and source-time range. Layout value carries variant, ordered feed/camera references, framing/anchor and background. Original removes the layout for that range. Treatment remains active on Original. |
| Multicam layouts | Group-clock spans are defaults. Overrides are stored by stable assembly occurrence ID and group-clock range. An override choosing Original must suppress an inherited group layout. |
| Feed angles | Stable angle ID, parent picture source ID and feed ID, inheriting parent sync, display transform and source revision. A feed-specific microphone may be mapped through the existing audio lanes. |
| Output format | One shared canvas and color configuration, with explicit frame rate, dimensions and background. Preserve legacy audio routing and unresolved-privacy policy as project export settings where a legacy composition supplied them. |

Editing a sequence layout replaces only its addressed range, splitting the old spans at the edges and coalescing equal neighbors. Moving and reordering preserve clip identity. Split at the corresponding source timestamp, with the right side given a new clip ID; duplicate gives the copy its own ID and copies the applicable spans. Trimming constrains rendering to the new clip bounds and preserves latent edits when the trim is extended again. Deletion removes the clip's spans from the active document, with undo restoring them. A new clip using the same recording inherits feed treatments and tile geometry; it gets its own layout. Replacing a clip with another recording clears the old clip layout after reporting the change and keeps the old source's privacy history through undo. Relinking media for the same recording preserves shapes and layouts for review, and invalidates certification until the media identity is rechecked.

Multicam occurrence IDs follow edits to assembly order. Split and duplicate use the same partition and copy rules in group time. The renderer resolves occurrence override, then group default, then Original. If a preset is invalid for the participating source at a given time, retain the edit with a diagnostic and use the layout background. It cannot substitute untreated source. A source-time tile correction affects every occurrence of the corrected footage.

Arranged maps feeds to stable positions within a layout epoch. A position can be assigned once, intentionally left blank, or retain its native tile. A mapping consumes the moved feed's native appearances for the resolved arrangement so a swap does not create accidental duplicates. The preferred visible tile supplies the crop. Swaps update both positions atomically; duplicate destinations are rejected. An absent feed displays the cell background. A command spanning a layout epoch change splits the layout and checks each epoch before saving. If a destination has no unique tile in any epoch, the edit reports the destination, source and time and leaves the project unchanged. If later geometry edits make a saved destination unavailable, the renderer reports the missing destination before clearing the moved feed. Uncovered pixels must come from the gated source or the chosen background.

A feed angle shows its preferred visible crop, or the configured gap color while offscreen; an unverified crop follows the privacy policy. Report picture coverage as visible and addressable only when the underlying recording and crop both have coverage. Keep the selected switch and report the gap. Audio follow may keep a bound microphone active independently of picture visibility. An interchange that cannot reference feed angles requires a rendered delivery and reports which angles need one. Initial conversion can convert a standalone selected recording or add feed angles to an existing multicam group. Conversion of a clip embedded in a wider sequence waits for a transaction that preserves the other clips, their time and audio; it must not discard them.

Merge retains the explicitly selected survivor ID and the stricter treatment, including historical scope. Split gives the new branch a fresh ID and copies the existing treatment and relevant history. Both operations include preferred tiles, layouts and angles in the reference check, report binding conflicts, and invalidate affected confirmations. A link over part of a tile creates range-local pieces with persisted identity; retained pieces must not alias each other. Review history and undo restore the whole transaction.

### Migration and legacy compatibility

Take a snapshot of the old document before projecting legacy timing into the new model. Use the legacy renderer's actual precedence and clocks, including assembly index, offset, switch boundaries and clip boundaries. Apply the old default where it participated. Intersect each resolved output-time shot with old clip occurrences and translate each intersection to clip source time, preserving resolved framing and audio. For multicam, store group defaults directly and translate winning legacy output or occurrence shots into overrides on the assigned occurrence IDs. Legacy shot precedence is occurrence-specific output, global output, group, then default. A repeated source span gets distinct overrides when its legacy pictures differed. Explicit Original in an override must remain distinguishable from inheritance. Preserve old black windows or unavailable slot behavior via migration compatibility state. Reject an inconsistent source document with a diagnostic that identifies the unresolved offset or shot.

Carry existing appearances, feed IDs, source identity stamps, ranges, coverage and preferences forward unchanged when representable. Promote legacy screen-share appearances to synthetic stable feed IDs and retain enough origin information to re-express untouched legacy presentation slots. Keep separate legacy screen shares separate until an editor links them. Move legacy redactions to feeds, retain strictly fail-closed gating for migrated content that relied on the broad legacy rule, and preserve legacy stop/cover, canvas and soundtrack behavior. A migrated composition should reproduce old frames on old supported inputs. Sequence layouts on unrelated clips that were inherited from the legacy default need an explicit migration record of the resolved legacy behavior; new edits never propagate the default onto new clips. If legacy canvas and still settings conflict, report the existing conflict.

A legacy command reads or edits through a projection with the old JSON contract. Test representability before mutating. A newly authored per-clip layout that cannot reconstruct the same old shots, a grid beyond four slots, a native feed angle or a newly linked screen-share feed cannot round-trip through the old contract. Return an explicit unsupported-edit diagnostic and retain the input bytes. Keep old output field names, file semantics and exit codes for legacy entry points. Fixture tests should compare decoded frames and audio for old default and timed compositions, split points, multiple unrelated clips, repeated assembly positions, and the legacy gates before and after migration.

## Privacy and publication

The existing Stage 1 compatibility path uses the legacy whole-frame stop/cover gate and legacy render settings. The target renderer applies the following policy from Stage 3.

1. Resolve participating source layers, including overlap and border pixels. Scope protections to any recording known to have shown a treated feed, including historical links, any scanned recording whose unassigned tiles could contain it, and any replacement of an in-scope recording until reconciliation. The source of a historical link stays in scope when the tile is reassigned. A completely unscanned, unrelated recording passes, with a diagnostic about the scope of the protection. A treatment follows the same feed across recordings.
2. Revalidate recording identity before producing pixels. A replaced recording produces a stop/cover result until accepted reconciliation and review. Even a strong current fingerprint says nothing about the validity of geometry produced for earlier bytes.
3. Resolve per-frame observation and review state. Frame-by-frame observation can clear inferred coverage only where linked identities survive verification and open issues have been resolved. A confirmation is an explicit scoped human override of review uncertainty for the identified feed and range. Confirming the whole recording can resolve a pending feed with no appearances when the accepted media still matches, coverage is fully verified and every box has a known identity. A rescan, replacement, merge, split, box correction, relink, treatment change or affected review change invalidates the relevant confirmations before publication.
4. Apply treatment on the source before crop, scaling or compositing, across every simultaneous tile of the feed. On checked footage, a crop that excludes treated and unassigned pixels passes. A crop that overlaps the treated tile passes only after sufficient treatment has been rendered; include known label bounds if the data supplies them. If the affected position cannot be established, conceal the entire affected layer or stop. A whole-picture view applies the same decision with the full source bounds.
5. Share this decision across Output monitor, thumbnails, single frames, JPEGs, ordinary, queued, selection, ISO and interchange exports, and stream-copy eligibility. A path unable to render required treatment refuses. Output playback may repeat/drop a frame or cover while waiting. Cache keys include source identity, effective layout, reviewed coverage and treatment state; invalidate persisted and live thumbnails for the affected inputs. Explicit Source review can show untreated video and is labelled at the API boundary. It is never a delivery artifact.

Keep publication policy distinct from picture treatment. Explicit exclusions, covered and removed feeds are withheld; a covered or removed ID selected explicitly is a validation error. Blurred feeds can be selected and their movies receive the treatment. Withheld feeds do not publish names, microphones, or voice bindings in filenames, manifest or delivered project. The shared mix may still carry a withheld voice and requires a report that identifies this property without naming the person. Leaving the mix out is available. Captions and transcripts can likewise carry withheld speech and require the scope warning. Review projects and source frames may contain private identifiers and should be kept in private job storage, separate from the manifest-listed delivery.

## Review results and exit status

Review preflight runs before any new movie is published. Ordinary adaptive inference and normal offscreen time are informational when privacy is not implicated. Unassigned tiles, unresolved identity matches, invalid geometry, incompatible replacement and exceeded supplied count hints are decisions to review. A lower-than-expected distinct feed count is a recording-wide issue; an over-limit simultaneous tile count identifies the affected spans. Stale source identity always needs reconciliation before rendering. When privacy requires checking, unknown or inferred frames and unresolved picture links follow the applicable stop/cover rule.

| Issue | Range | Resolution |
| --- | --- | --- |
| Feed count differs | Recording-wide | Merge, split or correct assignments; if the count is accepted, update or explicitly acknowledge the hint against the current scan |
| Visible boxes exceed supplied maximum | Source-time ranges | Correct the grid/boxes and re-evaluate; or explicitly revise the hint |
| Unassigned tile or ambiguous return | Tile/return range, with evidence times when available | Link, merge or split, choosing the corrected range. Unresolved can stay on the review project. |
| Invalid or stale source/scan relationship | Recording-wide, with affected ranges where known | Reconcile and review or replace the scan |
| Inferred coverage needed for a protected image | Affected source-time ranges | Verify against current media and assignments or record a scoped confirmation where geometry is established |

`--on-uncertain blank` covers reported uncertain intervals and may complete with warnings. It may override uncertainty with a conservative blank, but cannot legitimize an incompatible file, invalid output identity or selection of an explicitly withheld feed. Stage 1 covers the full affected output frame when the legacy gate calls for cover. A whole-recording count discrepancy with no localizable cause cannot be presented as a precise interval; an operator can clear it only by revising or accepting the hint or by repairing the scan.

Exit codes are 0 for completion, 1 for runtime failure, 2 for command usage, **3 for `needs_review`**, and 130 for interruption. The final result is one versioned JSON object with a status, source identity, review-project path if available, grouped issues, warnings, and a suggested next command. An issue carries a stable kind, source ID, an optional half-open source range, affected tile/feed IDs and resolution options. A recording-wide issue has no synthetic timestamp. Progress JSONL belongs on stderr. MCP must preserve the typed review result and artifacts when polling a job that exits 3. For ordinary failures, retain the existing failure channel.

## Resumable delivery

Bind a versioned delivery workspace to the source, selected video stream and logical job. The initial raw run may create a private review project with accepted tiles and stable IDs. In `needs_review`, publish no new movies and return the saved project path. Resume from that project after making edits. A repeat of the raw command can discover the bound review asset only when the full recorded input identity matches; it must never silently rescan into the same workspace. It is acceptable for the first implementation to require the explicit saved-project path.

Use a destination lock and private staging/checkpoint storage alongside or beneath the destination. Refuse unrelated directories, symlinks that escape the workspace, unknown schemas and filename collisions. Filenames include a sanitized name when publication allows it and a stable ID. Store the reviewed document and progress separately from public artifacts. Keep source review images and private name-bearing records outside the publication set. A newly encoded movie remains hidden until its writer closes, it is probed, and its verified checkpoint is written atomically. Interrupted individual movies are retried from their start; completed and verified artifacts can be reused. Report an interruption as 130.

An executable plan captures the source identity, the project revision it was built against, selected range/feeds, sizes, framing, crop preference, gap/camera-off handling, treatments, cover policy and audio routing. Executing a stale plan reports a mismatch. A new plan in the same logical workspace can reuse unaffected checkpoints. Fingerprint each output's canonical effective dependencies, including source content and display transform, relevant tiles and preferences, resolved treatments and checked coverage over the crop, canvas/codec/render revision, and bound audio content/offset/gain. If dependency precision is unavailable, invalidate affected outputs conservatively. A name-only edit can reuse media when the content/audio keys match, while refreshing filenames and project metadata. A change in another feed's assignment invalidates any crop whose redaction or uncertainty changes, including crops that overlap an inset. Media replacement invalidates old media checkpoints even when filenames match.

Public `manifest.json` is the completion record. Include schema version, delivery timebase/settings, source/plan digest, published artifact records, feed IDs, treatment-derived withholding status, reported blank ranges, expected track metadata and verified content checksums. A delivery becomes complete only after all selected artifacts and the aligned `multicam.cut` pass verification. Write the completion manifest last. Any interrupted publication or invalidated older delivery must be treated as stale or partial by verification; never certify a mix of generations. Reject unmanaged entries that would be overwritten. Verify checks paths, checksums, start, duration, dimensions, frame rate, and audio track layout against the manifest; it also checks that the project references only verified published media. Shared mix is delivered once, preserves sync, and is omitted when not requested or unavailable. An ISO microphone can continue through its feed's offscreen time.

## Acceptance thresholds

Score display-oriented tiles at fixture presentation timestamps, separately for adaptive and every-frame sampling. Use one-to-one rectangle matching at IoU ≥ 0.75. Count unmatched truth as misses and unmatched output as false tiles. Compare identities with an optimal one-to-one pairing of stable predicted and true IDs over the recording, so fragmenting one identity or swapping two can still score as failure. Score a reported unresolved match as unresolved and verify an issue covers its first affected time. Track transition windows separately but include them in overall rates.

| Check | Threshold |
| --- | --- |
| 25-tile, 40-feed gallery | Missed tile instances ≤ 1%, false tile instances ≤ 1%, wrongly assigned matched instances ≤ 0.5% in each sampling mode. Exactly 40 reviewed identities. No unreported unresolved move, departure, return or swap in the fixture. |
| Detector limit | At the declared box limit, retain every genuine cell in a fixed grid. A requested grid over the supported limit returns a clear error. Automatic overflow must report uncertainty where detectable. A conflicting supplied maximum produces dated diagnostics. |
| Private delivery | Zero untreated protected sentinel pixels in covered/blurred delivery paths under fixture expectations. Exercise overlap, repeated recording, independent recording, stale source, interrupted delivery and shared-mix disclosure. Explicit Source review is tested independently. |
| 1080p and 4K prototype | Report hardware, format, frame rate, p50/p95 frame latency and drop rate with dense blur plus crop. Stage 3 real-time target is p95 within 33.3 ms at 30 fps, measured separately at each resolution. If this is missed, the monitor drops/repeats or covers frames and records measurements. Trace HDR metadata, transfer function and pixel format from decode to output and compare with untreated export behavior. |
| Long review document | Two-hour, 40-feed fixture saves below 64 MiB, reopens with identical references, supports an edit and undo, and reopens after that round trip. Report serialized size and elapsed times. |
| Stage 4 decode and memory | Feed crops share a source decode in the common path. Record process peak memory and limit in-flight frames to a fixed budget (target ≤ 512 MiB of frame buffers). Report encoder overhead separately. If concurrent encoders exceed resources, reduce the batch and report extra decode passes. |

The thresholds specify acceptance targets. A prototype benchmark, fixture measurement or parity test result belongs with its measured command and environment.

## Fixture evidence

On the decoded 5 × 5 gallery, MPCut's adaptive and every-frame scans each recovered all 3,600 tile instances and all 40 feeds. Both modes reported the ambiguous return in the separate test at its first affected timestamp. The 8 × 8 fixed grid retained all 64 boxes. Automatic detection marked the over-capacity 72-cell fixture unknown, and its dated issue survived project save and reopen. The lossy control produced 73 unresolved instances and 38 linked feeds. [Gallery fixture and results](../Tests/Integration/tiles-gallery.md)

The [picture and project benchmark report](../Tests/Benchmarks/feeds-stage-0.md) records the benchmark methods and validation scope. Its [runner](../Tests/Benchmarks/feeds_stage0.sh) launches the tests on Backstage. The isolated optimized compositor was timed on an Apple M4 Max at 1080p and 4K with 40 tile blurs and 40 nameplate blurs plus a crop. Across SDR, PQ and HLG, the muted Backstage run measured p95 at 18.11–19.15 ms at 1080p and 33.10–41.58 ms at 4K. The Core Image baseline exceeded 33.3 ms in some 4K cases. After adding the dense Metal path and caching its immutable region data, the standalone pixel-checked benchmark measured p95 at 2.72–2.89 ms at 1080p and 7.83–7.95 ms at 4K. The test times the frame operation up through GPU readback. The report also records a more heavily loaded run. The HDR buffer checks preserved the transfer, BT.2020 primaries and above-white reference pixels. A muted Backstage debug run with the older compact writer round-tripped 96,000 spans over two hours and restored the edit with undo. The largest file in that run was 1,850,981 bytes. Save took 9.45 s and reopen took 12.31 s. The integrated editable JSON writer passed the same capacity check with a saved Solo layout, including persisted undo and redo. Its largest document was 53,629,639 bytes. The four [Tiles integration cases](../Tests/Integration/tiles_e2e.py) passed on a signed standalone CLI with an FFmpeg helper. They cover raw review, manifest tamper detection and resume, arranged layout over a gallery change, and virtual feed angles with transcript proposals. The [privacy fixture](../Tests/Integration/participant_privacy.py) checks rendered pixels and output timing, including rotated variable-frame-rate footage.
