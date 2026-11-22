# MPCut editing wish list

Compared with the current Swift working tree, CLI, and MCP handlers on November 21, 2026. This includes work in progress in the checkout. The numbers retain their original meanings so existing discussions still refer to the same features.

## What to ship first

| Order | Change | Done when |
|---|---|---|
| 1 | **Expose the live sequence’s export tier to MCP (#5).** The GUI already shows it, saved-project CLI inspection reports it, and the editor already builds a structured `tierReport`. The live `get_editor_state` sequence response does not attach it. | For an unsaved ordinary sequence, an agent can read the same tier, factors, and freshness flag the editor knows, including while a check is pending. No extra export job is needed. [Tier report](../Sources/MPCutApp/TimelineTierGate.swift) · [Live response](../Sources/MPCutApp/MCPLocalControl.swift) |
| 2 | **Inspect the contents of a queued sequence excerpt (#15).** Each entry already holds an ordered snapshot of clip requests. The GUI row shows the first filename and MCP returns the queue ID and outer bounds. | Queue a range spanning two clips, reorder the timeline, then inspect the entry. The GUI and MCP both show the two original source files and trims in captured order. For long entries, fetch details on demand. [Snapshot](../Sources/MPCutApp/EditorModel.swift) · [Queue UI](../Sources/MPCutApp/BulkQueueView.swift) · [Queue response](../Sources/MPCutApp/MCPOutputs.swift) |
| 3 | **Explain the nearest cut in the existing tier prompt (#5).** When a hand edit lowers the tier, MPCut can already offer a verified alternative. The prompt explains the tradeoff but gives limited detail about how far the edit will move. | For a split, show requested and proposed positions and the signed movement. For a trim, say how much material the alternative keeps or removes. Use indexed frames when meaningful and exact time for audio. Preserve whole-edit preflight. [Prompt](../Sources/MPCutApp/TimelineTierGate.swift) · [Nearest-split fixture](../Tests/MPCutAppTests/TierPromptNearestDisplayTests.swift) |

The primary transcription integration is **Transcriberrr JSON (#1–2)**. The complementary editing capability is **applying a multi-source range list to an open sequence (#8)**. It connects two existing workflows and would save more work than another presentation change. It needs transaction, revision, and undo handling, so budget it separately from the three changes above.

## Transcriberrr round trip (#1–2)

The [full transcription implementation plan](TRANSCRIPTION-PLAN.md) covers the Transcriberrr contract, word-based editing, and GUI, CLI, and MCP parity.

**Transcribe Multicam** sends every audio-bearing camera and external recorder stream to Transcriberrr as one session. When the job finishes, MPCut attaches the result automatically. The editor can search a speaker’s words, see which tracks captured them, and seek to the corresponding moment on any synchronized angle. The session includes audio from angles that never went on air. Transcribing a source once also covers every replay.

Transcriberrr’s native JSON is the primary format. Its current word records carry text, start, end, and optional speaker ID. Merged JSON can include speaker names and a list of source tracks, speakers, and offsets. Its current speaker-track merge assumes one speaker per isolated track. A camera mic can hear several speakers, and several cameras can hear the same utterance. Support SRT and WebVTT secondarily and retain their supplied cue-level timing when finer timing is unavailable.

| Step | Proposed behavior |
|---|---|
| Send | MPCut supplies a versioned session manifest with a job ID, stable source and stream IDs, original source identity, and the timing relationship between submitted audio, source media, and the multicam group. This also covers a delayed audio stream inside a camera file. Identify known isolated speaker mics and shared camera or room mics where possible. |
| Merge | Transcriberrr accepts explicit track identities and offsets. Use isolated tracks for known speakers and diarization where a recording contains multiple voices. Return a session-wide speaker ID and source-local timing for each word observation. Multiple recordings of the same utterance should point to one searchable result, while genuinely overlapping speakers retain their own words. Preserve uncertain associations for review. |
| Attach | Match returned IDs to the submitted sources and streams. Keep word timings anchored to source media so changing a camera offset or reordering the assembly updates the projection without another transcription job. Reopening the project or receiving the same completion twice should preserve a single attached result. Flag replaced or unmatched media. |
| Use | GUI, CLI, and MCP should support searching by phrase, speaker, or track. Report the word’s source evidence, its group time, camera angles covering that time, and each retained assembly occurrence. For dialogue in cut order, follow the actual program audio routing. An editor can optionally associate a speaker with a preferred camera angle. |

**Acceptance case.** Two cameras hear the same interview, Camera B starts late, and an external lav records the host. Send all three streams. Searching a host phrase should yield one utterance with its contributing tracks. Seeking to Camera B should land on its corresponding source frame when available. A guest speaking over the host should remain a distinct result. Repeating the passage in the assembly should produce two output locations for the same source words.

## Comparison by workflow

### Finding dialogue and takes

| # | Wishlist item | What works today | Remaining work |
|---|---|---|---|
| 1 | Import and search timed dialogue | Waveforms, silence reports, hard cuts, and recurring views help locate material. CSV and JSON accept known time ranges. | **New capability.** Make Transcriberrr JSON the native round trip described above. Also import existing JSON directly and accept standard subtitle cues as secondary inputs. |
| 2 | Read dialogue in cut order | Ordinary sequence state already returns each occurrence’s source and sequence bounds. | **Depends on #1.** Project the imported words onto those occurrences, preserving repeats and identifying partially retained words. Multicam needs the routed audio source and its offset. |
| 3 | Keep named selects | In/Out marks, ordered range lists, and export queue snapshots cover temporary selections and delivery. Scene labels name recurring views. | **New project data.** Keep a named source interval across save/reopen, including after all uses of it have been removed from the cut. A queue display label alone cannot do that. |
| 4 | Find takes separated by pauses | Minimum pause, retained padding, pause protection, join review, and Queue Takes already exist. Protecting a detected pause can keep two passages together before queueing. CLI silence JSON already supplies retained clips. | **Mostly covered.** The specific gap is correcting a missed take boundary directly in the candidate list before queueing. Existing manual marks or editing the CLI range list cover occasional corrections. |

[Silence and queue implementation](../Sources/MPCutApp/EditorModel.swift) · [Review controls](../Sources/MPCutApp/PauseControls.swift) · [CLI silence workflow](../Sources/MPCutCLI/CommandHelp.swift) · [Project format](CUT-FORMAT.md)

### Cutting and pacing

| # | Wishlist item | What works today | Remaining work |
|---|---|---|---|
| 5 | Choose copy-safe cuts | Ordinary sequences have keyframe snapping, a live tier badge, a configurable warning on a manual tier downgrade, and a nearest verified choice when eligible. Export Review shows original/proposed times and total duration change. MCP export preflight can return proposed ranges. | **Two small gaps.** Surface the existing live tier report to agents and quantify the movement at the hand-edit prompt. See the first and third priorities above. |
| 6 | Set one pause’s retained duration | Global padding, per-pause protection, preview, and batch shortening work. Ordinary protection tracks source spans by occurrence and track. Multicam protection can affect repeated uses of a group pause. | **Behavior change.** Support a numeric override for an individual pause. Define which occurrence it applies to and how it survives threshold changes that split or combine detections. |
| 7 | Review and nudge a hard cut | Editors can play across a join, scrub audio, inspect waveforms, frame-step, and trim. MCP can preview a trim, request waveform data, and control playback. The dedicated Preview Cut window is driven by a detected pause. | **Modest GUI improvement.** Open a short, repeatable preview around any existing join with one action. Reviewing two proposed source ranges before placing them is a separate extension. |
| 8 | Apply an ordered range plan | CLI export accepts multi-file ordered lists and repeats. Opening a prepared sequence file gives an editable assembly. GUI and MCP can apply ordered CSV ranges to one selected clip occurrence in one undoable edit. CSV times are relative to the trimmed clip. | **Real live-edit gap.** Insert a multi-source list or replace a selection in the current unsaved sequence, using explicitly source-relative bounds. Validate the whole plan and revision before committing one undo step. |

[Edit-time tier controls](../Sources/MPCutApp/TimelineTierGate.swift) · [Export review](../Sources/MPCutApp/ExportSheet.swift) · [Live edit commands](../Sources/MPCutApp/MCPSequence.swift) · [CSV and ordered-list conventions](USAGE.md#apply-csv-cut-points-to-a-clip)

### Multicam

| # | Wishlist item | What works today | Remaining work |
|---|---|---|---|
| 9 | Suggest sync offsets | Sources have exact manual offsets and nudges. Interchange code already reads camera timecode and audio time-reference metadata. | **Two distinct scopes.** Suggest offsets when recordings contain comparable timestamps. Distinguish missing metadata from a genuine zero start. Waveform matching and checking for drift later in the recording require new analysis. |
| 10 | Put several files on one angle | Multiple camera sources can be offset on the group clock. A source identifies one file, so camera restarts can be represented as additional sources and switches. | **Model change.** Keep one angle across multiple files, preserving real gaps and file identity through preview, editing, export, and interchange. Useful for long recordings. |
| 11 | See camera and mic coverage | The timeline already draws picture gaps and missing audio. Multicam frame reports expose availability at requested times. Export preflight and switch suggestions already provide alternatives for eligible failures. | **Mostly covered.** A narrower addition would check a *proposed* switch and routed mic through the next switch before committing it. No new coverage display is needed for the basic workflow. |
| 12 | Change the angle on one replay | Assembly occurrences already trim and reorder independently. Switches live on the group, so reusing its interval also reuses its switches. | **Model change.** Represent an occurrence-local override and carry it through saving, playback, export, and interchange while preserving the group default. |

[Multicam timeline](../Sources/MPCutApp/MulticamTimeline.swift) · [Source and switch operations](../Sources/MPCutApp/MulticamMCP.swift) · [Group and assembly model](../Sources/MPCutCore/MulticamProject.swift) · [Timecode reader](../Sources/MediaProbe/source_timecode.c)

### Revisions and delivery

| # | Wishlist item | What works today | Remaining work |
|---|---|---|---|
| 13 | Map source and output ranges | Live sequence state already lists document and occurrence IDs, source bounds, and output bounds per clip. Multicam exposes group and assembly bounds and supports occurrence-specific seeks. Agents can compute overlaps from this data today. | **Convenience query.** Return matching pieces in either direction, including partial and repeated uses. For notes against an older cut, read the saved review version first. |
| 14 | Explain changes since a revision | MCP enforces expected revisions. History exposes actions, cursor, token, and revision. An agent retaining the previous state can compare it with current state. | **New comparison operation.** Report affected occurrences and ranges. Decide how to handle undo, truncated history, or an unavailable prior revision before promising an arbitrary revision lookup. |
| 15 | Name, inspect, and revise queue entries | Sequence entries freeze clip requests. Multicam entries retain the project, group interval, media, and project-derived name. Both queues already support removal and preflight. | **Start with sequence snapshot inspection.** Per-entry names are a small follow-up. Replacing or extending an old snapshot needs explicit behavior when the live timeline has since changed. |
| 16 | Export a cut map | CLI JSON already gives source/output segments, track actions, and copy/encode information. Live MCP render returns its resolved plan. Adjacent timeline occurrences can coalesce into one export segment. | **Two different deliverables.** Saving the existing result beside a GUI export is a convenience. For editorial provenance, also retain original occurrence IDs and boundaries, including those inside coalesced segments. A saved copy of the export plan alone loses that distinction. |

[Live clocks and occurrence IDs](../Sources/MPCutApp/MCPLocalControl.swift) · [History response](../Sources/MPCutApp/MCPSequence.swift) · [Live render results](../Sources/MPCutApp/MCPOutputs.swift) · [CLI export JSON](../Sources/MPCutCLI/main.swift) · [Range coalescing](../Sources/MPCutCore/CutEngine.swift)

## Fixture checks

- Scanning the bundled quiet-pause movie with a 0.3-second minimum and 0.1-second retained pause returned one pause, one removal, and two retained clips. This exercises the existing take-candidate workflow.
- A temporary ProRes sequence with three three-frame occurrences, including a reused passage, exported nine copied frames and zero encoded frames. The second and third occurrences were contiguous in source time, so the CLI reported two resolved export segments. This is why an occurrence-level cut map needs timeline information as well as the render result.
