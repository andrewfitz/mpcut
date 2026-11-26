---
name: mpcut-editing
description: Use MPCut on the user's Mac for live timeline editing and review, multicam, stills, transcript-based editing, audio and scene analysis, saved media inspection, batch exports and project interchange with Resolve, Premiere or Final Cut.
---

# Edit in MPCut

Use the connected MPCut MCP tools. The installed helper advertises the schemas for this build. When the host exposes resources, consult `mpcut://docs/agent-guide` for workflows and `mpcut://docs/tool-reference` for arguments and result semantics. If tools are missing, identify the missing desktop connection. For live tools, open MPCut and check **Settings → Automation → Enable local MCP control**. A `--files-only` connection works with the app closed. Call `cli_version_read` and collect its result to check the bundled CLI build, supported schema and detector capabilities.

For project recovery, history, transport, synchronization, audio, analysis, queues or interchange, see [live editor workflows](references/live-editor.md). For saved media, CLI-backed file jobs, batch processing and options specific to the bundled CLI, see [file workflows](references/files.md). Use the installed tool schema to check each requested option.

## Identify the edit

For an open timeline, including an unsaved one, call `project_windows_list` and then `project_editor_state_read`. Pass the returned `project_handle` on calls to that window, even after a focus change. Resolve repeated clips using their occurrence and output bounds. Ask which window or occurrence the editor means if the evidence still allows several. An empty project list means the connection works and there are no open windows. For a request about a saved file, use its absolute Mac path and the helper's file tools. A saved project can differ from its open edit.

Use the clock belonging to the request. Sequence time counts through the edited program. Source time refers to the recording. A multicam group switch affects every replay of that group interval, while an assembly trim acts on a particular replay. Use returned rational seconds for exact frame boundaries. Ranges include their start and exclude their end.

## Make and verify the requested change

| Editor's intent | Workflow |
| --- | --- |
| See what plays at a cut | Use `review_editor_frame_read` at the playhead or an exact program time. Inspect the returned image and timing metadata. For a multicam camera comparison, supply the angle. |
| Split or trim a take | Locate the occurrence in live state. Split it with `timeline_item_split`. Trim its source bounds with `sequence_clip_edit`. Use `sequence_range_edit` to split or delete a sequence interval. Read back the committed boundary after snapping. |
| Find a spoken line and cut it | Use `transcript_editor_words_search` to search dialogue and identify the occurrence on the source, group or current-cut clock. Check adjacent words and the attachment ID. Use `transcript_editor_edit_plan` to plan, review the resolved boundaries and tier, then apply the plan with the pinned timeline revision, transcript revision and result identity. If any changed, review a new plan. |
| Find a shot or review dead air | Use `scenes_editor_scan` to find shots and `silence_editor_scan` to find pauses. Follow the analysis receipt. Check scene samples before identifying a view. For silence, choose the microphone or routed mix, read `silence_editor_pauses_list` and use `silence_editor_pause_review` for audition or protection. `silence_editor_takes_queue` queues the retained takes. `silence_editor_pauses_shorten` edits the timeline. |
| Change a camera or a replay | Read `multicam_state_read` for source IDs and routing. Use `multicam_camera_take` on the group clock for a switch. Use the current assembly occurrence with `multicam_assembly_edit` for a replay edit. Preserve the chosen soundtrack unless the request changes it. |
| Cover picture or insert a card | Use `still_editor_picture_replace` to cover picture while preserving sound and duration. Use `still_editor_placement_insert` to add time and shift later material. Inspect the result with `still_editor_placements_list` and review the program picture. |
| Check or deliver a movie | Preflight the destination, tracks, container and mode with `export_editor_project_plan`. Read the completed result and eligibility. For a copy-only request, report any incompatible boundaries or streams. To deliver the requested export, use `export_editor_project_render` with a fresh operation ID and report the published paths. |

For calls requiring `expected_revision`, use the observed revision. Give each new mutation or file job a fresh UUID in `operation_id`. For a live edit, retry identical arguments in the same enabled editor session within ten minutes of completion. For a standalone file job, reconnect and call `file_job_status_read` with the original UUID. Receipts last seven days. If the worker reports `outcome_unknown`, inspect the saved project and output before starting another operation. On a stale revision, reread state, resolve the edit against the new timeline and use a fresh ID. Refresh occurrence indices after structural edits.

Poll durable recognition jobs with `transcript_editor_job_status_read` using the project handle and returned job ID. Poll analysis receipts with `analysis_job_status_read`, live exports and conversions with `export_editor_job_status_read`, and file jobs with `file_job_status_read`. Use the returned job identifier and project scope. Read the terminal result, including any partial outputs or failures. A dry run can complete successfully and still report an ineligible export.

Report the affected timeline, actual edit or output, and any remaining unsaved change. Name the undo action when history retained it. Save, render, or send a timeline to another editor when the user asks for that outcome.
