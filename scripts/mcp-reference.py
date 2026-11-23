#!/usr/bin/env python3
"""Generate the bundled MCP tool reference from the helper's discovery catalog."""

import argparse
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Sources/MPCutApp/MCPResources"
REFERENCE = ROOT / "docs/MCP-REFERENCE.md"

GROUPS = {
    "projects": "Project discovery",
    "lifecycle": "Projects and preferences",
    "sequence": "Editing, navigation and history",
    "source_ranges": "Named selects and ordered source ranges",
    "timeline_review": "Range mapping and revision comparison",
    "stills": "Still image placements",
    "multicam": "Multicam",
    "sync": "Multicam synchronization",
    "presentation": "Window layout and monitoring",
    "review": "Inline picture review",
    "analysis": "Live analysis",
    "transcript": "Transcripts",
    "outputs": "Live exports",
    "file": "File tools and jobs",
    "file_review": "Saved timeline review and multicam analysis",
    "participants": "Participant tracking, review and delivery",
}

# Supplement the advertised input schemas with outcome semantics shared by each
# native command family. A new tool needs a documented return contract.
RESULT_GROUPS = {
    "project_windows_list": "`projects[]` supplies each window’s opaque `project_handle`, name, kind, dirty flag and revision. A saved project includes `project_path`.",
    "project_editor_state_read": "State includes `busy`, `modal`, selection, playhead, snapping and `history_max_steps`. Use `offset` and `total` to page `clips[]` or `occurrences[]` at a pinned revision. A sequence row identifies an occurrence by `id` and provides `sequence_from`, `sequence_to`, `source_from` and `source_to`. A multicam row identifies it by zero-based `index` and provides assembly bounds and group bounds for group rows. Insert rows identify the still placement and asset. Still placements are also paged under `stills` when present. `tier` reports the export tier of the timeline: its `id` (`true_lossless`, `lossless`, `reencode`, `checking` or `unavailable`), `name`, the best `mode` and `container`, `warnings`, and the `factors` that lower it, each with an `id`, a `message` and any `nearest` times. `current` is false while a newer timeline is being checked.",
    "still_editor_placements_list": "Page `items` using `offset` and `total`. Each row supplies stable `placement` and `asset` IDs, operation, framing, authored coordinates and visible program ranges, duration and offline status. Generated gaps have `kind: gap` and `offline: false`. Hidden replacements have zero visible duration.",
    "still_editor_placement_insert still_editor_picture_replace timeline_gap_insert still_editor_placement_update still_editor_placement_remove still_editor_asset_relink": "Returns the affected `placement` or `asset`, native action, revision, changed and history_retained. Read still_editor_placements_list or the refreshed timeline after structural edits.",
    "timeline_clips_space": "Returns `project_handle`, `action`, `revision`, `changed` and `history_retained`. Read `still_editor_placements_list` for gap placements and their durations.",
    "project_drafts_list": "Each entry in `drafts[]` contains its recoverable `draft_path` and modification time.",
    "preferences_read preferences_set": "Returns current preference values. Changes apply app-wide. Lowering the history limit can trim retained steps immediately.",
    "project_create project_open project_draft_recover project_media_add project_save project_window_focus history_panel_show playback_monitor_visibility_set multicam_setup_confirm multicam_setup_dismiss workspace_notice_dismiss": "Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.",
    "project_close": "`closed` reports whether the window closed. A dirty project requires a `changes` decision. Saving an untitled project also requires `project_path`.",
    "multicam_setup_read": "`sources[]` identifies pending source IDs, paths, video presence and available audio streams. `adding` distinguishes extending an existing project from initial setup.",
    "workspace_layout_read workspace_layout_set workspace_panel_show timeline_time_reveal": "Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points.",
    "history_read history_undo history_redo history_state_restore": "`actions`, `cursor`, `history_token` and `limit` describe the retained branch. Index zero is the state before the first retained action. A restore needs the index and token from one read. Refresh after a history change.",
    "history_editor_compare": "Returns a `comparison` with before and after clocks and durations, changed project fields, and occurrence changes with their before and after values. Pass an index and history token from the same history read and the current editor revision. An unavailable index or stale snapshot is an error.",
    "timeline_editor_range_map": "Returns the requested `mapping` with input and output clocks and intersecting `pieces[]`. Pieces identify the occurrence and carry clipped input and output bounds where applicable. Repeated source uses appear separately. A working copy can also report `original_file`. Supply both history selectors from one retained history read to map an older state. Follow the mapping’s `next_offset` for additional pieces.",
    "source_selects_list source_select_save source_select_remove": "Returns `revision` and `source_selects[]` with each select’s ID, name and source range. A select can reference media that has no occurrence in the current sequence.",
    "sequence_source_ranges_apply": "Returns the resulting `revision` and `range_count`. Ranges resolve and apply as one native history action in the supplied order. Invalid ranges and stale revisions leave the sequence unchanged.",
    "multicam_sync_suggest": "Returns the observed `revision` and a `report` against the reference recording. Suggestions include timestamp evidence, candidate offsets and any available waveform matches and drift evidence. A suggestion leaves project offsets unchanged.",
    "multicam_track_audio_sync_suggest": "Returns the revision, sync evidence for the selected camera and incoming streams, and any metadata or waveform offset relative to the camera recording.",
    "multicam_track_audio_edit": "Returns the revision, edit action, change status and history retention after applying or removing a synced recording replacement.",
    "participants_file_scan": "Returns a file job receipt. The completed result includes analysis identity, source clock, observations, change events, coverage, and backend diagnostics. Use `file_job_result_read` to retrieve a large report.",
    "participants_file_markers_build": "Returns a file job receipt. The completed result lists proposed markers with source timestamps, changed and eligible counts, and uncertain coverage.",
    "participants_file_project_inspect": "Returns a file job receipt. The completed result contains the editable participant object from the project.",
    "participants_file_project_accept participants_file_project_apply": "Returns a file job receipt. The completed result supplies the resulting project path and change count.",
    "participants_file_render_plan participants_file_render_export": "Returns a file job receipt. The completed result reports the output duration, canvas, audio policy, and coverage. The render result includes the published movie.",
    "participants_file_angles_list": "Returns a file job receipt. The completed result lists the selected virtual angles and their common source-clock interval.",
    "participants_file_angles_plan": "Returns a file job receipt. The completed result reports each angle’s canvas and coverage and the meeting-mix plan.",
    "participants_file_angles_render": "Returns a file job receipt. The completed result supplies the saved multicam project path and project details.",
    "timeline_file_range_map": "Returns a file job receipt. Poll `file_job_status_read` for the saved project’s mapping, including the input and output clocks and all intersecting occurrence pieces. Use `file_job_result_read` for a large result.",
    "history_file_compare": "Returns a file job receipt. Poll `file_job_status_read` for the comparison between the two saved projects. It reports changed project fields and before and after occurrence details. Use `file_job_result_read` for a large result.",
    "multicam_file_sync_suggest": "Returns a file job receipt. Poll `file_job_status_read` for timestamp evidence, candidate offsets, waveform matches and available drift evidence against the reference source.",
    "multicam_file_switch_coverage_read": "Returns a file job receipt. Poll `file_job_status_read` for the exact group interval and its picture status, audio routes and missing ranges.",
    "timeline_item_split": "Reports applied `boundary` in the requested clock, `left` and `right` occurrence references and `history_retained`. Sequence results include `source_time` and `sequence_time`. Multicam camera range results include `group_time`. A still split returns independent `left_placement` and `right_placement` IDs. Use the returned `revision` with the next edit.",
    "timeline_playhead_seek playback_transport_play playback_transport_pause": "Returns resulting transport and editor state. Ordinary editors include `playhead_seconds`, `playing`, `rate` and selection when present. Multicam transport includes `space`, `time`, `group_time` and the current occurrence during assembly preview.",
    "sequence_clip_edit sequence_range_edit timeline_selection_set playback_transport_control": "Returns resulting editor state with `revision`, or a command-specific result such as `action: Apply CSV` and `changed`. A trim preview reports the `trim_preview` token and its proposed `source_time`.",
    "multicam_camera_take": "`angle_id`, `group_time` and `group_until` identify the actual group interval affected. Assembly uses follow the group switch unless the occurrence has a picture override. The result reports `changed` and `history_retained`.",
    "multicam_state_read": "Returns the chosen page of sources, switches, suggestions, assembly occurrences or stills, group range, audio policy, `total` and revision. Camera rows identify the displayed angle and recording; separate recordings on an angle can carry explicit group coverage. Sources report availability and indexing state, with duration when known. Assembly rows may identify an occurrence-specific `angle_id`. The `switch_coverage` section reports the proposed group interval, picture and audio status, audio routes and missing group intervals. After an export fails at a range edge, the suggestions section includes `edge` with the one-based `range`, its `boundary` (`from` or `to`), the edge time `at` and the verified `times` it can move to.",
    "review_editor_frame_read": "Returns a JPEG image block in MCP `content` and decoded-frame metadata in `structuredContent`, including `source_time`, `duration`, `width` and `height`. A multicam result identifies the requested or active clock, timestamp, group time and camera. A still result identifies the asset and placement and reports program time. An image-capable host can inspect the picture directly.",
    "multicam_switch_edit multicam_program_audio_set": "Reports `revision`, `changed` and `history_retained`. A committed edit reports its native action and can carry a draft-write warning.",
    "multicam_source_edit": "Reports `revision`, `changed` and `history_retained`. Nudge reports `group_time` and the new `offset`. Relink identifies the source. `add_recording` places an additional file on the specified angle at `group_start`. A committed edit reports its native action and can carry a draft-write warning.",
    "multicam_group_end_set": "Reports the actual `group_to`, `revision`, `changed` and `history_retained`. A committed edit reports its native action and can carry a draft-write warning.",
    "multicam_assembly_edit": "Reports `revision`, `changed` and `history_retained`. `trim_edge` and `preview_trim` report an exact group `boundary`. `angle_set` and `angle_clear` set or remove a picture override for one occurrence. A committed edit reports its native action and can carry a draft-write warning.",
    "multicam_selection_set": "Reports selection and current preview position. Assembly selection uses the occurrence or bounds from the current revision.",
    "multicam_preview_control": "Reports the current clock, `time`, `group_time`, `playing`, `rate`, forward `speed`, `auditioning` and, in assembly preview, the current `occurrence`.",
    "analysis_editor_state_read": "Returns scan settings, readiness, progress and issues. `scene_coverage` shows source-clock progress by clip or source ID. Use `selected_scene_clip` or `selected_scene_camera` for the current selection. `media_refresh_progress` and `media_refresh_issues` describe the refresh and sources that need attention. Page `sources.items` for source IDs, index availability and audio stream indices.",
    "silence_editor_pauses_list": "Returns `items`, `offset` and `total`. Use returned pause IDs for reviews. Read each pause’s clock, occurrence, protection and removal. An individually adjusted pause can report requested and achieved retained seconds. A multicam assembly selection limits results to its occurrences.",
    "silence_editor_take_candidates_list": "Returns paged take candidates with exact ranges in the returned `clock` and `manual_start` for a take introduced by a manual split.",
    "silence_editor_take_boundary_edit": "Returns the updated take candidate count. Read the candidates again before queueing. Boundary edits split or join take candidates in sequence or assembly time.",
    "timeline_editor_join_preview": "Returns the join’s exact `position`, `clock` and `review_open`. Target an incoming sequence or assembly join by its following occurrence, or a multicam group join by switch time. Close the review with `silence_editor_pause_review` using action `done`.",
    "scenes_editor_boundaries_list": "Returns `items`, `offset` and `total`. Each item pairs source-clock scene boundaries with its view ID and label. View IDs for a range-local scan belong to that report. Archived results include `stale`, `stale_reason` and their original `source_stamp`.",
    "waveform_editor_peaks_read": "Returns source ID, stream, `source_from_seconds`, `source_to_seconds`, source clock, `peaks` and `bins_per_second`.",
    "waveform_editor_envelope_read": "Returns signed `low` and `high` arrays for the specified column count, source clock, stream and actual time window in seconds.",
    "scenes_editor_scan silence_editor_scan": "Returns an analysis receipt with `job_id`, `kind`, `input_revision` and `status`. Poll `analysis_job_status_read` for that receipt. Compatible scene requests share a worker and return separate receipts. A selected reuse request can join an all-source reuse scan for the same recording and completes when that recording’s report is published. Scene receipts identify the native worker with `worker_origin`. An existing GUI silence scan can be followed through `analysis_editor_state_read`.",
    "project_editor_media_refresh": "Returns an analysis job receipt. Poll `analysis_job_status_read` for per-source refresh results, preserved analysis, review issues and any persistence errors.",
    "scenes_editor_scan_cancel silence_editor_scan_cancel": "Returns `status: idle` or `status: cancel_requested` for the selected scan family. For a specific MCP-owned job, use `analysis_job_cancel` with its receipt.",
    "analysis_job_status_read analysis_job_cancel": "Reads the project-bound analysis receipt with `job_id`, `input_revision`, `kind`, `status` and progress when available. Poll until succeeded, failed or cancelled. Scene receipts report `coverage` by clip or source ID, including decoded, confirmed and durable positions. A cancelled scene job can leave resumable coverage. See persistence errors and the durable position to determine what reached disk. Sidecar saves report published outputs even when interrupted.",
    "project_operations_list": "`operations[]` identifies active native workers by `native_operation_id`, kind, label, state and progress when available. Supply the project for a project-owned worker. Omit it for an unowned project conversion.",
    "project_operation_cancel": "`cancellation_requested` acknowledges the request for the supplied native operation ID. Read active operations again. An operation that ended can return `operation_ended`.",
    "silence_editor_track_select silence_editor_threshold_set silence_threshold_calibrate_from_marks scenes_view_rename playback_pause_skipping_set": "Returns applied status and the current revision. Inspect `analysis_editor_state_read` or the relevant report for the new setting or result.",
    "silence_editor_pause_review": "`review_open` reports whether a cut audition is active. Editing the requested retained duration returns the requested and achieved values. Read the pause list again to inspect protection and retained durations.",
    "silence_editor_pauses_shorten silence_editor_takes_queue": "`mode`, `queue_count`, `changed` and `history_retained` describe the outcome. A committed edit can include a draft-write warning. Shortening uses native history. Queueing adds retained takes to the project’s export queue.",
    "analysis_editor_sidecars_save": "Returns an analysis job receipt. Poll `analysis_job_status_read` for terminal status and outputs. Use `analysis_file_sidecar_inspect` to inspect persisted sections.",
    "export_queue_list export_queue_range_add export_queue_entry_remove export_queue_entry_rename export_queue_entry_revise": "Returns the default `coordinate_space` and current `ranges[]` with IDs, names when set, boundaries and captured `items[]`. A multicam entry reports its own group or assembly clock. Items identify the file, source `from` and `to`, and the kind (`clip`, `still`, `angle`, `audio`, `gap` or `replacement`). Multicam items report output bounds, audio items can identify a stream, and generated spans can omit source bounds. Rename preserves the captured contents. Revise recaptures the current marked edit under the same entry ID and name. Extend requires an enclosing interval on the same clock.",
    "export_editor_project_plan export_editor_project_render": "Starts a live job. Poll `export_editor_job_status_read` for its result. A successful dry run can report `eligible: false` with `reason` and any available structured `issue`, `proposed_ranges`, `alternatives` or `fallback`. An eligible plan or render can include `cut_map.occurrences[]` in playback order, with individual requested, resolved and output ranges and render segment references. Still plans report copied and encoded camera duration, generated still duration, placement ranges and sound actions. Confirm published paths in the job’s `outputs`.",
    "export_editor_boundary_apply": "Returns the native action, applied revision and review details when the current copy-boundary proposal is committed. A retained action can be undone through native history.",
    "export_queue_plan export_queue_render": "Returns a live job receipt with `job_id`, `input_revision`, `state`, `progress` and published `outputs`. Poll `export_editor_job_status_read` with the same project. The terminal result reports planned `destinations` and still plans for applicable queue entries.",
    "project_editor_convert project_editor_resolve_export project_editor_resolve_import": "Returns a live job receipt for `export_editor_job_status_read`. Published `outputs` can include both the interchange file and the linked WAV directory. The terminal result reports conversion warnings or whether Resolve opened the timeline, as applicable.",
    "review_editor_frames_export": "Returns a live job receipt for `export_editor_job_status_read`. A still produces a JPEG. A batch returns its `manifest` path and the written `frames` count, plus `unavailable` for multicam samples where an angle has no picture.",
    "silence_file_shorten project_file_create project_file_edit still_file_project_create still_file_placement_insert still_file_picture_replace timeline_file_gap_insert still_file_placement_update still_file_placement_remove still_file_asset_relink still_file_placements_list timeline_file_clips_space transcript_file_job_run transcript_file_provider_capabilities_read transcript_file_tracks_list transcript_file_job_prepare transcript_file_job_status_read transcript_file_job_cancel transcript_file_job_retry transcript_file_attachment_import transcript_file_attachment_inspect transcript_file_attachment_bind transcript_file_attachment_detach transcript_file_words_read transcript_file_words_search transcript_file_occurrences_locate transcript_file_takes_compare transcript_file_edits_suggest transcript_file_words_correct transcript_file_selection_resolve transcript_file_script_align transcript_file_edit_plan transcript_file_edit_apply transcript_file_excerpt_queue transcript_file_export": "Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.",
    "transcript_editor_attachments_list": "Returns paged attachment IDs, result identities, binding counts and asset status.",
    "transcript_editor_words_read transcript_editor_words_search transcript_editor_occurrences_locate transcript_editor_attachment_tracks_list transcript_editor_speakers_list transcript_editor_word_evidence_read transcript_editor_track_activity_read transcript_editor_takes_compare transcript_editor_edits_suggest transcript_editor_word_candidates_list transcript_editor_authored_changes_list transcript_editor_bindings_list transcript_editor_script_align transcript_editor_script_candidates_list transcript_editor_script_qualifiers_list transcript_tracks_list transcript_editor_jobs_list": "Returns a page of items with its total and continuation offset when more items are available.",
    "transcript_editor_coverage_read": "Returns availability and gaps. Source and group coverage also return paged track status.",
    "transcript_editor_occurrence_seek": "Returns the resolved occurrence.",
    "transcript_editor_selection_resolve transcript_editor_selection_mark": "Returns the resolved selection.",
    "transcript_editor_edit_plan": "Returns the plan ID, resolved boundaries, selections, durations, affected speech and any tier assessment.",
    "transcript_editor_edit_apply": "Returns the native history action, whether the edit changed the timeline and the resulting transcript revision.",
    "transcript_editor_excerpt_queue": "Returns the captured excerpt’s queue ID.",
    "transcript_editor_plan_discard": "Confirms the plan was discarded.",
    "transcript_editor_words_correct": "Returns the authored record ID and resulting transcript revision.",
    "transcript_editor_excerpt_save": "Returns an output job receipt for the editable excerpt.",
    "transcript_editor_attachment_import": "Returns attachment and result IDs, replacement status, binding count and revision.",
    "transcript_editor_attachment_bind": "Returns the affected attachment and result IDs and resulting transcript revision.",
    "transcript_editor_attachment_detach": "Returns the removed attachment and result IDs and resulting transcript revision.",
    "transcript_editor_attachment_export": "Returns an output job receipt. Omit the attachment to export project-wide dialogue.",
    "transcript_provider_capabilities_read": "Returns the provider capability document.",
    "transcript_editor_job_start": "Returns the durable job ID and current state.",
    "transcript_editor_job_status_read": "Returns job state, attachment state, warning count and paged track progress.",
    "transcript_editor_job_warnings_list": "Returns job state and paged warnings.",
    "transcript_editor_job_cancel": "Returns the current cancellation state.",
    "transcript_editor_job_retry": "Returns the durable job ID.",
    "transcript_editor_job_reconcile": "Returns the job and attachment IDs and the current state.",
    "export_file_clips_join": "Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. A render plan that generates gaps reports `generated_still_duration` as an exact rational object alongside `copied_camera_duration` and `encoded_camera_duration`. A cut map retains each ordered occurrence even where multiple uses share a render segment. Use `file_job_result_read` for large payloads.",
    "export_editor_job_status_read export_editor_job_cancel": "Returns `state`, `progress`, `input_revision` and published `outputs`. After cancellation, poll until terminal. Read `result` or `error`; a failed batch can already have published files.",
    "sequence_source_soundtrack_replace": "A sequence needs `clip_id`, `replacement` and an `output` movie. Returns the applied source-audio replacement and output path.",
    "file_job_status_read file_job_cancel": "Returns `job_id` and `state`. For scene scans, refreshes, and transcript session staging, `progress_event` contains the latest available CLI event. Scene events include durable coverage when it has been saved. Terminal results include `exit_code` and `result_bytes`. Small output is available as `result` for JSON or `output_text` for text. Poll a cancelling job until its terminal state.",
    "file_job_result_read": "Returns a base64 byte page, `next_offset`, `result_bytes` and `done`. Decode each page, concatenate the bytes, then parse the CLI output.",
}
RESULTS = {name: description for names, description in RESULT_GROUPS.items() for name in names.split()}

ACTION_ARGUMENTS = {
    "multicam_switch_edit": [
        ("move, apply_suggestion", "existing switch time and new group time in to"),
        ("angle", "existing time and angle ID"), ("audio", "existing time, source and stream"),
        ("delete, default_audio", "existing switch time"),
    ],
    "multicam_source_edit": [
        ("rename, offset, relink", "source ID and respectively name, offset, or absolute path"),
        ("move", "source and direction (-1 or 1)"),
        ("nudge", "source and direction (-1 or 1), plus optional group time"),
        ("microphone", "source and optional stream. Omit stream to clear the assignment"),
        ("add_recording", "angle_id, absolute path and group_start"),
    ],
    "multicam_selection_set": [
        ("switch, occurrence", "switch time, or occurrence index"),
        ("group_range, assembly_range", "from and to in the chosen clock"),
    ],
    "multicam_assembly_edit": [
        ("append", "group from and to"), ("trim", "occurrence with new group from and/or to"),
        ("trim_edge, preview_trim", "occurrence, edge and group time"),
        ("move, remove", "occurrence. Move also needs the insertion slot in before"),
        ("angle_set, angle_clear", "occurrence. Setting an override also needs angle_id"),
        ("apply_edge_suggestion", "one of the suggested edge times in to"),
        ("split_selection, subtract_selection", "select a nonempty group or assembly interval first, then pass its exact space, from and to"),
    ],
    "multicam_preview_control": [
        ("audition", "angle ID"), ("shuttle, step, step_keyframe, step_scene, step_pause", "direction (-1 or 1)"),
        ("scrub_group, scrub_assembly", "time on the selected clock"),
        ("speed, snap", "speed multiplier, or snap target"),
    ],
    "multicam_group_end_set": [("set_end", "new group end time")],
    "silence_editor_pause_review": [("seek, protect, unprotect, preview", "pause ID returned by silence_editor_pauses_list")],
    "workspace_panel_show": [("show_help", "topic")],
    "workspace_layout_set": [
        ("set_zoom, set_waveform_span", "zoom, or span"),
        ("set_large_thumbnails, set_pause_controls", "enabled for thumbnails, visible for pause controls"),
        ("set_inspector", "optional section and visible"), ("set_scroll", "surface and fraction"),
        ("set_transcript", "visible"),
        ("set_track_label_width, set_timeline_height, set_inspector_width", "points"),
    ],
}


def code(value):
    # Literals in schemas are JSON-compatible scalars and identifiers.
    literal = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return "`" + literal.replace("|", "\\|") + "`"


def describe(schema):
    """Describe a field without dropping unions or constraints."""
    if "oneOf" in schema or "anyOf" in schema:
        alternatives = schema.get("oneOf", schema.get("anyOf"))
        shape = " or ".join(describe(option) for option in alternatives)
    elif "enum" in schema:
        shape = " / ".join(code(x) for x in schema["enum"])
    elif "const" in schema:
        shape = code(schema["const"])
    else:
        shape = schema.get("type", "JSON")
        if isinstance(shape, list):
            shape = " or ".join(shape)
        if shape == "array":
            shape = "array of " + describe(schema.get("items", {}))
        if shape == "object" and isinstance(schema.get("additionalProperties"), dict):
            shape = "object with values of type " + describe(schema["additionalProperties"])
    limits = []
    for key, label in [
        ("minimum", "minimum"), ("maximum", "maximum"),
        ("exclusiveMinimum", "greater than"), ("exclusiveMaximum", "less than"),
        ("minItems", "minimum items"), ("maxItems", "maximum items"),
        ("minLength", "minimum length"), ("maxLength", "maximum length"),
        ("default", "default"), ("format", "format"), ("pattern", "pattern"),
    ]:
        if key in schema:
            limits.append(f"{label} {code(schema[key])}")
    return ", ".join([shape, *limits])


def fields(properties, required, prefix=""):
    for key, schema in properties.items():
        path = prefix + key
        presence = "required" if key in required else "optional"
        description = " ".join(schema.get("description", "").split()).replace("|", "\\|")
        yield f"| {code(path)} | {presence} | {describe(schema)} | {description} |"
        nested = schema.get("items", {}) if schema.get("type") == "array" else schema
        for option in nested.get("oneOf", nested.get("anyOf", [])):
            if option.get("properties"):
                nested_prefix = path + ("[]" if nested is not schema else "")
                label = option.get("description", "object variant")
                label = " ".join(label.split()).replace("|", "\\|")
                yield f"| {code(nested_prefix)} | when using this variant | {describe(option)} | {label} |"
                yield from fields(option["properties"], option.get("required", []), nested_prefix + ".")
        if nested.get("properties"):
            nested_prefix = path + ("[]." if nested is not schema else ".")
            yield from fields(nested["properties"], nested.get("required", []), nested_prefix)


def render():
    files = sorted(CATALOG.glob("*.json"))
    if not files:
        raise ValueError(f"No tool catalogs in {CATALOG}")
    by_group = []
    seen = set()
    for catalog in files:
        tools = sorted(json.loads(catalog.read_text()), key=lambda tool: tool["name"])
        for tool in tools:
            name = tool["name"]
            if name in seen:
                raise ValueError(f"Duplicate tool name {name} in {catalog}")
            seen.add(name)
        by_group.append((GROUPS.get(catalog.stem, catalog.stem.replace("_", " ").title()), tools))

    out = [
        "# MPCut MCP tool reference", "",
        "This reference describes the inputs advertised by the bundled stdio helper. "
        "The connected host can retrieve the complete JSON Schemas through `tools/list`. "
        "Live tool calls use the running app and its local-control setting. The "
        "`--files-only` helper exposes saved-file tools through a private CLI worker. Results bound to a live project "
        "carry the `project_handle` and the current or applied revision. Starting a saved-file job returns "
        "a receipt with a `job_id`. Inspect `isError` first. MPCut domain errors carry a code and message "
        "in `structuredContent`. "
        "Invalid requests can also return an MCP protocol or SDK validation error. "
        "[Setup, clocks, history and recovery](MCP-AGENT-GUIDE.md)", "",
        f"**{len(seen)} tools.**", "",
    ]
    for group, tools in by_group:
        out += [f"## {group}", ""]
        for tool in tools:
            out += [f"### {code(tool['name'])}", "", tool["description"].strip(), ""]
            name = tool["name"]
            if name in RESULTS:
                result = RESULTS[name]
            elif group == GROUPS["file"] and not name.startswith("file_job_"):
                result = ("Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. "
                          "Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.")
            else:
                result = RESULTS[name]
            out += [result, ""]
            if name in ACTION_ARGUMENTS and "allOf" not in tool["inputSchema"]:
                out += ["| Action | Additional inputs or prerequisites |", "| --- | --- |"]
                for actions, inputs in ACTION_ARGUMENTS[name]:
                    names = ", ".join(code(x) for x in actions.split(", "))
                    out.append(f"| {names} | {inputs} |")
                out.append("")
            schema = tool["inputSchema"]
            if schema.get("properties"):
                out += ["| Argument | Presence | Values | Meaning |", "| --- | --- | --- | --- |"]
                out += fields(schema["properties"], schema.get("required", []))
                out.append("")
            else:
                out += ["Pass an empty arguments object.", ""]
            special = {k: v for k, v in schema.items()
                       if k not in {"type", "properties", "required", "additionalProperties", "description", "$schema"}}
            rules = special.get("allOf", [])
            if rules and all("const" in r.get("if", {}).get("properties", {}).get("action", {})
                             and set(r.get("then", {})) == {"required"} for r in rules):
                out += ["| Action | Additional required arguments |", "| --- | --- |"]
                for rule in rules:
                    action = rule["if"]["properties"]["action"]["const"]
                    required = ", ".join(code(key) for key in rule["then"]["required"])
                    out.append(f"| {code(action)} | {required} |")
                out.append("")
                del special["allOf"]
            if special:
                out += ["Additional schema rules", "", "```json", json.dumps(special, indent=2), "```", ""]
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if the bundled reference is stale")
    args = parser.parse_args()
    expected = render()
    if args.check:
        if not REFERENCE.exists() or REFERENCE.read_text() != expected:
            sys.exit("MCP tool reference is stale. Run python3 scripts/mcp-reference.py.")
    else:
        REFERENCE.write_text(expected)


if __name__ == "__main__":
    main()
