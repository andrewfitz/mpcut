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
    "multicam": "Multicam",
    "presentation": "Window layout and monitoring",
    "review": "Inline picture review",
    "analysis": "Live analysis",
    "outputs": "Live exports",
    "file": "File tools and jobs",
}

# Supplement the advertised input schemas with outcome semantics shared by each
# native command family. A new tool needs a documented return contract.
RESULT_GROUPS = {
    "list_projects": "`projects[]` supplies each window’s opaque `project` handle, name, kind, dirty flag and revision. A saved project includes `path`.",
    "get_editor_state": "State includes `busy`, `modal`, selection, playhead, snapping and `historyLimit`. Use `offset` and `total` to page `clips[]` or `occurrences[]` at a pinned revision. A sequence row identifies an occurrence by `id` and provides `sequenceFrom`, `sequenceTo`, `sourceFrom` and `sourceTo`. A multicam row identifies it by zero-based `index` and provides bounds in assembly and group time.",
    "list_drafts": "`drafts[]` contains recoverable paths and modification times.",
    "get_preferences set_preference": "Returns current preference values. Changes apply app-wide. Lowering the history limit can trim retained steps immediately.",
    "new_project open_project recover_project add_media save_project focus_project show_history set_video_monitor multicam_setup dismiss_notice": "Returns `project`, `revision`, `kind`, `dirty`, `path`, `setupPending` and `monitorVisible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.",
    "close_project": "`closed` reports whether the window closed. A dirty project requires a `changes` decision. Saving an untitled project also requires `path`.",
    "get_multicam_setup": "`sources[]` identifies pending source IDs, paths, video presence and available audio streams. `adding` distinguishes extending an existing project from initial setup.",
    "get_presentation set_presentation": "Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points.",
    "get_history undo redo restore_history": "`actions`, `cursor`, `historyToken` and `limit` describe the retained branch. Index zero is the state before the first retained action. A restore needs the index and token from one read. Refresh after a history change.",
    "split_at": "Reports applied `boundary` in the requested clock, `left` and `right` occurrence references and `historyRetained`. Sequence results include `sourceTime` and `sequenceTime`. Multicam results include `groupTime`. Use the returned `revision` with the next edit.",
    "seek set_playback": "Returns resulting transport and editor state. Ordinary editors include `playheadSeconds`, `playing`, `rate` and selection when present. Multicam transport includes `space`, `time`, `groupTime` and the current occurrence during assembly preview.",
    "sequence_control": "Returns resulting editor state with `revision`, or a command-specific result such as `action: Apply CSV` and `changed`. A trim preview reports the `trimPreview` token and its proposed `sourceTime`.",
    "set_camera_at": "`angle`, `time` and `until` identify the actual group interval affected. Repeated assembly uses share that switch. The result reports `changed` and `historyRetained`.",
    "get_multicam": "Returns the chosen page of sources, switches or suggestions, group range, audio policy, `total` and revision. A camera source reports its displayed `number`. Sources report availability and indexing state, with duration when known.",
    "review_frame": "Returns a JPEG image block in MCP `content` and decoded-frame metadata in `structuredContent`, including `sourceTime`, `duration`, `width` and `height`. A multicam result identifies the requested or active clock, timestamp, group time and camera. An image-capable host can inspect the picture directly.",
    "multicam_switch multicam_audio": "Reports `revision`, `changed` and `historyRetained`. A committed edit reports its native action and can carry a draft-write warning.",
    "multicam_source": "Reports `revision`, `changed` and `historyRetained`. Nudge reports `groupTime` and the new `offset`. Relink identifies the source. A committed edit reports its native action and can carry a draft-write warning.",
    "multicam_group": "Reports the actual `groupTo`, `revision`, `changed` and `historyRetained`. A committed edit reports its native action and can carry a draft-write warning.",
    "multicam_assembly": "Reports `revision`, `changed` and `historyRetained`. `trim_edge` and `preview_trim` report an exact group `boundary`. A committed edit reports its native action and can carry a draft-write warning.",
    "multicam_select": "Reports selection and current preview position. Assembly selection uses the occurrence or bounds from the current revision.",
    "multicam_preview": "Reports the current clock, `time`, `groupTime`, `playing`, `rate`, forward `speed`, `auditioning` and, in assembly preview, the current `occurrence`.",
    "analysis_state": "Returns scan settings, readiness, progress where available, status and issues. Page `sources.items` for source IDs, index availability, and absolute audio stream indices. Sequence state also identifies the source at the playhead.",
    "list_pauses": "Returns `items`, `offset` and `total`. Use returned pause IDs for reviews. Read each pause’s clock, occurrence where applicable, and protected/removal fields. A multicam assembly selection limits results to its occurrences.",
    "list_scenes": "Returns `items`, `offset` and `total`. Each item pairs source-clock scene boundaries with its view ID and label.",
    "get_waveform_peaks": "Returns source ID, stream, `fromSeconds`, `toSeconds`, source clock, `peaks` and `binsPerSecond`.",
    "get_waveform": "Returns signed `low` and `high` arrays for the specified column count, source clock, stream and actual time window in seconds.",
    "scan_analysis": "Returns an analysis receipt with `job`, `kind`, `inputRevision` and `status`. Poll `analysis_job_status` for that receipt. A scan already running in the editor returns `origin: editor` and can be followed through `analysis_state`.",
    "cancel_analysis": "Returns `status: idle` or `status: cancel_requested` for the selected scan family. For a specific MCP-owned job, use `analysis_job_cancel` with its receipt.",
    "analysis_job_status analysis_job_cancel": "Reads the project-bound analysis receipt with `job`, `inputRevision`, `kind`, `status` and progress when available. Poll until succeeded, failed or cancelled. Sidecar saves report published outputs even when interrupted.",
    "get_native_operations": "`operations[]` identifies active native workers by `nativeOperation`, kind, label, state and progress when available. Supply the project for a project-owned worker. Omit it for an unowned project conversion.",
    "cancel_native_operation": "`cancellationRequested` acknowledges the request for the supplied native operation ID. Read active operations again. An operation that ended can return `operation_ended`.",
    "configure_silence use_room_tone rename_view set_skip_pauses": "Returns applied status and the current revision. Inspect `analysis_state` or the relevant report for the new setting or result.",
    "review_pause": "`reviewOpen` reports whether the cut audition is active. Read the pause list again to inspect protection state.",
    "apply_pauses": "`mode`, `queueCount`, `changed` and `historyRetained` describe the outcome. A committed edit can include a draft-write warning. Shortening uses native history. Queueing adds retained takes to the project’s export queue.",
    "save_analysis_sidecars": "Returns an analysis job receipt. Poll `analysis_job_status` for terminal status and outputs. Use `file_sidecar` with `status` to inspect persisted sections.",
    "get_export_queue add_export_range remove_export_range": "Returns current `ranges[]` with IDs and boundaries, and `coordinateSpace`. Mark a valid range before adding an entry.",
    "render_project": "Starts a live job. Poll `live_job_status` for its result. A successful dry run can report `eligible: false` with `reason` and any available structured `issue`, `proposedRanges`, `alternatives` or `fallback`. An eligible render reports its plan. Confirm published paths in the job’s `outputs`.",
    "apply_export_review": "Returns the native action, applied revision and review details when the current copy-boundary proposal is committed. A retained action can be undone through native history.",
    "export_queue": "Returns a live job receipt with `job`, `inputRevision`, `state`, `progress` and published `outputs`. Poll `live_job_status` with the same project. The terminal result reports planned `destinations`.",
    "convert_live_project send_live_to_resolve": "Returns a live job receipt for `live_job_status`. Published `outputs` can include both the interchange file and the linked WAV directory. The terminal result reports conversion warnings or whether Resolve opened the timeline, as applicable.",
    "export_review_frames": "Returns a live job receipt for `live_job_status`. A still produces a JPEG. A batch returns its `manifest` path and the written `frames` count, plus `unavailable` for multicam samples where an angle has no picture.",
    "live_job_status cancel_live_job": "Returns `state`, `progress`, `inputRevision` and published `outputs`. After cancellation, poll until terminal. Read `result` or `error`; a failed batch can already have published files.",
    "replace_live_audio": "A sequence needs `clip`, `replacement` and an `output` movie. Returns the applied source-audio replacement and output path. A multicam project accepts an existing `source` plus `stream`, or external `replacement`, and returns the program-audio edit.",
    "file_job_status file_job_cancel": "Returns `job_id` and `state`. Terminal results include `exit_code` and `result_bytes`. Small output is available as `result` for JSON or `output_text` for text. Poll a cancelling job until its terminal state.",
    "file_job_result": "Returns a base64 byte page, `next_offset`, `result_bytes` and `done`. Decode each page, concatenate the bytes, then parse the CLI output.",
}
RESULTS = {name: description for names, description in RESULT_GROUPS.items() for name in names.split()}

ACTION_ARGUMENTS = {
    "multicam_switch": [
        ("move, apply_suggestion", "existing switch time and new group time in to"),
        ("angle", "existing time and angle ID"), ("audio", "existing time, source and stream"),
        ("delete, default_audio", "existing switch time"),
    ],
    "multicam_source": [
        ("rename, offset, relink", "source ID and respectively name, offset, or absolute path"),
        ("move", "source and direction (-1 or 1)"),
        ("nudge", "source and direction (-1 or 1), plus optional group time"),
        ("microphone", "source and optional stream. Omit stream to clear the assignment"),
    ],
    "multicam_select": [
        ("switch, occurrence", "switch time, or occurrence index"),
        ("group_range, assembly_range", "from and to in the chosen clock"),
    ],
    "multicam_assembly": [
        ("append", "group from and to"), ("trim", "occurrence with new group from and/or to"),
        ("trim_edge, preview_trim", "occurrence, edge and group time"),
        ("move, remove", "occurrence. Move also needs the insertion slot in before"),
        ("split_selection, subtract_selection", "select a nonempty group or assembly interval first, then pass its exact space, from and to"),
    ],
    "multicam_preview": [
        ("audition", "angle ID"), ("shuttle, step, step_keyframe, step_scene, step_pause", "direction (-1 or 1)"),
        ("scrub_group, scrub_assembly", "time on the selected clock"),
        ("speed, snap", "speed multiplier, or snap target"),
    ],
    "multicam_group": [("set_end", "new group end time")],
    "multicam_setup": [("confirm", "optional sourceOrder must contain every pending ID once. Opening and audio apply during initial setup")],
    "review_pause": [("seek, protect, unprotect, preview", "pause ID returned by list_pauses")],
    "set_presentation": [
        ("setZoom, setWaveformSpan", "zoom, or span"),
        ("setLargeThumbnails, setPauseControls", "enabled for thumbnails, visible for pause controls"),
        ("setInspector", "optional section and visible"), ("setScroll", "surface and fraction"),
        ("setTrackLabelWidth, setTimelineHeight, setInspectorWidth", "points"),
        ("showHelp", "topic"),
        ("revealTime", "surface and rational time in that surface’s clock"),
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
        "Tool calls use the running app and its local-control setting. Successful project-bound "
        "results carry the project handle and the current or applied revision. Inspect `isError` "
        "first. MPCut domain errors carry a code and message in `structuredContent`. "
        "Invalid requests can also return an MCP protocol or SDK validation error. "
        "[Setup, clocks, history and recovery](MCP-AGENT-GUIDE.md)", "",
        f"**{len(seen)} tools.**", "",
    ]
    for group, tools in by_group:
        out += [f"## {group}", ""]
        for tool in tools:
            out += [f"### {code(tool['name'])}", "", tool["description"].strip(), ""]
            name = tool["name"]
            if name.startswith("file_") and not name.startswith("file_job_"):
                result = ("Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. "
                          "Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.")
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
