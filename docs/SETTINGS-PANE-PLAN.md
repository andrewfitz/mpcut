# MPCut Settings redesign

## Status

Implemented. The eight-page window, the 76 keys that `preferences_read` lists and the features below are in the app. “What exists today” describes the window this plan replaced. The user guide describes the result. [Settings in the user guide](USAGE.md#set-editing-and-export-defaults)

Where the build differs from this plan:

- **Dialogue switches minimum hold** accepts 0.04–60 seconds, not 0–60.
- **Limit the shared cache folder** is entered in gigabytes of 10⁹ bytes, to three decimals, with a stepper that steps 1 GB and a field range of 0–1,000,000 GB, and stored in bytes. It and **Remove untitled drafts after** take only their saved value, never a launch argument, because both remove files. The app also enforces the limit when it changes, waits while a window is opening or importing, and checks what open projects protect before each removal. It enforces it after the sequence or multicam editor saves a cutcache, not after core’s automatic cutcache writes during indexing. It removes the least recently modified cutcaches first.
- **Save Export Result JSON** seeds only the sequence export sheet and the multicam save panel. The queue, JPEG, Resolve and interchange panels have no such checkbox.
- **Helper location** looks up `MPCUT_TRANSCRIBERRR_HELPER` first, then the chosen helper, then the installed Transcriberrr app. The CLI and file jobs skip the chosen helper.
- **Completion actions** also run for Export Current Frame and the Tiles program, and only for exports the editor starts. Exports an agent starts, replacement-audio working copies and transcript and caption files do not run them.
- **Starting folder.** Transcript, caption and excerpt panels keep a session folder separate from the editor’s export folder. Multicam excerpts fall back to Automatic in Source folder mode. A chosen folder that is `/` or not an absolute path counts as Automatic. The multicam Resolve and interchange panels follow the setting when it is not Automatic and remember a folder chosen in them for the session.
- **Automatic scans.** Both editors scan only the recordings just added, never one whose scan was cancelled and never one already in the project. Turning a switch off drops automatic scans that have not started. In multicam, the pause scan reads only the routed sound of the added recordings, and stopping a scan drops the recordings waiting for it.
- **Decision 8.** An omitted codec takes the Settings codec only where the destination can hold it, and otherwise H.264 with its quality. This includes Tiles renders, Tiles queue ranges and still projects without their own format. The queue uses the Settings container only for an H.264 or HEVC re-encode of ordinary ranges, only when it is not Automatic and only when it can carry the requested audio. An omitted `audio_output` takes the Settings multicam layout, but a downmix falls back to separate tracks where it cannot be rendered.
- **Reset All Warnings** returns the Finder action to Ask only when an alert’s “Don’t ask again” chose it. An action chosen in Settings stays, also after an alert chose one; choosing an action in Settings, or turning a warning switch back on, forgets the alert’s choice.
- **Restore Defaults** lists what will change, with a paragraph for each time the changes take effect and each row title quoted, and names the rows it keeps by their titles. It says a value returns at the next launch only for a value MPCut was opened with on the command line. A value the page does not show (the remembered chosen folder outside Chosen folder mode, a Find Tiles layout a build without TileTrail shows as Even Grid) never enables the button alone. The restore runs after the dialog has closed. Automation has nothing to restore, so that page has no Restore Defaults button.
- **Agent permissions.** `preferences_set` does not list the read-only keys, so its schema rejects them. The two stills timeline pixel keys declare `multipleOf: 2`. `file_replace_disabled` also covers the six transcript file tools that carry `in_place` inside `request`. `workspace_panel_show` uses `page` only for `show_settings`. With **Let agents change settings** off, `set_transcript_suggested_camera` stays allowed, and the snap action of `timeline_selection_set` is refused as well.
- **Find Tiles** seeds the grid and scan detail once, when a window’s Tiles inspector is created. Selecting an unscanned recording resets only the layout.
- **New stills timeline** frame rates 23.976, 29.97, 59.94 and 119.88 mean the exact NTSC rates (24000/1001 and so on), in Settings and in the Still Timeline Format panel.
- **Numeric fields** commit on Return, Tab, a click elsewhere in the window, a page change and window close. Esc puts the stored value back. A click on Restore Defaults… commits nothing: Restore drops a number typed on its page and not yet committed, so the factory value wins, and Cancel leaves it typed. Each tooltip states the range with grouped digits, and an entry that is limited, rounded or not a number shows a notice beside the field, or under it where there is no room, instead of an alert. Typed numbers read the same in every locale: “.” and “,” are both decimal marks, and a grouping separator counts only between groups of three digits. **Filler terms** commits the same way and keeps at most the 4,096 characters agents may store.
- **Storage usage** shows each store’s path, marks a folder that does not exist yet, and counts everything in each folder. Clear of transcript recognition results keeps results a saved transcription job can still reuse, and keeps the whole archive while a recent job record cannot be read. Its report says when nothing was removed and counts files MPCut does not recognize, which it leaves.
- **Defect 3** is fixed with an Automatic or English picker for the transcription language.
- `ParticipantDialogueOptions.Overlap.visibleSpeaker` stores and reports `visible_speaker`.
- **Time display.** Frames applies to the playhead and duration, the In, Out and Duration read-outs in both editors, the multicam inspector’s In and Out read-outs, and ruler labels under a one-second step. Labels a second or more apart stay `MM:SS`. The sequence editor counts at the stills timeline format or the first video’s constant rate. Multicam counts frames only when every picture angle shares one constant rate. Every other time, and everything written to files or returned to agents, stays in milliseconds. In Frames mode the playhead field reads three or four whole-number fields as `[H:]MM:SS:FF`, so an hours entry needs `H:MM:SS.0`, plain seconds or `H:MM:SS:FF`.

Unfinished or unverified:

- Testers walked the window four times on the current system. They confirmed the pages, factory values, persistence, search (also fast typing and a value set through accessibility), the scope and wording of Restore Defaults, live updates to an open editor, resizing down to 640 × 420 of content with nothing clipped, committing a number by a click elsewhere, range notices, the Storage paths and Clear reports, and one accessibility label per numeric field.
- The five controls that exposed their title both as a description and as a title element (Preferred engine, the container picker, Save new cutcaches, Save and reuse analysis, Enable local MCP control) now keep one label, checked by an in-process accessibility walk. Nobody has listened with VoiceOver.
- Each path, size and row button has its own accessibility identifier (`.path`, `.size`, `.show`, `.clear`, `.copy`), checked by the same walk on every page.
- Not checked on screen: macOS 14, notifications and their permission prompt, a second display, Clear on real cache entries, choosing a cache disk and the Shared cache folder row, the gap color panel, the visible effect of Force SDR, the launch recovery offer, and real exports and transcriptions with the new defaults.
- The `mcp/` Go code and the `press_menu.swift` accessibility helper were changed without a Go toolchain or a GUI run.
- Reopening projects at launch remains deferred. What macOS restores for these windows has not been checked.

Make ⌘, answer three questions. “Where do I change how MPCut behaves?” “How do I start the next edit, transcription or export with my usual choices?” “What is MPCut keeping on my disk, and who else can drive it?”

This revision replaces the six-page plan of 23 November. It keeps that plan’s window, its five scattered keys and its rule for what stays close to the work. It adds a full inventory of the app, two new pages (**Transcripts** and **Storage**), a reorganized **General** page, 27 rows of defaults, 16 new features, a frozen key schedule and a list of defects. It drops the transcription language default, because the engine accepts English only.

## What exists today

The Settings scene is a two-tab `TabView` fixed at 480 × 495 points. **General** stacks Automation, Media, Timeline, History, Playback and Export defaults. **Analysis** holds cutcache storage and Silence. All 16 keys in `EditorPreferences.Key` have a control. The pane was `Sources/MPCutApp/EditorSettings.swift`, since removed. [Preferences](../Sources/MPCutApp/EditorPreferences.swift)

Everything else an editor chooses repeatedly falls into one of four places.

| Where the choice lives | Examples | Count |
| --- | --- | --- |
| Saved in UserDefaults, outside `EditorPreferences` | Force SDR for viewer and monitor, clean feed, panel position, multicam track label width, recent files, last relink folder, suggested transcript cameras | 8 |
| Kept on the window until it closes | Re-encode codec and quality, export folder, playback speed, cut sections, Follow Playback | about 15 |
| Reset every time a sheet opens | Transcription engine and options, filler terms, Save Export Result JSON, ISO export options, dialogue hold | about 25 |
| A literal in the code | Still and gap duration, caption line length, pre-roll, recent-file count, cache limits | many |

Six on-disk stores have no interface beyond cutcaches. Nothing notifies the editor when an export finishes.

## Rule for what goes in Settings

Sort every candidate into one of four scopes. Only the first two belong in Settings.

1. **App-wide behavior.** One value for every window. Example: scrub audio.
2. **Starting value for new work.** Settings seeds a sheet, a new window or a new project. The sheet remains the place to override it, and the project keeps what was chosen. Example: re-encode codec.
3. **Window or review session.** Playhead, marks, zoom, panel visibility, Skip Pauses, monitored track, range tool.
4. **Project or recording.** Output canvas, soundtrack, room-tone calibration, tile count hints, manual thresholds, a recording’s saved tile layout.

How values are read:

- **Existing keys keep their live behavior.** Changing the movie export mode still updates the mode in every open sequence editor, as it does today. `EditorModel.swift:1508`
- **Mirrored keys become live.** A change from Settings, a context menu, a divider or an agent reaches every open window.
- **New starting values are read once**, when their window, sheet or job is created. Changing one never alters a running transport or an open sheet. Hiding and reopening a transcript pane keeps that window’s follow state.
- Opening or cancelling a sheet never writes a default.
- Each new key’s factory value equals today’s behavior, so an upgraded profile changes nothing. The one exception is marked in its row.

## The window

Keep the native `Settings` scene. Inside it, lay out a fixed-width sidebar list beside a scrolling grouped form in a plain horizontal stack. Do not use `NavigationSplitView`: its toolbar and collapse behavior inside a Settings scene differ between macOS 14 and later releases. Start at 760 × 560 points with a 640 × 420 minimum, and declare the resizability explicitly. Verify the layout on macOS 14 as well as the current system.

- **Selection.** Reopen the last page. Store the selection through `EditorPreferences`, never through `@AppStorage`.
- **Deep link.** One entry point opens Settings on a named page: `openSettings` plus the stored selection. As built, its one caller is the MCP `show_settings` action; the helper’s error text names the page in plain text. The local-control test finds “Enable local MCP control” only when Automation is showing. `mcp/integration/testdata/press_menu.swift:39`
- **Search.** A search field above the sidebar filters the same row definitions that label the controls. “HDR” finds both display pickers, “cache” finds Storage, “undo” finds the history limit, “export tier” finds the warning in General. A result opens its page and focuses the control.
- **Numeric fields.** One shared component for every number: a text field with a unit, a stepper, a range, and commit on Return, on focus loss, on page change and on window close. Typing alone never commits. The history field and the three silence fields move onto it; the silence controls inside the editor keep their own component.
- **Access.** Every page works with no project open and is reachable by keyboard and VoiceOver.
- **Restore Defaults.** Each page ends with one. It asks first and names what will change in open projects. It writes factory values through the property setters, so every observer runs. A value supplied as a launch argument applies again at the next launch that passes it. It skips five rows whose reset reaches beyond Settings: the undo limit, the cutcache location, local MCP control and the two agent permission switches.

Status in the tables below:

- **Here**: already a Settings control. It moves, with the same key, value and live behavior.
- **Mirror**: already saved, with a control elsewhere. Add a Settings control and keep the existing one.
- **Default**: an app-side literal or a forgotten sheet value becomes a stored starting value. No new behavior unless the row says so.
- **Feature**: new behavior, new interface outside Settings, or a change to core.

### General

| Control | Status | Factory value | Today |
| --- | --- | --- | --- |
| Opening several recordings from Finder: Ask / Join clips / Open as multicam | Default | Ask | Alert every time. `ProjectSessions.swift:908` |
| Maximum undo and redo steps | Here | 50 | `history_max_steps`. One app-wide value, applied to each project. |
| Recent items | Default | 10 | Literal. `RecentFiles.swift:7`. File → Open Recent keeps Clear Menu. |
| Offer to recover untitled projects at launch | Feature | Off | Drafts are reachable only through File → Recover Untitled Project…. |
| **Warnings** — Warn when an edit lowers the export tier | Here | On | `export_tier_downgrade_warning_enabled`. The alert already has “Don’t ask again”. |
| **Warnings** — Confirm before scanning scenes again | Default | On | Always asked in both editors. `EditorModel.swift:2552`, `MulticamAnalysisCommands.swift:61` |
| **Warnings** — Show “Exported …” after a project export with no warnings | Default | On | Always shown. It is the only sign that an interchange export finished. `ProjectConversionPanels.swift:149` |
| **Warnings** — “Don’t ask again” on the Finder and rescan alerts, and Reset All Warnings | Feature | — | Only the tier alert can be suppressed today. |

“Restart scene analysis?” discards a paused scan’s progress, so it always asks. Save, discard and quit confirmations stay unconditional.

### Editing

| Control | Status | Factory value | Today |
| --- | --- | --- | --- |
| Snap to | Here | Off | `timeline_snap_target` |
| Show source time ticks inside clips | Here | Off | `timeline_source_time_ticks_enabled` |
| Enlarge thumbnails and waveforms | Here | Off | `timeline_large_previews_enabled` |
| Show cut sections in new windows | Default | On | Per window. `MCPPresentation.swift:26` |
| Panel position: Above timeline / Full height | Mirror | Above timeline | `workspace_full_height_sidebar_enabled`, dock button |
| Multicam track label width | Mirror | 172 pt (106–360) | `multicam_track_label_width_points`, divider drag. Each window clamps the stored width to its own space. |
| Inserted still duration | Default | 2 s | Two insert paths with two rounding methods. `EditorModel.swift:7754`, `MulticamStillEdits.swift:218` |
| Color gap and Space Clips duration | Default | 2 s | `StillAuthoringControls.swift:280` |
| Gap color | Default | Black | Insert Color Gap and Space Clips each start their own color well at black. `StillAuthoringControls.swift:236`, `:256` |
| New stills timeline: size, frame rate, codec | Default | 1920 × 1080, 30 fps, H.264 | `StillTimelineFormatPanel.swift:22`. Container stays MOV and program color stays SDR. |
| Time display: Milliseconds / Frames | Feature | Milliseconds | Fixed `MM:SS.mmm`. `Timeline.swift:301`. Frames counts at the timeline’s cadence and falls back to milliseconds for audio-only timelines and for variable, mixed or unconfirmed frame rates. |

Give the three duration paths one shared helper that rounds to a whole frame at the active cadence.

### Playback & Monitors

| Control | Status | Factory value | Today |
| --- | --- | --- | --- |
| Play audio while scrubbing | Here | On | `playback_scrub_audio_enabled` |
| Mute preview audio, Preview volume | Here | Off, 100% | `playback_preview_muted`, `playback_preview_volume_fraction` |
| Starting playback speed | Default | 1× | Per window and never reset. `Preview.swift:571`, `MulticamPreview.swift:426` |
| Play around a cut: seconds before and after | Default | 1 s, 1 s | Join audition and sequence pause preview use 1 s. **Exception:** multicam pause review uses 0.75 s and moves to this value. `EditorModel.swift:6704`, `MulticamRangeEdits.swift:784`. The Preview Join sheet text states the seconds and must follow the setting. |
| Editor viewer: Automatic / Force SDR | Mirror | Automatic | `playback_viewer_force_sdr_enabled`, right-click. Applies to every picture surface except the Video Monitor, including sheet previews. |
| Video Monitor: Automatic / Force SDR | Mirror | Automatic | `playback_monitor_force_sdr_enabled`, right-click |
| Clean feed on the Video Monitor | Mirror | Off | `playback_monitor_clean_feed_enabled`, right-click |
| Open the Video Monitor on: Other display / Last position | Feature | Other display | Position is never remembered. `ProjectSessions.swift:415` |

### Media & Analysis

| Control | Status | Factory value | Today |
| --- | --- | --- | --- |
| Watch recordings for changes while editing | Here | Off | `media_auto_refresh_enabled` |
| Scan for scenes when a recording is added | Feature | Off | Scenes scan only on request. |
| Scan for pauses when a recording is added | Feature | Off | Runs on its own only when Snap to is Silence. |
| Silence: Minimum pause, Ignore sounds up to, Padding per side | Here | 1.5 s, 0.06 s, 0.2 s | `silence_*` |
| Find Tiles for a recording with no saved layout: Layout, Grid, Scan detail | Default | Video Call, 2 × 2, Adaptive | A scanned recording restores its own layout from the project. `ParticipantInspector.swift:67–73`, `:257` |
| Dialogue switches: Minimum hold, Overlapping speech, Offscreen speaker | Default | 1 s, Hold the Shot, Hold the Shot | Sheet state. `ParticipantDialogueReview.swift:13`. The tile switch lane uses the same 1 s with no field. `TileSwitches.swift:118` |

Indexing, waveforms and thumbnails stay automatic. A build without TileTrail has no Video Call or Camera Multiview layout, so its Find Tiles row offers Even Grid only and says why. An automatic pause scan uses the existing snap-scan bookkeeping, so a scan the editor cancelled stays cancelled across later edits. `EditorModel.swift:2338` The Silence footer says these values apply to the desktop app.

### Transcripts (new page)

| Control | Status | Factory value | Today |
| --- | --- | --- | --- |
| Transcriberrr status, available engines, Open Transcriberrr | Mirror | — | Shown only inside job setup. `TranscriptJobSetup.swift:189` |
| Helper location: Automatic / Choose… | Feature | Automatic | Environment variable only, read in core. `TranscriptJobProvider.swift:249`. The setting reaches desktop jobs. The CLI and the file worker keep the environment variable. |
| Preferred engine | Default | Automatic (Qwen3, then first available) | Sheet state. `TranscriptJobSetup.swift:200` |
| Identify speakers in mixed audio | Default | Off | Sheet state, cleared on every engine change. `TranscriptJobSetup.swift:84`, `:349` |
| Download missing models | Default | Off | Sheet state in setup and again in the retry form. `TranscriptJobSetup.swift:85`, `:490` |
| Follow playback in new windows | Default | On | Per window. `MCPPresentation.swift:8` |
| Reader text size | Default | 14 pt | Literal. `TranscriptFlowReader.swift:61` |
| Boundary: Nearest media frame / Copy-safe boundary / Exact requested time | Default | Nearest media frame | Sheet state in four places. `TranscriptPaneSheets.swift:362`, `TranscriptEditorialForm.swift:43`, `:302`, `:403` |
| Pause to keep when tightening | Default | 0.2 s | Literal `"0.20"`. `TranscriptPaneSheets.swift:358` |
| Filler terms | Default | Empty | Retyped for every review. `TranscriptEditorialForm.swift:81` |
| Export Transcript format | Default | Native JSON | Sheet state. `TranscriptPaneSheets.swift:515`. Export Captions stays SubRip. |
| Captions: characters per line, lines, longest cue, speaker labels | Feature | 42, 2, 6 s, On | Literals in core, with no way to drop the labels. `TranscriptSubtitles.swift:298–380`. Core takes the limits as parameters. CLI and MCP output keep the factory values. |

Seeding rules for job setup:

- A saved engine that is unavailable shows its reason and keeps the preference.
- Changing the engine re-seeds **Identify speakers** from the preference where the new engine supports it.
- The retry form seeds **Download missing models** from the preference. A retry otherwise uses the options its job captured.
- The app resolves **Automatic** and always passes a named engine. Core treats a missing engine as Qwen3 and fails when Qwen3 is not installed. `TranscriptJobProvider.swift:36`
- Model, speaker count and track assignments stay in job setup.

### Export

| Control | Status | Factory value | Today |
| --- | --- | --- | --- |
| Default movie export mode | Here | Smart Trim | `export_movie_default_mode` |
| Default JPEG preset | Here | Small review images | `export_jpeg_default_preset` |
| Re-encode video, Quality, ProRes quality | Default | H.264, Balanced, 422 | Kept per window in the sequence editor, per view in multicam. `ExportSheet.swift:60`, `MulticamExportChoices.swift:24`. Factory values come from `ExportRules.defaultCodec` and `defaultQuality`. |
| H.264 and HEVC container: Automatic / MP4 / MOV / MKV | Default | Automatic | Automatic keeps today’s split: MP4 in the sequence editor, MOV in multicam. ProRes stays MOV. |
| Multicam audio: Separate tracks / Downmix to mono / Downmix to stereo | Default | Separate tracks | `MulticamExportChoices.swift:26` |
| Save Export Result JSON | Default | Off | A new checkbox on every panel. `ExportResultFile.swift:11` |
| Open the timeline in Resolve after sending | Default | On | `ResolveExportPanel.swift:14` |
| Start export panels in: Automatic / Project folder / Source folder / Chosen folder | Feature | Automatic | Each entry point has its own rule, listed below. |
| When an export finishes: Show in Finder, Notify, Play a sound | Feature | Off, Off, Off | Status text only. No notification code exists. |

Export rules still decide what a timeline can use. Show the effective choice when a default is ineligible.

**Starting folder.** Automatic keeps each entry point’s rule. Any other choice supplies the first folder of a window’s session at every entry point. A folder chosen in a save panel wins for the rest of that session. If the chosen folder is offline, open the panel at its automatic location and mark the folder unavailable in Settings. Entry points today: sequence export and queue (`EditorModel.swift:1162`), multicam queue (`MulticamBulkQueue.swift:381`), JPEG frames (`JPEGExportPanel.swift:14`, `:91`), transcript and caption export (`TranscriptPane.swift:1402`, `:1568`), transcript excerpts (`TranscriptQueueExcerpt.swift:37`), and no rule at all for the multicam panel (`MulticamEditorView.swift:1604`), Resolve and project interchange.

**Completion actions.** They apply to sequence, multicam and queue exports, JPEG frames, ISO deliveries, Resolve sends and project interchange. Transcript and caption files are instant and excluded.

- The sound goes through `MutedLaunch`, so a muted launch stays silent.
- MPCut asks for notification permission only when the editor turns **Notify** on in Settings. It never asks at launch, and never because an agent or a launch argument set the value. A denied permission shows in the row with a link to System Settings.
- A notification posts only when MPCut is not the frontmost app.
- Code never touches the notification center in a process without a bundle identifier, which includes the test host.

### Storage (new page)

| Control | Status | Factory value | Today |
| --- | --- | --- | --- |
| Save and reuse analysis | Here | On | `analysis_sidecar_reuse_enabled` |
| Save new cutcaches, Shared cache folder, Clear cutcaches… | Here | Next to media | `Sidecars/config.json`, shared with the CLI |
| Limit the shared cache folder | Feature | No limit | Cutcaches are never evicted. |
| Usage list: size and Show in Finder for each store below, Clear where the table allows | Feature | — | No interface. |
| Remove untitled drafts after | Feature | Never | Drafts stay until saved or discarded. `ProjectDraft.swift:194` |

| Store | Location | Limit today | Clear |
| --- | --- | --- | --- |
| Generated stills | `~/Library/Caches/MPCut/GeneratedStills-v1` | 1 GiB, 128 entries | Yes. Skips entries in use. |
| Transcript recognition results | `~/Library/Application Support/MPCut/Transcript Claims` | Results are kept. Idle claim locks go after 30 days. | Yes. Shared with the CLI and Transcriberrr: skips locked claims and says so. |
| Transcript job scratch | `.transcript-jobs` in the drafts folder for the desktop, `~/Library/Application Support/MPCut/TranscriptJobs` for the CLI. The desktop prunes both. | 30 days | No. Guarded by locks and pruned already. |
| Untitled drafts | `~/Library/Autosave Information/com.mpcut.desktop` | None | Through File → Recover Untitled Project… only. |
| Suggested transcript cameras | UserDefaults `transcript_suggested_angles`, keyed by transcript attachment, never pruned | None | Yes. |
| Agent job receipts | `~/Library/Application Support/MPCut/File Job Receipts/v1` | 7 days, 8,192 receipts, 256 MiB | No. Clearing breaks job recovery for a connected agent. |

Rules for anything that removes files:

- **Draft retention** moves expired drafts to the Trash. It skips drafts that are open, locked or newer than the limit, and it never touches `.transcript-jobs`.
- **The cache limit** applies only to the managed `MPCut Cache` folder in cache-disk mode. The app enforces it at launch and after it saves a cutcache. The CLI ignores it, so the folder can exceed the limit between app runs. Eviction removes the least recently modified cutcaches first and never one that an open project or its history protects.
- **Clear** reports the bytes reclaimed and what it skipped.
- Every routine that removes files takes its folder as a parameter, so tests run it on temporary folders. Retention and the cache limit do nothing at their factory values.

### Automation

| Control | Status | Factory value | Today |
| --- | --- | --- | --- |
| Enable local MCP control, Status | Here | Off | `automation_local_mcp_enabled` |
| CLI path with Copy, Open Agent Guide | Mirror | — | About has Copy CLI Path. Help has the guide. |
| MCP helper path with Copy, Copy Agent Configuration | Feature | — | Neither exists. |
| Let agents change settings | Feature | On | Agents can change settings through several tools, listed below. |
| Let agents replace existing project files | Feature | On | `replace_existing` is honored without asking. |

State who can drive MPCut:

- The switch gates open projects and file jobs that run through the app.
- A client configured with `--files-only` processes files without the switch, through the bundled CLI. That stays so.
- The Grok connector listens on `127.0.0.1:8472` with a bearer key when its launcher is running.
- Agent edits are labelled in Project History.

**Enforcing “Let agents change settings”.** Enforce it where a preference is written, by the origin of the request, not per tool. With the switch off, every agent route below refuses and names the switch; reads still work.

- `preferences_set` (`MCPLifecycle.swift:384`)
- `workspace_layout_set`: large thumbnails, full-height panel, track label width (`MCPPresentation.swift:222`, `:234`, `:334`)
- Multicam preview actions: snap target, volume, mute, scrub audio (`MulticamMCP.swift:672`, `MulticamPreview.swift:437`)
- `analysis_file_cache_settings_set` through the app

Under `--files-only`, `analysis_file_cache_settings_set` runs in the CLI and can still change the cutcache location. Say so beside the switch. Both permission keys start with `automation_`, so agents can read them and cannot set them.

## Stays close to the work

- **Per project or recording:** output canvas and soundtrack, room-tone calibration, manual thresholds, audio routing, tile count hints, participant bindings and a scanned recording’s tile layout.
- **Per transcript:** a speaker’s suggested camera. It is stored app-wide today, keyed by attachment; Storage lists it and can clear it.
- **Per window:** playhead, marks, zoom, range tool, panel visibility, Skip Pauses, monitored audio track, Group or Assembly preview, queued ranges.
- **Per job:** transcription model, speaker count, track roles, the ISO export options, conversion loss approval and Premiere flattening. Loss approval should always be a fresh decision.
- **Not tunable:** scene and sync detection thresholds, worker counts, memory budgets, timeouts, encoder quality tables and hardware decoding. These have no safe range an editor could reason about.

## Defects found during the inventory

Fix these with the reorganization. None needs a setting.

1. **Preference storage bypasses test isolation.** Force SDR, clean feed, track label width and the last relink folder write to `UserDefaults.standard`. `@AppStorage(store: nil)` and `?? .standard` fall back to the standard store when isolation asks for no persistence. Rule: no Settings key uses `@AppStorage`, and a nil store means “do not persist”. `PreviewSurface.swift:55`, `MulticamTimeline.swift:55`, `ProjectMediaSheet.swift:261`, `EditorWorkspace.swift:19`, `MCPPresentation.swift:151`, `TranscriptSuggestedCameras.swift:20`
2. **Force SDR is read once** when a surface takes its role, so a change does not reach other open windows. `PreviewSurface.swift:55`
3. **The transcription Language field** takes free text with an “Automatic” prompt, and core rejects anything except English. `TranscriptJobSetup.swift:361`, `TranscriptJobProvider.swift:316`
4. **The multicam save panel** always suggests `Multicam.<ext>`, ignoring the project name. `MulticamEditorView.swift:1607`
5. **Multicam has no Show in Finder** after an export. The sequence editor has both a button and a menu item.
6. **Nothing keeps the Mac awake** during an export or a transcription. Do this unconditionally.
7. **The agent guide and the headless guide need a cross-reference.** Each is right about its own helper mode and neither mentions the other. `MCP-AGENT-GUIDE.md:34`, `HEADLESS.md:9`

## Decisions

1. **The local-control switch does not gate the file worker.** A headless worker has no app to ask. Settings and both guides describe this the same way.
2. **The CLI does not read desktop settings.** Scripts need the same result on every Mac. Each footer that could mislead says so.
3. **No update setting.** MPCut itself makes no outbound network requests, and a background check would be the first. Add **Help → Check for Updates…**, which opens the releases page in the browser.
4. **Automatic scene and pause scans are built, off by default.** They cost time and cutcache space on every recording added.
5. **Time display offers Milliseconds and Frames.** Timecode waits for a rule covering mixed frame rates and drop-frame.
6. **Agent permissions are two switches, both on.** Nothing changes for a connected agent until the editor turns one off.
7. **Audio follows the system output.** No device picker until someone needs a separate monitor output.
8. **Agents get the editor’s export and engine defaults.** When a live MCP call omits the mode, codec, quality, container, multicam audio layout or transcription engine, the app uses the Settings value, as it already does for the mode. `MCPOutputs.swift:356` Every other omitted argument keeps its documented fallback. File jobs and the CLI use factory values. The schemas say which applies.

Deferred, outside this plan:

- **Reopen projects at launch.** First check at runtime what macOS restores for these windows. App code gives a restored window an empty session. `ProjectSessions.swift:632`
- **Timecode display.**
- **Keyboard shortcut customization.** Shortcuts are defined in three places with no keymap. That is its own project.
- **Autosave for saved projects.** Only untitled work is drafted continuously. This is a document-model change.

## Key schedule

Names follow feature → subject → qualifier → unit. A key that only seeds new work carries `default`. Enumerations use the raw values of the Swift type named. Every key below is stored through `EditorPreferences`.

| Key | Swift property | Type and range | Factory |
| --- | --- | --- | --- |
| `open_multiple_recordings_default_action` | `multipleRecordingsAction` | `MultipleRecordingsAction`: `ask`, `join`, `multicam` | `ask` |
| `recent_files_max_count` | `recentFilesLimit` | integer 1–30 | 10 |
| `draft_recovery_prompt_enabled` | `offersDraftRecovery` | Boolean | false |
| `scene_rescan_confirmation_enabled` | `confirmsSceneRescan` | Boolean | true |
| `project_export_completion_message_enabled` | `showsProjectExportMessage` | Boolean | true |
| `timeline_cut_sections_default_enabled` | `showsCutSections` | Boolean | true |
| `workspace_full_height_sidebar_enabled` | `fullHeightSidebar` | Boolean (existing key) | false |
| `multicam_track_label_width_points` | `trackLabelWidth` | number 106–360 (existing key) | 172 |
| `still_placement_default_duration_seconds` | `stillDuration` | number 0.04–600 | 2 |
| `gap_default_duration_seconds` | `gapDuration` | number 0.04–600 | 2 |
| `gap_default_color` | `gapColor` | `#RRGGBB`, stored upper case | `#000000` |
| `still_timeline_default_width_pixels`, `…_height_pixels` | `stillTimelineWidth`, `stillTimelineHeight` | even integers 16–8192 | 1920, 1080 |
| `still_timeline_default_frame_rate` | `stillTimelineFrameRate` | number 1–240 | 30 |
| `still_timeline_default_codec` | `stillTimelineCodec` | `ReencodeCodec`: `h264`, `hevc`, `prores` | `h264` |
| `timeline_time_display` | `timeDisplay` | `TimelineTimeDisplay`: `milliseconds`, `frames` | `milliseconds` |
| `playback_default_speed` | `playbackSpeed` | `PlaybackSpeed` raw value: 0.125, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4, 8 | 1 |
| `playback_cut_preview_preroll_seconds`, `…_postroll_seconds` | `cutPreviewPreroll`, `cutPreviewPostroll` | number 0.25–10 | 1, 1 |
| `playback_viewer_force_sdr_enabled`, `playback_monitor_force_sdr_enabled`, `playback_monitor_clean_feed_enabled` | `viewerForceSDR`, `monitorForceSDR`, `monitorCleanFeed` | Boolean (existing keys) | false |
| `playback_monitor_placement` | `monitorPlacement` | `VideoMonitorPlacement`: `other_display`, `last_position` | `other_display` |
| `analysis_scene_auto_scan_enabled`, `analysis_silence_auto_scan_enabled` | `autoScanScenes`, `autoScanSilence` | Boolean | false |
| `tiles_scan_default_layout` | `tilesScanLayout` | `TilesScanLayout`: `video_call`, `camera_multiview`, `even_grid` | `video_call` |
| `tiles_scan_default_grid_columns`, `…_rows` | `tilesScanColumns`, `tilesScanRows` | integer 1–12 | 2, 2 |
| `tiles_scan_default_detail` | `tilesScanDetail` | `ParticipantSampling`: `adaptive`, `every_frame`, `sparse` | `adaptive` |
| `tiles_dialogue_default_min_hold_seconds` | `dialogueMinimumHold` | number 0.04–60 | 1 |
| `tiles_dialogue_default_overlap_policy` | `dialogueOverlap` | `ParticipantDialogueOptions.Overlap`: `hold`, `visible_speaker` | `hold` |
| `tiles_dialogue_default_offscreen_policy` | `dialogueOffscreen` | `ParticipantDialogueOptions.Offscreen`: `hold`, `original`, `reaction` | `hold` |
| `transcript_default_engine` | `transcriptEngine` | engine name, up to 128 characters; empty is Automatic | empty |
| `transcript_default_speaker_identification_enabled` | `identifiesSpeakers` | Boolean | false |
| `transcript_default_model_download_enabled` | `downloadsModels` | Boolean | false |
| `transcript_follow_playback_default_enabled` | `followsPlayback` | Boolean | true |
| `transcript_reader_text_size_points` | `readerTextSize` | number 11–24 | 14 |
| `transcript_edit_default_boundary_policy` | `boundaryPolicy` | `TranscriptEditRequest.BoundaryPolicy`: `nearest_frame`, `copy_safe`, `exact` | `nearest_frame` |
| `transcript_tighten_default_retained_pause_seconds` | `retainedPause` | number 0–10 | 0.2 |
| `transcript_default_filler_terms` | `fillerTerms` | one string, terms separated by commas, up to 4,096 characters | empty |
| `transcript_export_default_format` | `transcriptExportFormat` | `TranscriptFormat`: `json`, `text`, `srt`, `vtt` | `json` |
| `transcript_caption_max_line_characters` | `captionLineCharacters` | integer 20–80 | 42 |
| `transcript_caption_max_lines` | `captionLines` | integer 1–3 | 2 |
| `transcript_caption_max_cue_seconds` | `captionCueSeconds` | number 1–20 | 6 |
| `transcript_caption_speaker_labels_enabled` | `captionSpeakerLabels` | Boolean | true |
| `export_reencode_default_codec` | `reencodeCodec` | `ReencodeCodec`: `h264`, `hevc`, `prores` | `h264` |
| `export_reencode_default_quality` | `reencodeQuality` | `ReencodeQuality`: `smaller`, `balanced`, `high` | `balanced` |
| `export_prores_default_quality` | `proresQuality` | `ReencodeQuality`: `422-lt`, `422`, `422-hq` | `422` |
| `export_reencode_default_container` | `reencodeContainer` | `ExportContainerChoice`: `automatic`, `mp4`, `mov`, `mkv` | `automatic` |
| `export_multicam_default_audio_layout` | `multicamAudioLayout` | `MulticamAudioOutput`: `separate_tracks`, `downmix_mono`, `downmix_stereo` | `separate_tracks` |
| `export_result_json_default_enabled` | `savesExportResult` | Boolean | false |
| `resolve_send_open_timeline_default_enabled` | `opensResolveTimeline` | Boolean | true |
| `export_start_folder_mode` | `exportStartFolder` | `ExportStartFolderMode`: `automatic`, `project`, `source`, `chosen` | `automatic` |
| `export_finished_reveal_enabled`, `export_finished_notification_enabled`, `export_finished_sound_enabled` | `revealsFinishedExport`, `notifiesFinishedExport`, `playsFinishedExportSound` | Boolean | false |
| `analysis_shared_cache_max_bytes` | `sharedCacheLimitBytes` | integer; 0 is no limit | 0 |
| `draft_retention_days` | `draftRetentionDays` | integer 0–365; 0 is never | 0 |
| `automation_preferences_write_enabled`, `automation_file_replace_enabled` | `agentsChangeSettings`, `agentsReplaceFiles` | Boolean, read-only to agents | true |

Stored through `EditorPreferences` and kept out of the MCP list: `export_start_folder_path`, `transcript_helper_path`, `playback_monitor_last_frame`, `settings_selected_page`, `project_media_last_locate_folder`, `transcript_suggested_angles`, and the suppression state of each warning (`warnings_suppressed`).

Read-only to agents, because setting them removes files or widens access: `draft_retention_days`, `analysis_shared_cache_max_bytes` and every `automation_*` key.

### MCP preference contract

`preferences_read` lists every key in the schedule. `preferences_set` accepts all of them except the read-only keys named above. Values stay Boolean, string or number, which is why filler terms are one comma-separated string. `preferences_set` refuses with a message naming the switch when **Let agents change settings** is off. Each key’s schema records its type, unit, range and special values, as the naming convention requires.

## Order of work

1. **Reorganize.** Sidebar window with the eight pages, deep link, shared numeric field and Restore Defaults. Move the 16 keys with their names, encodings, factory values and live behavior. Route the mirrored keys through the injected `EditorPreferences` and make them live in every open window. Add the Transcriberrr status row, the Automation paths and the Storage usage list. Fix defects 1 to 7. Acceptance: an upgraded profile sees its values, both editors react to a live change, and the monitor can be configured before it opens.
2. **Seed the existing interface.** Add every **Default** row. Snapshot settings when a fresh sheet, window or job is created. Keep export rules, session overrides, explicit menu modes, command arguments and recorded jobs authoritative. Acceptance: set ProRes, a filler list and a 3 s still; open new sequence and multicam work; override once; cancel; reopen and see the saved defaults. Exercise a missing engine, audio-only output, a timeline with still placements and a 23.976 fps insertion. Two open editors can play at different speeds.
3. **Add the small features.** Export completion actions and starting folder, draft recovery and retention, Storage clearing and the cache limit, monitor position, caption limits, helper location, warning suppression with Reset All Warnings, Help → Check for Updates… and search.
4. **Add the larger features.** Automatic scene and pause scans, the Frames time display and the two agent permission switches. Acceptance: adding a recording with both scans on fills the scene and pause lanes without a menu command; cancelling either leaves the recording editable and the scan stays cancelled across later edits. With **Let agents change settings** off, an agent reads every value and changes none through any route.

Each slice extends the preference, presentation, sidecar and lifecycle tests: isolated defaults suites, invalid stored values, launch-argument overrides, relaunch with existing keys, and Settings with zero, one and two projects. No test reads or writes the real stores under `~/Library`.

## Files that change with the controls

**Settings paths written into code.** `mcp/bridge.go:59`, `Sources/MPCutCLI/CommandHelp.swift:396`, `Sources/MPCutCore/SidecarLocations.swift:333` and `:347`, `Sources/MPCutApp/MPCutApp.swift:187` and `:190`, `Sources/MPCutApp/MCPResources/lifecycle.json` and `Sources/MPCutApp/MCPLifecycle.swift:415`.

**Docs naming the old tabs.** `README.md`, `docs/USAGE.md` (the defaults table and the History, export, cutcache and agent sections), `docs/MCP-AGENT-GUIDE.md`, `docs/HEADLESS.md`, `docs/DESKTOP-PLUGINS.md`, `docs/CLI.md`, `docs/MCP-COVERAGE.md`, `docs/NAMING-CONVENTION.md` (its settings table says “tab” and “Analysis sidecars”), `packaging/grok/Setup.md`, `plugins/mpcut/skills/mpcut-editing` and `CHANGELOG.md`. Regenerate `docs/MCP-REFERENCE.md` with `scripts/mcp-reference.py`; do not edit it by hand.

**Tests.** In `Tests/MPCutAppTests`: `EditorPreferencesTests`, `MCPLifecycleTests`, `SidecarStorageSettingsTests`, `MCPPresentationTests`, `MCPEditorControlsTests`, `TimelineDisplayTests` (it injects the track width through `@AppStorage`), `ProjectDraftTests`, `LiveTranscriptLifecycleTests` and `MCPLocalControlTests`. Also `mcp/integration/settings_darwin_test.go` with `testdata/press_menu.swift`, and `Tests/Packaging/test_public_contracts.py`. The integration launchers pass `-automation_local_mcp_enabled YES`; that key name does not change.
