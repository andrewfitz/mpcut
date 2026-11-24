# MPCut naming convention

A person reading one setting should know what it controls. A person choosing an action should know whether it reads data, edits an open project, queues work or writes a file. Use the same concepts in the UI, accessibility labels, CLI, MCP, history and reports. The implementation plan defines the single-release cutover and verification requirements. [App-wide implementation plan](APP-NAMING-PLAN.md)

## Rules

- **Values:** feature → subject → qualifier → unit. Examples are `multicam_track_label_width_points`, `playback_preview_volume_fraction` and `history_max_steps`. Use ordinary language in the UI: **Multicam → Track label width**, **Playback → Preview volume**, **History → Maximum undo and redo steps**.
- **Actions:** feature → target when needed → object → verb. Examples are `multicam_camera_take`, `transcript_editor_excerpt_queue` and `export_queue_render`. Buttons use the same nouns in natural order: **Move switch**, **Queue excerpt**, **Render queued exports**.
- **Scope:** distinguish app preferences, window layout, project state, source tracks, timeline occurrences and job options. Specify whether a tool reads the open editor revision or a saved file. Identify the owner of a job when reporting or cancelling it.
- **Coordinates:** include the clock when source, sequence, group or assembly time could apply. Include the occurrence when footage repeats. Preserve exact rational times. Distinguish an absolute stream index from a displayed track number and specify the index base.
- **Spelling:** use snake_case for MPCut-owned public machine contracts and kebab-case for CLI flags. Each concept has one accepted spelling per surface. Honor field names defined by external protocols. A parent object or subcommand can supply the feature prefix once. A flat settings key, exported column or search result must stand on its own.

## Settings and interface vocabulary

| Swift preference | Standalone name | Settings tab, section and control |
|---|---|---|
| localMCPEnabled | automation_local_mcp_enabled | General → Automation → Enable local MCP control |
| automaticallyRefreshMedia | media_auto_refresh_enabled | General → Media → Watch recordings for changes while editing |
| useAnalysisSidecars | analysis_sidecar_reuse_enabled | Analysis → Analysis sidecars → Save and reuse analysis |
| historyLimit | history_max_steps | General → History → Maximum undo and redo steps |
| snapTarget | timeline_snap_target | General → Timeline → Snap to |
| sourceTimeTicks | timeline_source_time_ticks_enabled | General → Timeline → Show source time ticks inside clips |
| largeThumbnails | timeline_large_previews_enabled | General → Timeline → Enlarge thumbnails and waveforms |
| volume | playback_preview_volume_fraction | General → Playback → Preview volume |
| isMuted | playback_preview_muted | General → Playback → Mute preview audio |
| scrubSoundEnabled | playback_scrub_audio_enabled | General → Playback → Play audio while scrubbing |
| defaultExportMode | export_movie_default_mode | General → Export defaults → Default movie export mode |
| jpegPreset | export_jpeg_default_preset | General → Export defaults → Default JPEG preset |
| warnBeforeLoweringExportTier | export_tier_downgrade_warning_enabled | General → Export defaults → Warn when an edit lowers the export tier |
| minimumPause | silence_min_pause_seconds | Analysis → Silence → Minimum pause (s) |
| maxBlip | silence_max_blip_seconds | Analysis → Silence → Ignore sounds up to (s) |
| padding | silence_padding_per_side_seconds | Analysis → Silence → Padding per side (s) |

Window layout and multicam settings follow the same rule, including `workspace_full_height_sidebar_enabled` and `multicam_track_label_width_points`. Each schema records type, unit, scope, default, accepted range and special values. A changed preview volume affects monitoring; replacing the soundtrack changes media. In a transcript, padding extends a word selection. In silence editing, padding keeps quiet audio on each side of a cut.

## Choosing a command or tool

CLI command paths use ordinary words in feature, object, action order. For example, `mpcut project media refresh` checks recordings in a saved project, and `mpcut export ranges separate` writes one file per range. Use `mpcut help --json` for the command map and `mpcut help silence plan --json` for one operation. [CLI guide](CLI.md)

MCP identifiers include the target when it affects the result. `project_file_inspect` reads a saved project, and `project_editor_state_read` examines an open editor revision. A file operation that starts a job returns its handle. Read the associated job status before using its output. [Complete tool and argument reference](MCP-REFERENCE.md)

| Feature | Example | Effect |
|---|---|---|
| Projects and history | `project_window_focus`, `history_state_restore` | Focus a particular window or restore an edit state. |
| Media and timeline | `project_media_add`, `timeline_item_split` | Add media to the open project or split an item. |
| Playback and workspace | `playback_transport_pause`, `workspace_layout_read` | Pause playback or read the window layout. |
| Multicam | `multicam_camera_take`, `multicam_switch_edit` | Create a camera switch or change an existing switch. |
| Stills | `still_editor_placement_insert`, `still_editor_picture_replace` | Insert time or replace picture while retaining sound. |
| Analysis | `waveform_file_envelope_read`, `scenes_editor_scan` | Read signed amplitudes or detect scene boundaries. |
| Silence | `silence_file_plan`, `silence_file_export` | Calculate retained ranges or write shortened media. |
| Transcript | `transcript_editor_edit_plan`, `transcript_editor_edit_apply` | Review a word-based edit or apply it to the timeline. |
| Export and interchange | `export_queue_render`, `project_file_resolve_import` | Render queued edits or import a saved project into Resolve. |

## Adoption across the app

1. Review the complete feature map together. Use one meaning for each shared noun: an asset is an input, a placement is one use, a range has a clock, a queue entry is a captured edit, and an output is a written file.
2. For each operation, record its current selectors, arguments, results, defaults, units, owner and side effects. Split destinations only where all existing behavior has a home. Preserve undo, revision checks, job ownership, retries, preflight and saved-report replay.
3. Publish the same vocabulary in menus, settings search, accessibility, CLI help, MCP schemas, reports and plugin instructions. Ship a single current contract across the app, CLI, MCP helper, plugins and native saved formats. Remove retired names, fallback readers and preference conversions together.
4. Verify behavior in each family: recovery and history, clip editing, multicam routing and repeated occurrences, still placements, transcript edits, scene and audio analysis, queued renders and interchange. Verify both what a command changes and which file or project receives that change. Verify each setting against its published units, including zero and boundary values.
