---
name: mpcut-editing
description: Use MPCut on the user's Mac for live timeline editing and review, multicam, stills, audio and scene analysis, saved media inspection, batch exports and project interchange with Resolve, Premiere or Final Cut.
---

# Edit in MPCut

Use the connected MPCut MCP tools. The installed helper advertises the schemas for this build. When the host exposes resources, consult `mpcut://docs/agent-guide` for workflows and `mpcut://docs/tool-reference` for arguments and result semantics. If tools are missing, identify the missing desktop connection. If tools are present but the editor is unavailable, have the editor open MPCut and check **Settings → General → Automation → Enable local MCP control**.

For project recovery, history, transport, synchronization, audio, analysis, queues or interchange, see [live editor workflows](references/live-editor.md). For saved media, CLI-backed file jobs, batch processing and options specific to the bundled CLI, see [file workflows](references/files.md). Use the installed tool schema to check each requested option.

## Identify the edit

For an open timeline, including an unsaved one, call `list_projects` and then `get_editor_state`. Keep the chosen window handle even if focus changes. Resolve repeated clips using their occurrence and output bounds. Ask which window or occurrence the editor means if the evidence still allows several. An empty project list means the connection works and there are no open windows. For a request about a saved file, use its absolute Mac path and the helper's file tools. A saved project can differ from its open edit.

Use the clock belonging to the request. Sequence time counts through the edited program. Source time refers to the recording. A multicam group switch affects every replay of that group interval, while an assembly trim acts on a particular replay. Use returned rational seconds for exact frame boundaries. Ranges include their start and exclude their end.

## Make and verify the requested change

| Editor's intent | Workflow |
| --- | --- |
| See what plays at a cut | Use `review_frame` at the playhead or an exact program time. Inspect the returned image and timing metadata. For a multicam camera comparison, supply the angle. |
| Split or trim a take | Locate the occurrence in live state. Use `split_at` in the specified clock. For `sequence_control` trims use source time, and for range edits use sequence bounds. Read back the committed boundary after snapping. |
| Find a shot or review dead air | Use `scan_analysis` for scenes or silence and follow its receipt. Use `list_scenes` and inspect a sample before identifying a view. For silence, establish the microphone or routed mix, inspect `list_pauses` and use `review_pause` for audition or protection. Use `apply_pauses` in queue or shorten mode according to the request. |
| Change a camera or a replay | Read `get_multicam` for source IDs and routing. Use `set_camera_at` on the group clock for a switch. Use the current assembly occurrence with `multicam_assembly` for a replay edit. Preserve the chosen soundtrack unless the request changes it. |
| Cover picture or insert a card | On builds advertising `add_still` and `list_stills`, use replace to preserve sound and duration, or insert to add duration and shift later material. Inspect the placement and check the resulting program picture. If the build lacks still editing, tell the editor this request needs a build with those tools. |
| Check or deliver a movie | Preflight the chosen destination, tracks, container and mode with `render_project` and `dryRun: true`. Check the completed result's eligibility and plan. For a copy-only request, surface incompatible boundaries or streams before changing the cut or encoding. For a requested eligible export, submit a new operation with `dryRun: false` and report the published paths. |

For calls requiring `expectedRevision`, use the observed revision. Give each new mutation or file job a fresh UUID in `operationID`. After an uncertain reply, retry identical arguments with the same ID within the same session's ten-minute completion window. After expiry, inspect current state and history to establish the outcome. On a stale revision, reread state, resolve the edit against the new timeline and use a fresh ID. Refresh occurrence indices after structural edits.

Poll analysis receipts with `analysis_job_status`, live exports and conversions with `live_job_status`, and file jobs with `file_job_status`. Use the returned job identifier and project scope. Read the terminal result, including any partial outputs or failures. A dry run can complete successfully and still report an ineligible export.

Report the affected timeline, actual edit or output, and any remaining unsaved change. Name the undo action when history retained it. Save, render, or send a timeline to another editor when the user asks for that outcome.
