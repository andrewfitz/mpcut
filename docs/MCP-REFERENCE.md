# MPCut MCP tool reference

This reference describes the inputs advertised by the bundled stdio helper. The connected host can retrieve the complete JSON Schemas through `tools/list`. Live tool calls use the running app and its local-control setting. The `--files-only` helper exposes saved-file tools through a private CLI worker. Results bound to a live project carry the `project_handle` and the current or applied revision. Starting a saved-file job returns a receipt with a `job_id`. Inspect `isError` first. MPCut domain errors carry a code and message in `structuredContent`. Invalid requests can also return an MCP protocol or SDK validation error. [Setup, clocks, history and recovery](MCP-AGENT-GUIDE.md)

**325 tools.**

## Live analysis

### `analysis_editor_sidecars_save`

Save completed analysis to the configured sidecar location for each project source. Poll the returned job with analysis_job_status_read.

Returns an analysis job receipt. Poll `analysis_job_status_read` for terminal status and outputs. Use `analysis_file_sidecar_inspect` to inspect persisted sections.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |

### `analysis_editor_state_read`

Read scene and silence scan status, scene coverage, current scene selection, media refresh status and issues, settings, and a bounded page of source IDs and absolute audio stream indices.

Returns scan settings, readiness, progress and issues. `scene_coverage` shows source-clock progress by clip or source ID. Use `selected_scene_clip` or `selected_scene_camera` for the current selection. `media_refresh_progress` and `media_refresh_issues` describe the refresh and sources that need attention. Page `sources.items` for source IDs, index availability and audio stream indices.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `500` |  |

### `analysis_job_cancel`

Request cancellation of this specific MCP-started scan, sidecar save or media refresh. Poll analysis_job_status_read for its terminal state.

Reads the project-bound analysis receipt with `job_id`, `input_revision`, `kind`, `status` and progress when available. Poll until succeeded, failed or cancelled. Scene receipts report `coverage` by clip or source ID, including decoded, confirmed and durable positions. A cancelled scene job can leave resumable coverage. See persistence errors and the durable position to determine what reached disk. Sidecar saves report published outputs even when interrupted.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `job_id` | required | string |  |

### `analysis_job_status_read`

Read a retained scene, silence, sidecar save or media refresh job. Scene jobs include requested, decoded, confirmed and durable source coverage as available.

Reads the project-bound analysis receipt with `job_id`, `input_revision`, `kind`, `status` and progress when available. Poll until succeeded, failed or cancelled. Scene receipts report `coverage` by clip or source ID, including decoded, confirmed and durable positions. A cancelled scene job can leave resumable coverage. See persistence errors and the durable position to determine what reached disk. Sidecar saves report published outputs even when interrupted.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `job_id` | required | string |  |

### `playback_pause_skipping_set`

Enable or disable native skipping of detected pauses during playback.

Returns applied status and the current revision. Inspect `analysis_editor_state_read` or the relevant report for the new setting or result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |
| `enabled` | required | boolean |  |

### `project_editor_media_refresh`

Check indexed project recordings and refresh changed sources using the native editor. Poll analysis_job_status_read for updated sources and review issues.

Returns an analysis job receipt. Poll `analysis_job_status_read` for per-source refresh results, preserved analysis, review issues and any persistence errors. The receipt includes `media` rows with the shared project media status and current uses.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |
| `deep` | optional | boolean | Verify stream content even when the file stamp is unchanged. |

### `scenes_editor_boundaries_list`

Read exact source-relative scene boundaries and recurring views for a source or a sequence clip.

Returns `items`, `offset` and `total`. Each item pairs source-clock scene boundaries with its view ID and label. View IDs for a range-local scan belong to that report. Archived results include `stale`, `stale_reason` and their original `source_stamp`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `source_id` | optional | string |  |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `500` |  |
| `clip_id` | optional | string, format `uuid` | Sequence occurrence ID. Read the report that covers the clip’s current source interval. |
| `include_stale` | optional | boolean | Prefer the archived report from a prior source generation when available. Archived rows carry their stale reason and original source stamp. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "source_id"
      ]
    },
    {
      "required": [
        "clip_id"
      ]
    }
  ]
}
```

### `scenes_editor_scan`

Scan scenes in the open editor. Select the whole project or a source using scope and target.

Returns an analysis receipt with `job_id`, `kind`, `input_revision` and `status`. Poll `analysis_job_status_read` for that receipt. Compatible scene requests share a worker and return separate receipts. A selected reuse request can join an all-source reuse scan for the same recording and completes when that recording’s report is published. Scene receipts identify the native worker with `worker_origin`. An existing GUI silence scan can be followed through `analysis_editor_state_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |
| `scope` | optional | `all` / `selected` | Scene scope. All scans every referenced recording. Selected scans a sequence clip’s source interval or a multicam recording. |
| `target` | optional | string, minimum length `1` | Clip UUID from project_editor_state_read or camera ID from multicam_state_read. Applies to selected scope and defaults to the current editor selection. |
| `policy` | optional | `reuse` / `resume` / `restart` | Reuse returns current results or resumes unfinished analysis. Resume prefers a saved replacement attempt. Restart begins a replacement identified by operation_id. |

### `scenes_editor_scan_cancel`

Cancel the active scene scan for the target project.

Returns `status: idle` or `status: cancel_requested` for the selected scan family. For a specific MCP-owned job, use `analysis_job_cancel` with its receipt.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |

### `scenes_view_rename`

Set the name for every matching view in a full-source analysis. Supply the report_id from the source boundaries to guard the reviewed view. An empty name restores the default.

Returns applied status and the current revision. Inspect `analysis_editor_state_read` or the relevant report for the new setting or result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |
| `source_id` | required | string |  |
| `report_id` | required | string, pattern `^[a-f0-9]{64}$` | Report ID returned by scenes_editor_boundaries_list with source_id. |
| `view` | required | integer, minimum `1` |  |
| `name` | required | string, maximum length `1024` |  |

### `silence_editor_pause_review`

Seek, preview, protect or unprotect a pause by its silence_editor_pauses_list ID. Multicam protection applies to the group-time pause across repeated occurrences. Protecting the auditioned multicam pause closes its review. Done closes the review. Use set_retained with a nonnegative total duration in seconds, or reset_retained, for one detected pause in its occurrence. next_cut and keep_and_advance operate on an open detected-pause review.

`review_open` reports whether a cut audition is active. Setting a retained duration returns the requested and achieved values. Resetting it can combine the pause with its neighbors. When the original pause disappears, the response omits the duration fields. Read the pause list again for the updated intervals.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `seek`, `protect`, `unprotect`, `preview` | pause ID returned by silence_editor_pauses_list |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |
| `pause` | optional | string |  |
| `action` | required | `seek` / `preview` / `protect` / `unprotect` / `set_retained` / `reset_retained` / `next_cut` / `keep_and_advance` / `done` |  |
| `retained_seconds` | optional | number, minimum `0` |  |

### `silence_editor_pauses_list`

Read detected pauses, proposed removals, clock and protection state from the current sequence or multicam assembly. Use the returned pause ID for review.

Returns `items`, `offset` and `total`. Use returned pause IDs for reviews. Read each pause’s clock, occurrence, protection and removal. An individually adjusted pause can report requested and achieved retained seconds. A multicam assembly selection limits results to its occurrences.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `500` |  |

### `silence_editor_pauses_shorten`

Shorten the reviewed pauses on the open timeline, respecting protection and retained padding.

`mode`, `queue_count`, `changed` and `history_retained` describe the outcome. A committed edit can include a draft-write warning. Shortening uses native history. Queueing adds retained takes to the project’s export queue.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |

### `silence_editor_scan`

Scan the open editor for pauses using its current silence preferences.

Returns an analysis receipt with `job_id`, `kind`, `input_revision` and `status`. Poll `analysis_job_status_read` for that receipt. Compatible scene requests share a worker and return separate receipts. A selected reuse request can join an all-source reuse scan for the same recording and completes when that recording’s report is published. Scene receipts identify the native worker with `worker_origin`. An existing GUI silence scan can be followed through `analysis_editor_state_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |

### `silence_editor_scan_cancel`

Cancel the active pause scan for the target project.

Returns `status: idle` or `status: cancel_requested` for the selected scan family. For a specific MCP-owned job, use `analysis_job_cancel` with its receipt.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |

### `silence_editor_take_boundary_edit`

Add a divider inside a take, resolving to an edit boundary, or remove a manual divider by the exact candidate start. Queueing uses these dividers without trimming media.

Returns the updated take candidate count. Read the candidates again before queueing. Boundary edits split or join take candidates in sequence or assembly time.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |
| `action` | required | `add` / `remove` |  |
| `position` | required | string | Exact sequence or assembly time as rational seconds or timecode. |

### `silence_editor_take_candidates_list`

List take candidates after detected removals and manual dividers. Each item has an exact range and a manual_start indicator. The response clock is sequence or assembly.

Returns paged take candidates with exact ranges in the returned `clock` and `manual_start` for a take introduced by a manual split.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `500` |  |

### `silence_editor_takes_queue`

Add the audible ranges between reviewed pauses to the native export queue.

`mode`, `queue_count`, `changed` and `history_retained` describe the outcome. A committed edit can include a draft-write warning. Shortening uses native history. Queueing adds retained takes to the project’s export queue.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |

### `silence_editor_threshold_set`

Set the silence threshold in dBFS. A null threshold selects automatic detection. A sequence threshold applies to the named source or the source at the playhead.

Returns applied status and the current revision. Inspect `analysis_editor_state_read` or the relevant report for the new setting or result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |
| `source_id` | optional | string |  |
| `silence_threshold_db` | required | number or null, minimum `-120`, maximum `0` |  |

### `silence_editor_track_select`

Select the zero-based analysis track ordinal in a sequence.

Returns applied status and the current revision. Inspect `analysis_editor_state_read` or the relevant report for the new setting or result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |
| `track_ordinal` | required | integer, minimum `0` |  |

### `silence_threshold_calibrate_from_marks`

Calibrate manual thresholds from measured audio in the marked sequence, group, or assembly range and clear the consumed marks.

Returns applied status and the current revision. Inspect `analysis_editor_state_read` or the relevant report for the new setting or result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |

### `timeline_editor_join_preview`

Open a short replayable audition around an existing join. Specify one of before_clip_id for a sequence item, before_occurrence for a multicam assembly item, or switch_time for a saved multicam switch. Close it with silence_editor_pause_review action done.

Returns the join’s exact `position`, `clock` and `review_open`. Target an incoming sequence or assembly join by its following occurrence, or a multicam group join by switch time. Close the review with `silence_editor_pause_review` using action `done`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |
| `before_clip_id` | optional | string | Sequence timeline item ID immediately after the join. |
| `before_occurrence` | optional | integer, minimum `1` | Zero-based multicam assembly index immediately after the join. |
| `switch_time` | optional | string | Exact group time of a saved multicam switch. |

### `waveform_editor_envelope_read`

Read signed minimum and maximum sample amplitudes for equal-width source-time bins using the same envelope decoder as the GUI and CLI. Use source IDs and absolute stream indices from analysis_editor_state_read.

Returns signed `low` and `high` arrays for the specified column count, source clock, stream and actual time window in seconds.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `source_id` | required | string |  |
| `audio_stream_index` | required | integer, minimum `0` |  |
| `columns` | optional | integer, minimum `1`, maximum `2048` |  |
| `source_from` | optional | string |  |
| `source_to` | optional | string |  |

### `waveform_editor_peaks_read`

Read linear-amplitude peak bins from a completed native waveform on the selected sequence track or a routed multicam track. Unobserved bins are null. Stream uses an absolute stream index. Use waveform_editor_envelope_read for a signed envelope or another indexed stream.

Returns source ID, stream, `source_from_seconds`, `source_to_seconds`, source clock, `peaks` and `bins_per_second`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `source_id` | required | string |  |
| `audio_stream_index` | required | integer, minimum `0` |  |
| `columns` | optional | integer, minimum `1`, maximum `2048` |  |
| `source_from` | optional | string |  |
| `source_to` | optional | string |  |

## Cache

### `analysis_file_cache_clear`

Remove only the confirmed cache copies using tokens from a preview with the same folder, project and location. A changed selection requires a fresh preview. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. The completed result reports `cleared`, `cleared_sources`, `skipped` and `reclaimed_bytes`. If the selection changed, preview again before confirming a new request.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry identical arguments. |
| `folder` | required | string, pattern `^/` | Absolute path to the folder to search recursively. |
| `project_path` | optional | string, pattern `^/` | Optional saved project whose media and history are protected. |
| `location` | optional | `media` / `project` / `disk` | Limit results to this cache location. |
| `clear_tokens` | required | array of string, pattern `^[0-9a-f]{64}$`, minimum items `1`, maximum items `500` |  |
| `confirm` | required | `true` | Confirm removal of the selected cache copies. |

### `analysis_file_cache_preview`

Discover cutcaches within an explicit folder. Review cache details, reclaimable bytes and clear tokens before selecting copies. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. The completed result lists scoped copies with `path`, `source`, `folder`, `location`, reclaimable bytes and storage details. Use the eligible copies’ `clear_token` values with the same scope to clear selected copies.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry identical arguments. |
| `folder` | required | string, pattern `^/` | Absolute path to the folder to search recursively. |
| `project_path` | optional | string, pattern `^/` | Optional saved project whose media and history are protected. |
| `location` | optional | `media` / `project` / `disk` | Limit results to this cache location. |

### `analysis_file_cache_settings_read`

Read where MPCut writes new cutcaches and whether the configured shared folder is available. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. The completed result reports `mode`, the configured shared `folder` if any, and `folder_available`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry identical arguments. |

### `analysis_file_cache_settings_set`

Select where MPCut writes new cutcaches. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. The completed result reports `mode`, the configured shared `folder` if any, and `folder_available`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry identical arguments. |
| `mode` | required | `media` / `project` / `disk` |  |
| `folder` | optional | string, pattern `^/` | Optional writable shared folder when selecting disk mode. Omit it to retain the configured folder. |

Additional schema rules

```json
{
  "if": {
    "required": [
      "folder"
    ]
  },
  "then": {
    "properties": {
      "mode": {
        "const": "disk"
      }
    }
  }
}
```

## File tools and jobs

### `analysis_file_sidecar_build`

Build selected analysis sections in the configured sidecar location. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project_path` | optional | string, pattern `^/` | Optional absolute path to a saved project for project-folder cache lookup and storage. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `only` | optional | array of `index` / `scenes` / `audio`, minimum items `1` |  |
| `silence_audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index of the audio to analyze. |
| `silence_threshold_db` | optional | number, minimum `-120`, maximum `0` |  |
| `silence_min_pause_seconds` | optional | number |  |
| `no_sidecar` | optional | boolean |  |
| `only_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |

### `analysis_file_sidecar_inspect`

Inspect the analysis sections available for a recording. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project_path` | optional | string, pattern `^/` | Optional absolute path to a saved project for project-folder cache lookup and storage. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `no_sidecar` | optional | boolean |  |

### `cli_help_read`

Read native help, manual, examples, or the multicam project template. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `topic` | optional | string, minimum length `1` | Canonical CLI help topic, such as silence plan or transcript words search. Omit to list commands. |

### `cli_version_read`

Identify the bundled file CLI build. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. The completed result reports the CLI `version`, Mach-O UUID as `build_id`, `project_schema_versions`, and `detector_capabilities` for the bundled CLI and current host.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |

### `export_file_clips_join`

Join ordered clips into one output and report the occurrence-level cut map when available. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry. Group ranges from one Mix project preserve lane IDs and bindings. Use video-only or remove audio to join a Mix project with other sources.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. A render plan that generates gaps reports `generated_still_duration` as an exact rational object alongside `copied_camera_duration` and `encoded_camera_duration`. A cut map retains each ordered occurrence even where multiple uses share a render segment. Use `file_job_result_read` for large payloads.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `space_clips` | optional | string, minimum length `1` | Set gaps between picture items for this render. Use source for source timing or a nonnegative gap duration in exact rational seconds. Applies to project timelines and ordered ranges from picture files. Saved project documents are preserved. |
| `edit` | optional | object |  |
| `edit.clips` | required | array of object, minimum items `1` |  |
| `edit.clips[].file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.clips[].project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `edit.clips[].from` | optional | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `edit.clips[].from` | when using this variant | object | object variant |
| `edit.clips[].from.numerator` | required | integer |  |
| `edit.clips[].from.denominator` | required | integer, minimum `1` |  |
| `edit.clips[].to` | optional | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `edit.clips[].to` | when using this variant | object | object variant |
| `edit.clips[].to.numerator` | required | integer |  |
| `edit.clips[].to.denominator` | required | integer, minimum `1` |  |
| `edit.clips[].ranges_file` | optional | string, pattern `^/` | Native CSV/JSON ranges file. For file-based exports. |
| `edit.file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `edit.order` | optional | array of integer, minimum `1`, minimum items `1` |  |
| `output` | optional | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index for the requested audio track. |
| `mode` | optional | `copy` / `smart` / `encode` |  |
| `video` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` |  |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` |  |
| `snap` | optional | `exact` / `nearest` |  |
| `dry_run` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `clips_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `order_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Multicam audio delivery. Separate tracks preserve lane order. Downmix renders the lanes into one mono or stereo track. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "edit"
          ]
        },
        {
          "required": [
            "input_file"
          ]
        },
        {
          "required": [
            "clips_file"
          ]
        }
      ]
    },
    {
      "if": {
        "required": [
          "clips_file"
        ]
      },
      "then": {
        "required": [
          "output"
        ]
      }
    }
  ]
}
```

### `export_file_project_render`

Render a saved or inline project. The completed CLI result can include an occurrence-level cut map. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `space_clips` | optional | string, minimum length `1` | Set gaps between picture items for this render. Use source for source timing or a nonnegative gap duration in exact rational seconds. Applies to project timelines and ordered ranges from picture files. Saved project documents are preserved. |
| `require_camera_copy` | optional | boolean | Require zero encoded camera duration when rendering a saved or inline project. |
| `output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index for the requested audio track. |
| `mode` | optional | `copy` / `smart` / `encode` |  |
| `video` | optional | `h264` / `hevc` / `prores` / `jpeg` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` |  |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` / `alac` |  |
| `snap` | optional | `exact` / `nearest` |  |
| `dry_run` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Multicam audio delivery. Separate tracks preserve lane order. Downmix renders the lanes into one mono or stereo track. |
| `still_timing` | optional | `cadence` / `held` | Still picture timing. Held writes one independently decodable sample per visible hold. Cadence uses the authored frame schedule. |
| `container` | optional | `mov` / `mp4` / `m4v` / `mkv` / `m4a` / `mka` / `wav` / `wave` / `caf` / `flac` | Explicit container for a still project export. Match the destination filename extension and selected tracks. |
| `plan_token` | optional | string, minimum length `1` | Token from the approved dry run. Supply project_path and render with the same media, destination and options. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "project_data"
          ]
        }
      ]
    },
    {
      "if": {
        "required": [
          "plan_token"
        ]
      },
      "then": {
        "required": [
          "project_path"
        ],
        "properties": {
          "dry_run": {
            "const": false
          }
        }
      }
    }
  ]
}
```

### `export_file_ranges_join`

Render ordered or repeated ranges of a single recording. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `ranges` | optional | array of object, minimum items `1` |  |
| `ranges[].from` | required | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `ranges[].from` | when using this variant | object | object variant |
| `ranges[].from.numerator` | required | integer |  |
| `ranges[].from.denominator` | required | integer, minimum `1` |  |
| `ranges[].to` | required | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `ranges[].to` | when using this variant | object | object variant |
| `ranges[].to.numerator` | required | integer |  |
| `ranges[].to.denominator` | required | integer, minimum `1` |  |
| `snap` | optional | `exact` / `nearest` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index for the requested audio track. |
| `dry_run` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `ranges_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "ranges"
          ]
        },
        {
          "required": [
            "ranges_file"
          ]
        }
      ]
    }
  ]
}
```

### `export_file_ranges_separate`

Write separate numbered outputs for ranges of one recording. Results include completed outputs on a partial failure. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `output_directory` | optional | string, pattern `^/` | Absolute path to an existing output directory. Each rendered file needs a new name. |
| `ranges` | optional | array of object, minimum items `1` |  |
| `ranges[].from` | required | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `ranges[].from` | when using this variant | object | object variant |
| `ranges[].from.numerator` | required | integer |  |
| `ranges[].from.denominator` | required | integer, minimum `1` |  |
| `ranges[].to` | required | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `ranges[].to` | when using this variant | object | object variant |
| `ranges[].to.numerator` | required | integer |  |
| `ranges[].to.denominator` | required | integer, minimum `1` |  |
| `container` | optional | string, minimum length `1` | Container extension. |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index for the requested audio track. |
| `mode` | optional | `copy` / `smart` / `encode` |  |
| `video` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` |  |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` |  |
| `snap` | optional | `exact` / `nearest` |  |
| `dry_run` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `ranges_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `subfolder` | optional | string, minimum length `1` | Optional single directory name beneath the chosen output directory. Path separators and control characters are forbidden. |
| `base_name` | optional | string, minimum length `1` | Optional single filename prefix. Path separators and control characters are forbidden. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "input_file"
          ]
        },
        {
          "required": [
            "file",
            "output_directory",
            "ranges"
          ]
        },
        {
          "required": [
            "file",
            "output_directory",
            "ranges_file"
          ]
        }
      ]
    }
  ]
}
```

### `export_file_soundtrack_replace`

Write media with a replacement soundtrack. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `space_clips` | optional | string, minimum length `1` | Set gaps between picture items for this render. Use source for source timing or a nonnegative gap duration in exact rational seconds. Applies to project timelines and ordered ranges from picture files. Saved project documents are preserved. |
| `edit` | optional | object | Supply replace_audio for the full edit or for one or more file clips. |
| `edit.clips` | required | array of object, minimum items `1` |  |
| `edit.clips[].file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.clips[].project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `edit.clips[].from` | optional | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `edit.clips[].from` | when using this variant | object | object variant |
| `edit.clips[].from.numerator` | required | integer |  |
| `edit.clips[].from.denominator` | required | integer, minimum `1` |  |
| `edit.clips[].to` | optional | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `edit.clips[].to` | when using this variant | object | object variant |
| `edit.clips[].to.numerator` | required | integer |  |
| `edit.clips[].to.denominator` | required | integer, minimum `1` |  |
| `edit.clips[].ranges_file` | optional | string, pattern `^/` | Native CSV/JSON ranges file. For file-based exports. |
| `edit.clips[].replace_audio` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.clips[].replace_track` | optional | integer, minimum `0` |  |
| `edit.clips[].replacement_stream` | optional | integer, minimum `0` |  |
| `edit.file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `edit.order` | optional | array of integer, minimum `1`, minimum items `1` |  |
| `edit.replace_audio` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.replace_track` | optional | integer, minimum `0` |  |
| `edit.replacement_stream` | optional | integer, minimum `0` |  |
| `output` | optional | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index for the requested audio track. |
| `mode` | optional | `copy` / `smart` / `encode` |  |
| `video` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` |  |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` |  |
| `snap` | optional | `exact` / `nearest` |  |
| `dry_run` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `order_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "edit"
          ]
        },
        {
          "required": [
            "input_file"
          ]
        }
      ]
    }
  ]
}
```

### `file_job_cancel`

Request cancellation through the worker that started the job. Poll status until completion to see any outputs the job already published.

Returns `job_id` and `state`. For scene scans, refreshes, and transcript session staging, `progress_event` contains the latest available CLI event. Scene events include durable coverage when it has been saved. Finished jobs report `exit_code` and whether the payload is still available. Generic retained payloads include `result_bytes`, with small output available as `result` for JSON or `output_text` for text. Tiles ISO delivery can end in `needs_review` with a reviewable project. An interrupted standalone worker may leave `outcome_unknown`. Poll a cancelling job until its terminal state.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `job_id` | required | string, format `uuid` | The job UUID returned when the request was accepted. |

### `file_job_release`

Discard a terminal job's saved result payload while retaining the outcome and operation ID. Repeat safely after collecting all result pages.

Returns the terminal job receipt with `result_available: false`. The operation UUID can still be used to look up or retry the same request while the receipt is retained.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `job_id` | required | string, format `uuid` | The operation UUID used as the job identifier. |

### `file_job_result_read`

Read an exact byte range from the terminal CLI JSON document as base64; concatenate decoded chunks.

Returns a base64 byte page, `next_offset`, `result_bytes` and `done`. Decode each page, concatenate the bytes, then parse the CLI output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `job_id` | required | string, format `uuid` | The job UUID returned when the request was accepted. |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `131072` |  |

### `file_job_status_read`

Get state, native progress and the terminal JSON result. Supply the original operation_id as job_id if the acceptance response was lost. Standalone files-only receipts survive reconnects for seven days after completion or recorded interruption. An outcome_unknown receipt prevents an interrupted operation from running again. Scene scans, refreshes and Tiles delivery can include the latest available progress event. A Tiles ISO delivery job can finish in needs_review with exit code 3 and a reviewable project. For large results, read result_bytes using file_job_result_read.

Returns `job_id` and `state`. For scene scans, refreshes, and transcript session staging, `progress_event` contains the latest available CLI event. Scene events include durable coverage when it has been saved. Finished jobs report `exit_code` and whether the payload is still available. Generic retained payloads include `result_bytes`, with small output available as `result` for JSON or `output_text` for text. Tiles ISO delivery can end in `needs_review` with a reviewable project. An interrupted standalone worker may leave `outcome_unknown`. Poll a cancelling job until its terminal state.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `job_id` | required | string, format `uuid` | The job UUID returned when the request was accepted. |

### `media_file_inspect`

Inspect recording metadata or a bounded window of frames or packets. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `detail` | optional | `metadata` / `frames` / `keyframes` / `audio_packets` |  |
| `source_from` | optional | string, minimum length `1` | Inclusive start in source time. |
| `source_to` | optional | string, minimum length `1` | Exclusive end in source time. |
| `packet_audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index of the audio to analyze. |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index for the requested audio track. |
| `no_sidecar` | optional | boolean |  |

### `project_file_convert`

Convert between editable MPCut, Resolve, Premiere and Final Cut Pro projects. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `destination_format` | optional | `cut` / `resolve` / `premiere` / `fcp` | Destination editor format. Its value must match the output filename extension. |
| `allow_loss` | optional | boolean |  |
| `flatten_multicam` | optional | boolean |  |

### `project_file_create`

Write an editable timeline to a new .cut destination. Operations execute in order.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `request` | required | object |  |
| `request.out_project` | required | string, pattern `^/` |  |
| `request.operations` | required | array of object |  |
| `request.operations[].action` | required | string |  |
| `request.operations[].id` | optional | string, minimum length `1` |  |
| `request.operations[].index` | optional | integer, minimum `0` |  |
| `request.operations[].to_index` | optional | integer, minimum `0` |  |
| `request.operations[].at` | optional | string |  |
| `request.operations[].from` | optional | string |  |
| `request.operations[].to` | optional | string |  |
| `request.operations[].file` | optional | string |  |
| `request.operations[].new_id` | optional | string |  |
| `request.operations[].angle_id` | optional | string |  |
| `request.operations[].name` | optional | string |  |
| `request.operations[].ranges` | optional | array of object or object, minimum items `1` |  |
| `request.operations[].ranges[]` | when using this variant | object | object variant |
| `request.operations[].ranges[].file` | required | string, minimum length `1` |  |
| `request.operations[].ranges[].from` | required | string, minimum length `1` | Exact time in seconds as a decimal, timecode or fraction. |
| `request.operations[].ranges[].to` | required | string, minimum length `1` | Exact time in seconds as a decimal, timecode or fraction. |
| `request.operations[].ranges[]` | when using this variant | object | object variant |
| `request.operations[].ranges[].select_id` | required | string, minimum length `1` |  |
| `request.operations[].path` | optional | string, minimum length `1` | Media path for add_recording or audio_replacement_set, relative to working_directory if needed. |
| `request.operations[].group_start` | optional | string, minimum length `1` | Exact time in the multicam group for the start of the added recording. |
| `request.operations[].mode` | optional | `fixed` / `follow` / `none` / `mix` / `replace` |  |
| `request.operations[].source_id` | optional | string, minimum length `1` |  |
| `request.operations[].audio_stream_index` | optional | integer, minimum `0` |  |
| `request.operations[].lanes` | optional | array of object |  |
| `request.operations[].lanes[].id` | required | string, minimum length `1` |  |
| `request.operations[].lanes[].label` | required | string, minimum length `1` |  |
| `request.operations[].lanes[].color_slot` | required | integer, minimum `0`, maximum `7` |  |
| `request.operations[].lanes[].target` | required | object or object |  |
| `request.operations[].lanes[].target` | when using this variant | object | object variant |
| `request.operations[].lanes[].target.kind` | required | `camera` |  |
| `request.operations[].lanes[].target.angle_id` | required | string, minimum length `1` |  |
| `request.operations[].lanes[].target` | when using this variant | object | object variant |
| `request.operations[].lanes[].target.kind` | required | `recording` |  |
| `request.operations[].lanes[].target.source_id` | required | string, minimum length `1` |  |
| `request.operations[].lanes[].target.audio_stream_index` | required | integer, minimum `0` |  |
| `request.operations[].original` | optional | object |  |
| `request.operations[].original.source_id` | required | string, minimum length `1` |  |
| `request.operations[].original.audio_stream_index` | required | integer, minimum `0` |  |
| `request.operations[].replacement` | optional | object |  |
| `request.operations[].replacement.source_id` | required | string, minimum length `1` |  |
| `request.operations[].replacement.audio_stream_index` | required | integer, minimum `0` |  |
| `request.operations[].replacement_stream_index` | optional | integer, minimum `0` |  |
| `request.operations[].replacement_source_id` | optional | string, minimum length `1` |  |
| `request.operations[].relative_offset` | optional | string, minimum length `1` |  |
| `request.operations[].uncovered` | optional | `keep_original` / `leave_uncovered` |  |
| `request.operations[].reference_source_id` | optional | string, minimum length `1` | Camera recording ID for an aligned program replacement. |
| `request.operations[].offset` | optional | string, minimum length `1` | Exact signed camera offset. |
| `request.operations[].attachment_id` | optional | string, minimum length `1` | Transcript attachment identifier. |
| `request.operations[].speaker_id` | optional | string, minimum length `1` | Speaker identifier within the attachment. |
| `request.operations[].project_revision` | optional | string, minimum length `1` | Reviewed multicam revision for a switch operation. |
| `request.kind` | required | `sequence` / `multicam` |  |
| `request.angles` | optional | array of object, minimum items `1` |  |
| `request.angles[].id` | required | string |  |
| `request.angles[].file` | required | string |  |
| `request.angles[].offset` | optional | string |  |
| `request.angles[].audio_stream_index` | optional | integer, minimum `0` | Optional absolute audio stream index for this camera's default lane. |
| `request.group_end` | optional | string |  |

### `project_file_edit`

Write an editable timeline to a new .cut destination. Operations execute in order.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `request` | required | object |  |
| `request.out_project` | required | string, pattern `^/` |  |
| `request.operations` | required | array of object |  |
| `request.operations[].action` | required | string |  |
| `request.operations[].id` | optional | string, minimum length `1` |  |
| `request.operations[].index` | optional | integer, minimum `0` |  |
| `request.operations[].to_index` | optional | integer, minimum `0` |  |
| `request.operations[].at` | optional | string |  |
| `request.operations[].from` | optional | string |  |
| `request.operations[].to` | optional | string |  |
| `request.operations[].file` | optional | string |  |
| `request.operations[].new_id` | optional | string |  |
| `request.operations[].angle_id` | optional | string |  |
| `request.operations[].name` | optional | string |  |
| `request.operations[].ranges` | optional | array of object or object, minimum items `1` |  |
| `request.operations[].ranges[]` | when using this variant | object | object variant |
| `request.operations[].ranges[].file` | required | string, minimum length `1` |  |
| `request.operations[].ranges[].from` | required | string, minimum length `1` | Exact time in seconds as a decimal, timecode or fraction. |
| `request.operations[].ranges[].to` | required | string, minimum length `1` | Exact time in seconds as a decimal, timecode or fraction. |
| `request.operations[].ranges[]` | when using this variant | object | object variant |
| `request.operations[].ranges[].select_id` | required | string, minimum length `1` |  |
| `request.operations[].path` | optional | string, minimum length `1` | Media path for add_recording or audio_replacement_set, relative to working_directory if needed. |
| `request.operations[].group_start` | optional | string, minimum length `1` | Exact time in the multicam group for the start of the added recording. |
| `request.operations[].mode` | optional | `fixed` / `follow` / `none` / `mix` / `replace` |  |
| `request.operations[].source_id` | optional | string, minimum length `1` |  |
| `request.operations[].audio_stream_index` | optional | integer, minimum `0` |  |
| `request.operations[].lanes` | optional | array of object |  |
| `request.operations[].lanes[].id` | required | string, minimum length `1` |  |
| `request.operations[].lanes[].label` | required | string, minimum length `1` |  |
| `request.operations[].lanes[].color_slot` | required | integer, minimum `0`, maximum `7` |  |
| `request.operations[].lanes[].target` | required | object or object |  |
| `request.operations[].lanes[].target` | when using this variant | object | object variant |
| `request.operations[].lanes[].target.kind` | required | `camera` |  |
| `request.operations[].lanes[].target.angle_id` | required | string, minimum length `1` |  |
| `request.operations[].lanes[].target` | when using this variant | object | object variant |
| `request.operations[].lanes[].target.kind` | required | `recording` |  |
| `request.operations[].lanes[].target.source_id` | required | string, minimum length `1` |  |
| `request.operations[].lanes[].target.audio_stream_index` | required | integer, minimum `0` |  |
| `request.operations[].original` | optional | object |  |
| `request.operations[].original.source_id` | required | string, minimum length `1` |  |
| `request.operations[].original.audio_stream_index` | required | integer, minimum `0` |  |
| `request.operations[].replacement` | optional | object |  |
| `request.operations[].replacement.source_id` | required | string, minimum length `1` |  |
| `request.operations[].replacement.audio_stream_index` | required | integer, minimum `0` |  |
| `request.operations[].replacement_stream_index` | optional | integer, minimum `0` |  |
| `request.operations[].replacement_source_id` | optional | string, minimum length `1` |  |
| `request.operations[].relative_offset` | optional | string, minimum length `1` |  |
| `request.operations[].uncovered` | optional | `keep_original` / `leave_uncovered` |  |
| `request.operations[].reference_source_id` | optional | string, minimum length `1` | Camera recording ID for an aligned program replacement. |
| `request.operations[].offset` | optional | string, minimum length `1` | Exact signed camera offset. |
| `request.operations[].attachment_id` | optional | string, minimum length `1` | Transcript attachment identifier. |
| `request.operations[].speaker_id` | optional | string, minimum length `1` | Speaker identifier within the attachment. |
| `request.operations[].project_revision` | optional | string, minimum length `1` | Reviewed multicam revision for a switch operation. |
| `request.project_path` | required | string |  |
| `request.project_revision` | optional | string, minimum length `1` | Revision from tiles switches propose. Checked against the saved multicam project before any operation. |

### `project_file_inspect`

Inspect a saved or inline project. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `no_sidecar` | optional | boolean |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "project_data"
          ]
        }
      ]
    }
  ]
}
```

### `project_file_media_refresh`

Check recordings referenced by a saved project and refresh eligible analysis sidecars. The project file stays untouched. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. The completed result includes `media` rows with the shared project media status and current uses, plus refresh results for recording sidecars.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project_path` | required | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `deep` | optional | boolean | Verify stream content even when the file stamp is unchanged. |
| `no_sidecar` | optional | boolean | Check recordings without reading or writing analysis sidecars. |

### `project_file_resolve_export`

Write an editable Resolve timeline. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `output` | optional | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `edit` | optional | object |  |
| `edit.clips` | required | array of object, minimum items `1` |  |
| `edit.clips[].file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.clips[].from` | optional | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `edit.clips[].from` | when using this variant | object | object variant |
| `edit.clips[].from.numerator` | required | integer |  |
| `edit.clips[].from.denominator` | required | integer, minimum `1` |  |
| `edit.clips[].to` | optional | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `edit.clips[].to` | when using this variant | object | object variant |
| `edit.clips[].to.numerator` | required | integer |  |
| `edit.clips[].to.denominator` | required | integer, minimum `1` |  |
| `edit.clips[].replace_audio` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.clips[].replace_track` | optional | integer, minimum `0` |  |
| `edit.clips[].replacement_stream` | optional | integer, minimum `0` |  |
| `edit.file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `edit.order` | optional | array of integer, minimum `1`, minimum items `1` |  |
| `edit.replace_audio` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.replace_track` | optional | integer, minimum `0` |  |
| `edit.replacement_stream` | optional | integer, minimum `0` |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `clips_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `no_sidecar` | optional | boolean |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "project_data"
          ]
        },
        {
          "required": [
            "clips_file"
          ]
        },
        {
          "required": [
            "edit"
          ]
        },
        {
          "required": [
            "input_file"
          ]
        }
      ]
    },
    {
      "if": {
        "oneOf": [
          {
            "required": [
              "project_path"
            ]
          },
          {
            "required": [
              "project_data"
            ]
          },
          {
            "required": [
              "clips_file"
            ]
          }
        ]
      },
      "then": {
        "required": [
          "output"
        ]
      }
    }
  ]
}
```

### `project_file_resolve_import`

Write a Resolve timeline and import it into the open Resolve project. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `output` | optional | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `edit` | optional | object |  |
| `edit.clips` | required | array of object, minimum items `1` |  |
| `edit.clips[].file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.clips[].from` | optional | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `edit.clips[].from` | when using this variant | object | object variant |
| `edit.clips[].from.numerator` | required | integer |  |
| `edit.clips[].from.denominator` | required | integer, minimum `1` |  |
| `edit.clips[].to` | optional | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `edit.clips[].to` | when using this variant | object | object variant |
| `edit.clips[].to.numerator` | required | integer |  |
| `edit.clips[].to.denominator` | required | integer, minimum `1` |  |
| `edit.clips[].replace_audio` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.clips[].replace_track` | optional | integer, minimum `0` |  |
| `edit.clips[].replacement_stream` | optional | integer, minimum `0` |  |
| `edit.file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `edit.order` | optional | array of integer, minimum `1`, minimum items `1` |  |
| `edit.replace_audio` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.replace_track` | optional | integer, minimum `0` |  |
| `edit.replacement_stream` | optional | integer, minimum `0` |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `clips_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `no_sidecar` | optional | boolean |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "project_data"
          ]
        },
        {
          "required": [
            "clips_file"
          ]
        },
        {
          "required": [
            "edit"
          ]
        },
        {
          "required": [
            "input_file"
          ]
        }
      ]
    },
    {
      "if": {
        "oneOf": [
          {
            "required": [
              "project_path"
            ]
          },
          {
            "required": [
              "project_data"
            ]
          },
          {
            "required": [
              "clips_file"
            ]
          }
        ]
      },
      "then": {
        "required": [
          "output"
        ]
      }
    }
  ]
}
```

### `review_file_frames_export`

Write JPEG review images and a manifest for a source, edited program, or synchronized multicam angles. With tile processing, group and assembly requests sample the rendered program. Poll file_job_status_read with the returned job_id and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `output` | required | string, pattern `^/` | Absolute path to a new directory for the frame images and manifest. |
| `at` | optional | array of string, minimum length `1`, minimum items `1` |  |
| `preset` | optional | `review` / `full` |  |
| `select` | optional | `scenes` / `non_silent` |  |
| `sample` | optional | `first` / `midpoint` |  |
| `limit` | optional | integer, minimum `1` |  |
| `silence_audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index of the audio to analyze. |
| `silence_threshold_db` | optional | number, minimum `-120`, maximum `0` |  |
| `silence_min_pause_seconds` | optional | number |  |
| `no_sidecar` | optional | boolean |  |
| `at_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `clock` | optional | `sequence` / `assembly` / `group` | Project timebase. Sequence projects use sequence time. Multicam defaults to group time for angle comparisons. Select assembly for the edited program. Project frame exports require at or at_file. |
| `format` | optional | `jpeg` / `png` / `tiff` | Image format. Lossless PNG and TIFF require a supported source. Defaults to JPEG. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "file"
          ]
        },
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "project_data"
          ]
        }
      ]
    }
  ]
}
```

### `scenes_file_export`

Export grouped footage using fresh or saved scene boundaries. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `report` | optional | object | Existing native CLI JSON report; retain its file, source stamp, and indices. |
| `export_to` | required | string, pattern `^/` | Absolute path to an existing output directory. Each rendered file needs a new name. |
| `group_by` | optional | `scene` / `view` |  |
| `container` | optional | string, minimum length `1` | Container extension. |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index for the requested audio track. |
| `dry_run` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `scenes_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `subfolder` | optional | string, minimum length `1` | Optional single directory name beneath the chosen output directory. Path separators and control characters are forbidden. |
| `base_name` | optional | string, minimum length `1` | Optional single filename prefix. Path separators and control characters are forbidden. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "file"
          ]
        },
        {
          "required": [
            "report"
          ]
        },
        {
          "required": [
            "input_file"
          ]
        }
      ]
    }
  ]
}
```

### `scenes_file_scan`

Scan a recording or project for scene boundaries. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `no_sidecar` | optional | boolean |  |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `source_to` | optional | string | Exclusive end in source time. |
| `clip_id` | optional | string, minimum length `1` | Stable sequence occurrence ID in the saved project. |
| `camera_id` | optional | string, minimum length `1` | Stable camera ID in the saved multicam project. |
| `all_sources` | optional | boolean | Scan all referenced video sources in the saved project. This is the default project scope. |
| `policy` | optional | `reuse` / `resume` / `restart` | Reuse returns current results or resumes unfinished analysis. Resume prefers a saved replacement attempt. Restart begins a replacement identified by operation_id. |
| `source_from` | optional | string | Inclusive start in source time. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "file"
          ]
        },
        {
          "required": [
            "project_path"
          ]
        }
      ]
    }
  ]
}
```

### `scenes_file_view_rename`

Rename a recurring view in a saved project. Use an empty name to restore the default. Returns a job_id. Poll file_job_status_read for the CLI result.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `project_path` | required | string, pattern `^/` | Absolute path to the saved project. |
| `out_project` | required | string, pattern `^/` | Absolute path to a new .cut file. |
| `no_sidecar` | optional | boolean |  |
| `file` | required | string, pattern `^/` | Absolute recording path from a full-source project scene scan. |
| `report_id` | required | string, pattern `^[a-f0-9]{64}$` | Report ID returned by a full-source project scene scan. |
| `view` | required | integer, minimum `1` |  |
| `name` | required | string, maximum length `1024` |  |

### `silence_file_export`

Write shortened media from a recording, project or pause report. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `report` | optional | object | Existing native CLI JSON report; retain its file, source stamp, and indices. |
| `silence_audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index of the audio to analyze. |
| `silence_threshold_db` | optional | number, minimum `-120`, maximum `0` |  |
| `silence_max_blip_seconds` | optional | number, minimum `0`, maximum `1`, default `0.06` | Longest measured sound in seconds to join across quiet stretches during a new scan. Zero disables joining. |
| `silence_min_pause_seconds` | optional | number | Positive minimum detected pause duration in seconds. |
| `silence_padding_per_side_seconds` | optional | number, minimum `0` | Seconds of silence to keep on each side of a cut (default 0.2). |
| `waveform` | optional | integer, minimum `1`, maximum `8192` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index for the requested audio track. |
| `mode` | optional | `smart` / `copy` |  |
| `output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `no_sidecar` | optional | boolean |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `pauses_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `retain_pauses` | optional | array of object, minimum items `1` | Override the total retained seconds of detected project pauses. |
| `retain_pauses[].pause_id` | required | string, minimum length `1` |  |
| `retain_pauses[].retained_seconds` | required | number, minimum `0` |  |
| `protect_pauses` | optional | array of string, minimum items `1` | Sequence pause IDs to retain, from a scan with matching settings. |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` | Audio action for project output. For multicam, independent of picture mode. |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Audio delivery for a retained multicam project output. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "file"
          ]
        },
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "project_data"
          ]
        },
        {
          "required": [
            "report"
          ]
        },
        {
          "required": [
            "input_file"
          ]
        }
      ]
    },
    {
      "if": {
        "not": {
          "allOf": [
            {
              "not": {
                "required": [
                  "audio"
                ]
              }
            },
            {
              "not": {
                "required": [
                  "audio_output"
                ]
              }
            }
          ]
        }
      },
      "then": {
        "required": [
          "output"
        ],
        "oneOf": [
          {
            "required": [
              "project_path"
            ]
          },
          {
            "required": [
              "project_data"
            ]
          }
        ]
      }
    }
  ]
}
```

### `silence_file_pause_protect`

Save protection for pauses identified by a multicam project silence scan, keeping the assembly intact. Returns a job_id. Poll file_job_status_read for the CLI result.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `project_path` | required | string, pattern `^/` | Absolute path to the saved project. |
| `out_project` | required | string, pattern `^/` | Absolute path to a new .cut file. |
| `no_sidecar` | optional | boolean |  |
| `protect_pauses` | required | array of string, minimum length `1`, minimum items `1` | Pause IDs from the same saved project and detector settings. |
| `silence_threshold_db` | optional | number, minimum `-120`, maximum `0` |  |
| `silence_min_pause_seconds` | optional | number, greater than `0` |  |
| `silence_max_blip_seconds` | optional | number, minimum `0`, maximum `1` |  |

### `silence_file_plan`

Plan shortened media from a recording, project or saved pause report. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `report` | optional | object | Existing native CLI JSON report; retain its file, source stamp, and indices. |
| `silence_audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index of the audio to analyze. |
| `silence_threshold_db` | optional | number, minimum `-120`, maximum `0` |  |
| `silence_max_blip_seconds` | optional | number, minimum `0`, maximum `1`, default `0.06` | Longest measured sound in seconds to join across quiet stretches during a new scan. Zero disables joining. |
| `silence_min_pause_seconds` | optional | number | Positive minimum detected pause duration in seconds. |
| `silence_padding_per_side_seconds` | optional | number, minimum `0` | Seconds of silence to keep on each side of a cut (default 0.2). |
| `waveform` | optional | integer, minimum `1`, maximum `8192` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index for the requested audio track. |
| `mode` | optional | `smart` / `copy` |  |
| `output` | optional | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `no_sidecar` | optional | boolean |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `pauses_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `retain_pauses` | optional | array of object, minimum items `1` | Override the total retained seconds of detected project pauses. |
| `retain_pauses[].pause_id` | required | string, minimum length `1` |  |
| `retain_pauses[].retained_seconds` | required | number, minimum `0` |  |
| `take_boundaries` | optional | array of string, minimum length `1`, minimum items `1` | Exact sequence or assembly split times for take candidates in a project report without an output movie. |
| `protect_pauses` | optional | array of string, minimum items `1` | Sequence pause IDs to retain, from a scan with matching settings. |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` | Audio action for project output. For multicam, independent of picture mode. |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Audio delivery for a retained multicam project output. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "file"
          ]
        },
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "project_data"
          ]
        },
        {
          "required": [
            "report"
          ]
        },
        {
          "required": [
            "input_file"
          ]
        }
      ]
    },
    {
      "if": {
        "not": {
          "allOf": [
            {
              "not": {
                "required": [
                  "audio"
                ]
              }
            },
            {
              "not": {
                "required": [
                  "audio_output"
                ]
              }
            }
          ]
        }
      },
      "then": {
        "required": [
          "output"
        ],
        "oneOf": [
          {
            "required": [
              "project_path"
            ]
          },
          {
            "required": [
              "project_data"
            ]
          }
        ]
      }
    }
  ]
}
```

### `silence_file_room_tone_calibrate`

Set per-track silence thresholds from routed multicam audio inside the supplied room-tone range. Returns a job_id. Poll file_job_status_read for the CLI result.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `project_path` | required | string, pattern `^/` | Absolute path to the saved project. |
| `out_project` | required | string, pattern `^/` | Absolute path to a new .cut file. |
| `no_sidecar` | optional | boolean |  |
| `clock` | required | `group` / `assembly` |  |
| `from` | required | string, minimum length `1` |  |
| `to` | required | string, minimum length `1` |  |

### `silence_file_scan`

Scan a recording or project for pauses. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `silence_audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index of the audio to analyze. |
| `silence_threshold_db` | optional | number, minimum `-120`, maximum `0` |  |
| `silence_max_blip_seconds` | optional | number, minimum `0`, maximum `1`, default `0.06` | Longest measured sound in seconds to join across quiet stretches during a new scan. Zero disables joining. |
| `silence_min_pause_seconds` | optional | number | Positive minimum detected pause duration in seconds. |
| `silence_padding_per_side_seconds` | optional | number, minimum `0` | Seconds of silence to keep on each side of a cut (default 0.2). |
| `waveform` | optional | integer, minimum `1`, maximum `8192` |  |
| `no_sidecar` | optional | boolean |  |
| `retain_pauses` | optional | array of object, minimum items `1` | Override the total retained seconds of detected project pauses. |
| `retain_pauses[].pause_id` | required | string, minimum length `1` |  |
| `retain_pauses[].retained_seconds` | required | number, minimum `0` |  |
| `take_boundaries` | optional | array of string, minimum length `1`, minimum items `1` | Exact sequence or assembly split times for take candidates in a project report without an output movie. |
| `protect_pauses` | optional | array of string, minimum items `1` | Sequence pause IDs to retain, from a scan with matching settings. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "file"
          ]
        },
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "project_data"
          ]
        }
      ]
    }
  ]
}
```

### `silence_file_shorten`

Write a new editable project with reviewed pauses shortened.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project_path` | required | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `silence_threshold_db` | optional | number, minimum `-120`, maximum `0` |  |
| `silence_max_blip_seconds` | optional | number, minimum `0`, maximum `1`, default `0.06` | Longest measured sound in seconds to join across quiet stretches during a new scan. Zero disables joining. |
| `silence_min_pause_seconds` | optional | number | Positive minimum detected pause duration in seconds. |
| `silence_padding_per_side_seconds` | optional | number, minimum `0` | Seconds of silence to keep on each side of a cut (default 0.2). |
| `no_sidecar` | optional | boolean |  |
| `retain_pauses` | optional | array of object, minimum items `1` | Override the total retained seconds of detected project pauses. |
| `retain_pauses[].pause_id` | required | string, minimum length `1` |  |
| `retain_pauses[].retained_seconds` | required | number, minimum `0` |  |
| `protect_pauses` | optional | array of string, minimum items `1` | Sequence pause IDs to retain, from a scan with matching settings. |
| `out_project` | required | string |  |

### `still_file_asset_relink`

Relink a still asset to the same image at a new location in a saved project. This is an asset-ID alias for project_file_media_relink.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `asset` | required | string |  |
| `image` | required | string |  |
| `project_path` | required | string |  |
| `out_project` | optional | string |  |
| `in_place` | optional | `true` |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ]
        }
      ]
    }
  ]
}
```

### `still_file_picture_replace`

Run still picture replace on a saved project. See cli_help_read for timing and destination options.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `image` | optional | string |  |
| `asset` | optional | string |  |
| `clock` | required | string |  |
| `from` | required | string |  |
| `to` | required | string |  |
| `fit` | optional | `fit` / `fill` |  |
| `crop_x` | optional | string |  |
| `crop_y` | optional | string |  |
| `crop_width` | optional | string |  |
| `crop_height` | optional | string |  |
| `background` | optional | string |  |
| `color` | optional | `sdr` / `pq` / `hlg` |  |
| `project_path` | required | string |  |
| `out_project` | optional | string |  |
| `in_place` | optional | `true` |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ]
        }
      ]
    },
    {
      "oneOf": [
        {
          "required": [
            "image"
          ]
        },
        {
          "required": [
            "asset"
          ]
        }
      ]
    }
  ]
}
```

### `still_file_placement_insert`

Run still placement insert on a saved project. See cli_help_read for timing and destination options.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `image` | optional | string |  |
| `asset` | optional | string |  |
| `clock` | required | string |  |
| `at` | required | string |  |
| `fit` | optional | `fit` / `fill` |  |
| `crop_x` | optional | string |  |
| `crop_y` | optional | string |  |
| `crop_width` | optional | string |  |
| `crop_height` | optional | string |  |
| `background` | optional | string |  |
| `color` | optional | `sdr` / `pq` / `hlg` |  |
| `duration` | optional | string |  |
| `frames` | optional | integer, minimum `1` |  |
| `rate` | optional | string |  |
| `project_path` | required | string |  |
| `out_project` | optional | string |  |
| `in_place` | optional | `true` |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ]
        }
      ]
    },
    {
      "oneOf": [
        {
          "required": [
            "image"
          ]
        },
        {
          "required": [
            "asset"
          ]
        }
      ]
    },
    {
      "oneOf": [
        {
          "required": [
            "duration"
          ]
        },
        {
          "required": [
            "frames",
            "rate"
          ]
        }
      ]
    }
  ]
}
```

### `still_file_placement_remove`

Run still placement remove on a saved project. See cli_help_read for timing and destination options.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `placement` | required | string |  |
| `project_path` | required | string |  |
| `out_project` | optional | string |  |
| `in_place` | optional | `true` |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ]
        }
      ]
    }
  ]
}
```

### `still_file_placement_update`

Run still placement update on a saved project. See cli_help_read for timing and destination options.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `placement` | required | string |  |
| `asset` | optional | string |  |
| `at` | optional | string |  |
| `from` | optional | string |  |
| `to` | optional | string |  |
| `clock` | optional | string |  |
| `fragment_index` | optional | integer, minimum `0` |  |
| `duplicate_id` | optional | string |  |
| `detach_id` | optional | string |  |
| `fit` | optional | `fit` / `fill` |  |
| `crop_x` | optional | string |  |
| `crop_y` | optional | string |  |
| `crop_width` | optional | string |  |
| `crop_height` | optional | string |  |
| `background` | optional | string |  |
| `color` | optional | `sdr` / `pq` / `hlg` |  |
| `duration` | optional | string |  |
| `frames` | optional | integer, minimum `1` |  |
| `rate` | optional | string |  |
| `project_path` | required | string |  |
| `out_project` | optional | string |  |
| `in_place` | optional | `true` |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ]
        }
      ]
    }
  ]
}
```

### `still_file_placements_list`

Run still placement list on a saved project. See cli_help_read for timing and destination options.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `placement` | optional | string |  |
| `project_path` | required | string |  |

### `still_file_project_create`

Create a new still-only project, optionally with a recording at program zero. See cli_help_read for timeline and destination options.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `out_project` | required | string |  |
| `image` | optional | string |  |
| `gap` | optional | `true` |  |
| `width` | required | integer, minimum `1` |  |
| `height` | required | integer, minimum `1` |  |
| `codec` | optional | `h264` / `hevc` / `prores` / `jpeg` |  |
| `container` | optional | `mov` / `mp4` / `m4v` / `mkv` |  |
| `background` | optional | string |  |
| `color` | optional | `sdr` / `pq` / `hlg` |  |
| `duration` | optional | string |  |
| `frames` | optional | integer, minimum `1` |  |
| `rate` | required | string |  |
| `soundtrack` | optional | string, pattern `^/` | Absolute path to the recording. |
| `audio_stream` | optional | integer, minimum `0` | Optional absolute audio stream index. Defaults to the first audio stream. |
| `from` | optional | string | Optional source in-point on an audio sample boundary, as exact rational seconds. |
| `to` | optional | string | Optional source out-point on an audio sample boundary, as exact rational seconds. |
| `fit_soundtrack` | optional | `true` | Fit the single image to the recording’s exact audible duration in the same edit. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "image"
          ]
        },
        {
          "required": [
            "gap"
          ]
        }
      ]
    },
    {
      "oneOf": [
        {
          "required": [
            "duration"
          ]
        },
        {
          "required": [
            "frames"
          ]
        },
        {
          "required": [
            "fit_soundtrack",
            "image",
            "soundtrack"
          ]
        }
      ]
    }
  ],
  "dependentRequired": {
    "audio_stream": [
      "soundtrack"
    ],
    "from": [
      "soundtrack"
    ],
    "to": [
      "soundtrack"
    ]
  }
}
```

### `still_file_soundtrack_attach`

Attach a recording at program zero in a still-only sequence. Optionally fit its single image to the selected audio range. Returns a file job receipt.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `out_project` | optional | string |  |
| `project_path` | required | string, pattern `^/` |  |
| `in_place` | optional | `true` |  |
| `soundtrack` | required | string, pattern `^/` | Absolute path to the recording. |
| `audio_stream` | optional | integer, minimum `0` | Optional absolute audio stream index. Defaults to the first audio stream. |
| `from` | optional | string | Optional source in-point on an audio sample boundary, as exact rational seconds. |
| `to` | optional | string | Optional source out-point on an audio sample boundary, as exact rational seconds. |
| `fit_soundtrack` | optional | `true` | Fit the single image to the recording’s exact audible duration in the same edit. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "out_project"
      ]
    },
    {
      "required": [
        "in_place"
      ]
    }
  ]
}
```

### `still_file_soundtrack_detach`

Detach the recording from a still-only sequence and keep its picture timing. Returns a file job receipt.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `out_project` | optional | string |  |
| `project_path` | required | string, pattern `^/` |  |
| `in_place` | optional | `true` |  |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "out_project"
      ]
    },
    {
      "required": [
        "in_place"
      ]
    }
  ]
}
```

### `still_file_soundtrack_fit`

Fit the single image in a still-only sequence to its attached soundtrack’s exact audible duration. Returns a file job receipt.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `out_project` | optional | string |  |
| `project_path` | required | string, pattern `^/` |  |
| `in_place` | optional | `true` |  |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "out_project"
      ]
    },
    {
      "required": [
        "in_place"
      ]
    }
  ]
}
```

### `timeline_file_clips_space`

Run timeline clips space on a saved project. See cli_help_read for timing and destination options.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `source_timing` | optional | boolean |  |
| `background` | optional | string |  |
| `color` | optional | `sdr` / `pq` / `hlg` |  |
| `duration` | optional | string |  |
| `frames` | optional | integer, minimum `1` |  |
| `rate` | optional | string |  |
| `project_path` | required | string |  |
| `out_project` | optional | string |  |
| `in_place` | optional | `true` |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ]
        }
      ]
    },
    {
      "oneOf": [
        {
          "required": [
            "source_timing"
          ]
        },
        {
          "required": [
            "duration"
          ]
        },
        {
          "required": [
            "frames",
            "rate"
          ]
        }
      ]
    }
  ]
}
```

### `timeline_file_gap_insert`

Run timeline gap insert on a saved project. See cli_help_read for timing and destination options.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `clock` | required | string |  |
| `at` | required | string |  |
| `background` | optional | string |  |
| `color` | optional | `sdr` / `pq` / `hlg` |  |
| `duration` | optional | string |  |
| `frames` | optional | integer, minimum `1` |  |
| `rate` | optional | string |  |
| `project_path` | required | string |  |
| `out_project` | optional | string |  |
| `in_place` | optional | `true` |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ]
        }
      ]
    },
    {
      "oneOf": [
        {
          "required": [
            "duration"
          ]
        },
        {
          "required": [
            "frames",
            "rate"
          ]
        }
      ]
    }
  ]
}
```

### `waveform_file_envelope_read`

Query a signed audio amplitude envelope. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index of the audio to analyze. |
| `source_from` | optional | string, minimum length `1` | Inclusive start in source time. |
| `source_to` | optional | string, minimum length `1` | Exclusive end in source time. |
| `columns` | optional | integer, minimum `1`, maximum `65536` |  |
| `no_sidecar` | optional | boolean |  |

## Inline saved-file picture review

### `review_file_frame_read`

Start a job to read one exact frame from a source video or a saved project's program as a bounded review JPEG. Poll file_job_status_read and then call review_file_frame_result_read with the returned job_id.

Returns a file job receipt. Poll `file_job_status_read` to check completion, then call `review_file_frame_result_read` with the same `job_id`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Reuse for identical retries. |
| `file` | optional | string, pattern `^/` | Absolute path to source video. Reads the source clock. |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. |
| `at` | required | string, minimum length `1` | Time in seconds, timecode, or exact rational seconds such as 1001/30000. |
| `clock` | optional | `sequence` / `group` / `assembly` | Saved-project clock. Defaults to sequence for a sequence project and assembly for a multicam project. Group reads the group switch lane. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "file"
      ],
      "allOf": [
        {
          "not": {
            "required": [
              "project_path"
            ]
          }
        },
        {
          "not": {
            "required": [
              "clock"
            ]
          }
        }
      ]
    },
    {
      "required": [
        "project_path"
      ],
      "not": {
        "required": [
          "file"
        ]
      }
    }
  ]
}
```

### `review_file_frame_result_read`

Read the JPEG and frame metadata for a successful review_file_frame_read job. Returns one image/jpeg content block. The image is at most 640 pixels on either axis and 1 MiB before base64 encoding.

Returns one JPEG image block in MCP `content` and the requested clock and time, dimensions, and available frame metadata in `structuredContent`. Camera renders can identify the source, while still and generated gap renders identify their placements or generated picture. Rendered participant and Tiles frames report `privacy_issue_count` and a bounded `privacy_issues` preview when issues affect the frame. The JPEG is bounded to 640 pixels per axis and 1 MiB.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `job_id` | required | string, format `uuid` | Job ID returned by review_file_frame_read. |

## Saved project media

### `project_file_media_leave_offline`

Mark a current media reference as deliberately offline. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. The completed result reports the published `out_project`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_path` | required | string, pattern `^/` | Absolute path to a saved project. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry an identical request. |
| `working_directory` | optional | string, pattern `^/` | Existing working directory for the CLI job. |
| `source` | required | string, minimum length `1` | Path returned by the project media list, or an absolute source path. |
| `out_project` | optional | string, pattern `^/` | Write a new project at this path. |
| `in_place` | optional | boolean | Update the input project. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "out_project"
      ]
    },
    {
      "required": [
        "in_place"
      ],
      "properties": {
        "in_place": {
          "const": true
        }
      }
    }
  ]
}
```

### `project_file_media_list`

List current project media references, their statuses and uses. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. Poll `file_job_status_read` for `sources` containing paths, statuses and uses. Read large results with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_path` | required | string, pattern `^/` | Absolute path to a saved project. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry an identical request. |
| `working_directory` | optional | string, pattern `^/` | Existing working directory for the CLI job. |
| `include_history` | optional | boolean | Include media used only by retained undo or redo states. Defaults to false. |

### `project_file_media_locate`

Search a folder for relink candidates and optionally apply unique matches. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. A search reports candidate rows in `sources`. With `apply_matches`, the result reports candidate rows under `search`, outcomes under `sources`, `applied_count` and any published `out_project`. Use `project_file_media_relink` to apply selected mappings after review.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_path` | required | string, pattern `^/` | Absolute path to a saved project. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry an identical request. |
| `working_directory` | optional | string, pattern `^/` | Existing working directory for the CLI job. |
| `folder` | required | string, pattern `^/` | Absolute path to the folder to search, including its subdirectories. |
| `include_history` | optional | boolean | Include media used only by retained undo or redo states. Defaults to false. |
| `apply_matches` | optional | boolean | Apply unique verified or matched candidates. Defaults to false. |
| `out_project` | optional | string, pattern `^/` | Write a new project at this path. |
| `in_place` | optional | boolean | Update the input project. |

Additional schema rules

```json
{
  "allOf": [
    {
      "if": {
        "required": [
          "apply_matches"
        ],
        "properties": {
          "apply_matches": {
            "const": true
          }
        }
      },
      "then": {
        "oneOf": [
          {
            "required": [
              "out_project"
            ]
          },
          {
            "required": [
              "in_place"
            ],
            "properties": {
              "in_place": {
                "const": true
              }
            }
          }
        ]
      }
    },
    {
      "if": {
        "not": {
          "required": [
            "apply_matches"
          ],
          "properties": {
            "apply_matches": {
              "const": true
            }
          }
        }
      },
      "then": {
        "allOf": [
          {
            "not": {
              "required": [
                "out_project"
              ]
            }
          },
          {
            "not": {
              "required": [
                "in_place"
              ],
              "properties": {
                "in_place": {
                  "const": true
                }
              }
            }
          }
        ]
      }
    }
  ]
}
```

### `project_file_media_relink`

Relink one or more paths to the same media, including references in retained undo and redo history. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. Poll `file_job_status_read` for `sources` containing the candidate outcome for each requested mapping, `applied_count` and the published `out_project` when applicable.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_path` | required | string, pattern `^/` | Absolute path to a saved project. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry an identical request. |
| `working_directory` | optional | string, pattern `^/` | Existing working directory for the CLI job. |
| `from` | optional | string, minimum length `1` | Path returned by the project media list, or an absolute source path. |
| `to` | optional | string, pattern `^/` | Absolute path to the candidate media file. |
| `mappings` | optional | array of object, minimum items `1`, maximum items `256` | Explicit old-to-new path mappings. |
| `mappings[].from` | required | string, minimum length `1` | Path returned by the project media list, or an absolute source path. |
| `mappings[].to` | required | string, pattern `^/` | Absolute path to the candidate media file. |
| `from_prefix` | optional | string, pattern `^/` | Previous folder root. |
| `to_prefix` | optional | string, pattern `^/` | New folder root. |
| `out_project` | optional | string, pattern `^/` | Write a new project at this path. |
| `in_place` | optional | boolean | Update the input project. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "from",
        "to"
      ],
      "not": {
        "required": [
          "mappings"
        ]
      },
      "allOf": [
        {
          "not": {
            "required": [
              "from_prefix"
            ]
          }
        },
        {
          "not": {
            "required": [
              "to_prefix"
            ]
          }
        }
      ]
    },
    {
      "required": [
        "mappings"
      ],
      "allOf": [
        {
          "not": {
            "required": [
              "from"
            ]
          }
        },
        {
          "not": {
            "required": [
              "to"
            ]
          }
        },
        {
          "not": {
            "required": [
              "from_prefix"
            ]
          }
        },
        {
          "not": {
            "required": [
              "to_prefix"
            ]
          }
        }
      ]
    },
    {
      "required": [
        "from_prefix",
        "to_prefix"
      ],
      "allOf": [
        {
          "not": {
            "required": [
              "from"
            ]
          }
        },
        {
          "not": {
            "required": [
              "to"
            ]
          }
        },
        {
          "not": {
            "required": [
              "mappings"
            ]
          }
        }
      ]
    }
  ],
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `project_file_media_replace`

Preview the consequences of replacing a source. Set confirm to true and specify an output to apply the replacement. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. Poll `file_job_status_read` for the ripple `report`. A confirmed replacement also reports the published `out_project`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_path` | required | string, pattern `^/` | Absolute path to a saved project. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry an identical request. |
| `working_directory` | optional | string, pattern `^/` | Existing working directory for the CLI job. |
| `source` | required | string, minimum length `1` | Path returned by the project media list, or an absolute source path. |
| `with` | required | string, pattern `^/` | Absolute path to the candidate media file. |
| `conform` | optional | `trim` / `keep` | Trim overlapping ranges to the new end, or keep affected ranges offline. Defaults to trim. |
| `allow_loss` | optional | boolean | Approve the selected handling of ranges beyond the new end. |
| `confirm` | optional | boolean | Apply the replacement. Omit or set false to preview. |
| `out_project` | optional | string, pattern `^/` | Write a new project at this path. |
| `in_place` | optional | boolean | Update the input project. |
| `use_id` | optional | string, minimum length `1` | Apply to one use ID from project_editor_media_list. Omit to replace all uses. |
| `loss` | optional | `remove` / `keep_offline` | Explicit treatment of uses starting beyond the new source extent. |
| `clock` | optional | `source_relative` / `source_timecode` | Preserve relative times or map cuts through comparable source clocks. |
| `stream_mapping` | optional | array of object, maximum items `256` | Map selected old audio streams to candidate audio streams. |
| `stream_mapping[].from` | required | integer, minimum `0` |  |
| `stream_mapping[].to` | required | integer, minimum `0` |  |
| `reset_crop` | optional | boolean | Reset authored still crop to fit the new image. |
| `replacement_offset` | optional | string, minimum length `1` | Exact multicam source offset in seconds or as a rational. |
| `shared_time_of_day` | optional | boolean | Confirm that comparable mixed clock kinds share a time of day. |
| `transcript` | optional | `keep_unverified` / `retranscribe` | Keep the transcript unverified or remove the affected binding for retranscription. |
| `resync` | optional | `timecode` / `waveform` | Recompute multicam alignment using the selected method. |

Additional schema rules

```json
{
  "allOf": [
    {
      "if": {
        "required": [
          "confirm"
        ],
        "properties": {
          "confirm": {
            "const": true
          }
        }
      },
      "then": {
        "oneOf": [
          {
            "required": [
              "out_project"
            ]
          },
          {
            "required": [
              "in_place"
            ],
            "properties": {
              "in_place": {
                "const": true
              }
            }
          }
        ]
      }
    },
    {
      "if": {
        "not": {
          "required": [
            "confirm"
          ],
          "properties": {
            "confirm": {
              "const": true
            }
          }
        }
      },
      "then": {
        "allOf": [
          {
            "not": {
              "required": [
                "out_project"
              ]
            }
          },
          {
            "not": {
              "required": [
                "in_place"
              ],
              "properties": {
                "in_place": {
                  "const": true
                }
              }
            }
          }
        ]
      }
    }
  ]
}
```

### `project_file_media_revert`

Restore a previous media location when all current and retained uses trace to its relink. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. The completed result reports the published `out_project` and a `report` describing the restored location.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_path` | required | string, pattern `^/` | Absolute path to a saved project. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry an identical request. |
| `working_directory` | optional | string, pattern `^/` | Existing working directory for the CLI job. |
| `source` | required | string, minimum length `1` | Path returned by the project media list, or an absolute source path. |
| `out_project` | optional | string, pattern `^/` | Write a new project at this path. |
| `in_place` | optional | boolean | Update the input project. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "out_project"
      ]
    },
    {
      "required": [
        "in_place"
      ],
      "properties": {
        "in_place": {
          "const": true
        }
      }
    }
  ]
}
```

## Saved timeline review and multicam analysis

### `history_file_compare`

Compare a saved .cut with another file or with one of its retained undo or redo states.

Returns a file job receipt. Poll `file_job_status_read` for changed project fields and before and after occurrence details. Inspect `participant_changes` for affected source and tile IDs, intervals or points. Select the before state with `before_project_path` or `history_index`. Use `file_job_result_read` for a large result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `before_project_path` | optional | string | Absolute path to the earlier saved .cut. |
| `project_path` | required | string | Absolute path to the later saved .cut. |
| `history_index` | optional | integer, minimum `0` | Zero-based index from oldest retained state through newest. The number of undo steps is the current cursor. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "before_project_path"
      ]
    },
    {
      "required": [
        "history_index"
      ]
    }
  ]
}
```

### `history_file_restore_copy`

Write a new .cut copy with its cursor at the selected retained state, carrying over its undo and redo history. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. The completed result reports the published `out_project` and selected `history_index`. The copy retains the history branches with its cursor at the selected state.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it to retry an identical request. |
| `project_path` | required | string, pattern `^/` | Absolute path to the saved .cut project. |
| `history_index` | required | integer, minimum `0` | Zero-based index from oldest retained state through newest. The number of undo steps is the current cursor. |
| `out_project` | required | string, pattern `^/` | Absolute path for the new .cut copy. |

### `multicam_file_switch_coverage_read`

Check picture and routed sound through the proposed group switch interval in a saved multicam project.

Returns a file job receipt. Poll `file_job_status_read` for the exact group interval and its picture status, audio routes and missing ranges.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `project_path` | required | string | Absolute path to the saved multicam .cut. |
| `angle_id` | required | string, minimum length `1` | Camera angle ID for the proposed switch. |
| `group_time` | required | string | Exact proposed group time in rational seconds. |

### `multicam_file_sync_suggest`

Analyze a saved multicam project for offsets, waveform matches and drift. With a replacement file and explicit stream indices, also report offsets relative to the selected camera recording.

Returns a file job receipt. Poll `file_job_status_read` for timestamp evidence, candidate offsets, waveform matches and available drift evidence against the reference source.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `project_path` | required | string | Absolute path to the saved multicam .cut. |
| `source_id` | optional | string, minimum length `1` | Analyze one recording other than the reference. Defaults to all other recordings. |
| `reference_source_id` | optional | string, minimum length `1` | Choose a recording on the reference camera for group sync, or any camera recording for replacement sync. |
| `reference_stream` | optional | integer, minimum `0` | Absolute scratch stream index for replacement sync. |
| `replacement` | optional | string, pattern `^/` | Absolute path to a replacement recording. |
| `replacement_stream` | optional | integer, minimum `0` | Absolute audio stream index in the replacement recording. |
| `program` | optional | boolean | Evaluate coverage across the entire program. Omit reference_stream for a video-only reference. |
| `seed` | optional | string, minimum length `1` | Optional starting offset relative to the scratch recording. |
| `metadata_only` | optional | boolean | Skip waveform analysis and drift checks. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "replacement",
        "replacement_stream",
        "reference_source_id"
      ],
      "not": {
        "required": [
          "source_id"
        ]
      }
    },
    {
      "allOf": [
        {
          "not": {
            "required": [
              "replacement"
            ]
          }
        },
        {
          "not": {
            "required": [
              "reference_stream"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement_stream"
            ]
          }
        },
        {
          "not": {
            "required": [
              "seed"
            ]
          }
        },
        {
          "not": {
            "required": [
              "program"
            ]
          }
        }
      ]
    }
  ],
  "if": {
    "allOf": [
      {
        "required": [
          "replacement"
        ]
      },
      {
        "not": {
          "properties": {
            "program": {
              "const": true
            }
          },
          "required": [
            "program"
          ]
        }
      }
    ]
  },
  "then": {
    "required": [
      "reference_stream"
    ]
  }
}
```

### `project_file_document_print`

Read the expanded JSON of a saved .cut without opening it, including retained history. Poll file_job_status_read and use file_job_result_read for larger documents.

Returns a file job receipt. The completed output is the expanded saved document, including retained history. Use `file_job_result_read` to retrieve the original JSON bytes or a large document.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it to retry an identical request. |
| `project_path` | required | string, pattern `^/` | Absolute path to the saved .cut project. |

### `timeline_file_range_map`

Map an exact half-open range of a saved project between source and sequence or group and assembly clocks. Repeated occurrences appear separately.

Returns a file job receipt. Poll `file_job_status_read` for the saved project’s mapping, including the input and output clocks and all intersecting occurrence pieces. Use `file_job_result_read` for a large result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `project_path` | required | string | Absolute path to the saved .cut project. |
| `space` | required | `source` / `sequence` / `group` / `assembly` |  |
| `from` | required | string | Inclusive rational time in the selected clock. |
| `to` | required | string | Exclusive rational time in the selected clock. |
| `file` | optional | string | Absolute path identifying one source file. |
| `occurrence_index` | optional | integer, minimum `0` | Zero-based occurrence index in the saved project. |

## Projects and preferences

### `history_panel_close`

Dismiss the target project’s history sheet and wait for the native sheet to close.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |

### `history_panel_show`

Show the native history sheet for the target project.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |

### `multicam_setup_confirm`

Confirm pending camera setup, optionally supplying source order, names, microphones and opening angle.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `source_order` | optional | array of string, minimum length `1` |  |
| `names` | optional | object with values of type string |  |
| `audio_streams` | optional | object with values of type integer, minimum `0` or null |  |
| `opening` | optional | string, minimum length `1` |  |
| `audio` | optional | object |  |
| `audio.mode` | required | `follow` / `none` / `fixed` / `mix` |  |
| `audio.source_id` | optional | string, minimum length `1` |  |
| `audio.audio_stream_index` | optional | integer, minimum `0` |  |

### `multicam_setup_dismiss`

Dismiss the pending multicam setup in the target project.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |

### `multicam_setup_read`

Inspect the pending setup after a multicam import. Returns source IDs, picture/stream availability, and whether the project already exists.

`sources[]` identifies pending source IDs, paths, video presence and available audio streams. `adding` distinguishes extending an existing project from initial setup.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |

### `playback_monitor_visibility_set`

Show or close the target window’s native video monitor.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |
| `visible` | required | boolean |  |

### `preferences_read`

Read every shared MPCut setting in the key schedule, including the read-only local-control, agent permission, draft retention and cache limit values.

Returns current preference values. Changes apply app-wide. Lowering the history limit can trim retained steps immediately.

Pass an empty arguments object.

### `preferences_set`

Change a native preference. Lowering history_max_steps immediately trims retained history in open projects. Refused while Settings → Automation → Let agents change settings is off. Local MCP control, the agent permissions, draft_retention_days and analysis_shared_cache_max_bytes are read-only to agents.

Returns current preference values. Changes apply app-wide. Lowering the history limit can trim retained steps immediately.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `key` | required | `media_auto_refresh_enabled` / `analysis_sidecar_reuse_enabled` / `history_max_steps` / `timeline_source_time_ticks_enabled` / `timeline_snap_target` / `timeline_large_previews_enabled` / `playback_preview_volume_fraction` / `playback_preview_muted` / `playback_scrub_audio_enabled` / `export_movie_default_mode` / `export_jpeg_default_preset` / `export_tier_downgrade_warning_enabled` / `silence_min_pause_seconds` / `silence_max_blip_seconds` / `silence_padding_per_side_seconds` / `open_multiple_recordings_default_action` / `recent_files_max_count` / `draft_recovery_prompt_enabled` / `scene_rescan_confirmation_enabled` / `project_export_completion_message_enabled` / `timeline_cut_sections_default_enabled` / `workspace_full_height_sidebar_enabled` / `multicam_track_label_width_points` / `still_placement_default_duration_seconds` / `gap_default_duration_seconds` / `gap_default_color` / `still_timeline_default_width_pixels` / `still_timeline_default_height_pixels` / `still_timeline_default_frame_rate` / `still_timeline_default_codec` / `timeline_time_display` / `playback_default_speed` / `playback_cut_preview_preroll_seconds` / `playback_cut_preview_postroll_seconds` / `playback_viewer_force_sdr_enabled` / `playback_monitor_force_sdr_enabled` / `playback_monitor_clean_feed_enabled` / `playback_monitor_placement` / `analysis_scene_auto_scan_enabled` / `analysis_silence_auto_scan_enabled` / `tiles_scan_default_layout` / `tiles_scan_default_grid_columns` / `tiles_scan_default_grid_rows` / `tiles_scan_default_detail` / `tiles_dialogue_default_min_hold_seconds` / `tiles_dialogue_default_overlap_policy` / `tiles_dialogue_default_offscreen_policy` / `transcript_default_engine` / `transcript_default_speaker_identification_enabled` / `transcript_default_model_download_enabled` / `transcript_follow_playback_default_enabled` / `transcript_reader_text_size_points` / `transcript_edit_default_boundary_policy` / `transcript_tighten_default_retained_pause_seconds` / `transcript_default_filler_terms` / `transcript_export_default_format` / `transcript_caption_max_line_characters` / `transcript_caption_max_lines` / `transcript_caption_max_cue_seconds` / `transcript_caption_speaker_labels_enabled` / `export_reencode_default_codec` / `export_reencode_default_quality` / `export_prores_default_quality` / `export_reencode_default_container` / `export_multicam_default_audio_layout` / `export_result_json_default_enabled` / `resolve_send_open_timeline_default_enabled` / `export_start_folder_mode` / `export_finished_reveal_enabled` / `export_finished_notification_enabled` / `export_finished_sound_enabled` |  |
| `value` | required | boolean or string or number | The type, unit, range and special values of each key are in its conditional schema. Enum values match preferences_read. |

Additional schema rules

```json
{
  "allOf": [
    {
      "if": {
        "properties": {
          "key": {
            "const": "media_auto_refresh_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Watch recordings for changes while editing. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "analysis_sidecar_reuse_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Save and reuse analysis in cutcaches. Factory true."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "history_max_steps"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "integer",
            "minimum": 0,
            "maximum": 500,
            "description": "Undo and redo steps, 0\u2013500; 0 turns history off. Lowering it trims open projects. Factory 50."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "timeline_source_time_ticks_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Show source time ticks inside clips. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "timeline_snap_target"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "off",
              "keyframes",
              "scenes",
              "silence"
            ],
            "description": "Snap target. Factory off."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "timeline_large_previews_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Enlarge thumbnails and waveforms. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "playback_preview_volume_fraction"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 0,
            "maximum": 1,
            "description": "Preview volume as a fraction, 0\u20131. Factory 1."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "playback_preview_muted"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Mute preview audio. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "playback_scrub_audio_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Play audio while scrubbing. Factory true."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_movie_default_mode"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "copy",
              "smart",
              "encode"
            ],
            "description": "Default movie export mode. Factory smart."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_jpeg_default_preset"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "review",
              "full"
            ],
            "description": "Default JPEG preset. Factory review."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_tier_downgrade_warning_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Warn when an edit lowers the export tier. Factory true."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "silence_min_pause_seconds"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 0.02,
            "description": "Minimum pause in seconds, at least 0.02. Factory 1.5."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "silence_max_blip_seconds"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 0,
            "maximum": 1,
            "description": "Ignore sounds up to this many seconds, 0\u20131; 0 keeps every interruption. Factory 0.06."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "silence_padding_per_side_seconds"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 0,
            "description": "Silence kept on each side of a cut in seconds, at least 0. Factory 0.2."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "open_multiple_recordings_default_action"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "ask",
              "join",
              "multicam"
            ],
            "description": "Opening several recordings from Finder: ask, join clips or open as multicam. Factory ask."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "recent_files_max_count"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "integer",
            "minimum": 1,
            "maximum": 30,
            "description": "Recent items, 1\u201330. Factory 10."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "draft_recovery_prompt_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Offer to recover untitled projects at launch. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "scene_rescan_confirmation_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Confirm before scanning scenes again. Factory true."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "project_export_completion_message_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Show the exported message after a project export with no warnings. Factory true."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "timeline_cut_sections_default_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Show cut sections in new windows. Starting value. Factory true."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "workspace_full_height_sidebar_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Full-height panel beside the timeline in every window. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "multicam_track_label_width_points"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 106,
            "maximum": 360,
            "description": "Multicam track label width in points, 106\u2013360. Each window clamps it to its own space. Factory 172."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "still_placement_default_duration_seconds"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 0.04,
            "maximum": 600,
            "description": "Inserted still duration in seconds, 0.04\u2013600. Starting value. Factory 2."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "gap_default_duration_seconds"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 0.04,
            "maximum": 600,
            "description": "Color gap and Space Clips duration in seconds, 0.04\u2013600. Starting value. Factory 2."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "gap_default_color"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "string",
            "pattern": "^#[0-9A-Fa-f]{6}$",
            "description": "Gap color as #RRGGBB. Starting value. Factory #000000."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "still_timeline_default_width_pixels"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "integer",
            "minimum": 16,
            "maximum": 8192,
            "multipleOf": 2,
            "description": "New stills timeline width in pixels, an even number from 16 to 8192. An odd number is refused. Factory 1920."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "still_timeline_default_height_pixels"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "integer",
            "minimum": 16,
            "maximum": 8192,
            "multipleOf": 2,
            "description": "New stills timeline height in pixels, an even number from 16 to 8192. An odd number is refused. Factory 1080."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "still_timeline_default_frame_rate"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 1,
            "maximum": 240,
            "description": "New stills timeline frame rate in frames per second, 1\u2013240. Factory 30."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "still_timeline_default_codec"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "h264",
              "hevc",
              "prores"
            ],
            "description": "New stills timeline codec. Factory h264."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "timeline_time_display"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "milliseconds",
              "frames"
            ],
            "description": "Time display. Factory milliseconds."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "playback_default_speed"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "enum": [
              0.125,
              0.25,
              0.5,
              0.75,
              1,
              1.25,
              1.5,
              2,
              4,
              8
            ],
            "description": "Starting playback speed as a rate. Factory 1."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "playback_cut_preview_preroll_seconds"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 0.25,
            "maximum": 10,
            "description": "Seconds played before a cut, 0.25\u201310. Factory 1."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "playback_cut_preview_postroll_seconds"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 0.25,
            "maximum": 10,
            "description": "Seconds played after a cut, 0.25\u201310. Factory 1."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "playback_viewer_force_sdr_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Force SDR on every picture surface except the Video Monitor. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "playback_monitor_force_sdr_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Force SDR on the Video Monitor. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "playback_monitor_clean_feed_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Clean feed on the Video Monitor. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "playback_monitor_placement"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "other_display",
              "last_position"
            ],
            "description": "Where the Video Monitor opens. Factory other_display."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "analysis_scene_auto_scan_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Scan for scenes when a recording is added. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "analysis_silence_auto_scan_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Scan for pauses when a recording is added. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "tiles_scan_default_layout"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "video_call",
              "camera_multiview",
              "even_grid"
            ],
            "description": "Find Tiles layout for a recording with no saved layout. A build without TileTrail uses even_grid. Factory video_call."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "tiles_scan_default_grid_columns"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "integer",
            "minimum": 1,
            "maximum": 12,
            "description": "Find Tiles grid columns, 1\u201312. Factory 2."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "tiles_scan_default_grid_rows"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "integer",
            "minimum": 1,
            "maximum": 12,
            "description": "Find Tiles grid rows, 1\u201312. Factory 2."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "tiles_scan_default_detail"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "adaptive",
              "every_frame",
              "sparse"
            ],
            "description": "Find Tiles scan detail. Factory adaptive."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "tiles_dialogue_default_min_hold_seconds"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 0.04,
            "maximum": 60,
            "description": "Dialogue switches minimum hold in seconds, 0.04\u201360. Factory 1."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "tiles_dialogue_default_overlap_policy"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "hold",
              "visible_speaker"
            ],
            "description": "Dialogue switches during overlapping speech. Factory hold."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "tiles_dialogue_default_offscreen_policy"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "hold",
              "original",
              "reaction"
            ],
            "description": "Dialogue switches for an offscreen speaker. Factory hold."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_default_engine"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "string",
            "maxLength": 128,
            "description": "Preferred transcription engine name; empty is Automatic (Qwen3, then the first available). Factory empty."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_default_speaker_identification_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Identify speakers in mixed audio. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_default_model_download_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Download missing models. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_follow_playback_default_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Follow playback in new windows. Starting value. Factory true."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_reader_text_size_points"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 11,
            "maximum": 24,
            "description": "Transcript reader text size in points, 11\u201324. Factory 14."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_edit_default_boundary_policy"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "nearest_frame",
              "copy_safe",
              "exact"
            ],
            "description": "Transcript edit boundary. Factory nearest_frame."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_tighten_default_retained_pause_seconds"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 0,
            "maximum": 10,
            "description": "Pause to keep when tightening, in seconds, 0\u201310. Factory 0.2."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_default_filler_terms"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "string",
            "maxLength": 4096,
            "description": "Filler terms as one string, terms separated by commas. Factory empty."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_export_default_format"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "json",
              "text",
              "srt",
              "vtt"
            ],
            "description": "Export Transcript format. Factory json."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_caption_max_line_characters"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "integer",
            "minimum": 20,
            "maximum": 80,
            "description": "Caption characters per line, 20\u201380. Factory 42."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_caption_max_lines"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "integer",
            "minimum": 1,
            "maximum": 3,
            "description": "Caption lines per cue, 1\u20133. Factory 2."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_caption_max_cue_seconds"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 1,
            "maximum": 20,
            "description": "Longest caption cue in seconds, 1\u201320. Factory 6."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "transcript_caption_speaker_labels_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Speaker labels in captions. Factory true."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_reencode_default_codec"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "h264",
              "hevc",
              "prores"
            ],
            "description": "Default re-encode video codec. Factory h264."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_reencode_default_quality"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "smaller",
              "balanced",
              "high"
            ],
            "description": "Default H.264 and HEVC quality. Factory balanced."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_prores_default_quality"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "422-lt",
              "422",
              "422-hq"
            ],
            "description": "Default ProRes quality. Factory 422."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_reencode_default_container"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "automatic",
              "mp4",
              "mov",
              "mkv"
            ],
            "description": "H.264 and HEVC container; automatic is MP4 in the sequence editor and MOV in multicam. ProRes stays MOV. Factory automatic."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_multicam_default_audio_layout"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "separate_tracks",
              "downmix_mono",
              "downmix_stereo"
            ],
            "description": "Default multicam audio layout. Factory separate_tracks."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_result_json_default_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Save Export Result JSON. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "resolve_send_open_timeline_default_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Open the timeline in Resolve after sending. Factory true."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_start_folder_mode"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "enum": [
              "automatic",
              "project",
              "source",
              "chosen"
            ],
            "description": "Where export panels start. Factory automatic."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_finished_reveal_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Show in Finder when an export finishes. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_finished_notification_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Notify when an export finishes. Setting it never asks for notification permission. Factory false."
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "const": "export_finished_sound_enabled"
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean",
            "description": "Play a sound when an export finishes. Factory false."
          }
        }
      }
    }
  ]
}
```

### `project_close`

Close this window. Specify what to do with unsaved edits; save requires a .cut path if the document is untitled.

`closed` reports whether the window closed. A dirty project requires a `changes` decision. Saving an untitled project also requires `project_path`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `changes` | optional | `save` / `discard` / `cancel` |  |
| `project_path` | optional | string, minimum length `1`, pattern `^/` | Absolute local filesystem path. |
| `replace_existing` | optional | boolean |  |

### `project_create`

Create a new ordinary sequence or multicam project window. Supply local recording paths for initial import. Multicam requires a camera and opens the setup sheet.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `kind` | optional | `sequence` / `multicam` |  |
| `paths` | optional | array of string, minimum length `1`, pattern `^/`, minimum items `1`, maximum items `512` |  |

### `project_draft_recover`

Recover an unlocked draft from a path returned by project_drafts_list.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `draft_path` | required | string, minimum length `1`, pattern `^/` | Absolute local filesystem path. |

### `project_drafts_list`

List unlocked untitled project recovery files and last-modified times.

Each entry in `drafts[]` contains its recoverable `draft_path` and modification time.

Pass an empty arguments object.

### `project_media_add`

Add local recordings using the native editor. In a sequence, append or insert at index; in a multicam editor this opens source setup. Read editor state after partial import.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `paths` | required | array of string, minimum length `1`, pattern `^/`, minimum items `1`, maximum items `512` |  |
| `index` | optional | integer, minimum `0` |  |

### `project_open`

Open a saved MPCut project and wait for native document loading. An already-open document is activated.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `project_path` | required | string, minimum length `1`, pattern `^/` | Absolute local filesystem path. |

### `project_operation_cancel`

Cancel the exact native worker returned by project_operations_list. Supply its same project handle for window-owned work. An ended worker cannot cancel its successor.

`cancellation_requested` acknowledges the request for the supplied native operation ID. Read active operations again. An operation that ended can return `operation_ended`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | optional | string, minimum length `1` | Target live window. Omit for app-wide project conversion. |
| `native_operation_id` | required | string, format `uuid` |  |
| `operation_id` | required | string, minimum length `1`, maximum length `128` |  |

### `project_operations_list`

Inspect current native UI import/export/multicam workers for a specified project, including conversion started in that window. Omit project to inspect app-wide conversion. Scene/silence scans use analysis_editor_state_read.

`operations[]` identifies active native workers by `native_operation_id`, kind, label, state and progress when available. Supply the project for a project-owned worker. Omit it for an unowned project conversion.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | optional | string, minimum length `1` | Target live window. Omit for app-wide project conversion. |

### `project_save`

Save the live project with native history. Supply a new .cut path for Save As. Writing over another existing destination requires replace_existing.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `project_path` | optional | string, minimum length `1`, pattern `^/` | Absolute local filesystem path. |
| `replace_existing` | optional | boolean |  |

### `project_window_focus`

Bring the specified project window to the front.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |

### `recent_files_clear`

Clear the application’s Open Recent menu. Returns the remaining paths.

Returns absolute local `paths[]` from Open Recent, newest first. Clearing returns an empty list.

Pass an empty arguments object.

### `recent_files_list`

List the absolute local paths shown in Open Recent, newest first.

Returns absolute local `paths[]` from Open Recent, newest first. Clearing returns an empty list.

Pass an empty arguments object.

### `workspace_notice_dismiss`

Dismiss a native informational or error notice after inspecting it. Use its exact message so a newer notice remains visible.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending`, `monitor_visible` and `history_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `message` | required | string, minimum length `1` |  |
| `project_handle` | required | string, minimum length `1` |  |

## Live project media

### `project_editor_media_leave_offline`

Mark a current media reference as deliberately offline.

Returns `changed` and the current `revision`. The change applies across retained history without adding an undo step.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Revision from the editor state or the candidate receipt. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for this request. Reuse it to retry an identical request. |
| `source` | required | string, minimum length `1` | Path returned by the project media list, or an absolute source path. |

### `project_editor_media_list`

List current project media references, their statuses and uses.

Returns paged `items`, `offset` and `total`. Each row reports the path, status and uses. Set `include_history` to include retained edits.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Zero-based page offset. |
| `limit` | optional | integer, minimum `1`, maximum `256` | Maximum number of media rows to return. |
| `expected_revision` | optional | integer, minimum `0` | Pin pagination to the revision from the previous page. |
| `include_history` | optional | boolean | Include media used only by retained undo or redo states. Defaults to false. |

### `project_editor_media_locate`

Search a folder for relink candidates. Set apply_matches to apply unique verified or matched candidates. Poll analysis_job_status_read for the outcome.

Returns an analysis receipt for `analysis_job_status_read`. With `apply_matches`, the completed receipt reports `candidates`, `applied`, `failures`, `changed` and the resulting `revision`. To review candidates first, omit `apply_matches` and pass approved mappings and `locate_job_id` to `project_editor_media_relink` at the receipt's `input_revision`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Revision from the editor state or the candidate receipt. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for this request. Reuse it to retry an identical request. |
| `folder` | required | string, pattern `^/` | Absolute path to the folder to search, including its subdirectories. |
| `include_history` | optional | boolean | Include media used only by retained undo or redo states. Defaults to false. |
| `apply_matches` | optional | boolean | Apply unique verified or matched candidates. Defaults to false. |

### `project_editor_media_relink`

Relink one or more paths to the same media, including references in retained undo and redo history.

Returns `applied` old paths, `failures` keyed by old path and whether the project changed. Relink updates every retained state in place.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Revision from the editor state or the candidate receipt. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for this request. Reuse it to retry an identical request. |
| `from` | optional | string, minimum length `1` | Path returned by the project media list, or an absolute source path. |
| `to` | optional | string, pattern `^/` | Absolute path to the candidate media file. |
| `mappings` | optional | array of object, minimum items `1`, maximum items `256` | Explicit old-to-new path mappings. |
| `mappings[].from` | required | string, minimum length `1` | Path returned by the project media list, or an absolute source path. |
| `mappings[].to` | required | string, pattern `^/` | Absolute path to the candidate media file. |
| `from_prefix` | optional | string, pattern `^/` | Previous folder root. |
| `to_prefix` | optional | string, pattern `^/` | New folder root. |
| `locate_job_id` | optional | string, format `uuid` | Use candidate generations from this completed locate job. Supply exact from and to paths from its candidate rows. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "from",
        "to"
      ],
      "not": {
        "required": [
          "mappings"
        ]
      },
      "allOf": [
        {
          "not": {
            "required": [
              "from_prefix"
            ]
          }
        },
        {
          "not": {
            "required": [
              "to_prefix"
            ]
          }
        }
      ]
    },
    {
      "required": [
        "mappings"
      ],
      "allOf": [
        {
          "not": {
            "required": [
              "from"
            ]
          }
        },
        {
          "not": {
            "required": [
              "to"
            ]
          }
        },
        {
          "not": {
            "required": [
              "from_prefix"
            ]
          }
        },
        {
          "not": {
            "required": [
              "to_prefix"
            ]
          }
        }
      ]
    },
    {
      "required": [
        "from_prefix",
        "to_prefix"
      ],
      "allOf": [
        {
          "not": {
            "required": [
              "from"
            ]
          }
        },
        {
          "not": {
            "required": [
              "to"
            ]
          }
        },
        {
          "not": {
            "required": [
              "mappings"
            ]
          }
        },
        {
          "not": {
            "required": [
              "locate_job_id"
            ]
          }
        }
      ]
    }
  ]
}
```

### `project_editor_media_replace`

Preview the consequences of replacing a source. Set confirm to true to apply the replacement.

Returns the ripple `report` with warnings, blockers, affected uses and before and after duration. A preview returns `preview_id`. Repeat the reviewed request with `confirm: true` and `preview_id` to apply the reviewed file generation at that revision. Read `changed` to see whether an edit was committed.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Revision from the editor state or the candidate receipt. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for this request. Reuse it to retry an identical request. |
| `source` | required | string, minimum length `1` | Path returned by the project media list, or an absolute source path. |
| `with` | required | string, pattern `^/` | Absolute path to the candidate media file. |
| `conform` | optional | `trim` / `keep` | Trim overlapping ranges to the new end, or keep affected ranges offline. Defaults to trim. |
| `allow_loss` | optional | boolean | Approve the selected handling of ranges beyond the new end. |
| `confirm` | optional | boolean | Apply the replacement. Omit or set false to preview. |
| `use_id` | optional | string, minimum length `1` | Apply to one use ID from project_editor_media_list. Omit to replace all uses. |
| `loss` | optional | `remove` / `keep_offline` | Explicit treatment of uses starting beyond the new source extent. |
| `clock` | optional | `source_relative` / `source_timecode` | Preserve relative times or map cuts through comparable source clocks. |
| `stream_mapping` | optional | array of object, maximum items `256` | Map selected old audio streams to candidate audio streams. |
| `stream_mapping[].from` | required | integer, minimum `0` |  |
| `stream_mapping[].to` | required | integer, minimum `0` |  |
| `reset_crop` | optional | boolean | Reset authored still crop to fit the new image. |
| `replacement_offset` | optional | string, minimum length `1` | Exact multicam source offset in seconds or as a rational. |
| `shared_time_of_day` | optional | boolean | Confirm that comparable mixed clock kinds share a time of day. |
| `transcript` | optional | `keep_unverified` / `retranscribe` | Keep the transcript unverified or remove the affected binding for retranscription. |
| `resync` | optional | `timecode` / `waveform` | Recompute multicam alignment using the selected method. |
| `preview_id` | optional | string, format `uuid` | Apply the exact reviewed preview. Repeat the same source, candidate and options with confirm true. |

Additional schema rules

```json
{
  "allOf": [
    {
      "if": {
        "required": [
          "preview_id"
        ]
      },
      "then": {
        "required": [
          "confirm"
        ],
        "properties": {
          "confirm": {
            "const": true
          }
        }
      }
    }
  ]
}
```

### `project_editor_media_revert`

Restore a previous media location when all current and retained uses trace to its relink.

Returns `changed` and the current `revision`. The change applies across retained history without adding an undo step.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Revision from the editor state or the candidate receipt. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for this request. Reuse it to retry an identical request. |
| `source` | required | string, minimum length `1` | Path returned by the project media list, or an absolute source path. |

## Multicam

### `multicam_assembly_edit`

Edit retained occurrences. append requires group from/to; trim requires occurrence and from or to; move requires occurrence and before; remove requires an explicit occurrence. Removing the last explicit occurrence restores the implicit full group. Selection actions require space, from and to matching the selected range; read those values from multicam_selection_set. Use trim_edge or preview_trim with occurrence, edge and group time for native handle snapping. apply_edge_suggestion moves the unsafe range edge reported by multicam_state_read suggestions to one of its verified times in to. Set a picture-only occurrence override with angle_set (occurrence and angle_id), or restore group picture switches with angle_clear (occurrence).

Reports `revision`, `changed` and `history_retained`. `trim_edge` and `preview_trim` report an exact group `boundary`. `angle_set` and `angle_clear` set or remove a picture override for one occurrence. A committed edit reports its native action and can carry a draft-write warning.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `append` | group from and to |
| `trim` | occurrence with new group from and/or to |
| `trim_edge`, `preview_trim` | occurrence, edge and group time |
| `move`, `remove` | occurrence. Move also needs the insertion slot in before |
| `angle_set`, `angle_clear` | occurrence. Setting an override also needs angle_id |
| `apply_edge_suggestion` | one of the suggested edge times in to |
| `split_selection`, `subtract_selection` | select a nonempty group or assembly interval first, then pass its exact space, from and to |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Live project handle returned by project_windows_list. |
| `expected_revision` | required | integer | Revision from project_editor_state_read. |
| `operation_id` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `action` | required | `append` / `trim` / `move` / `remove` / `split_selection` / `subtract_selection` / `trim_edge` / `preview_trim` / `apply_edge_suggestion` / `angle_set` / `angle_clear` |  |
| `occurrence` | optional | integer | Zero-based assembly occurrence. |
| `before` | optional | integer | Zero-based insertion slot before removal, from 0 through count. |
| `from` | optional | string | Exact rational seconds on the group clock for append or trim, or the selected clock for a selection edit. |
| `to` | optional | string | Exact rational seconds on the group clock for append or trim, or the selected clock for a selection edit. |
| `edge` | optional | `start` / `end` |  |
| `time` | optional | string | Group time for a snapped trim edge. |
| `space` | optional | `group` / `assembly` |  |
| `angle_id` | optional | string | Camera angle ID for angle_set. |

### `multicam_camera_take`

Take a camera by angle ID or displayed number at an explicit group time with native snapping and history. Returns the actual time and end of the affected switch interval.

`angle_id`, `group_time` and `group_until` identify the actual group interval affected. Assembly uses follow the group switch unless the occurrence has a picture override. The result reports `changed` and `history_retained`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Live project handle returned by project_windows_list. |
| `expected_revision` | required | integer | Revision from project_editor_state_read. |
| `operation_id` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `angle_id` | optional | string | Stable camera source ID from the live project. |
| `camera_number` | optional | integer, minimum `1` | One-based displayed camera number from the current revision. |
| `occurrence` | optional | integer, minimum `0` | Optional source-backed assembly occurrence from the current revision. |
| `group_time` | required | string | Exact rational seconds on the multicam group clock. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "angle_id"
      ]
    },
    {
      "required": [
        "camera_number"
      ]
    }
  ]
}
```

### `multicam_group_end_set`

Set the group end using time or extend to the last available camera.

Reports the actual `group_to`, `revision`, `changed` and `history_retained`. A committed edit reports its native action and can carry a draft-write warning.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `set_end` | new group end time |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Live project handle returned by project_windows_list. |
| `expected_revision` | required | integer | Revision from project_editor_state_read. |
| `operation_id` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `action` | required | `set_end` / `extend` |  |
| `time` | optional | string | Exact rational seconds on the multicam group clock. |

### `multicam_preview_control`

Set preview mode or transport. audition takes angle; speed takes a rate; shuttle and step actions take direction; snap takes target.

Reports the current clock, `time`, `group_time`, `playing`, `rate`, forward `speed`, `auditioning` and, in assembly preview, the current `occurrence`.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `audition` | angle ID |
| `shuttle`, `step`, `step_keyframe`, `step_scene`, `step_pause` | direction (-1 or 1) |
| `scrub_group`, `scrub_assembly` | time on the selected clock |
| `speed`, `snap` | speed multiplier, or snap target |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Live project handle returned by project_windows_list. |
| `action` | required | `group` / `assembly` / `audition` / `program` / `shuttle` / `speed` / `step` / `step_keyframe` / `step_scene` / `step_pause` / `start` / `end` / `snap` / `scrub_group` / `scrub_assembly` / `end_scrub` |  |
| `angle_id` | optional | string | Stable camera source ID from the live project. |
| `speed` | optional | `0.125` / `0.25` / `0.5` / `0.75` / `1` / `1.25` / `1.5` / `2` / `4` / `8` |  |
| `direction` | optional | `-1` / `1` |  |
| `target` | optional | `off` / `keyframes` / `scenes` / `silence` |  |
| `time` | optional | string | Scrub position in the specified clock, rational seconds. |

### `multicam_program_audio_set`

Set Fixed, Follow, None or Mix audio. Mix accepts an ordered lane list. Replace applies one soundtrack and clears switch overrides. For an external replacement, supply a reference_source_id and confirmed relative_offset to align the incoming sound.

Reports `revision`, `changed` and `history_retained`. A committed edit reports its native action and can carry a draft-write warning.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Live project handle returned by project_windows_list. |
| `expected_revision` | required | integer | Revision from project_editor_state_read. |
| `operation_id` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `mode` | required | `fixed` / `follow` / `none` / `replace` / `mix` |  |
| `source_id` | optional | string | Stable ID of a camera or separate audio source. |
| `audio_stream_index` | optional | integer | Absolute audio stream index in the indicated source. |
| `replacement` | optional | string, minimum length `1` | Absolute path to an external replacement recording. |
| `replacement_audio_stream_index` | optional | integer, minimum `0` |  |
| `lanes` | optional | array of object |  |
| `lanes[].id` | required | string, minimum length `1` |  |
| `lanes[].label` | required | string, minimum length `1` |  |
| `lanes[].color_slot` | required | integer, minimum `0`, maximum `7` |  |
| `lanes[].target` | required | object or object |  |
| `lanes[].target` | when using this variant | object | object variant |
| `lanes[].target.kind` | required | `camera` |  |
| `lanes[].target.angle_id` | required | string, minimum length `1` |  |
| `lanes[].target` | when using this variant | object | object variant |
| `lanes[].target.kind` | required | `recording` |  |
| `lanes[].target.source_id` | required | string, minimum length `1` |  |
| `lanes[].target.audio_stream_index` | required | integer, minimum `0` |  |
| `reference_source_id` | optional | string, minimum length `1` | Camera recording ID for an aligned program replacement. |
| `relative_offset` | optional | string, minimum length `1` | Confirmed rational offset relative to the reference recording. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "properties": {
        "mode": {
          "enum": [
            "none",
            "follow"
          ]
        }
      },
      "allOf": [
        {
          "not": {
            "required": [
              "source_id"
            ]
          }
        },
        {
          "not": {
            "required": [
              "audio_stream_index"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement_audio_stream_index"
            ]
          }
        },
        {
          "not": {
            "required": [
              "lanes"
            ]
          }
        }
      ]
    },
    {
      "properties": {
        "mode": {
          "enum": [
            "fixed",
            "replace"
          ]
        }
      },
      "required": [
        "source_id",
        "audio_stream_index"
      ],
      "allOf": [
        {
          "not": {
            "required": [
              "replacement"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement_audio_stream_index"
            ]
          }
        },
        {
          "not": {
            "required": [
              "lanes"
            ]
          }
        }
      ]
    },
    {
      "properties": {
        "mode": {
          "const": "replace"
        }
      },
      "required": [
        "replacement"
      ],
      "allOf": [
        {
          "not": {
            "required": [
              "source_id"
            ]
          }
        },
        {
          "not": {
            "required": [
              "audio_stream_index"
            ]
          }
        },
        {
          "not": {
            "required": [
              "lanes"
            ]
          }
        }
      ]
    },
    {
      "properties": {
        "mode": {
          "const": "mix"
        }
      },
      "required": [],
      "allOf": [
        {
          "not": {
            "required": [
              "source_id"
            ]
          }
        },
        {
          "not": {
            "required": [
              "audio_stream_index"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement_audio_stream_index"
            ]
          }
        }
      ]
    },
    {
      "properties": {
        "mode": {
          "const": "fixed"
        }
      },
      "required": [],
      "allOf": [
        {
          "not": {
            "required": [
              "source_id"
            ]
          }
        },
        {
          "not": {
            "required": [
              "audio_stream_index"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement_audio_stream_index"
            ]
          }
        },
        {
          "not": {
            "required": [
              "lanes"
            ]
          }
        }
      ]
    }
  ],
  "allOf": [
    {
      "if": {
        "required": [
          "reference_source_id"
        ]
      },
      "then": {
        "required": [
          "reference_source_id",
          "relative_offset",
          "replacement",
          "replacement_audio_stream_index"
        ],
        "properties": {
          "mode": {
            "const": "replace"
          }
        }
      }
    },
    {
      "if": {
        "required": [
          "relative_offset"
        ]
      },
      "then": {
        "required": [
          "reference_source_id",
          "relative_offset",
          "replacement",
          "replacement_audio_stream_index"
        ],
        "properties": {
          "mode": {
            "const": "replace"
          }
        }
      }
    }
  ]
}
```

### `multicam_selection_set`

Select a switch at group time, occurrence by index, a range with from/to in the named clock, tool or marks in this window.

Reports selection and current preview position. Assembly selection uses the occurrence or bounds from the current revision.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `switch`, `occurrence` | switch time, or occurrence index |
| `group_range`, `assembly_range` | from and to in the chosen clock |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Live project handle returned by project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | Required when selecting an occurrence from an assembly with still inserts. |
| `action` | required | `switch` / `occurrence` / `group_range` / `assembly_range` / `mark_in` / `mark_out` / `clear_marks` / `pointer` / `range_tool` |  |
| `time` | optional | string | Exact rational seconds on the multicam group clock. |
| `occurrence` | optional | integer | Zero-based assembly occurrence. |
| `from` | optional | string | Inclusive range start, rational seconds. |
| `to` | optional | string | Exclusive range end, rational seconds. |

### `multicam_source_edit`

Edit a camera or recorder. rename requires name; offset requires offset; nudge/move require direction; nudge also accepts a group time; microphone sets stream (omit to clear); relink uses project_editor_media_relink and requires the same recording at an absolute path; add_recording requires angle_id, an absolute path and group_start.

Reports `revision`, `changed` and `history_retained`. Nudge reports `group_time` and the new `offset`. Relink identifies the source. `add_recording` places an additional file on the specified angle at `group_start`. A committed edit reports its native action and can carry a draft-write warning.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `rename`, `offset`, `relink` | source ID and respectively name, offset, or absolute path |
| `move` | source and direction (-1 or 1) |
| `nudge` | source and direction (-1 or 1), plus optional group time |
| `microphone` | source and optional stream. Omit stream to clear the assignment |
| `add_recording` | angle_id, absolute path and group_start |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Live project handle returned by project_windows_list. |
| `expected_revision` | required | integer | Revision from project_editor_state_read. |
| `operation_id` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `action` | required | `rename` / `offset` / `nudge` / `move` / `microphone` / `relink` / `add_recording` |  |
| `source_id` | optional | string | Stable recording ID. Required except for add_recording. |
| `angle_id` | optional | string | Camera angle ID for add_recording. |
| `group_start` | optional | string | Exact group time at which the new recording’s first picture appears. |
| `name` | optional | string | Display name; empty restores default. |
| `offset` | optional | string | Exact sync offset in rational seconds. |
| `time` | optional | string | Group time for the frame or audio sample used by nudge. Omit to use the current group playhead. |
| `direction` | optional | `-1` / `1` |  |
| `audio_stream_index` | optional | integer | Absolute audio stream index in the indicated source. |
| `path` | optional | string | Absolute replacement or additional recording path. |

### `multicam_state_read`

Inspect the live group, program audio and reference camera. Page sources with offsets, index issues and stream IDs, switches with overrides, persistent transcript voice links, suggested switch boundaries and range edges, assembly occurrences, or still placements. For switch_coverage, supply group_time and angle_id to check the proposed snapped interval before committing a take. The audio section gives the saved Mix lanes and bindings and the resolved program spans and gaps.

Returns the chosen page of sources, switches, suggestions, assembly occurrences or stills, group range, audio policy, `total` and revision. Camera rows identify the displayed angle and recording; separate recordings on an angle can carry explicit group coverage. Sources report availability and indexing state, with duration when known. Assembly rows may identify an occurrence-specific `angle_id`. The `switch_coverage` section reports the proposed group interval, picture and audio status, audio routes and missing group intervals. After an export fails at a range edge, the suggestions section includes `edge` with the one-based `range`, its `boundary` (`from` or `to`), the edge time `at` and the verified `times` it can move to.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `section` | required | `sources` / `switches` / `suggestions` / `assembly` / `stills` / `switch_coverage` / `audio` / `voice_angles` |  |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `200` |  |
| `expected_revision` | optional | integer, minimum `0` |  |
| `angle_id` | optional | string | Camera angle ID for switch_coverage. |
| `group_time` | optional | string | Requested exact group time for switch_coverage. |

### `multicam_switch_edit`

Edit an existing group switch at time. move/apply_suggestion require to, angle requires angle, audio requires source and stream. default_audio restores project routing.

Reports `revision`, `changed` and `history_retained`. A committed edit reports its native action and can carry a draft-write warning.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `move`, `apply_suggestion` | existing switch time and new group time in to |
| `angle` | existing time and angle ID |
| `audio` | existing time, source and stream |
| `delete`, `default_audio` | existing switch time |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Live project handle returned by project_windows_list. |
| `expected_revision` | required | integer | Revision from project_editor_state_read. |
| `operation_id` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `action` | required | `move` / `apply_suggestion` / `delete` / `angle` / `audio` / `default_audio` |  |
| `time` | required | string | Exact rational seconds on the multicam group clock. |
| `to` | optional | string | Exact rational seconds on the multicam group clock. |
| `angle_id` | optional | string | Stable camera source ID from the live project. |
| `source_id` | optional | string | Stable ID of a camera or separate audio source. |
| `audio_stream_index` | optional | integer | Absolute audio stream index in the indicated source. |

### `multicam_track_audio_edit`

Apply a confirmed rational replacement offset relative to a recording, or remove its binding. Applies to the selected original stream across audio policies.

Returns the revision, edit action, change status and history retention after applying or removing a synced recording replacement.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Live project handle returned by project_windows_list. |
| `expected_revision` | required | integer | Revision from project_editor_state_read. |
| `operation_id` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `action` | required | `set` / `remove` |  |
| `id` | required | string, minimum length `1` |  |
| `original` | optional | object |  |
| `original.source_id` | required | string, minimum length `1` |  |
| `original.audio_stream_index` | required | integer, minimum `0` |  |
| `replacement` | optional | object |  |
| `replacement.source_id` | required | string, minimum length `1` |  |
| `replacement.audio_stream_index` | required | integer, minimum `0` |  |
| `path` | optional | string, minimum length `1`, pattern `^/` |  |
| `replacement_stream_index` | optional | integer, minimum `0` |  |
| `replacement_source_id` | optional | string, minimum length `1` |  |
| `relative_offset` | optional | string, minimum length `1` |  |
| `uncovered` | optional | `keep_original` / `leave_uncovered` |  |

Additional schema rules

```json
{
  "oneOf": [
    {
      "properties": {
        "action": {
          "const": "remove"
        }
      },
      "required": [],
      "allOf": [
        {
          "not": {
            "required": [
              "original"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement"
            ]
          }
        },
        {
          "not": {
            "required": [
              "path"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement_stream_index"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement_source_id"
            ]
          }
        },
        {
          "not": {
            "required": [
              "relative_offset"
            ]
          }
        },
        {
          "not": {
            "required": [
              "uncovered"
            ]
          }
        }
      ]
    },
    {
      "properties": {
        "action": {
          "const": "set"
        }
      },
      "required": [
        "original",
        "replacement",
        "relative_offset",
        "uncovered"
      ],
      "allOf": [
        {
          "not": {
            "required": [
              "path"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement_stream_index"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement_source_id"
            ]
          }
        }
      ]
    },
    {
      "properties": {
        "action": {
          "const": "set"
        }
      },
      "required": [
        "original",
        "path",
        "replacement_stream_index",
        "replacement_source_id",
        "relative_offset",
        "uncovered"
      ],
      "allOf": [
        {
          "not": {
            "required": [
              "replacement"
            ]
          }
        }
      ]
    }
  ]
}
```

### `multicam_track_audio_sync_suggest`

Compare an original scratch stream with a replacement stream and report metadata alignment, waveform alignment and drift. The optional seed is a rational offset relative to the original recording. Set program for program-wide replacement coverage.

Returns the revision, sync evidence for the selected camera and incoming streams, and any metadata or waveform offset relative to the camera recording.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Live project handle returned by project_windows_list. |
| `expected_revision` | required | integer | Revision from project_editor_state_read. |
| `operation_id` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `original` | required | object |  |
| `original.source_id` | required | string, minimum length `1` |  |
| `original.audio_stream_index` | optional | integer, minimum `0` |  |
| `replacement` | optional | object |  |
| `replacement.source_id` | required | string, minimum length `1` |  |
| `replacement.audio_stream_index` | required | integer, minimum `0` |  |
| `path` | optional | string, minimum length `1`, pattern `^/` |  |
| `replacement_stream_index` | optional | integer, minimum `0` |  |
| `replacement_source_id` | optional | string, minimum length `1` |  |
| `seed` | optional | string, minimum length `1` |  |
| `metadata_only` | optional | boolean |  |
| `program` | optional | boolean | Evaluate coverage across the program. The original stream index is optional with a video-only reference. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "replacement"
      ],
      "allOf": [
        {
          "not": {
            "required": [
              "path"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement_stream_index"
            ]
          }
        },
        {
          "not": {
            "required": [
              "replacement_source_id"
            ]
          }
        }
      ]
    },
    {
      "required": [
        "path",
        "replacement_stream_index"
      ],
      "not": {
        "required": [
          "replacement"
        ]
      }
    }
  ],
  "if": {
    "not": {
      "properties": {
        "program": {
          "const": true
        }
      },
      "required": [
        "program"
      ]
    }
  },
  "then": {
    "properties": {
      "original": {
        "properties": {
          "audio_stream_index": {
            "type": "integer",
            "minimum": 0
          }
        },
        "required": [
          "audio_stream_index"
        ]
      }
    }
  }
}
```

### `multicam_voice_angle_edit`

Set a persistent link from a transcript attachment and speaker to a camera angle. Clear it to resume automatic matching. Read explicit links in multicam_state_read with section voice_angles.

Returns the updated project revision after setting or clearing the transcript speaker’s camera assignment.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | optional | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `action` | required | `set` / `clear` |  |
| `attachment_id` | required | string, minimum length `1` |  |
| `speaker_id` | required | string, minimum length `1` |  |
| `angle_id` | optional | string, minimum length `1` | Required for set. |

## Project export settings

### `project_editor_output_read`

Read the project’s effective export canvas, soundtrack, and unchecked-coverage policy.

Returns `output.settings` with canvas, audio and unresolved privacy policy, plus `output.has_stored_canvas`, any still format or soundtrack, and the live revision. Set also reports `changed`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |

### `project_editor_output_set`

Change one or more persistent export settings in a single undoable edit. Save the open project to persist the edit to disk.

Returns `output.settings` with canvas, audio and unresolved privacy policy, plus `output.has_stored_canvas`, any still format or soundtrack, and the live revision. Set also reports `changed`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier. Repeat the exact request after a lost reply. |
| `width` | optional | integer, minimum `2`, maximum `8192` | Canvas width in pixels. Use an even value. |
| `height` | optional | integer, minimum `2`, maximum `8192` | Canvas height in pixels. Use an even value. |
| `frame_rate` | optional | string, minimum length `1` | Frames per second, for example 25 or 30000/1001. |
| `background` | optional | integer, minimum `0`, maximum `16777215` | RGB integer in 0xRRGGBB order. |
| `audio_mode` | optional | `program` / `silence` / `lanes` / `iso` / `follow` | Soundtrack mode. Still timelines use the still soundtrack tools. |
| `audio_ids` | optional | array of string, minimum length `1`, minimum items `1` | One feed ID for iso, one camera ID for follow, or mix lane IDs for lanes. Omit for program or silence. |
| `unresolved_privacy` | optional | `stop` / `cover` | Stop export on unchecked coverage or cover the unchecked picture. |

### `project_file_output_read`

Read the project’s effective export canvas, soundtrack, and unchecked-coverage policy. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. The completed result includes `output.settings`, `output.has_stored_canvas` and any still format or soundtrack. Set also reports `changed` and `out_project`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_path` | required | string, pattern `^/` |  |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry an identical request. |
| `working_directory` | optional | string, pattern `^/` |  |

### `project_file_output_set`

Change one or more persistent export settings in a single undoable edit. Supply either out_project or in_place. Poll file_job_status_read with the returned job_id.

Returns a file job receipt. The completed result includes `output.settings`, `output.has_stored_canvas` and any still format or soundtrack. Set also reports `changed` and `out_project`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_path` | required | string, pattern `^/` |  |
| `operation_id` | required | string, format `uuid` | Fresh UUID for a distinct file job. Reuse it to retry an identical request. |
| `working_directory` | optional | string, pattern `^/` |  |
| `width` | optional | integer, minimum `2`, maximum `8192` | Canvas width in pixels. Use an even value. |
| `height` | optional | integer, minimum `2`, maximum `8192` | Canvas height in pixels. Use an even value. |
| `frame_rate` | optional | string, minimum length `1` | Frames per second, for example 25 or 30000/1001. |
| `background` | optional | integer, minimum `0`, maximum `16777215` | RGB integer in 0xRRGGBB order. |
| `audio_mode` | optional | `program` / `silence` / `lanes` / `iso` / `follow` | Soundtrack mode. Still timelines use the still soundtrack tools. |
| `audio_ids` | optional | array of string, minimum length `1`, minimum items `1` | One feed ID for iso, one camera ID for follow, or mix lane IDs for lanes. Omit for program or silence. |
| `unresolved_privacy` | optional | `stop` / `cover` | Stop export on unchecked coverage or cover the unchecked picture. |
| `out_project` | optional | string, pattern `^/` | Absolute path for a new .cut document. Choose one destination. |
| `in_place` | optional | boolean | Set true to update the original saved project. |

## Live exports

### `export_editor_boundary_apply`

Apply one verified boundary change as a native undo step. Run export_editor_project_plan first. For a still-bearing timeline supply the exact still adjustment from its camera-copy preflight.

Returns the native action, applied revision and review details when the current copy-boundary proposal is committed. A retained action can be undone through native history.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `mode` | optional | `smart` / `copy` | Mode used to review the still boundary. Defaults to smart. |
| `tracks` | optional | `all` / `video` | Tracks used to review the still boundary. Defaults to all. |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` | Sound action used to review the still boundary. |
| `still_adjustment` | optional | object | Exact adjustment from result.issue.still_boundary_adjustments for a whole-timeline dry run with require_camera_copy. |
| `still_adjustment.placement_id` | required | string, minimum length `1` |  |
| `still_adjustment.boundary` | required | `start` / `end` / `insertion` |  |
| `still_adjustment.clock` | required | `source` / `group` / `sequence` / `assembly` |  |
| `still_adjustment.occurrence_id` | optional | string, minimum length `1` |  |
| `still_adjustment.requested_time` | required | object |  |
| `still_adjustment.requested_time.numerator` | required | integer |  |
| `still_adjustment.requested_time.denominator` | required | integer, minimum `1` |  |
| `still_adjustment.adjusted_time` | required | object |  |
| `still_adjustment.adjusted_time.numerator` | required | integer |  |
| `still_adjustment.adjusted_time.denominator` | required | integer, minimum `1` |  |
| `still_adjustment.duration_change` | required | object |  |
| `still_adjustment.duration_change.numerator` | required | integer |  |
| `still_adjustment.duration_change.denominator` | required | integer, minimum `1` |  |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |

### `export_editor_job_cancel`

Request cancellation of this project’s specific output job; inspect its terminal result to see which outputs were published.

Returns `state`, `progress`, `input_revision` and published `outputs`. After cancellation, poll until terminal. Read `result` or `error`; a failed batch can already have published files.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `job_id` | required | string, minimum length `1` |  |

### `export_editor_job_status_read`

Read progress, terminal outcome and published paths for an export job in this project.

Returns `state`, `progress`, `input_revision` and published `outputs`. After cancellation, poll until terminal. Read `result` or `error`; a failed batch can already have published files.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `job_id` | required | string, minimum length `1` |  |

### `export_editor_project_plan`

Plan the open project export and report eligible ranges, review findings and the occurrence-level cut map when available. An ordinary plan lists under warnings what the output does not keep: reductions made by an encode, and cover art, attached files, chapters, timecode, or subtitle and data tracks that a copy leaves behind. A plain copy that keeps everything has no warnings field. A re-encode lists each audio track under audio_actions with its codec, bit_rate or bit_depth and reason. A multicam plan also lists under warnings, after the plan's own, what its program leaves out of its sources, such as the chapters of a camera other than the reference angle; plan.warnings keeps the plan's own. Still plans carry their warnings inside plan. When audio auto cannot copy a sound-only selection, applied names the conversion the export rules chose and warnings begin with what it gives up.

Starts a live job. Poll `export_editor_job_status_read` for its result. A successful dry run can report `eligible: false` with `reason` and any available structured `issue`, `proposed_ranges`, `alternatives` or `fallback`. An eligible plan or render can include `cut_map.occurrences[]` in playback order, with individual requested, resolved and output ranges and render segment references. Still plans report copied and encoded camera duration, generated still duration and sample count, placement ranges, effective output codec and sound actions. Confirm published paths in the job’s `outputs`. `warnings` lists what a copy cannot carry in the chosen container and the notes of a re-encode, and is absent for a plain copy that keeps everything. A re-encode also reports `audio_actions` with each track’s codec, bit rate or bit depth, and reason.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `scope` | optional | `timeline` / `selection` / `group` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `require_camera_copy` | optional | boolean | Require zero encoded camera duration when generating stills. |
| `mode` | optional | `smart` / `copy` / `encode` | Defaults to Smart Trim for visible still picture. Other outputs use Settings → Export → Default movie export mode, or their native defaults. |
| `codec` | optional | `h264` / `hevc` / `prores` / `jpeg` | Video codec for Re-encode. When omitted in a live editor, the export uses Settings → Export → Re-encode video where the destination extension can hold it, and H.264 where it cannot. This applies to an ordinary or multicam Re-encode, a Tiles render and a still project without its own format; a still project with a format keeps its format's codec. File jobs and the CLI use the factory value, H.264. |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` | Use smaller, balanced or high for H.264 and HEVC. Use 422-lt, 422 or 422-hq for ProRes. For ordinary movie export, requires Re-encode. Still picture also supports these settings in Smart Trim. When omitted in a live editor, the export uses Settings → Export → Quality or ProRes quality for the chosen codec. File jobs and the CLI use balanced or 422. |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` / `alac` |  |
| `audio_track_ordinal` | optional | integer, minimum `0` | Zero-based track within the ordinary source audio tracks. |
| `use_reviewed_cuts` | optional | boolean | Use the native verified copy-boundary proposal for this ordinary export only. The timeline and its history stay intact. |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Multicam audio delivery. Separate tracks preserve lane order. Downmix renders the lanes into one mono or stereo track. When omitted in a live multicam editor, the export uses Settings → Export → Multicam audio. A downmix from Settings applies only when the output keeps sound, audio is omitted, auto, pcm or aac, and the destination extension renders that sound; otherwise separate tracks. File jobs and the CLI use separate tracks. |
| `still_timing` | optional | `cadence` / `held` | Still picture timing. Held writes one independently decodable sample per visible hold. Cadence uses the authored frame schedule. |
| `container` | optional | `mov` / `mp4` / `m4v` / `mkv` / `m4a` / `mka` / `wav` / `wave` / `caf` / `flac` | Explicit container for a still project export. Match the destination filename extension and selected tracks. |

### `export_editor_project_render`

Render the open project to the output path and report its occurrence-level cut map when available. The result reports warnings and audio_actions as export_editor_project_plan does. A written Smart Trim export of a sequence adds encoded_edge_results, one row for each encoded edge with its segment, from, to, encoded_bytes, target_bytes and retried, and for an AV1 edge max_qp, with first_attempt_bytes when it was retried. A written export adds written_warnings when writing changed something no plan could know, such as constant quality the encoder could not take or pictures decoded in software after the hardware decoder failed; the warnings of a plan and its render stay the same.

Starts a live job. Poll `export_editor_job_status_read` for its result. A successful dry run can report `eligible: false` with `reason` and any available structured `issue`, `proposed_ranges`, `alternatives` or `fallback`. An eligible plan or render can include `cut_map.occurrences[]` in playback order, with individual requested, resolved and output ranges and render segment references. Still plans report copied and encoded camera duration, generated still duration and sample count, placement ranges, effective output codec and sound actions. Confirm published paths in the job’s `outputs`. `warnings` lists what a copy cannot carry in the chosen container and the notes of a re-encode, and is absent for a plain copy that keeps everything. A re-encode also reports `audio_actions` with each track’s codec, bit rate or bit depth, and reason.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `scope` | optional | `timeline` / `selection` / `group` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `require_camera_copy` | optional | boolean | Require zero encoded camera duration when generating stills. |
| `mode` | optional | `smart` / `copy` / `encode` | Defaults to Smart Trim for visible still picture. Other outputs use Settings → Export → Default movie export mode, or their native defaults. |
| `codec` | optional | `h264` / `hevc` / `prores` / `jpeg` | Video codec for Re-encode. When omitted in a live editor, the export uses Settings → Export → Re-encode video where the destination extension can hold it, and H.264 where it cannot. This applies to an ordinary or multicam Re-encode, a Tiles render and a still project without its own format; a still project with a format keeps its format's codec. File jobs and the CLI use the factory value, H.264. |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` | Use smaller, balanced or high for H.264 and HEVC. Use 422-lt, 422 or 422-hq for ProRes. For ordinary movie export, requires Re-encode. Still picture also supports these settings in Smart Trim. When omitted in a live editor, the export uses Settings → Export → Quality or ProRes quality for the chosen codec. File jobs and the CLI use balanced or 422. |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` / `alac` |  |
| `audio_track_ordinal` | optional | integer, minimum `0` | Zero-based track within the ordinary source audio tracks. |
| `use_reviewed_cuts` | optional | boolean | Use the native verified copy-boundary proposal for this ordinary export only. The timeline and its history stay intact. |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Multicam audio delivery. Separate tracks preserve lane order. Downmix renders the lanes into one mono or stereo track. When omitted in a live multicam editor, the export uses Settings → Export → Multicam audio. A downmix from Settings applies only when the output keeps sound, audio is omitted, auto, pcm or aac, and the destination extension renders that sound; otherwise separate tracks. File jobs and the CLI use separate tracks. |
| `still_timing` | optional | `cadence` / `held` | Still picture timing. Held writes one independently decodable sample per visible hold. Cadence uses the authored frame schedule. |
| `container` | optional | `mov` / `mp4` / `m4v` / `mkv` / `m4a` / `mka` / `wav` / `wave` / `caf` / `flac` | Explicit container for a still project export. Match the destination filename extension and selected tracks. |

### `export_queue_entry_remove`

Remove one entry from this project’s native export queue.

Returns the default `coordinate_space` and current `ranges[]` with IDs, names when set, boundaries and captured `items[]`. A multicam entry reports its own group or assembly clock. Items identify the file, source `from` and `to`, and the kind (`clip`, `still`, `angle`, `audio`, `gap` or `replacement`). Multicam items report output bounds, audio items can identify a stream, and generated spans can omit source bounds. Still entries with a captured timing choice report `still_timing`. Rename preserves the captured contents. Revise recaptures the current marked edit under the same entry ID and name. Extend requires an enclosing interval on the same clock. An entry with `needs_replan: true` can be removed or replanned. Replan uses the original bounds, or newly marked bounds for a transcript excerpt.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `id` | required | string, minimum length `1` |  |

### `export_queue_entry_rename`

Rename a native queue entry while keeping its captured media and bounds.

Returns the default `coordinate_space` and current `ranges[]` with IDs, names when set, boundaries and captured `items[]`. A multicam entry reports its own group or assembly clock. Items identify the file, source `from` and `to`, and the kind (`clip`, `still`, `angle`, `audio`, `gap` or `replacement`). Multicam items report output bounds, audio items can identify a stream, and generated spans can omit source bounds. Still entries with a captured timing choice report `still_timing`. Rename preserves the captured contents. Revise recaptures the current marked edit under the same entry ID and name. Extend requires an enclosing interval on the same clock. An entry with `needs_replan: true` can be removed or replanned. Replan uses the original bounds, or newly marked bounds for a transcript excerpt.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `id` | required | string, minimum length `1` |  |
| `name` | required | string, minimum length `1` | Display name and default export filename stem. |

### `export_queue_entry_revise`

Recapture the live edit for an existing queue entry. Replace uses the current marks. Extend requires a strict superset in the same coordinate space. Replan applies an affected entry’s original bounds to the current timeline. For an affected transcript excerpt, mark the range to recapture.

Returns the default `coordinate_space` and current `ranges[]` with IDs, names when set, boundaries and captured `items[]`. A multicam entry reports its own group or assembly clock. Items identify the file, source `from` and `to`, and the kind (`clip`, `still`, `angle`, `audio`, `gap` or `replacement`). Multicam items report output bounds, audio items can identify a stream, and generated spans can omit source bounds. Still entries with a captured timing choice report `still_timing`. Rename preserves the captured contents. Revise recaptures the current marked edit under the same entry ID and name. Extend requires an enclosing interval on the same clock. An entry with `needs_replan: true` can be removed or replanned. Replan uses the original bounds, or newly marked bounds for a transcript excerpt.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `id` | required | string, minimum length `1` |  |
| `mode` | required | `replace` / `extend` / `replan` |  |

### `export_queue_list`

Read the native export queue and its captured contents. Each entry includes its identifier, exact marked range, ordered source trims, and whether a media change requires replanning. Mix audio rows include lane_id, lane_label and lane_color_slot. Uncovered audio intervals have kind audio_gap.

Returns the default `coordinate_space` and current `ranges[]` with IDs, names when set, boundaries and captured `items[]`. A multicam entry reports its own group or assembly clock. Items identify the file, source `from` and `to`, and the kind (`clip`, `still`, `angle`, `audio`, `gap` or `replacement`). Multicam items report output bounds, audio items can identify a stream, and generated spans can omit source bounds. Still entries with a captured timing choice report `still_timing`. Rename preserves the captured contents. Revise recaptures the current marked edit under the same entry ID and name. Extend requires an enclosing interval on the same clock. An entry with `needs_replan: true` can be removed or replanned. Replan uses the original bounds, or newly marked bounds for a transcript excerpt.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |

### `export_queue_plan`

Plan exports of queued entries using their captured ranges. range_plans has one row for each ordinary sequence entry: destination, mode, tracks, container, duration, copied_video_duration and encoded_video_duration for picture, audio_actions for converted sound, a summary, and warnings for what the output does not keep, such as cover art, attached files, chapters, timecode, or subtitle and data tracks that a copy leaves behind. Still and multicam entries report under still_plans and multicam_plans. A multicam_plans row adds warnings, after its plan's own, with what its program leaves out of its sources, such as chapters.

Returns a live job receipt with `job_id`, `input_revision`, `state`, `progress` and published `outputs`. Poll `export_editor_job_status_read` with the same project. The terminal result reports planned `destinations` and still plans for applicable queue entries. Affected entries are skipped and their IDs appear in `skipped_needs_replan`. `range_plans[]` gives each ordinary range’s destination, mode, container, copied and encoded video durations, audio actions and `warnings`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `container` | optional | string, minimum length `1` | Container for every queued file. When omitted in a live editor, an H.264 or HEVC Re-encode of ordinary ranges uses Settings → Export → H.264 and HEVC container unless it is Automatic or cannot carry the requested audio; otherwise MOV, or each still project's own format. ProRes stays MOV. |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `require_camera_copy` | optional | boolean | Require zero encoded camera duration when generating stills. |
| `mode` | optional | `smart` / `copy` / `encode` |  |
| `codec` | optional | `h264` / `hevc` / `prores` / `jpeg` | Video codec for Re-encode. When omitted in a live editor, Re-encode with picture of ordinary queued ranges, and a queue with Tiles ranges, use Settings → Export → Re-encode video where the container can hold it, and H.264 where it cannot. Ranges with still picture keep their own format or H.264. |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` | When omitted in a live editor, Re-encode with picture of ordinary queued ranges, and a queue with Tiles ranges, use Settings → Export → Quality or ProRes quality for the chosen codec; other outputs use balanced or 422. |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` / `alac` |  |
| `audio_track_ordinal` | optional | integer, minimum `0` | Zero-based track within the ordinary source audio tracks. |
| `subfolder` | optional | string, minimum length `1` | Optional output subfolder. |
| `base_name` | optional | string, minimum length `1` | Optional filename prefix. |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Multicam audio delivery. Separate tracks preserve lane order. Downmix renders the lanes into one mono or stereo track. When omitted in a live multicam editor, the queue uses Settings → Export → Multicam audio. A downmix from Settings applies only when the output keeps sound, audio is omitted, auto, pcm or aac, and the container renders that sound; otherwise separate tracks. Other callers use separate tracks. |
| `still_timing` | optional | `cadence` / `held` | Still picture timing. Held writes one independently decodable sample per visible hold. Cadence uses the authored frame schedule. |

### `export_queue_range_add`

Add the current marked range to the native queue, preserving the captured edit and media.

Returns the default `coordinate_space` and current `ranges[]` with IDs, names when set, boundaries and captured `items[]`. A multicam entry reports its own group or assembly clock. Items identify the file, source `from` and `to`, and the kind (`clip`, `still`, `angle`, `audio`, `gap` or `replacement`). Multicam items report output bounds, audio items can identify a stream, and generated spans can omit source bounds. Still entries with a captured timing choice report `still_timing`. Rename preserves the captured contents. Revise recaptures the current marked edit under the same entry ID and name. Extend requires an enclosing interval on the same clock. An entry with `needs_replan: true` can be removed or replanned. Replan uses the original bounds, or newly marked bounds for a transcript excerpt.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |

### `export_queue_render`

Render the queued entries to the output directory. The result reports range_plans as export_queue_plan does. A written ordinary range whose Smart Trim encoded edges adds encoded_edge_results to its row, as export_editor_project_render reports them. written_warnings lists, under each file name, what writing changed that no plan could know.

Returns a live job receipt with `job_id`, `input_revision`, `state`, `progress` and published `outputs`. Poll `export_editor_job_status_read` with the same project. The terminal result reports planned `destinations` and still plans for applicable queue entries. Affected entries are skipped and their IDs appear in `skipped_needs_replan`. `range_plans[]` gives each ordinary range’s destination, mode, container, copied and encoded video durations, audio actions and `warnings`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `container` | optional | string, minimum length `1` | Container for every queued file. When omitted in a live editor, an H.264 or HEVC Re-encode of ordinary ranges uses Settings → Export → H.264 and HEVC container unless it is Automatic or cannot carry the requested audio; otherwise MOV, or each still project's own format. ProRes stays MOV. |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `require_camera_copy` | optional | boolean | Require zero encoded camera duration when generating stills. |
| `mode` | optional | `smart` / `copy` / `encode` |  |
| `codec` | optional | `h264` / `hevc` / `prores` / `jpeg` | Video codec for Re-encode. When omitted in a live editor, Re-encode with picture of ordinary queued ranges, and a queue with Tiles ranges, use Settings → Export → Re-encode video where the container can hold it, and H.264 where it cannot. Ranges with still picture keep their own format or H.264. |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` | When omitted in a live editor, Re-encode with picture of ordinary queued ranges, and a queue with Tiles ranges, use Settings → Export → Quality or ProRes quality for the chosen codec; other outputs use balanced or 422. |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` / `alac` |  |
| `audio_track_ordinal` | optional | integer, minimum `0` | Zero-based track within the ordinary source audio tracks. |
| `subfolder` | optional | string, minimum length `1` | Optional output subfolder. |
| `base_name` | optional | string, minimum length `1` | Optional filename prefix. |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Multicam audio delivery. Separate tracks preserve lane order. Downmix renders the lanes into one mono or stereo track. When omitted in a live multicam editor, the queue uses Settings → Export → Multicam audio. A downmix from Settings applies only when the output keeps sound, audio is omitted, auto, pcm or aac, and the container renders that sound; otherwise separate tracks. Other callers use separate tracks. |
| `still_timing` | optional | `cadence` / `held` | Still picture timing. Held writes one independently decodable sample per visible hold. Cadence uses the authored frame schedule. |

### `project_editor_convert`

Export the current unsaved edit as a new .cut, .drp, .drt, .prproj, .fcpxml, .fcpxmld or .fcpbundle. Host applications may be required. Poll export_editor_job_status_read for warnings and actual output paths.

Returns a live job receipt for `export_editor_job_status_read`. Published `outputs` can include both the interchange file and the linked WAV directory. The terminal result reports conversion warnings or whether Resolve opened the timeline, as applicable.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `allow_loss` | optional | boolean |  |
| `flatten_multicam` | optional | boolean |  |

### `project_editor_resolve_export`

Write an interchange timeline from the current project for Resolve. The result lists warnings for what the timeline could not keep exactly, such as cuts rounded to the frame grid.

Returns a live job receipt for `export_editor_job_status_read`. Published `outputs` can include both the interchange file and the linked WAV directory. The terminal result reports conversion warnings or whether Resolve opened the timeline, as applicable.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |

### `project_editor_resolve_import`

Write an interchange timeline and import it into Resolve. The result lists warnings for what the timeline could not keep exactly, such as cuts rounded to the frame grid.

Returns a live job receipt for `export_editor_job_status_read`. Published `outputs` can include both the interchange file and the linked WAV directory. The terminal result reports conversion warnings or whether Resolve opened the timeline, as applicable.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |

### `review_editor_frames_export`

Export review JPEGs from the live editor. Programs with generated stills or tile edits use the rendered program for current-frame and program-time samples. Tile-edited multicam projects can sample switches on the group clock. Scene and non-silent source sampling require a project without tile processing.

Returns a live job receipt for `export_editor_job_status_read`. A still produces a JPEG. A batch returns its `manifest` path and written `frames` count. Tile output reports any applied `privacy_issues`. Ordinary multicam angle samples report `unavailable` when an angle has no picture.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `selection` | optional | `playhead` / `still` / `times` / `switches` / `scenes` / `non_silent` |  |
| `space` | optional | `sequence` / `group` / `assembly` | Still and playhead samples use the active program clock. For explicit times, select the clock of the supplied timestamps. With tile edits, omitting space uses the active program clock. Switch sampling uses multicam group time. |
| `times` | optional | array of string, minimum length `1`, minimum items `1`, maximum items `4096` |  |
| `preset` | optional | `review` / `full` |  |
| `sample` | optional | `first` / `midpoint` |  |
| `limit` | optional | integer, minimum `1` | Optional maximum frame count for scene or non-silent sampling. |

Additional schema rules

```json
{
  "allOf": [
    {
      "if": {
        "properties": {
          "selection": {
            "const": "times"
          }
        },
        "required": [
          "selection"
        ]
      },
      "then": {
        "required": [
          "times"
        ]
      }
    },
    {
      "if": {
        "required": [
          "times"
        ]
      },
      "then": {
        "properties": {
          "selection": {
            "const": "times"
          }
        },
        "required": [
          "selection"
        ]
      }
    },
    {
      "if": {
        "required": [
          "space"
        ]
      },
      "then": {
        "properties": {
          "selection": {
            "enum": [
              "still",
              "playhead",
              "times"
            ]
          }
        }
      }
    },
    {
      "if": {
        "required": [
          "limit"
        ]
      },
      "then": {
        "properties": {
          "selection": {
            "enum": [
              "scenes",
              "non_silent"
            ]
          }
        },
        "required": [
          "selection"
        ]
      }
    }
  ]
}
```

### `sequence_source_soundtrack_replace`

Replace the source soundtrack for a sequence clip, write the working copy to output and record the edit in history.

A sequence needs `clip_id`, `replacement` and an `output` movie. Returns the applied source-audio replacement and output path.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `clip_id` | required | string, minimum length `1` |  |
| `replacement` | required | string, minimum length `1` |  |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `target_audio_stream_index` | optional | integer, minimum `0` |  |
| `replacement_audio_stream_index` | optional | integer, minimum `0` |  |

## Participant tracking, review and delivery

### `participants_file_angles_list`

Plan virtual angles for selected participants on a common source clock. Poll file_job_status_read and fetch the JSON with file_job_result_read.

Returns a file job receipt. The completed result lists the selected virtual angles and their common source-clock interval.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it when retrying the same request in this session. |
| `project_path` | required | string, pattern `^/` | Absolute path to an existing .cut project. |
| `source_id` | required | string, minimum length `1` | Multicam recording ID or a sequence source path from the project. |
| `participant_ids` | optional | array of string, minimum length `1` |  |
| `range` | required | object | Half-open interval in source-relative seconds. |
| `range.from` | required | string, minimum length `1` | Exact rational seconds in the source clock. |
| `range.to` | required | string, minimum length `1` | Exact rational seconds in the source clock. |
| `include_original` | optional | boolean | Include an original gallery angle. |
| `presentation_ids` | optional | array of string, minimum length `1` | Accepted presentation appearance IDs. |

Additional schema rules

```json
{
  "anyOf": [
    {
      "required": [
        "participant_ids"
      ],
      "properties": {
        "participant_ids": {
          "minItems": 1
        }
      }
    },
    {
      "required": [
        "include_original"
      ],
      "properties": {
        "include_original": {
          "const": true
        }
      }
    },
    {
      "required": [
        "presentation_ids"
      ],
      "properties": {
        "presentation_ids": {
          "minItems": 1
        }
      }
    }
  ]
}
```

### `participants_file_angles_plan`

Report picture coverage, duration and audio routing before rendering aligned angle media. Poll file_job_status_read and fetch the JSON with file_job_result_read.

Returns a file job receipt. The completed result reports each angle’s canvas and coverage and the meeting-mix plan.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it when retrying the same request in this session. |
| `project_path` | required | string, pattern `^/` | Absolute path to an existing .cut project. |
| `source_id` | required | string, minimum length `1` | Multicam recording ID or a sequence source path from the project. |
| `participant_ids` | optional | array of string, minimum length `1` |  |
| `range` | required | object | Half-open interval in source-relative seconds. |
| `range.from` | required | string, minimum length `1` | Exact rational seconds in the source clock. |
| `range.to` | required | string, minimum length `1` | Exact rational seconds in the source clock. |
| `canvas` | required | object | ParticipantCanvas with dimensions, frame rate and RGB background. |
| `audio` | optional | object | Optional ParticipantMulticamAudioRouting. Defaults to one gallery mix lane. |
| `include_original` | optional | boolean | Include an original gallery angle. |
| `presentation_ids` | optional | array of string, minimum length `1` | Accepted presentation appearance IDs. |

Additional schema rules

```json
{
  "anyOf": [
    {
      "required": [
        "participant_ids"
      ],
      "properties": {
        "participant_ids": {
          "minItems": 1
        }
      }
    },
    {
      "required": [
        "include_original"
      ],
      "properties": {
        "include_original": {
          "const": true
        }
      }
    },
    {
      "required": [
        "presentation_ids"
      ],
      "properties": {
        "presentation_ids": {
          "minItems": 1
        }
      }
    }
  ]
}
```

### `participants_file_angles_render`

Write aligned participant angle movies and multicam.cut to a new directory. Poll file_job_status_read and fetch the JSON with file_job_result_read.

Returns a file job receipt. The completed result supplies the saved multicam project path and project details.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it when retrying the same request in this session. |
| `project_path` | required | string, pattern `^/` | Absolute path to an existing .cut project. |
| `source_id` | required | string, minimum length `1` | Multicam recording ID or a sequence source path from the project. |
| `participant_ids` | optional | array of string, minimum length `1` |  |
| `range` | required | object | Half-open interval in source-relative seconds. |
| `range.from` | required | string, minimum length `1` | Exact rational seconds in the source clock. |
| `range.to` | required | string, minimum length `1` | Exact rational seconds in the source clock. |
| `canvas` | required | object | ParticipantCanvas with dimensions, frame rate and RGB background. |
| `audio` | optional | object | Optional ParticipantMulticamAudioRouting. Defaults to one gallery mix lane. |
| `output_directory` | required | string, pattern `^/` | Absolute path of a new directory for the angle movies and project. |
| `include_original` | optional | boolean | Include an original gallery angle. |
| `presentation_ids` | optional | array of string, minimum length `1` | Accepted presentation appearance IDs. |

Additional schema rules

```json
{
  "anyOf": [
    {
      "required": [
        "participant_ids"
      ],
      "properties": {
        "participant_ids": {
          "minItems": 1
        }
      }
    },
    {
      "required": [
        "include_original"
      ],
      "properties": {
        "include_original": {
          "const": true
        }
      }
    },
    {
      "required": [
        "presentation_ids"
      ],
      "properties": {
        "presentation_ids": {
          "minItems": 1
        }
      }
    }
  ]
}
```

### `participants_file_angles_take`

Take a virtual angle at an exact output timestamp and save the resulting timed picture decision.

Returns a file job receipt. The completed result supplies the project path and change count.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it when retrying the same request in this session. |
| `project_path` | required | string, pattern `^/` | Absolute path to an existing .cut project. |
| `angle` | required | object | A virtual angle from participants_file_angles_list. |
| `output_time` | required | string, minimum length `1` | Exact timestamp on the edited output clock. |
| `out_project` | optional | string, pattern `^/` | Absolute path for a new .cut project. |
| `in_place` | optional | `true` | Replace the project using its current disk revision. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "out_project"
      ]
    },
    {
      "required": [
        "in_place"
      ]
    }
  ]
}
```

### `participants_file_markers_build`

Generate participant scene candidates from saved scan events without rescanning media. Poll file_job_status_read and fetch the JSON with file_job_result_read.

Returns a file job receipt. The completed result lists proposed markers with source timestamps, changed and eligible counts, and uncertain coverage.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it when retrying the same request in this session. |
| `analysis_file` | required | string, pattern `^/` | Absolute path to the scan JSON. |
| `rule` | optional | object | Optional ParticipantMarkerRule. Defaults to any participant change. |

### `participants_file_project_accept`

Import a saved participant scan into a specific project recording. Verify and correct the accepted associations before rendering. Poll file_job_status_read and fetch the JSON with file_job_result_read.

Returns a file job receipt. The completed result supplies the resulting project path and change count.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it when retrying the same request in this session. |
| `project_path` | required | string, pattern `^/` | Absolute path to an existing .cut project. |
| `source_id` | required | string, minimum length `1` | Multicam recording ID or a sequence source path from the project. |
| `analysis_file` | required | string, pattern `^/` | Absolute path to the scan JSON. |
| `out_project` | optional | string, pattern `^/` | Absolute path for a new .cut project. |
| `in_place` | optional | `true` | Replace the project using its current disk revision. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "out_project"
      ]
    },
    {
      "required": [
        "in_place"
      ]
    }
  ]
}
```

### `participants_file_project_apply`

Replace the accepted participant edit of a saved project. Use project inspect to retrieve the editable participant document. Poll file_job_status_read and fetch the JSON with file_job_result_read.

Returns a file job receipt. The completed result supplies the resulting project path and change count.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it when retrying the same request in this session. |
| `project_path` | required | string, pattern `^/` | Absolute path to an existing .cut project. |
| `participants` | optional | object | The complete ParticipantProject object returned by participants_file_project_inspect. |
| `participants_file` | optional | string, pattern `^/` | Absolute path to a saved participant object. Use this for edits larger than a tool request. |
| `out_project` | optional | string, pattern `^/` | Absolute path for a new .cut project. |
| `in_place` | optional | `true` | Replace the project using its current disk revision. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "out_project"
      ]
    },
    {
      "required": [
        "in_place"
      ]
    }
  ],
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "participants"
          ]
        },
        {
          "required": [
            "participants_file"
          ]
        }
      ]
    }
  ]
}
```

### `participants_file_project_inspect`

Read the portable participant roster, accepted geometry, overrides and render plan of a saved project. Poll file_job_status_read and fetch the JSON with file_job_result_read.

Returns a file job receipt. The completed result contains the editable participant object from the project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it when retrying the same request in this session. |
| `project_path` | required | string, pattern `^/` | Absolute path to an existing .cut project. |

### `participants_file_render_export`

Render participant shots to a new movie. Unresolved privacy intervals follow the plan’s explicit stop or full-frame cover policy. Poll file_job_status_read and fetch the JSON with file_job_result_read.

Returns a file job receipt. The completed result reports the output duration, canvas, audio policy, and coverage. The render result includes the published movie.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it when retrying the same request in this session. |
| `project_path` | required | string, pattern `^/` | Absolute path to an existing .cut project. |
| `plan` | optional | object | Optional ParticipantRenderPlan. Omit this to use the saved participant plan. |
| `output` | required | string, pattern `^/` | Absolute path for a new movie. |

### `participants_file_render_plan`

Report the shot canvas, duration, audio and coverage for a participant render. Poll file_job_status_read and fetch the JSON with file_job_result_read.

Returns a file job receipt. The completed result reports the output duration, canvas, audio policy, and coverage. The render result includes the published movie.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it when retrying the same request in this session. |
| `project_path` | required | string, pattern `^/` | Absolute path to an existing .cut project. |
| `plan` | optional | object | Optional ParticipantRenderPlan. Omit this to use the saved participant plan. |
| `output` | optional | string, pattern `^/` | Optional absolute output path to check without writing a movie. |

### `participants_file_scan`

Scan a video recording for participant observations, tracks, change events and coverage. By default a completed scan is cached in the source’s analysis sidecar. Poll file_job_status_read and fetch the JSON with file_job_result_read.

Returns a file job receipt. The completed result includes analysis identity, source clock, observations, change events, coverage, and backend diagnostics. Use `file_job_result_read` to retrieve a large report.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it when retrying the same request in this session. |
| `file` | required | string, pattern `^/` | Absolute input recording path. |
| `backend` | optional | `auto` / `cpu-only` / `gpu-required` |  |
| `sampling` | optional | `adaptive` / `every-frame` / `sparse` |  |
| `include_scenes` | optional | boolean |  |
| `feed_layout` | optional | string, pattern `^(auto\|[0-9]+x[0-9]+)$` | Use auto or enter COLSxROWS for a fixed grid of up to 64 feeds. Omit for meeting analysis or to reuse a saved scan configuration. |
| `no_sidecar` | optional | boolean |  |
| `output` | optional | string, pattern `^/` | Optional absolute path for a new scan JSON file. Pass this file to participant project accept or marker building. |
| `summary` | optional | boolean | With output, return the scan's state, counts, coverage and resume point in place of the full report. A long every-frame report can exceed 100 MB. |
| `resume_file` | optional | string, pattern `^/` | Optional absolute path to a compatible saved partial scan to resume. |

## Window layout and monitoring

### `timeline_time_reveal`

Reveal the requested exact time on a horizontal timeline surface.

Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points. `monitor_picture`, `cut_sections_visible` (sequence), `full_height_panel` and `transcript_follow_playback` describe the active settings. Multicam `transcript_suggested_cameras` maps attachment IDs to their remembered speaker and angle IDs.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `surface` | required | `sequence` / `assembly` / `group` |  |
| `time` | required | string | For reveal_time, a rational timestamp in the named sequence, assembly or group clock. Scrolls the time into view without moving the playhead. |

### `workspace_layout_read`

Read a project window’s timeline zoom, native layout, panel state and scroll positions. Returned scroll surface names identify available controls.

Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points. `monitor_picture`, `cut_sections_visible` (sequence), `full_height_panel` and `transcript_follow_playback` describe the active settings. Multicam `transcript_suggested_cameras` maps attachment IDs to their remembered speaker and angle IDs.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |

### `workspace_layout_set`

Change the layout of the requested editor window.

Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points. `monitor_picture`, `cut_sections_visible` (sequence), `full_height_panel` and `transcript_follow_playback` describe the active settings. Multicam `transcript_suggested_cameras` maps attachment IDs to their remembered speaker and angle IDs.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `action` | required | `zoom_in` / `zoom_out` / `set_zoom` / `fit` / `restore_zoom` / `set_large_thumbnails` / `set_inspector` / `set_transcript` / `set_tiles` / `set_waveform_span` / `set_pause_controls` / `set_scroll` / `set_track_label_width` / `set_timeline_height` / `set_inspector_width` / `set_monitor_picture` / `set_cut_sections` / `set_full_height_panel` / `set_transcript_follow_playback` / `set_transcript_suggested_camera` |  |
| `zoom` | optional | number, minimum `0`, maximum `13` | Timeline zoom exponent. A value of 0 fits the timeline, and 1 doubles its width. |
| `enabled` | optional | boolean | Used by set_large_thumbnails, set_full_height_panel and set_transcript_follow_playback. Thumbnail size and panel docking are shared across windows. |
| `span` | optional | `timeline_zoom` / `whole_clip` / `10_seconds` / `1_second` / `100_milliseconds` / `10_milliseconds` |  |
| `visible` | optional | boolean | Required for set_pause_controls, set_transcript, set_tiles and set_cut_sections. Defaults to true for set_inspector. |
| `section` | optional | `switches` / `sources` / `assembly` / `export` / `transcript` / `tiles` |  |
| `surface` | optional | `sequence` / `assembly` / `group` / `tracks` |  |
| `fraction` | optional | number, minimum `0`, maximum `1` | Fraction of available scroll travel. Zero shows the beginning; one shows the far end. |
| `points` | optional | number, minimum `1`, maximum `10000` | Divider size in screen points. Track labels accept 106 to 360. Native layout constraints apply. |
| `picture` | optional | `source` / `output` | Source or composed Output in the editor viewer. The separate playback monitor continues to show composed Output. |
| `attachment` | optional | string, minimum length `1` | Transcript attachment ID for a remembered multicam camera. |
| `speaker` | optional | string, minimum length `1` | Speaker ID within the transcript attachment. |
| `camera` | optional | string, minimum length `1` or null | Project angle ID to remember, or null to clear it. |

| Action | Additional required arguments |
| --- | --- |
| `set_zoom` | `zoom` |
| `set_large_thumbnails` | `enabled` |
| `set_waveform_span` | `span` |
| `set_transcript` | `visible` |
| `set_tiles` | `visible` |
| `set_pause_controls` | `visible` |
| `set_scroll` | `surface`, `fraction` |
| `set_track_label_width` | `points` |
| `set_timeline_height` | `points` |
| `set_inspector_width` | `points` |
| `set_monitor_picture` | `picture` |
| `set_cut_sections` | `visible` |
| `set_full_height_panel` | `enabled` |
| `set_transcript_follow_playback` | `enabled` |
| `set_transcript_suggested_camera` | `attachment`, `speaker`, `camera` |

### `workspace_panel_show`

Show the requested app or project panel.

Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points. `monitor_picture`, `cut_sections_visible` (sequence), `full_height_panel` and `transcript_follow_playback` describe the active settings. Multicam `transcript_suggested_cameras` maps attachment IDs to their remembered speaker and angle IDs.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `show_help` | topic |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `action` | required | `show_about` / `show_settings` / `show_help` / `show_last_export` / `show_tiles` |  |
| `topic` | optional | `guide` / `agent_guide` / `release_notes` |  |
| `page` | optional | `general` / `editing` / `playback` / `media` / `transcripts` / `export` / `storage` / `automation` | Used only by show_settings: the Settings page to open. Omit it to reopen the last page. Other actions ignore it. |

## Project discovery

### `project_editor_state_read`

Read a live project's revision, editor state and a page of sequence clips or multicam occurrences. Pass the first page's revision on subsequent pages to detect concurrent edits.

State includes `busy`, `modal`, selection, playhead, snapping and `history_max_steps`. `unavailable_operations` maps each tool the present state blocks to its reason, such as `history_redo` with no redo step. It lists blocked tools only: a tool it does not name is not blocked by this state. Use `offset` and `total` to page `clips[]` or `occurrences[]` at a pinned revision. A sequence row identifies an occurrence by `id` and provides `sequence_from`, `sequence_to`, `source_from` and `source_to`. A multicam row identifies it by zero-based `index` and provides assembly bounds and group bounds for group rows. Insert rows identify the still placement and asset. Still placements are also paged under `stills` when present. `tier` reports the export tier of the timeline: its `id` (`true_lossless`, `lossless`, `reencode`, `checking` or `unavailable`), `name`, the best `mode` and `container`, `warnings`, and the `factors` that lower it, each with an `id`, a `message` and any `nearest` times. `current` is false while a newer timeline is being checked. A sequence's `preview` names the playback `decoder` (`avfoundation`, or `ffmpeg` with the `fallback_reason` that moved playback to it), gives `picture_decoder_note` when FFmpeg decoded the picture on screen in place of AVFoundation, and repeats what the viewer shows: a blocking or retryable `issue`, an `audio_warning`, a `picture_notice` when playback skipped pictures to the next keyframe, and a `picture_issue`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Project handle returned by project_windows_list. |
| `offset` | optional | integer, minimum `0` | Zero-based position of the first timeline entry. Defaults to zero. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum timeline entries to return. Defaults to 50. |
| `expected_revision` | optional | integer, minimum `0` | Require this document revision for a consistent view across pages. |

### `project_windows_list`

List the live MPCut project windows, including untitled projects. Use each returned project handle to target exactly that window. Focus is informational.

`projects[]` supplies each window’s opaque `project_handle`, name, kind, dirty flag and revision. A saved project includes `project_path`.

Pass an empty arguments object.

## Inline picture review

### `review_editor_frame_read`

Return JPEGs inline from the open project: the playhead, one time, or up to 12 times in one call. Sequence, group and assembly times read the current edit; Output applies tile layouts and feed treatments and Source shows the untreated recording. The source clock reads any time in one recording by source_id or file, including material the edit no longer uses, for example what plays just before a cut. Start with the default 640-pixel picture, which is enough to identify a shot. Text is reliable only when it is about 8 pixels or taller in the returned picture, and smaller text can be misread without looking wrong. When the result reports native_width and native_height, the picture was reduced: to read on-screen text or other fine detail, ask again with region for that part of the frame at its own pixels, or with a larger max_edge for the whole frame. A region costs far fewer tokens than a large whole frame.

Returns a JPEG image block in MCP `content` and timing metadata in `structuredContent`. Read `view` to distinguish Output from untreated Source review. A rendered tile frame reports `frame_time`, `duration`, dimensions and any applied `privacy_issues`. Source review identifies the sampled `source_time` and camera when applicable. A still result identifies its asset and placement. With `times`, the metadata is `view` and `frames[]` in request order, and `content` holds one `frame N: space time` label and one image per frame. A batch whose images pass 2 MiB together fails with `response_too_large`. With `space: "source"` the result adds the recording’s `file`, and in multicam its `group_time`. The source clock reaches material the edit no longer uses, including a recording that only a retained undo or redo state still holds. A sequence time past the edit fails with `invalid_target`. `native_width` and `native_height` appear when the returned picture is smaller than the whole one or is a `region` of it, and the region is echoed. That is the cue to ask again with a larger `max_edge` or a `region` when detail is missing. A review JPEG that would pass 1 MiB is encoded at a lower quality to fit.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | optional | integer, minimum `0` |  |
| `time` | optional | string | One frame time: seconds, a clock time such as 19:01.5, or exact rational seconds such as 1001/30000. Supply space with time. |
| `times` | optional | array of string, minimum items `1`, maximum items `12` | Several frame times in the same formats, all on the clock in space. The result holds frames, in request order, and one image per frame. Together the images can total 2 MiB. |
| `space` | optional | `sequence` / `group` / `assembly` / `source` | Clock of the supplied times. Source is the recording's own clock and needs source_id or file. |
| `source_id` | optional | string, minimum length `1` | With space source: a source_id from project_editor_state_read clips, a transcript word, or a multicam source. |
| `file` | optional | string, minimum length `1` | With space source: absolute path of a recording the project uses or keeps in its undo history. |
| `view` | optional | `output` / `source` | Output shows the rendered program. Source shows the untreated recording for correction and review. |
| `angle_id` | optional | string, minimum length `1` | A multicam camera ID for Source review. Omit to use the camera selected at that time. |
| `max_edge` | optional | integer, minimum `160`, maximum `3840` | Longest image edge in pixels. Defaults to 640. 1280 reads most on-screen text in HD footage, and 1920 to 2576 in 4K. Token cost grows with the area, so prefer region for detail and lower this to 320 for a contact sheet of many times. |
| `region` | optional | object | Return only this part of the picture, keeping its own pixels up to max_edge. Use it to read small detail in 4K or larger footage. Fractions of the picture from its top left: x 0.5, y 0, width 0.5, height 0.5 is the top right quarter. |
| `region.x` | required | number, minimum `0`, maximum `1` | Left edge. |
| `region.y` | required | number, minimum `0`, maximum `1` | Top edge. |
| `region.width` | required | number, minimum `0`, maximum `1` | At least 0.01. |
| `region.height` | required | number, minimum `0`, maximum `1` | At least 0.01. |

Additional schema rules

```json
{
  "allOf": [
    {
      "if": {
        "required": [
          "angle_id",
          "view"
        ]
      },
      "then": {
        "properties": {
          "view": {
            "const": "source"
          }
        }
      }
    },
    {
      "if": {
        "required": [
          "time"
        ]
      },
      "then": {
        "required": [
          "space"
        ]
      }
    },
    {
      "if": {
        "required": [
          "times"
        ]
      },
      "then": {
        "required": [
          "space"
        ]
      }
    },
    {
      "if": {
        "required": [
          "space"
        ],
        "not": {
          "required": [
            "times"
          ]
        }
      },
      "then": {
        "required": [
          "time"
        ]
      }
    },
    {
      "not": {
        "required": [
          "time",
          "times"
        ]
      }
    },
    {
      "if": {
        "required": [
          "source_id"
        ]
      },
      "then": {
        "properties": {
          "space": {
            "const": "source"
          }
        },
        "required": [
          "space"
        ]
      }
    },
    {
      "if": {
        "required": [
          "file"
        ]
      },
      "then": {
        "properties": {
          "space": {
            "const": "source"
          }
        },
        "required": [
          "space"
        ]
      }
    }
  ]
}
```

## Editing, navigation and history

### `history_read`

Read retained native history, cursor, and history token for this project.

`actions`, `cursor`, `history_token` and `limit` describe the retained branch. Index zero is the state before the first retained action. A restore needs the index and token from one read. Refresh after a history change.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |

### `history_redo`

Redo one native history action in the specified document.

`actions`, `cursor`, `history_token` and `limit` describe the retained branch. Index zero is the state before the first retained action. A restore needs the index and token from one read. Refresh after a history change.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer | Document revision observed by the caller. |
| `operation_id` | required | string | Unique mutation ID. Reuse only for an identical retry. |

### `history_state_restore`

Restore a retained native history state by zero-based index and history_read token.

`actions`, `cursor`, `history_token` and `limit` describe the retained branch. Index zero is the state before the first retained action. A restore needs the index and token from one read. Refresh after a history change.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer | Document revision observed by the caller. |
| `operation_id` | required | string | Unique mutation ID. Reuse only for an identical retry. |
| `index` | required | integer, minimum `0` | 0 is the first retained state. |
| `history_token` | required | string | Token from history_read. |

### `history_undo`

Undo one native history action in the specified document.

`actions`, `cursor`, `history_token` and `limit` describe the retained branch. Index zero is the state before the first retained action. A restore needs the index and token from one read. Refresh after a history change.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer | Document revision observed by the caller. |
| `operation_id` | required | string | Unique mutation ID. Reuse only for an identical retry. |

### `playback_transport_control`

Step to a boundary, shuttle, change preview speed or scrub in the specified clock.

Returns resulting editor state with `revision`, or a command-specific result such as `action: Apply CSV` and `changed`. A trim preview reports the `trim_preview` token and its proposed `source_time`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer | Document revision observed by the caller. |
| `operation_id` | required | string | Unique mutation ID. Reuse only for an identical retry. |
| `action` | required | `step` / `shuttle` / `speed` / `scrub` / `end_scrub` |  |
| `space` | optional | `sequence` / `source` / `group` / `assembly` |  |
| `time` | optional | string | Exact media time as rational seconds, e.g. 1001/30000. |
| `direction` | optional | `-1` / `1` |  |
| `unit` | optional | `frame` / `keyframe` / `scene` / `pause` |  |
| `rate` | optional | `0.125` / `0.25` / `0.5` / `0.75` / `1` / `1.25` / `1.5` / `2` / `4` / `8` |  |

| Action | Additional required arguments |
| --- | --- |
| `step` | `direction`, `unit` |
| `shuttle` | `direction` |
| `speed` | `rate` |
| `scrub` | `space`, `time` |

### `playback_transport_pause`

Pause preview playback in the target project window.

Returns resulting transport and editor state. Ordinary editors include `playhead_seconds`, `playing`, `rate` and selection when present. Multicam transport includes `space`, `time`, `group_time` and the current occurrence during assembly preview.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |

### `playback_transport_play`

Start preview playback in the target project window.

Returns resulting transport and editor state. Ordinary editors include `playhead_seconds`, `playing`, `rate` and selection when present. Multicam transport includes `space`, `time`, `group_time` and the current occurrence during assembly preview.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |

### `sequence_clip_edit`

Edit one clip occurrence. Trim previews return a token for committing or cancelling the proposed boundary.

Returns resulting editor state with `revision`, or a command-specific result such as `action: Apply CSV` and `changed`. A trim preview reports the `trim_preview` token and its proposed `source_time`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer | Document revision observed by the caller. |
| `operation_id` | required | string | Unique mutation ID. Reuse only for an identical retry. |
| `action` | required | `copy_container` / `move` / `trim` / `restore_edge` / `delete_clip` / `apply_csv` / `preview_trim` / `cancel_trim` |  |
| `occurrence` | optional | string | Clip occurrence UUID from project_editor_state_read. |
| `time` | optional | string | Exact media time as rational seconds, e.g. 1001/30000. |
| `value` | optional | string | Snap target off, keyframes, scenes, or silence, or a copy container extension supported by this sequence. Snap to is a shared setting: with Settings → Automation → Let agents change settings off, snap is refused with settings_write_disabled. |
| `slot` | optional | integer, minimum `0` | Insertion slot before moving, 0 through clip count. |
| `edge` | optional | `start` / `end` |  |
| `path` | optional | string | Absolute input CSV path. |
| `trim_preview` | optional | string, format `uuid` | Receipt identifying your active trim preview. Use it to preview or commit the same occurrence and edge, or to cancel. |

| Action | Additional required arguments |
| --- | --- |
| `copy_container` | `value` |
| `move` | `occurrence`, `slot` |
| `trim` | `occurrence`, `edge`, `time` |
| `restore_edge` | `occurrence`, `edge` |
| `delete_clip` | `occurrence` |
| `apply_csv` | `occurrence`, `path` |
| `preview_trim` | `occurrence`, `edge`, `time` |
| `cancel_trim` | `trim_preview` |

### `sequence_range_edit`

Split or delete the sequence interval between two exact timeline times.

Returns resulting editor state with `revision`, or a command-specific result such as `action: Apply CSV` and `changed`. A trim preview reports the `trim_preview` token and its proposed `source_time`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer | Document revision observed by the caller. |
| `operation_id` | required | string | Unique mutation ID. Reuse only for an identical retry. |
| `action` | required | `delete_range` / `split_range` |  |
| `from` | optional | string | Sequence start time in seconds. |
| `to` | optional | string | Sequence end time in seconds. |

| Action | Additional required arguments |
| --- | --- |
| `delete_range` | `from`, `to` |
| `split_range` | `from`, `to` |

### `timeline_item_split`

Split the specified clip, assembly range or inserted still with native undo history. Split a still at an interior presentation boundary in sequence or assembly time.

Reports applied `boundary` in the requested clock, `left` and `right` occurrence references and `history_retained`. Sequence results include `source_time` and `sequence_time`. Multicam camera range results include `group_time`. A still split returns independent `left_placement` and `right_placement` IDs. Use the returned `revision` with the next edit.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer | Document revision observed by the caller. |
| `operation_id` | required | string | Unique mutation ID. Reuse only for an identical retry. |
| `space` | required | `sequence` / `source` / `group` / `assembly` |  |
| `time` | required | string | Exact media time as rational seconds, e.g. 1001/30000. |
| `occurrence` | required | string or integer, minimum `0` |  |

### `timeline_playhead_seek`

Seek within the named project. Source time requires a clip occurrence. Multicam group time with an occurrence seeks that use in assembly preview; an occurrence supplied with assembly time must match the position.

Returns resulting transport and editor state. Ordinary editors include `playhead_seconds`, `playing`, `rate` and selection when present. Multicam transport includes `space`, `time`, `group_time` and the current occurrence during assembly preview.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |
| `space` | required | `sequence` / `source` / `group` / `assembly` |  |
| `time` | required | string | Exact media time as rational seconds, e.g. 1001/30000. |
| `expected_revision` | optional | integer, minimum `0` | Pin the seek to the document revision used to resolve the occurrence. |
| `occurrence` | optional | string or integer, minimum `0` | Clip UUID for an ordinary editor, or zero-based assembly occurrence index for multicam. |

### `timeline_selection_set`

Select a timeline occurrence or range, set marks, or change the selection and snapping controls.

Returns resulting editor state with `revision`, or a command-specific result such as `action: Apply CSV` and `changed`. A trim preview reports the `trim_preview` token and its proposed `source_time`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer | Document revision observed by the caller. |
| `operation_id` | required | string | Unique mutation ID. Reuse only for an identical retry. |
| `action` | required | `select` / `select_range` / `mark_in` / `mark_out` / `clear_marks` / `range_tool` / `snap` |  |
| `occurrence` | optional | string | Clip occurrence UUID from project_editor_state_read. |
| `from` | optional | string | Sequence start time in seconds. |
| `to` | optional | string | Sequence end time in seconds. |
| `space` | optional | `sequence` / `source` / `group` / `assembly` |  |
| `time` | optional | string | Exact media time as rational seconds, e.g. 1001/30000. |
| `enabled` | optional | boolean | Requested setting. |
| `value` | optional | string | Snap target off, keyframes, scenes, or silence, or a copy container extension supported by this sequence. Snap to is a shared setting: with Settings → Automation → Let agents change settings off, snap is refused with settings_write_disabled. |

| Action | Additional required arguments |
| --- | --- |
| `select` | `occurrence` |
| `select_range` | `from`, `to` |
| `mark_in` | `space`, `time` |
| `mark_out` | `space`, `time` |
| `range_tool` | `enabled` |
| `snap` | `value` |

## Named selects and ordered source ranges

### `sequence_source_ranges_apply`

Insert an ordered list of source intervals into a sequence when from equals to, or replace the specified sequence interval when from is less than to. Repeated ranges create independent occurrences. The whole plan commits as one undo step.

Returns the resulting `revision` and `range_count`. Ranges resolve and apply as one native history action in the supplied order. Invalid ranges and stale revisions leave the sequence unchanged.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Revision observed before preparing the edit. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique mutation ID. Reuse only for an identical retry. |
| `from` | required | string, minimum length `1` | Destination start on the sequence clock. |
| `to` | required | string, minimum length `1` | Destination end on the sequence clock. |
| `ranges` | required | array of object or object, minimum items `1` |  |
| `ranges[]` | when using this variant | object | object variant |
| `ranges[].file` | required | string, minimum length `1`, pattern `^/` | Absolute source media file path. |
| `ranges[].from` | required | string, minimum length `1` | Exact time in seconds as a decimal, timecode or fraction. |
| `ranges[].to` | required | string, minimum length `1` | Exact time in seconds as a decimal, timecode or fraction. |
| `ranges[]` | when using this variant | object | object variant |
| `ranges[].select_id` | required | string, minimum length `1` |  |

### `source_select_remove`

Remove a named source interval by ID with native undo history.

Returns `revision` and `source_selects[]` with each select’s ID, name and source range. A select can reference media that has no occurrence in the current sequence.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Revision observed before preparing the edit. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique mutation ID. Reuse only for an identical retry. |
| `id` | required | string, minimum length `1` |  |

### `source_select_save`

Save or update a named source interval by ID with native undo history.

Returns `revision` and `source_selects[]` with each select’s ID, name and source range. A select can reference media that has no occurrence in the current sequence.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Revision observed before preparing the edit. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique mutation ID. Reuse only for an identical retry. |
| `id` | required | string, minimum length `1` |  |
| `name` | required | string, minimum length `1` |  |
| `range` | required | object |  |
| `range.file` | required | string, minimum length `1`, pattern `^/` | Absolute source media file path. |
| `range.from` | required | string, minimum length `1` | Exact time in seconds as a decimal, timecode or fraction. |
| `range.to` | required | string, minimum length `1` | Exact time in seconds as a decimal, timecode or fraction. |

### `source_selects_list`

List the sequence project’s named source intervals, including recordings absent from its timeline.

Returns `revision` and `source_selects[]` with each select’s ID, name and source range. A select can reference media that has no occurrence in the current sequence.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Opaque live document handle from project_windows_list. |

## Still image placements

### `still_editor_asset_relink`

Relink a still asset to the same image at a new location. Every use and retained history follows the relink.

Returns the affected `asset`, `revision` and `changed`. Every use and retained history follows the relink.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` |  |
| `asset` | required | string, minimum length `1` |  |
| `path` | required | string, pattern `^/` | Absolute local image path. |

### `still_editor_picture_replace`

Replace picture over the requested range, preserving the soundtrack and timeline duration.

Returns the affected `placement` or `asset`, native action, revision, changed and history_retained. Read still_editor_placements_list or the refreshed timeline after structural edits.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` |  |
| `path` | required | string, pattern `^/` | Absolute local image path. |
| `space` | required | `sequence` / `group` |  |
| `from` | required | string | Inclusive replacement start. Exact rational seconds. |
| `to` | required | string | Exclusive replacement end. Exact rational seconds. |
| `fit` | optional | `fit` / `fill` |  |
| `crop` | optional | object | Normalized crop rectangle as exact rational coordinates. |
| `crop.x` | required | string |  |
| `crop.y` | required | string |  |
| `crop.width` | required | string |  |
| `crop.height` | required | string |  |
| `background` | optional | string, pattern `^#[0-9A-Fa-f]{6}$` |  |

### `still_editor_placement_insert`

Insert the source image at the requested time, extending the timeline. Supply initial_format to start a still-only timeline in a blank sequence window.

Returns the affected `placement` or `asset`, native action, revision, changed and history_retained. Read still_editor_placements_list or the refreshed timeline after structural edits.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` |  |
| `path` | required | string, pattern `^/` | Absolute local image path. |
| `space` | required | `sequence` / `assembly` |  |
| `at` | required | string | Placement position in the selected clock. Exact rational seconds. |
| `duration` | required | string | Positive duration. Exact rational seconds. |
| `cadence` | optional | string | Positive frame interval, for example 1001/30000. Exact rational seconds. |
| `fit` | optional | `fit` / `fill` |  |
| `crop` | optional | object | Normalized crop rectangle as exact rational coordinates. |
| `crop.x` | required | string |  |
| `crop.y` | required | string |  |
| `crop.width` | required | string |  |
| `crop.height` | required | string |  |
| `background` | optional | string, pattern `^#[0-9A-Fa-f]{6}$` |  |
| `initial_format` | optional | object | Required for the first still or gap in a blank sequence, with at set to zero. |
| `initial_format.width` | required | integer, minimum `2`, maximum `8192` |  |
| `initial_format.height` | required | integer, minimum `2`, maximum `8192` |  |
| `initial_format.cadence` | required | string | Exact frame interval in seconds, for example 1001/30000. |
| `initial_format.codec` | required | `h264` / `hevc` / `prores` / `jpeg` |  |
| `initial_format.container` | required | string, minimum length `1` |  |
| `initial_format.color` | optional | `sdr` / `pq` / `hlg` | Program color. Defaults to SDR. |

### `still_editor_placement_remove`

Remove a placement. Deleting a replacement reveals the underlying picture. Deleting an insert ripples the sequence or assembly.

Returns the affected `placement` or `asset`, native action, revision, changed and history_retained. Read still_editor_placements_list or the refreshed timeline after structural edits.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` |  |
| `placement` | required | string, minimum length `1` |  |

### `still_editor_placement_update`

Edit framing, move or resize an insert, or change the bounds of a replacement. Supply sequence time for ordinary projects, assembly time for multicam inserts, and group time for multicam replacements.

Returns the affected `placement` or `asset`, native action, revision, changed and history_retained. Read still_editor_placements_list or the refreshed timeline after structural edits.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` |  |
| `asset` | optional | string, minimum length `1` | Use another existing still asset for this placement. |
| `clear_crop` | optional | boolean | Clear the existing crop rectangle. |
| `clock` | optional | `sequence` / `source` / `group` | Clock of replacement bounds or destination. Defaults to sequence or group. |
| `fragment_index` | optional | integer, minimum `0` | Current index of the sequence replacement fragment to edit. |
| `duplicate_id` | optional | string, minimum length `1` | New replacement ID when duplicating to the supplied destination. |
| `detach_id` | optional | string, minimum length `1` | New replacement ID when detaching the selected source fragment. |
| `placement` | required | string, minimum length `1` |  |
| `at` | optional | string | Placement position in the selected clock. Exact rational seconds. |
| `duration` | optional | string | Positive duration. Exact rational seconds. |
| `cadence` | optional | string | Positive frame interval, for example 1001/30000. Exact rational seconds. |
| `from` | optional | string | Inclusive replacement start. Exact rational seconds. |
| `to` | optional | string | Exclusive replacement end. Exact rational seconds. |
| `fit` | optional | `fit` / `fill` |  |
| `crop` | optional | object | Normalized crop rectangle as exact rational coordinates. |
| `crop.x` | required | string |  |
| `crop.y` | required | string |  |
| `crop.width` | required | string |  |
| `crop.height` | required | string |  |
| `background` | optional | string, pattern `^#[0-9A-Fa-f]{6}$` |  |

Additional schema rules

```json
{
  "not": {
    "properties": {
      "clear_crop": {
        "const": true
      }
    },
    "required": [
      "crop",
      "clear_crop"
    ]
  }
}
```

### `still_editor_placements_list`

Read a page of image placements, including authored and visible ranges and asset availability.

Page `items` using `offset` and `total`. Each row supplies stable `placement` and `asset` IDs, operation, framing, authored coordinates and visible program ranges, duration and offline status. Generated gaps have `kind: gap` and `offline: false`. Hidden replacements have zero visible duration. A linked recording appears under `soundtrack`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | optional | integer, minimum `0` |  |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `200` |  |

### `still_editor_soundtrack_attach`

Attach a recording at program zero in a still-only sequence. Optionally fit its single image to the selected audio range.

Returns the native action, revision, changed and history_retained. An attached recording appears under `soundtrack`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` |  |
| `soundtrack` | required | string, pattern `^/` | Absolute path to the recording. |
| `audio_stream` | optional | integer, minimum `0` | Optional absolute audio stream index. Defaults to the first audio stream. |
| `from` | optional | string | Optional source in-point on an audio sample boundary, as exact rational seconds. |
| `to` | optional | string | Optional source out-point on an audio sample boundary, as exact rational seconds. |
| `fit_soundtrack` | optional | `true` | Fit the single image to the recording’s exact audible duration in the same edit. |

### `still_editor_soundtrack_detach`

Detach the recording from a still-only sequence and keep its picture timing.

Returns the native action, revision, changed and history_retained. An attached recording appears under `soundtrack`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` |  |

### `still_editor_soundtrack_fit`

Fit the single image in a still-only sequence to its attached soundtrack’s exact audible duration.

Returns the native action, revision, changed and history_retained. An attached recording appears under `soundtrack`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` |  |

### `timeline_clips_space`

Set the gaps between consecutive picture items in one native undo step. Use a uniform duration or restore spacing from the source time between clips. Existing leading and trailing gaps are retained.

Returns `project_handle`, `action`, `revision`, `changed` and `history_retained`. Read `still_editor_placements_list` for gap placements and their durations.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` |  |
| `duration` | optional | string | Nonnegative uniform gap duration in exact rational seconds. Zero removes gaps between picture items. |
| `source_timing` | optional | `true` | Use source timing between chronologically ordered, nonoverlapping ranges of the same media file or multicam group. Use a uniform duration when spacing photo stills. |
| `cadence` | optional | string | Positive frame interval in exact rational seconds, for example 1001/30000. Defaults to the timeline cadence when available. Omit it when removing gaps with duration zero. |
| `background` | optional | string, pattern `^#[0-9A-Fa-f]{6}$` | Gap color. Defaults to black. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "duration"
      ]
    },
    {
      "required": [
        "source_timing"
      ]
    }
  ]
}
```

### `timeline_gap_insert`

Insert a generated color gap at the requested timeline time. Supply initial_format to start a still-only timeline in a blank sequence window.

Returns the affected `placement` or `asset`, native action, revision, changed and history_retained. Read still_editor_placements_list or the refreshed timeline after structural edits.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` |  |
| `space` | required | `sequence` / `assembly` |  |
| `at` | required | string | Placement position in the selected clock. Exact rational seconds. |
| `duration` | required | string | Positive duration. Exact rational seconds. |
| `cadence` | optional | string | Positive frame interval, for example 1001/30000. Exact rational seconds. |
| `background` | optional | string, pattern `^#[0-9A-Fa-f]{6}$` |  |
| `initial_format` | optional | object | Required for the first still or gap in a blank sequence, with at set to zero. |
| `initial_format.width` | required | integer, minimum `2`, maximum `8192` |  |
| `initial_format.height` | required | integer, minimum `2`, maximum `8192` |  |
| `initial_format.cadence` | required | string | Exact frame interval in seconds, for example 1001/30000. |
| `initial_format.codec` | required | `h264` / `hevc` / `prores` / `jpeg` |  |
| `initial_format.container` | required | string, minimum length `1` |  |
| `initial_format.color` | optional | `sdr` / `pq` / `hlg` | Program color. Defaults to SDR. |

## Multicam synchronization

### `multicam_sync_suggest`

Read sync evidence against the reference camera. Reports recorded timecode or Broadcast Wave offsets, waveform matches and drift when available. Confirm clock comparability and review the results before applying an offset with multicam_source_edit.

Returns the observed `revision` and a `report` against the reference recording. Suggestions include timestamp evidence, candidate offsets and any available waveform matches and drift evidence. A suggestion leaves project offsets unchanged.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | optional | integer, minimum `0` |  |
| `source_id` | optional | string, minimum length `1` | Analyze one recording other than the reference. Defaults to all other recordings. |
| `reference_source_id` | optional | string, minimum length `1` | Select a recording on the reference camera. Defaults to its primary recording. |
| `metadata_only` | optional | boolean | Skip waveform analysis and drift checks. |

## Tiles and ISO delivery

### `tiles_editor_accept`

Accept a pending tile review or an explicit scan, or revise count hints for accepted tiles.

With the source alone, applies the pending review and its saved choices in one edit and returns the revision and operation count. Pass the pending `review_token` to accept the exact staged choices you reviewed. With an explicit scan, reports the scan state, recording ID, feed count, analysis path and review issue count. Count hints alone update the accepted geometry’s expectations. Use `clear_count_hints` to clear them.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `review_token` | optional | string, pattern `^[a-f0-9]{64}$` | Optional token from pending read or stage to accept only the reviewed pending choices. |
| `expected_feeds` | optional | integer, minimum `1` | The expected number of unique feeds. A mismatch requires review. |
| `max_visible_tiles` | optional | integer, minimum `1` | The expected maximum visible tiles in one frame. A mismatch requires review. |
| `clear_count_hints` | optional | `true` | Clear both count hints without changing the accepted tiles or feed IDs. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |

Additional schema rules

```json
{
  "allOf": [
    {
      "not": {
        "required": [
          "clear_count_hints",
          "expected_feeds"
        ]
      }
    },
    {
      "not": {
        "required": [
          "clear_count_hints",
          "max_visible_tiles"
        ]
      }
    },
    {
      "not": {
        "required": [
          "review_token",
          "analysis_file"
        ]
      }
    },
    {
      "not": {
        "required": [
          "review_token",
          "expected_feeds"
        ]
      }
    },
    {
      "not": {
        "required": [
          "review_token",
          "max_visible_tiles"
        ]
      }
    },
    {
      "not": {
        "required": [
          "review_token",
          "clear_count_hints"
        ]
      }
    }
  ]
}
```

### `tiles_editor_angles_plan`

Plan synchronized ISO delivery for the selected feeds.

Returns the requested plan or verification report.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `all` | optional | boolean | Select all feeds on the recording. |
| `feed_id` | optional | array of string, minimum length `1`, minimum items `1` | Repeat for multiple feed IDs. |
| `size` | optional | string, minimum length `1` | Output dimensions as WIDTHxHEIGHT. |
| `frame_rate` | optional | string, minimum length `1` | Output frame rate as a rational value. |
| `fit` | optional | `fit` / `fill` | Framing within each ISO canvas. |
| `gap_color` | optional | string, minimum length `1` | RGB color used for absent feeds. |
| `camera_off` | optional | `keep` / `blank` | Handling for camera-off appearances. |
| `on_uncertain` | optional | `stop` / `blank` | Handling for uncertain intervals. |
| `no_meeting_mix` | optional | boolean | Omit the standalone meeting mix. |
| `no_isos` | optional | boolean | Omit the individual ISO movies. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `output` | optional | string, pattern `^/` | The destination for the command’s output. |

### `tiles_editor_angles_render`

Render angles from a saved plan or a feed selection.

Starts a live job. Poll `analysis_job_status_read` with the same project handle and `job_id` for the delivery result. An export dry run returns its plan without rendering. An export with unresolved review issues reports `needs_review` and the plan.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `all` | optional | boolean | Select all feeds on the recording. |
| `feed_id` | optional | array of string, minimum length `1`, minimum items `1` | Repeat for multiple feed IDs. |
| `size` | optional | string, minimum length `1` | Output dimensions as WIDTHxHEIGHT. |
| `frame_rate` | optional | string, minimum length `1` | Output frame rate as a rational value. |
| `fit` | optional | `fit` / `fill` | Framing within each ISO canvas. |
| `gap_color` | optional | string, minimum length `1` | RGB color used for absent feeds. |
| `camera_off` | optional | `keep` / `blank` | Handling for camera-off appearances. |
| `on_uncertain` | optional | `stop` / `blank` | Handling for uncertain intervals. |
| `no_meeting_mix` | optional | boolean | Omit the standalone meeting mix. |
| `no_isos` | optional | boolean | Omit the individual ISO movies. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `plan` | optional | string, pattern `^/` | A saved executable Tiles angle plan. |
| `output` | required | string, pattern `^/` | The destination for the command’s output. |
| `resume` | optional | boolean | Resume a compatible delivery in the destination. |

### `tiles_editor_angles_use`

Use selected feeds as angles in the existing multicam project.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `all` | optional | boolean | Select all feeds on the recording. |
| `feed_id` | optional | array of string, minimum length `1`, minimum items `1` | Repeat for multiple feed IDs. |
| `clip_id` | optional | string, minimum length `1` | The occurrence ID from the project timeline. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "feed_id"
          ]
        },
        {
          "required": [
            "all"
          ],
          "properties": {
            "all": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_editor_angles_verify`

Verify an existing ISO delivery against its manifest.

Returns the requested plan or verification report.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `output` | required | string, pattern `^/` | Existing ISO delivery folder containing manifest.json. |

### `tiles_editor_box_add`

Draw a tile in the source frame for a source-clock range.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `from` | required | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | required | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `feed_id` | optional | string, minimum length `1` | The feed ID from feeds list. |
| `tile_id` | optional | string, minimum length `1` | The tile ID from inspect. |
| `bounds` | required | object | Normalized source-frame bounds. |
| `bounds.x` | required | number, minimum `0`, maximum `1` |  |
| `bounds.y` | required | number, minimum `0`, maximum `1` |  |
| `bounds.width` | required | number, minimum `0`, maximum `1` |  |
| `bounds.height` | required | number, minimum `0`, maximum `1` |  |

### `tiles_editor_box_set`

Correct a tile’s bounds over a source-clock range.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `from` | required | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | required | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `feed_id` | optional | string, minimum length `1` | The feed ID from feeds list. |
| `tile_id` | required | string, minimum length `1` | The tile ID from inspect. |
| `bounds` | required | object | Normalized source-frame bounds. |
| `bounds.x` | required | number, minimum `0`, maximum `1` |  |
| `bounds.y` | required | number, minimum `0`, maximum `1` |  |
| `bounds.width` | required | number, minimum `0`, maximum `1` |  |
| `bounds.height` | required | number, minimum `0`, maximum `1` |  |

### `tiles_editor_export_isos`

Plan, render and verify ISO delivery from a recording or reviewed project. Check for needs_review and resume from the returned review project.

Starts a live job. Poll `analysis_job_status_read` with the same project handle and `job_id` for the delivery result. An export dry run returns its plan without rendering. An export with unresolved review issues reports `needs_review` and the plan.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `all` | optional | boolean | Select all feeds on the recording. |
| `feed_id` | optional | array of string, minimum length `1`, minimum items `1` | Repeat for multiple feed IDs. |
| `size` | optional | string, minimum length `1` | Output dimensions as WIDTHxHEIGHT. |
| `frame_rate` | optional | string, minimum length `1` | Output frame rate as a rational value. |
| `fit` | optional | `fit` / `fill` | Framing within each ISO canvas. |
| `gap_color` | optional | string, minimum length `1` | RGB color used for absent feeds. |
| `camera_off` | optional | `keep` / `blank` | Handling for camera-off appearances. |
| `on_uncertain` | optional | `stop` / `blank` | Handling for uncertain intervals. |
| `no_meeting_mix` | optional | boolean | Omit the standalone meeting mix. |
| `no_isos` | optional | boolean | Omit the individual ISO movies. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `output` | optional | string, pattern `^/` | The destination for the command’s output. |
| `dry_run` | optional | boolean | Review the plan without rendering deliverables. |
| `resume` | optional | boolean | Resume a compatible delivery in the destination. |

Additional schema rules

```json
{
  "allOf": [
    {
      "if": {
        "not": {
          "required": [
            "dry_run"
          ],
          "properties": {
            "dry_run": {
              "const": true
            }
          }
        }
      },
      "then": {
        "required": [
          "output"
        ]
      }
    }
  ]
}
```

### `tiles_editor_feeds_add`

Add a project feed and return its feed_id for assigning tiles. The name defaults to Feed N.

Returns the new feed_id and updated editor revision. Creating a feed adds one undo step.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `name` | optional | string, minimum length `1` | The display name for the feed. |

### `tiles_editor_feeds_confirm`

Confirm reviewed coverage for a feed. Whole-recording confirmation can resolve complete absence when the accepted recording matches, coverage is verified throughout, and every tile has a known identity.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |

### `tiles_editor_feeds_inspect`

Inspect one feed’s tiles, gaps, microphone and voice bindings.

Returns Tiles review data, including the recording scope, feed identities and visible tile counts when applicable.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |

### `tiles_editor_feeds_list`

List distinct feeds in the selected recording.

Returns Tiles review data, including the recording scope, feed identities and visible tile counts when applicable.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |

### `tiles_editor_feeds_merge`

Merge a duplicate feed into another feed.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `into_feed_id` | required | string, minimum length `1` | The feed that survives the merge. |

### `tiles_editor_feeds_mic`

Assign or clear an isolated microphone for the feed.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `mic_id` | optional | string, minimum length `1` | The microphone lane or source ID. |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute audio stream index. |
| `clear` | optional | boolean | Clear the selected assignment. |
| `binding` | optional | object | A ParticipantAudioBinding with a lane_id or stream selection. |

### `tiles_editor_feeds_prefer`

Choose the feed tile used when multiple tiles show it.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `tile_id` | optional | string, minimum length `1` | The tile ID from inspect. |
| `clear` | optional | boolean | Clear the selected assignment. |

### `tiles_editor_feeds_rename`

Set the feed display name.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `name` | required | string, minimum length `1` | The display name for the feed. |

### `tiles_editor_feeds_split`

Split a tile and optional interval into a separate feed.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `tile_id` | required | string, minimum length `1` | The tile ID from inspect. |
| `name` | optional | string, minimum length `1` | The display name for the feed. |
| `new_feed_id` | optional | string, minimum length `1` | Stable ID for the new feed. |

### `tiles_editor_feeds_treatment`

Change the treatment for the feed’s visible appearances.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `treatment` | required | `none` / `blur` / `cover` / `remove` | Treatment applied to the feed’s visible appearances. |
| `color` | optional | string, minimum length `1` | RGB color in hexadecimal. |

### `tiles_editor_feeds_voice`

Assign or clear a transcript voice for the feed.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `attachment_id` | optional | string, minimum length `1` | The transcript attachment ID. |
| `track_id` | optional | string, minimum length `1` | The transcript track ID. |
| `speaker_id` | optional | string, minimum length `1` | The transcript voice ID. |
| `clear` | optional | boolean | Clear the selected assignment. |

### `tiles_editor_grid_correct`

Correct an even grid for a source-clock range and report carried links.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `from` | required | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | required | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `grid` | required | string, minimum length `1` | Corrected even grid as COLSxROWS. |

### `tiles_editor_inspect`

Inspect visible tiles, source-clock ranges, layout changes and review issues.

Returns Tiles review data, including the recording scope, feed identities and visible tile counts when applicable.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `issues` | optional | boolean | Return review issues and timestamps. |
| `at` | optional | string, minimum length `1` | Source-clock timestamp. |
| `layout_changes` | optional | boolean | Return detected layout changes. |
| `rule` | optional | object | Optional ParticipantMarkerRule for the layout-change query. |
| `clock` | optional | `source` | Time coordinate for a Tiles query. |

### `tiles_editor_layout_list`

Read saved tile layouts in the project.

Returns the layouts on the selected clips or group.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `clip_id` | optional | string, minimum length `1` | The occurrence ID from the project timeline. |

### `tiles_editor_layout_set`

Set the output layout for a clip or group over a source-clock range.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `clip_id` | optional | string, minimum length `1` | The occurrence ID from the project timeline. |
| `layout` | required | `original` / `solo` / `pair` / `side-by-side` / `grid` / `flow` / `arranged` | Clip or group layout. |
| `feed_id` | optional | array of string, minimum length `1`, minimum items `1` | Repeat for multiple feed IDs. |
| `occurrence_id` | optional | string, minimum length `1` | The assembly occurrence ID. |
| `group` | optional | boolean | Apply to the multicam group. |
| `slot` | optional | array of object, minimum items `1` | Explicit source, framing and destination assignments for the layout. |
| `slot[].id` | required | string | Feed, camera or presentation ID. Use an empty string for an empty slot. |
| `slot[].target` | optional | `participant` / `camera` / `presentation` / `empty` | Slot source type. |
| `slot[].framing` | optional | `fit` / `fill` | Fit or fill the slot. |
| `slot[].anchor_x` | optional | number, minimum `0`, maximum `1` |  |
| `slot[].anchor_y` | optional | number, minimum `0`, maximum `1` |  |
| `slot[].background` | optional | integer, minimum `0`, maximum `16777215` | RGB value. |
| `slot[].include_camera_off` | optional | boolean | Include camera-off appearances. |
| `slot[].destination_tile_id` | optional | string, minimum length `1` | Tile position to target in an arranged layout. |
| `compact` | optional | boolean | Compact the layout when a feed is absent. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "clip_id"
          ]
        },
        {
          "required": [
            "occurrence_id"
          ]
        },
        {
          "required": [
            "group"
          ],
          "properties": {
            "group": {
              "const": true
            }
          }
        }
      ]
    },
    {
      "not": {
        "required": [
          "feed_id",
          "slot"
        ]
      }
    }
  ]
}
```

### `tiles_editor_link`

Assign a tile to a feed over a source-clock range.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `tile_id` | required | string, minimum length `1` | The tile ID from inspect. |
| `feed_id` | optional | string, minimum length `1` | The feed ID from feeds list. |
| `clear` | optional | boolean | Clear the selected assignment. |

### `tiles_editor_pending_discard`

Discard one pending Tiles review as an undoable edit.

Pass the `review_token` from the current pending review. The result identifies the source and reports one undoable edit.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `review_token` | required | string, pattern `^[a-f0-9]{64}$` | The current review token from pending read. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |

### `tiles_editor_pending_read`

Read the saved pending Tiles review and all staged choices for one recording.

Returns the saved pending scan identity and state, choice feed IDs, complete staged choices and a `review_token`. This reads the pending review even when the source also has accepted geometry.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |

### `tiles_editor_pending_stage`

Replace the choices staged for one pending Tiles review.

Pass the `review_token` from the current pending review and the complete `choices` object. The result includes the updated `pending_review` and its new token. Use Tiles accept or reconcile to apply the choices.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `review_token` | required | string, pattern `^[a-f0-9]{64}$` | The current review token from pending read. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `choices` | required | object | Complete replacement choices from pending read. Omitted fields take their empty defaults. |
| `choices.analysis_identity` | optional | string | The pending scan identity. Omit to bind to the selected scan. |
| `choices.names` | optional | object with values of type string | Display names by choice feed ID. |
| `choices.unchecked` | optional | array of string, minimum length `1` | Choice feed IDs to leave unassigned. |
| `choices.merged` | optional | object with values of type string, minimum length `1` | Removed choice feed IDs mapped directly to surviving IDs. |
| `choices.expected_feeds` | optional | string | Expected unique feed count, as text. Use an empty string to clear. |
| `choices.expected_tiles` | optional | string | Expected peak visible tile count, as text. Use an empty string to clear. |
| `choices.edited_hints` | optional | boolean | Set true when explicitly changing or clearing count hints. |
| `choices.grids` | optional | array of object | Source-time grid corrections in application order. |
| `choices.grids[].range` | required | object |  |
| `choices.grids[].range.from` | required | string |  |
| `choices.grids[].range.to` | required | string |  |
| `choices.grids[].columns` | required | integer, minimum `1`, maximum `64` |  |
| `choices.grids[].rows` | required | integer, minimum `1`, maximum `64` |  |

### `tiles_editor_preview`

Write an annotated source frame for a timestamp or issue. This source review can show untreated pixels.

Returns the path of the written annotated source frame.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `at` | optional | string, minimum length `1` | Source-clock timestamp. |
| `clock` | optional | `source` | Time coordinate for a Tiles query. |
| `issue_id` | optional | string, minimum length `1` | Review issue ID from Tiles inspect. |
| `output` | required | string, pattern `^/` | The destination for the command’s output. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "at"
          ]
        },
        {
          "required": [
            "issue_id"
          ]
        }
      ]
    }
  ]
}
```

### `tiles_editor_reconcile`

Review the effect of replacing a recording, or apply a reviewed change.

Returns a review token and affected tile, feed and treatment IDs. Apply that token at the same project revision to commit one edit.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |
| `apply` | optional | `true` | Apply the reviewed reconciliation to the project. |
| `review` | optional | string, minimum length `1` | Review token returned by a reconciliation preview. |

Additional schema rules

```json
{
  "allOf": [
    {
      "if": {
        "required": [
          "apply"
        ],
        "properties": {
          "apply": {
            "const": true
          }
        }
      },
      "then": {
        "required": [
          "expected_revision",
          "review"
        ]
      }
    }
  ]
}
```

### `tiles_editor_scan`

Find visible tiles, feeds and layout changes. Save a pending review in the project or supply an output for a separate report.

Poll `analysis_job_status_read` with the project handle and `job_id` for the scan state, recording ID, counts and revision. By default the editor saves a pending review as one undoable project edit. Specify `output` to write a standalone `analysis_file` or a resumable `checkpoint_directory`. Saving a pending review or accepting tiles requires `expected_revision`. Incomplete coverage returns a failed job with its partial result. The summary lists count mismatches and `review_issue_count` counts all scan issues.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `output` | optional | string, pattern `^/` | The destination for the command’s output. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `backend` | optional | `auto` / `cpu-only` / `gpu-required` | Detector backend. |
| `sampling` | optional | `adaptive` / `every-frame` / `sparse` | Frame sampling mode. |
| `feed_layout` | optional | string, minimum length `1` | Detector layout hint such as auto or 2x2. |
| `gallery_grid` | optional | string, minimum length `1` | Expected gallery grid as COLSxROWS. |
| `expected_feeds` | optional | integer, minimum `1` | The expected number of unique feeds. A mismatch requires review. |
| `max_visible_tiles` | optional | integer, minimum `1` | The expected maximum visible tiles in one frame. A mismatch requires review. |
| `include_scenes` | optional | boolean | Include scene analysis in the scan. |
| `no_sidecar` | optional | boolean | Skip reading or writing the recording analysis cache. |
| `resume_file` | optional | string, pattern `^/` | A partial scan to resume. |
| `resume` | optional | boolean | Resume this recording’s pending scan, or the checkpoint beside the supplied output path. |
| `accept` | optional | boolean | Accept the completed scan as one project edit. |

Additional schema rules

```json
{
  "allOf": [
    {
      "if": {
        "not": {
          "required": [
            "output"
          ]
        }
      },
      "then": {
        "required": [
          "expected_revision"
        ]
      }
    },
    {
      "if": {
        "required": [
          "accept"
        ],
        "properties": {
          "accept": {
            "const": true
          }
        }
      },
      "then": {
        "required": [
          "expected_revision"
        ]
      }
    }
  ]
}
```

### `tiles_editor_switches_accept`

Accept proposed multicam cuts in one undoable edit.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `proposal` | required | object | The revision-bound proposal from tiles_editor_switches_propose. |

### `tiles_editor_switches_propose`

Propose multicam cuts from the project transcript.

Returns revision-bound switch proposals. Pass one proposal to `tiles_editor_switches_accept` with the same revision.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `attachment_id` | optional | string, minimum length `1` | The transcript attachment ID. |
| `minimum_hold` | optional | string, minimum length `1` | Minimum duration between proposed switches. |
| `voice_angle` | optional | array of string, minimum length `1`, minimum items `1` | Voice-to-angle assignments. |

### `tiles_editor_tile_screen_share`

Mark a tile as a screen share over the selected interval.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `tile_id` | required | string, minimum length `1` | The tile ID from inspect. |

### `tiles_editor_tile_split`

Split one tile at a source-clock timestamp.

Reports the edit at the resulting project revision and any affected IDs or correction details. A change creates one history action.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | The open window handle from project_windows_list. |
| `operation_id` | optional | string, minimum length `1`, maximum length `128` | A unique ID for this live operation. Reuse it with identical arguments to replay the result or job receipt. |
| `expected_revision` | required | integer, minimum `0` | The revision from the latest editor state or tool result. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `tile_id` | required | string, minimum length `1` | The tile ID from inspect. |
| `at` | required | string, minimum length `1` | Source-clock timestamp. |
| `new_tile_id` | optional | string, minimum length `1` | Stable ID for the new tile. |

### `tiles_file_accept`

Accept a pending tile review or an explicit scan, or revise count hints for accepted tiles.

Returns a file job receipt. Its result reports the saved edit and the total `review_issue_count` for the recording in the updated project. Pass the pending `review_token` to accept the exact staged choices you reviewed.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `review_token` | optional | string, pattern `^[a-f0-9]{64}$` | Optional token from pending read or stage to accept only the reviewed pending choices. |
| `expected_feeds` | optional | integer, minimum `1` | The expected number of unique feeds. A mismatch requires review. |
| `max_visible_tiles` | optional | integer, minimum `1` | The expected maximum visible tiles in one frame. A mismatch requires review. |
| `clear_count_hints` | optional | `true` | Clear both count hints without changing the accepted tiles or feed IDs. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    },
    {
      "not": {
        "required": [
          "clear_count_hints",
          "expected_feeds"
        ]
      }
    },
    {
      "not": {
        "required": [
          "clear_count_hints",
          "max_visible_tiles"
        ]
      }
    },
    {
      "not": {
        "required": [
          "review_token",
          "analysis_file"
        ]
      }
    },
    {
      "not": {
        "required": [
          "review_token",
          "expected_feeds"
        ]
      }
    },
    {
      "not": {
        "required": [
          "review_token",
          "max_visible_tiles"
        ]
      }
    },
    {
      "not": {
        "required": [
          "review_token",
          "clear_count_hints"
        ]
      }
    }
  ]
}
```

### `tiles_file_angles_plan`

Plan synchronized ISO delivery for the selected feeds.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `all` | optional | boolean | Select all feeds on the recording. |
| `feed_id` | optional | array of string, minimum length `1`, minimum items `1` | Repeat for multiple feed IDs. |
| `size` | optional | string, minimum length `1` | Output dimensions as WIDTHxHEIGHT. |
| `frame_rate` | optional | string, minimum length `1` | Output frame rate as a rational value. |
| `fit` | optional | `fit` / `fill` | Framing within each ISO canvas. |
| `gap_color` | optional | string, minimum length `1` | RGB color used for absent feeds. |
| `camera_off` | optional | `keep` / `blank` | Handling for camera-off appearances. |
| `on_uncertain` | optional | `stop` / `blank` | Handling for uncertain intervals. |
| `no_meeting_mix` | optional | boolean | Omit the standalone meeting mix. |
| `no_isos` | optional | boolean | Omit the individual ISO movies. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `output` | optional | string, pattern `^/` | The destination for the command’s output. |

### `tiles_file_angles_render`

Render angles from a saved plan or a feed selection.

Returns a file job receipt. Poll `file_job_status_read` for the manifest and published paths. The terminal state `needs_review` has exit code 3 and a JSON result with `review_project_path`, timestamped `issues` and `suggested_next_command`. Use that saved project as the input after corrections.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | optional | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `all` | optional | boolean | Select all feeds on the recording. |
| `feed_id` | optional | array of string, minimum length `1`, minimum items `1` | Repeat for multiple feed IDs. |
| `size` | optional | string, minimum length `1` | Output dimensions as WIDTHxHEIGHT. |
| `frame_rate` | optional | string, minimum length `1` | Output frame rate as a rational value. |
| `fit` | optional | `fit` / `fill` | Framing within each ISO canvas. |
| `gap_color` | optional | string, minimum length `1` | RGB color used for absent feeds. |
| `camera_off` | optional | `keep` / `blank` | Handling for camera-off appearances. |
| `on_uncertain` | optional | `stop` / `blank` | Handling for uncertain intervals. |
| `no_meeting_mix` | optional | boolean | Omit the standalone meeting mix. |
| `no_isos` | optional | boolean | Omit the individual ISO movies. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `plan` | optional | string, pattern `^/` | A saved executable Tiles angle plan. |
| `output` | required | string, pattern `^/` | The destination for the command’s output. |
| `resume` | optional | boolean | Resume a compatible delivery in the destination. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "plan"
          ]
        },
        {
          "required": [
            "project_path"
          ]
        }
      ]
    }
  ]
}
```

### `tiles_file_angles_use`

Use selected feeds as angles in the existing multicam project.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `all` | optional | boolean | Select all feeds on the recording. |
| `feed_id` | optional | array of string, minimum length `1`, minimum items `1` | Repeat for multiple feed IDs. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `clip_id` | optional | string, minimum length `1` | The occurrence ID from the project timeline. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    },
    {
      "oneOf": [
        {
          "required": [
            "feed_id"
          ]
        },
        {
          "required": [
            "all"
          ],
          "properties": {
            "all": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_angles_verify`

Verify an existing ISO delivery against its manifest.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `output` | required | string, pattern `^/` | Existing ISO delivery folder containing manifest.json. |

### `tiles_file_box_add`

Draw a tile in the source frame for a source-clock range.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `from` | required | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | required | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `feed_id` | optional | string, minimum length `1` | The feed ID from feeds list. |
| `tile_id` | optional | string, minimum length `1` | The tile ID from inspect. |
| `bounds` | required | object | Normalized source-frame bounds. |
| `bounds.x` | required | number, minimum `0`, maximum `1` |  |
| `bounds.y` | required | number, minimum `0`, maximum `1` |  |
| `bounds.width` | required | number, minimum `0`, maximum `1` |  |
| `bounds.height` | required | number, minimum `0`, maximum `1` |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_box_set`

Correct a tile’s bounds over a source-clock range.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `from` | required | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | required | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `feed_id` | optional | string, minimum length `1` | The feed ID from feeds list. |
| `tile_id` | required | string, minimum length `1` | The tile ID from inspect. |
| `bounds` | required | object | Normalized source-frame bounds. |
| `bounds.x` | required | number, minimum `0`, maximum `1` |  |
| `bounds.y` | required | number, minimum `0`, maximum `1` |  |
| `bounds.width` | required | number, minimum `0`, maximum `1` |  |
| `bounds.height` | required | number, minimum `0`, maximum `1` |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_export_isos`

Plan, render and verify ISO delivery from a recording or reviewed project. Check for needs_review and resume from the returned review project.

Returns a file job receipt. Poll `file_job_status_read` for the manifest and published paths. The terminal state `needs_review` has exit code 3 and a JSON result with `review_project_path`, timestamped `issues` and `suggested_next_command`. Use that saved project as the input after corrections.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | optional | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `all` | optional | boolean | Select all feeds on the recording. |
| `feed_id` | optional | array of string, minimum length `1`, minimum items `1` | Repeat for multiple feed IDs. |
| `size` | optional | string, minimum length `1` | Output dimensions as WIDTHxHEIGHT. |
| `frame_rate` | optional | string, minimum length `1` | Output frame rate as a rational value. |
| `fit` | optional | `fit` / `fill` | Framing within each ISO canvas. |
| `gap_color` | optional | string, minimum length `1` | RGB color used for absent feeds. |
| `camera_off` | optional | `keep` / `blank` | Handling for camera-off appearances. |
| `on_uncertain` | optional | `stop` / `blank` | Handling for uncertain intervals. |
| `no_meeting_mix` | optional | boolean | Omit the standalone meeting mix. |
| `no_isos` | optional | boolean | Omit the individual ISO movies. |
| `backend` | optional | `auto` / `cpu-only` / `gpu-required` | Detector backend. |
| `sampling` | optional | `adaptive` / `every-frame` / `sparse` | Frame sampling mode. |
| `feed_layout` | optional | string, minimum length `1` | Detector layout hint such as auto or 2x2. |
| `gallery_grid` | optional | string, minimum length `1` | Expected gallery grid as COLSxROWS. |
| `expected_feeds` | optional | integer, minimum `1` | The expected number of unique feeds. A mismatch requires review. |
| `max_visible_tiles` | optional | integer, minimum `1` | The expected maximum visible tiles in one frame. A mismatch requires review. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `file` | optional | string, pattern `^/` | The input recording. |
| `output` | optional | string, pattern `^/` | The destination for the command’s output. |
| `dry_run` | optional | boolean | Review the plan without rendering deliverables. |
| `resume` | optional | boolean | Resume a compatible delivery in the destination. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "file"
          ]
        }
      ]
    },
    {
      "if": {
        "required": [
          "file"
        ]
      },
      "then": {
        "required": [
          "output"
        ]
      }
    },
    {
      "if": {
        "not": {
          "required": [
            "dry_run"
          ],
          "properties": {
            "dry_run": {
              "const": true
            }
          }
        }
      },
      "then": {
        "required": [
          "output"
        ]
      }
    }
  ]
}
```

### `tiles_file_feeds_add`

Add a project feed and return its feed_id for assigning tiles. The name defaults to Feed N.

Returns a file job receipt. Its result contains the new project feed_id for tiles_file_box_add or tiles_file_link.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `name` | optional | string, minimum length `1` | The display name for the feed. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_feeds_confirm`

Confirm reviewed coverage for a feed. Whole-recording confirmation can resolve complete absence when the accepted recording matches, coverage is verified throughout, and every tile has a known identity.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_feeds_inspect`

Inspect one feed’s tiles, gaps, microphone and voice bindings.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | optional | string, pattern `^/` | The saved .cut project. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "analysis_file"
          ]
        }
      ]
    }
  ]
}
```

### `tiles_file_feeds_list`

List distinct feeds in the selected recording.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | optional | string, pattern `^/` | The saved .cut project. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "analysis_file"
          ]
        }
      ]
    }
  ]
}
```

### `tiles_file_feeds_merge`

Merge a duplicate feed into another feed.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `into_feed_id` | required | string, minimum length `1` | The feed that survives the merge. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_feeds_mic`

Assign or clear an isolated microphone for the feed.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `mic_id` | optional | string, minimum length `1` | The microphone lane or source ID. |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute audio stream index. |
| `clear` | optional | boolean | Clear the selected assignment. |
| `binding` | optional | object | A ParticipantAudioBinding with a lane_id or stream selection. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_feeds_prefer`

Choose the feed tile used when multiple tiles show it.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `tile_id` | optional | string, minimum length `1` | The tile ID from inspect. |
| `clear` | optional | boolean | Clear the selected assignment. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_feeds_rename`

Set the feed display name.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `name` | required | string, minimum length `1` | The display name for the feed. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_feeds_split`

Split a tile and optional interval into a separate feed.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `tile_id` | required | string, minimum length `1` | The tile ID from inspect. |
| `name` | optional | string, minimum length `1` | The display name for the feed. |
| `new_feed_id` | optional | string, minimum length `1` | Stable ID for the new feed. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_feeds_treatment`

Change the treatment for the feed’s visible appearances.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `treatment` | required | `none` / `blur` / `cover` / `remove` | Treatment applied to the feed’s visible appearances. |
| `color` | optional | string, minimum length `1` | RGB color in hexadecimal. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_feeds_voice`

Assign or clear a transcript voice for the feed.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `feed_id` | required | string, minimum length `1` | The feed ID from feeds list. |
| `attachment_id` | optional | string, minimum length `1` | The transcript attachment ID. |
| `track_id` | optional | string, minimum length `1` | The transcript track ID. |
| `speaker_id` | optional | string, minimum length `1` | The transcript voice ID. |
| `clear` | optional | boolean | Clear the selected assignment. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_grid_correct`

Correct an even grid for a source-clock range and report carried links.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `from` | required | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | required | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `grid` | required | string, minimum length `1` | Corrected even grid as COLSxROWS. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_inspect`

Inspect visible tiles, source-clock ranges, layout changes and review issues.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | optional | string, pattern `^/` | The saved .cut project. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `issues` | optional | boolean | Return review issues and timestamps. |
| `at` | optional | string, minimum length `1` | Source-clock timestamp. |
| `layout_changes` | optional | boolean | Return detected layout changes. |
| `rule` | optional | object | Optional ParticipantMarkerRule for the layout-change query. |
| `clock` | optional | `source` | Time coordinate for a Tiles query. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "analysis_file"
          ]
        }
      ]
    }
  ]
}
```

### `tiles_file_layout_list`

Read saved tile layouts in the project.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `clip_id` | optional | string, minimum length `1` | The occurrence ID from the project timeline. |

### `tiles_file_layout_set`

Set the output layout for a clip or group over a source-clock range.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `clip_id` | optional | string, minimum length `1` | The occurrence ID from the project timeline. |
| `layout` | required | `original` / `solo` / `pair` / `side-by-side` / `grid` / `flow` / `arranged` | Clip or group layout. |
| `feed_id` | optional | array of string, minimum length `1`, minimum items `1` | Repeat for multiple feed IDs. |
| `occurrence_id` | optional | string, minimum length `1` | The assembly occurrence ID. |
| `group` | optional | boolean | Apply to the multicam group. |
| `slot` | optional | array of object, minimum items `1` | Explicit source, framing and destination assignments for the layout. |
| `slot[].id` | required | string | Feed, camera or presentation ID. Use an empty string for an empty slot. |
| `slot[].target` | optional | `participant` / `camera` / `presentation` / `empty` | Slot source type. |
| `slot[].framing` | optional | `fit` / `fill` | Fit or fill the slot. |
| `slot[].anchor_x` | optional | number, minimum `0`, maximum `1` |  |
| `slot[].anchor_y` | optional | number, minimum `0`, maximum `1` |  |
| `slot[].background` | optional | integer, minimum `0`, maximum `16777215` | RGB value. |
| `slot[].include_camera_off` | optional | boolean | Include camera-off appearances. |
| `slot[].destination_tile_id` | optional | string, minimum length `1` | Tile position to target in an arranged layout. |
| `compact` | optional | boolean | Compact the layout when a feed is absent. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    },
    {
      "oneOf": [
        {
          "required": [
            "clip_id"
          ]
        },
        {
          "required": [
            "occurrence_id"
          ]
        },
        {
          "required": [
            "group"
          ],
          "properties": {
            "group": {
              "const": true
            }
          }
        }
      ]
    },
    {
      "not": {
        "required": [
          "feed_id",
          "slot"
        ]
      }
    }
  ]
}
```

### `tiles_file_link`

Assign a tile to a feed over a source-clock range.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `tile_id` | required | string, minimum length `1` | The tile ID from inspect. |
| `feed_id` | optional | string, minimum length `1` | The feed ID from feeds list. |
| `clear` | optional | boolean | Clear the selected assignment. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_pending_discard`

Discard one pending Tiles review as an undoable edit.

Pass the `review_token` from the current pending review. The result identifies the source and reports one undoable edit.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `review_token` | required | string, pattern `^[a-f0-9]{64}$` | The current review token from pending read. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_pending_read`

Read the saved pending Tiles review and all staged choices for one recording.

Returns the saved pending scan identity and state, choice feed IDs, complete staged choices and a `review_token`. This reads the pending review even when the source also has accepted geometry.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |

### `tiles_file_pending_stage`

Replace the choices staged for one pending Tiles review.

Pass the `review_token` from the current pending review and the complete `choices` object. The result includes the updated `pending_review` and its new token. Use Tiles accept or reconcile to apply the choices.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `review_token` | required | string, pattern `^[a-f0-9]{64}$` | The current review token from pending read. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `choices` | required | object | Complete replacement choices from pending read. Omitted fields take their empty defaults. |
| `choices.analysis_identity` | optional | string | The pending scan identity. Omit to bind to the selected scan. |
| `choices.names` | optional | object with values of type string | Display names by choice feed ID. |
| `choices.unchecked` | optional | array of string, minimum length `1` | Choice feed IDs to leave unassigned. |
| `choices.merged` | optional | object with values of type string, minimum length `1` | Removed choice feed IDs mapped directly to surviving IDs. |
| `choices.expected_feeds` | optional | string | Expected unique feed count, as text. Use an empty string to clear. |
| `choices.expected_tiles` | optional | string | Expected peak visible tile count, as text. Use an empty string to clear. |
| `choices.edited_hints` | optional | boolean | Set true when explicitly changing or clearing count hints. |
| `choices.grids` | optional | array of object | Source-time grid corrections in application order. |
| `choices.grids[].range` | required | object |  |
| `choices.grids[].range.from` | required | string |  |
| `choices.grids[].range.to` | required | string |  |
| `choices.grids[].columns` | required | integer, minimum `1`, maximum `64` |  |
| `choices.grids[].rows` | required | integer, minimum `1`, maximum `64` |  |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_preview`

Write an annotated source frame for a timestamp or issue. This source review can show untreated pixels.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | optional | string, pattern `^/` | The saved .cut project. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `at` | optional | string, minimum length `1` | Source-clock timestamp. |
| `clock` | optional | `source` | Time coordinate for a Tiles query. |
| `issue_id` | optional | string, minimum length `1` | Review issue ID from Tiles inspect. |
| `output` | required | string, pattern `^/` | The destination for the command’s output. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "project_path"
          ]
        },
        {
          "required": [
            "analysis_file"
          ]
        }
      ]
    },
    {
      "oneOf": [
        {
          "required": [
            "at"
          ]
        },
        {
          "required": [
            "issue_id"
          ]
        }
      ]
    }
  ]
}
```

### `tiles_file_reconcile`

Review the effect of replacing a recording, or apply a reviewed change.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `analysis_file` | optional | string, pattern `^/` | A saved Tiles scan JSON file. |
| `apply` | optional | `true` | Apply the reviewed reconciliation to the project. |
| `review` | optional | string, minimum length `1` | Review token returned by a reconciliation preview. |

Additional schema rules

```json
{
  "allOf": [
    {
      "if": {
        "required": [
          "apply"
        ],
        "properties": {
          "apply": {
            "const": true
          }
        }
      },
      "then": {
        "allOf": [
          {
            "oneOf": [
              {
                "required": [
                  "out_project"
                ]
              },
              {
                "required": [
                  "in_place"
                ],
                "properties": {
                  "in_place": {
                    "const": true
                  }
                }
              }
            ]
          },
          {
            "required": [
              "review"
            ]
          }
        ]
      }
    }
  ]
}
```

### `tiles_file_scan`

Scan a recording for visible tiles, distinct feeds and layout changes.

Returns a file job receipt. With an output path, its compact result includes the saved paths, coverage and count mismatches. The total `review_issue_count` matches the number of entries from `tiles_file_inspect` with `issues: true` on the scan.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `file` | required | string, pattern `^/` | The input recording. |
| `output` | optional | string, pattern `^/` | The output scan JSON. With this option the job returns a small scan summary. |
| `backend` | optional | `auto` / `cpu-only` / `gpu-required` | Detector backend. |
| `sampling` | optional | `adaptive` / `every-frame` / `sparse` | Frame sampling mode. |
| `feed_layout` | optional | string, minimum length `1` | Detector layout hint such as auto or 2x2. |
| `gallery_grid` | optional | string, minimum length `1` | Expected gallery grid as COLSxROWS. |
| `expected_feeds` | optional | integer, minimum `1` | The expected number of unique feeds. A mismatch requires review. |
| `max_visible_tiles` | optional | integer, minimum `1` | The expected maximum visible tiles in one frame. A mismatch requires review. |
| `include_scenes` | optional | boolean | Include scene analysis in the scan. |
| `no_sidecar` | optional | boolean | Skip reading or writing the recording analysis cache. |
| `resume_file` | optional | string, pattern `^/` | A partial scan to resume. |

### `tiles_file_switches_propose`

Propose multicam cuts from the project transcript.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `attachment_id` | optional | string, minimum length `1` | The transcript attachment ID. |
| `minimum_hold` | optional | string, minimum length `1` | Minimum duration between proposed switches. |
| `voice_angle` | optional | array of string, minimum length `1`, minimum items `1` | Voice-to-angle assignments. |

### `tiles_file_tile_screen_share`

Mark a tile as a screen share over the selected interval.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `from` | optional | string, minimum length `1` | Inclusive source-clock start as a timestamp. |
| `to` | optional | string, minimum length `1` | Exclusive source-clock end as a timestamp. |
| `tile_id` | required | string, minimum length `1` | The tile ID from inspect. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

### `tiles_file_tile_split`

Split one tile at a source-clock timestamp.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct file job. Reuse it for an identical retry. |
| `working_directory` | optional | string, pattern `^/` | Base directory for relative paths inside requests and saved documents. |
| `project_path` | required | string, pattern `^/` | The saved .cut project. |
| `source_id` | optional | string, minimum length `1` | The recording ID. Select it when multiple recordings are eligible. |
| `out_project` | optional | string, pattern `^/` | Write the updated project to this .cut path. |
| `in_place` | optional | `true` | Update the saved project in place. |
| `tile_id` | required | string, minimum length `1` | The tile ID from inspect. |
| `at` | required | string, minimum length `1` | Source-clock timestamp. |
| `new_tile_id` | optional | string, minimum length `1` | Stable ID for the new tile. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "out_project"
          ]
        },
        {
          "required": [
            "in_place"
          ],
          "properties": {
            "in_place": {
              "const": true
            }
          }
        }
      ]
    }
  ]
}
```

## Range mapping and revision comparison

### `history_editor_compare`

Compare a retained undo or redo state with the current timeline without moving the history cursor. Reports affected occurrences and participant changes with source IDs, tile IDs, and source intervals where applicable. The page limit covers occurrence and participant rows together.

Returns a `comparison` with before and after clocks and durations, changed project fields, and occurrence changes with their before and after values. Pass an index and history token from the same history read and the current editor revision. An unavailable index or stale snapshot is an error. The same page limit and next_offset cover occurrence changes and participant_changes reporting affected sources, tiles and source-clock intervals or points.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Current live document revision. Pins the request and subsequent pages. |
| `history_index` | required | integer, minimum `0` | Zero-based state index in the retained history returned by history_read. The cursor selects the current state. |
| `history_token` | required | string | History token from a fresh history_read. |
| `offset` | optional | integer, minimum `0` | Start at this result row. Use next_offset from the previous page. |
| `limit` | optional | integer, minimum `1`, maximum `500` | Maximum result rows per page. Defaults to 100. |

### `timeline_editor_range_map`

Map an exact half-open interval between source and sequence time, or between group and assembly time. Returns all matching pieces in output order, including repeats. Supply a history token and index together to query a retained review state.

Returns the requested `mapping` with input and output clocks and intersecting `pieces[]`. Pieces identify the occurrence and carry clipped input and output bounds where applicable. Repeated source uses appear separately. A working copy can also report `original_file`. Supply both history selectors from one retained history read to map an older state. Follow the mapping’s `next_offset` for additional pieces.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string | Opaque live document handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Current live document revision. Pins the request and subsequent pages. |
| `history_index` | optional | integer, minimum `0` | Zero-based state index in the retained history returned by history_read. The cursor selects the current state. |
| `history_token` | optional | string | History token from a fresh history_read. |
| `offset` | optional | integer, minimum `0` | Start at this result row. Use next_offset from the previous page. |
| `limit` | optional | integer, minimum `1`, maximum `500` | Maximum result rows per page. Defaults to 100. |
| `space` | required | `source` / `sequence` / `group` / `assembly` | Clock of the queried range. |
| `from` | required | string | Inclusive rational start time. |
| `to` | required | string | Exclusive rational end time. |
| `file` | optional | string | Exact playable or original sequence source path. Omit to match every source. |
| `occurrence_index` | optional | integer, minimum `0` | Limit to one zero-based timeline occurrence in the selected revision. |

## Transcripts

### `transcript_editor_attachment_bind`

Update the source bindings and optional clock origin of an attachment.

Returns the affected attachment and result IDs and resulting transcript revision.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | required | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. On import, the attachment whose result the file replaces: it keeps its ID, and its bindings and origin unless new ones are supplied. Omit it to add an attachment. |
| `result_id` | required | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Replay key. Reuse it only with identical arguments. |
| `bindings` | required | array of object, minimum items `0`, maximum items `500` |  |
| `bindings[].track_id` | required | string, minimum length `1`, maximum length `512` |  |
| `bindings[].source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `bindings[].file` | optional | string, minimum length `1`, maximum length `4096` | Sequence media path as stored in the live project. |
| `bindings[].audio_stream_index` | required | integer, minimum `0`, maximum `2147483647` |  |
| `bindings[].channel` | optional | integer, minimum `0`, maximum `2147483647` |  |
| `bindings[].offset` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `bindings[].offset` | when using this variant | object | object variant |
| `bindings[].offset.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `bindings[].offset.denominator` | required | integer, minimum `1` |  |
| `bindings[].sequence_clock_origin` | optional | string, minimum length `1`, maximum length `128` or object | Presentation clock offset of the sequence, if known. |
| `bindings[].sequence_clock_origin` | when using this variant | object | object variant |
| `bindings[].sequence_clock_origin.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `bindings[].sequence_clock_origin.denominator` | required | integer, minimum `1` |  |
| `bindings[].sequence_stream_ordinal` | optional | integer, minimum `1`, maximum `2147483647` |  |
| `origin` | optional | string, minimum length `1`, maximum length `128` or null | Exact rational origin. Omit on bind to preserve it or supply null to clear it. |

### `transcript_editor_attachment_detach`

Remove a transcript attachment from the open project.

Returns the removed attachment and result IDs and resulting transcript revision.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | required | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. On import, the attachment whose result the file replaces: it keeps its ID, and its bindings and origin unless new ones are supplied. Omit it to add an attachment. |
| `result_id` | required | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Replay key. Reuse it only with identical arguments. |

### `transcript_editor_attachment_export`

Write a transcript or captions on the requested clock.

Returns an output job receipt. Omit the attachment to export project-wide dialogue.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Replay key. Reuse it only with identical arguments. |
| `path` | required | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |
| `format` | required | `json` / `srt` / `vtt` / `text` |  |
| `space` | optional | `source` / `group` / `current_cut` | Select the source, synchronized group or current cut clock. |
| `file` | optional | string, maximum length `4096` | Sequence source file to include in read or search results. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. On import, the attachment whose result the file replaces: it keeps its ID, and its bindings and origin unless new ones are supplied. Omit it to add an attachment. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |

### `transcript_editor_attachment_import`

Import or replace a transcript attachment with optional track bindings.

Returns attachment and result IDs, replacement status, binding count and revision.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Replay key. Reuse it only with identical arguments. |
| `path` | required | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |
| `format` | required | `json` / `srt` / `vtt` / `text` |  |
| `bindings` | optional | array of object, minimum items `0`, maximum items `500` |  |
| `bindings[].track_id` | required | string, minimum length `1`, maximum length `512` |  |
| `bindings[].source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `bindings[].file` | optional | string, minimum length `1`, maximum length `4096` | Sequence media path as stored in the live project. |
| `bindings[].audio_stream_index` | required | integer, minimum `0`, maximum `2147483647` |  |
| `bindings[].channel` | optional | integer, minimum `0`, maximum `2147483647` |  |
| `bindings[].offset` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `bindings[].offset` | when using this variant | object | object variant |
| `bindings[].offset.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `bindings[].offset.denominator` | required | integer, minimum `1` |  |
| `bindings[].sequence_clock_origin` | optional | string, minimum length `1`, maximum length `128` or object | Presentation clock offset of the sequence, if known. |
| `bindings[].sequence_clock_origin` | when using this variant | object | object variant |
| `bindings[].sequence_clock_origin.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `bindings[].sequence_clock_origin.denominator` | required | integer, minimum `1` |  |
| `bindings[].sequence_stream_ordinal` | optional | integer, minimum `1`, maximum `2147483647` |  |
| `origin` | optional | string, minimum length `1`, maximum length `128` or null | Exact rational origin. Omit on bind to preserve it or supply null to clear it. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. On import, the attachment whose result the file replaces: it keeps its ID, and its bindings and origin unless new ones are supplied. Omit it to add an attachment. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |

### `transcript_editor_attachment_tracks_list`

List tracks in the attached transcript result.

Returns a page of items with its total and continuation offset when more items are available.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |

### `transcript_editor_attachments_list`

List attached transcript results and report asset availability.

Returns paged attachment IDs, result identities, binding counts and asset status.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |

### `transcript_editor_authored_changes_list`

List authored changes to the attached transcript.

Returns a page of items with its total and continuation offset when more items are available.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |

### `transcript_editor_bindings_list`

Inspect each transcript track’s binding and current source status.

Returns a page of items with its total and continuation offset when more items are available.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |

### `transcript_editor_coverage_read`

Inspect gaps in transcript coverage, including paged track evidence on the source and group clocks.

Returns availability and gaps. Source and group coverage also return paged track status.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `space` | optional | `source` / `group` / `current_cut` | Select the source, synchronized group or current cut clock. |
| `file` | optional | string, maximum length `4096` | Sequence source file to include in read or search results. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `track_offset` | optional | integer, minimum `0` | Offset for the Source or Group coverage track page. Defaults to zero. |
| `track_limit` | optional | integer, minimum `1`, maximum `200` | Maximum rows for the Source or Group coverage track page. Defaults to limit. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |

### `transcript_editor_edit_apply`

Apply the reviewed edit to its owning project revision.

Returns the native history action, whether the edit changed the timeline and the resulting transcript revision.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `result_id` | required | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Replay key. Reuse it only with identical arguments. |
| `plan_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | Plan returned by the plan action in the same live project. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. Required when several transcripts are attached, unless each selection carries attachment_id or an occurrence ID. |

### `transcript_editor_edit_plan`

Review a transcript edit and retain its exact boundaries for apply or queue. A top-level attachment_id or result_id scopes its selections. To plan across attachments, address each selection by attachment or occurrence IDs.

Returns the plan ID, resolved boundaries, selections, durations, affected speech and any tier assessment.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `result_id` | required | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Replay key. Reuse it only with identical arguments. |
| `edit` | required | object |  |
| `edit.action` | required | `split` / `trim_start` / `trim_end` / `delete` / `tighten` / `assemble` / `insert` / `replace` / `switch_angle` / `queue` |  |
| `edit.selections` | required | array of object, minimum items `1`, maximum items `64` |  |
| `edit.selections[].first_word_id` | required | string, minimum length `1`, maximum length `512` |  |
| `edit.selections[].last_word_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `edit.selections[].space` | optional | `source` / `group` / `current_cut` |  |
| `edit.selections[].kind` | optional | `phrase` / `gap` |  |
| `edit.selections[].first_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `edit.selections[].last_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `edit.selections[].leading_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `edit.selections[].leading_padding` | when using this variant | object | object variant |
| `edit.selections[].leading_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `edit.selections[].leading_padding.denominator` | required | integer, minimum `1` |  |
| `edit.selections[].trailing_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `edit.selections[].trailing_padding` | when using this variant | object | object variant |
| `edit.selections[].trailing_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `edit.selections[].trailing_padding.denominator` | required | integer, minimum `1` |  |
| `edit.selections[].attachment_id` | optional | string, maximum length `512` | Transcript attachment for this passage. Supply for selections spanning attachments. |
| `edit.target` | optional | object | Use an occurrence ID when a word appears more than once in the selected clock. |
| `edit.target.first_word_id` | required | string, minimum length `1`, maximum length `512` |  |
| `edit.target.last_word_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `edit.target.space` | optional | `source` / `group` / `current_cut` |  |
| `edit.target.kind` | optional | `phrase` / `gap` |  |
| `edit.target.first_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `edit.target.last_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `edit.target.leading_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `edit.target.leading_padding` | when using this variant | object | object variant |
| `edit.target.leading_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `edit.target.leading_padding.denominator` | required | integer, minimum `1` |  |
| `edit.target.trailing_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `edit.target.trailing_padding` | when using this variant | object | object variant |
| `edit.target.trailing_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `edit.target.trailing_padding.denominator` | required | integer, minimum `1` |  |
| `edit.target.attachment_id` | optional | string, maximum length `512` | Transcript attachment for this passage. Supply for selections spanning attachments. |
| `edit.position` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `edit.position` | when using this variant | object | object variant |
| `edit.position.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `edit.position.denominator` | required | integer, minimum `1` |  |
| `edit.retained_duration` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `edit.retained_duration` | when using this variant | object | object variant |
| `edit.retained_duration.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `edit.retained_duration.denominator` | required | integer, minimum `1` |  |
| `edit.angle_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `edit.name` | optional | string, minimum length `1`, maximum length `512` |  |
| `edit.boundary_policy` | optional | `exact` / `nearest_frame` / `copy_safe` |  |
| `edit.edge` | optional | `start` / `end` |  |
| `edit.start_frame_nudge` | optional | integer, minimum `-10000`, maximum `10000` |  |
| `edit.end_frame_nudge` | optional | integer, minimum `-10000`, maximum `10000` |  |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. Required when several transcripts are attached, unless each selection carries attachment_id or an occurrence ID. |

### `transcript_editor_edits_suggest`

Find proposed transcript edits using the selected filler terms. Takes are compact rows unless verbose is set.

Returns a page of items with its total and continuation offset. A match or take is one compact row: `text`, `from`, `to`, the speaker, a `words` count, the four `first_` and `last_` word and occurrence IDs a selection takes, and the adjacent words as `before` and `after` text. With `verbose`, `words`, `before` and `after` are arrays of full word records.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `space` | optional | `source` / `group` / `current_cut` | Select the source, synchronized group or current cut clock. |
| `file` | optional | string, maximum length `4096` | Sequence source file to include in read or search results. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `filler_terms` | optional | array of string, minimum length `1`, maximum length `512`, minimum items `1`, maximum items `100` |  |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |
| `verbose` | optional | boolean | Return full word records with binding, lane, routing and evidence fields, about 2 KB per word. Omit for compact rows. |

### `transcript_editor_excerpt_queue`

Capture the reviewed excerpt in the export queue.

Returns the captured excerpt’s queue ID.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `result_id` | required | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Replay key. Reuse it only with identical arguments. |
| `plan_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | Plan returned by the plan action in the same live project. |
| `name` | required | string, minimum length `1`, maximum length `512` | Name shown for the captured queue entry. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. Required when several transcripts are attached, unless each selection carries attachment_id or an occurrence ID. |

### `transcript_editor_excerpt_save`

Write a captured excerpt as an editable project.

Returns an output job receipt for the editable excerpt.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Replay key. Reuse it only with identical arguments. |
| `queue_id` | required | string, format `uuid` | Captured transcript excerpt ID from the named queue. |
| `path` | required | string, maximum length `4096`, pattern `^/` | Absolute destination for the new editable .cut snapshot. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. Required when several transcripts are attached, unless each selection carries attachment_id or an occurrence ID. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |

### `transcript_editor_job_cancel`

Request cancellation of a recognition job.

Returns the current cancellation state.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for each distinct start, cancel or retry request. |
| `job_id` | required | string, format `uuid` | Durable job ID from start or list. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |

### `transcript_editor_job_reconcile`

Update a generated attachment after its source offsets change.

Returns the job and attachment IDs and the current state.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for each distinct start, cancel or retry request. |
| `attachment_id` | required | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | required | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |

### `transcript_editor_job_retry`

Retry recognition for a durable job.

Returns the durable job ID.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for each distinct start, cancel or retry request. |
| `job_id` | required | string, format `uuid` | Durable job ID from start or list. |
| `download` | optional | boolean | Explicitly permit the helper to download a missing model. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |

### `transcript_editor_job_start`

Start durable recognition for the open document.

Returns the durable job ID and current state.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `operation_id` | required | string, format `uuid` | Fresh UUID for each distinct start, cancel or retry request. |
| `policy` | optional | `reuse` / `resume` / `restart`, default `reuse` |  |
| `download` | optional | boolean | Explicitly permit the helper to download a missing model. |
| `options` | optional | object |  |
| `options.engine` | optional | string, minimum length `1`, maximum length `512` | Transcriberrr engine name. When omitted, the app uses Settings → Transcripts → Preferred engine; Automatic, or a preferred engine that cannot run on this Mac, resolves to qwen3, then the first available engine. File jobs and the CLI use qwen3 and never read desktop Settings. |
| `options.model` | optional | string, minimum length `1`, maximum length `512` |  |
| `options.language` | optional | string, minimum length `1`, maximum length `512` |  |
| `options.expected_speakers` | optional | integer, minimum `1` |  |
| `options.diarization` | optional | boolean |  |
| `options.selected_tracks` | optional | array of string, minimum length `1`, maximum length `512`, minimum items `0`, maximum items `1000` |  |
| `options.track_options` | optional | object with values of type object |  |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |

### `transcript_editor_job_status_read`

Read the state and paged track progress of a recognition job.

Returns job state, attachment state, warning count and paged track progress.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `job_id` | required | string, format `uuid` | Durable job ID from start or list. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |

### `transcript_editor_job_warnings_list`

Page diagnostics for a recognition job.

Returns job state and paged warnings.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `job_id` | required | string, format `uuid` | Durable job ID from start or list. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |

### `transcript_editor_jobs_list`

List durable recognition jobs owned by the document.

Returns a page of items with its total and continuation offset when more items are available.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |

### `transcript_editor_occurrence_seek`

Move the playhead to an exact word occurrence in the pinned revision. The occurrence is compact unless verbose is set.

Returns the resolved occurrence as a compact word row, or the full record with `verbose`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `result_id` | required | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `space` | optional | `source` / `group` / `current_cut` | Select the source, synchronized group or current cut clock. |
| `occurrence_id` | required | string, minimum length `1`, maximum length `512` |  |
| `file` | optional | string, maximum length `4096` | Sequence source file to include in read or search results. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |
| `verbose` | optional | boolean | Return full word records with binding, lane, routing and evidence fields, about 2 KB per word. Omit for compact rows. |

### `transcript_editor_occurrences_locate`

Locate occurrences by word ID or read one exact occurrence. Rows are compact unless verbose is set.

Returns a page of compact word rows, as `transcript_editor_words_read` does, or full word records with `verbose`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `space` | optional | `source` / `group` / `current_cut` | Select the source, synchronized group or current cut clock. |
| `file` | optional | string, maximum length `4096` | Sequence source file to include in read or search results. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `word_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |
| `verbose` | optional | boolean | Return full word records with binding, lane, routing and evidence fields, about 2 KB per word. Omit for compact rows. |

### `transcript_editor_plan_discard`

Release a retained edit plan.

Confirms the plan was discarded.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `plan_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | Plan returned by the plan action in the same live project. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. Required when several transcripts are attached, unless each selection carries attachment_id or an occurrence ID. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |

### `transcript_editor_script_align`

Align script beats to dialogue and page candidate and qualifier counts.

Returns a page of items with its total and continuation offset when more items are available.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `space` | optional | `source` / `group` / `current_cut` | Select the source, synchronized group or current cut clock. |
| `script` | required | string, minimum length `1`, maximum length `65536` | Script text to align against the transcript. |
| `file` | optional | string, maximum length `4096` | Sequence source file to include in read or search results. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `context_words` | optional | integer, minimum `0`, maximum `100` | Surrounding words per take. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |

### `transcript_editor_script_candidates_list`

Page candidate matches for a script beat. Takes are compact rows unless verbose is set.

Returns a page of items with its total and continuation offset. A match or take is one compact row: `text`, `from`, `to`, the speaker, a `words` count, the four `first_` and `last_` word and occurrence IDs a selection takes, and the adjacent words as `before` and `after` text. With `verbose`, `words`, `before` and `after` are arrays of full word records.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `space` | optional | `source` / `group` / `current_cut` | Select the source, synchronized group or current cut clock. |
| `script` | required | string, minimum length `1`, maximum length `65536` | Script text to align against the transcript. |
| `file` | optional | string, maximum length `4096` | Sequence source file to include in read or search results. |
| `beat` | required | integer, minimum `0` | Zero-based beat index from align-script. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `context_words` | optional | integer, minimum `0`, maximum `100` | Surrounding words per take. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |
| `verbose` | optional | boolean | Return full word records with binding, lane, routing and evidence fields, about 2 KB per word. Omit for compact rows. |

### `transcript_editor_script_qualifiers_list`

Page qualifier evidence for a script beat.

Returns a page of items with its total and continuation offset when more items are available.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `space` | optional | `source` / `group` / `current_cut` | Select the source, synchronized group or current cut clock. |
| `script` | required | string, minimum length `1`, maximum length `65536` | Script text to align against the transcript. |
| `file` | optional | string, maximum length `4096` | Sequence source file to include in read or search results. |
| `beat` | required | integer, minimum `0` | Zero-based beat index from align-script. |
| `qualifier` | optional | integer, minimum `0` | Optional qualifier index from script-qualifiers. Page presence and absence evidence for that qualifier. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `context_words` | optional | integer, minimum `0`, maximum `100` | Surrounding words per take. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |

### `transcript_editor_selection_mark`

Set the native timeline marks to a word selection.

Returns the resolved selection.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `result_id` | required | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Replay key. Reuse it only with identical arguments. |
| `selection` | required | object | Use an occurrence ID when a word appears more than once in the selected clock. |
| `selection.first_word_id` | required | string, minimum length `1`, maximum length `512` |  |
| `selection.last_word_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selection.space` | optional | `source` / `group` / `current_cut` |  |
| `selection.kind` | optional | `phrase` / `gap` |  |
| `selection.first_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selection.last_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selection.leading_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `selection.leading_padding` | when using this variant | object | object variant |
| `selection.leading_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `selection.leading_padding.denominator` | required | integer, minimum `1` |  |
| `selection.trailing_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `selection.trailing_padding` | when using this variant | object | object variant |
| `selection.trailing_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `selection.trailing_padding.denominator` | required | integer, minimum `1` |  |
| `selection.attachment_id` | optional | string, maximum length `512` | Transcript attachment for this passage. Supply for selections spanning attachments. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. Required when several transcripts are attached, unless each selection carries attachment_id or an occurrence ID. |

### `transcript_editor_selection_resolve`

Resolve a word selection on the requested clock with optional transcript reader expansion.

Returns the resolved selection.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `selection` | required | object | Use an occurrence ID when a word appears more than once in the selected clock. |
| `selection.first_word_id` | required | string, minimum length `1`, maximum length `512` |  |
| `selection.last_word_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selection.space` | optional | `source` / `group` / `current_cut` |  |
| `selection.kind` | optional | `phrase` / `gap` |  |
| `selection.first_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selection.last_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selection.leading_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `selection.leading_padding` | when using this variant | object | object variant |
| `selection.leading_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `selection.leading_padding.denominator` | required | integer, minimum `1` |  |
| `selection.trailing_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `selection.trailing_padding` | when using this variant | object | object variant |
| `selection.trailing_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `selection.trailing_padding.denominator` | required | integer, minimum `1` |  |
| `selection.attachment_id` | optional | string, maximum length `512` | Transcript attachment for this passage. Supply for selections spanning attachments. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. Required when several transcripts are attached, unless each selection carries attachment_id or an occurrence ID. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `expansion` | optional | `earlier` / `later` / `sentence` / `speaker_turn` / `preceding_question` | Expand phrase endpoints using the transcript reader boundaries in the selected clock. |

### `transcript_editor_speakers_list`

List speakers in the selected transcript.

Returns a page of items with its total and continuation offset when more items are available.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |

### `transcript_editor_takes_compare`

Compare takes matching a phrase. Each take is one compact row with adjacent words as before and after text. Set verbose for full word records.

Returns a page of items with its total and continuation offset. A match or take is one compact row: `text`, `from`, `to`, the speaker, a `words` count, the four `first_` and `last_` word and occurrence IDs a selection takes, and the adjacent words as `before` and `after` text. With `verbose`, `words`, `before` and `after` are arrays of full word records.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `space` | optional | `source` / `group` / `current_cut` | Select the source, synchronized group or current cut clock. |
| `query` | required | string, minimum length `1`, maximum length `4096` | Words to find or compare. |
| `file` | optional | string, maximum length `4096` | Sequence source file to include in read or search results. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `context_words` | optional | integer, minimum `0`, maximum `100` | Surrounding words per take. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |
| `verbose` | optional | boolean | Return full word records with binding, lane, routing and evidence fields, about 2 KB per word. Omit for compact rows. |

### `transcript_editor_track_activity_read`

Read activity measurements for an attached transcript track.

Returns a page of items with its total and continuation offset when more items are available.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `track_id` | required | string, minimum length `1`, maximum length `512` |  |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |

### `transcript_editor_word_candidates_list`

List candidate tracks for a word.

Returns a page of items with its total and continuation offset when more items are available.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `word_id` | required | string, minimum length `1`, maximum length `512` |  |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |

### `transcript_editor_word_evidence_read`

List recognized and inferred observations for a word.

Returns a page of items with its total and continuation offset when more items are available.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `word_id` | required | string, minimum length `1`, maximum length `512` |  |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |

### `transcript_editor_words_correct`

Record a transcript correction or authored change.

Returns the authored record ID and resulting transcript revision.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | required | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `result_id` | required | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Replay key. Reuse it only with identical arguments. |
| `selection` | optional | object | Use an occurrence ID when a word appears more than once in the selected clock. |
| `selection.first_word_id` | required | string, minimum length `1`, maximum length `512` |  |
| `selection.last_word_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selection.space` | optional | `source` / `group` / `current_cut` |  |
| `selection.kind` | optional | `phrase` / `gap` |  |
| `selection.first_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selection.last_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selection.leading_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `selection.leading_padding` | when using this variant | object | object variant |
| `selection.leading_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `selection.leading_padding.denominator` | required | integer, minimum `1` |  |
| `selection.trailing_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `selection.trailing_padding` | when using this variant | object | object variant |
| `selection.trailing_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `selection.trailing_padding.denominator` | required | integer, minimum `1` |  |
| `selection.attachment_id` | optional | string, maximum length `512` | Transcript attachment for this passage. Supply for selections spanning attachments. |
| `change` | required | object or object or object or object or object or object or object or object | Supply one change. Word-based changes use a selection to store a source-time anchor. |
| `change` | when using this variant | object | object variant |
| `change.replace_text` | required | object |  |
| `change.replace_text.text` | required | string, maximum length `65536` |  |
| `change` | when using this variant | object | object variant |
| `change.assign_speaker` | required | object |  |
| `change.assign_speaker.speaker_id` | required | string, minimum length `1`, maximum length `512` |  |
| `change` | when using this variant | object | object variant |
| `change.rename_speaker` | required | object |  |
| `change.rename_speaker.speaker_id` | required | string, minimum length `1`, maximum length `512` |  |
| `change.rename_speaker.name` | required | string, minimum length `1`, maximum length `512` |  |
| `change` | when using this variant | object | object variant |
| `change.merge_speakers` | required | object |  |
| `change.merge_speakers.source_id` | required | string, minimum length `1`, maximum length `512` |  |
| `change.merge_speakers.target_id` | required | string, minimum length `1`, maximum length `512` |  |
| `change` | when using this variant | object | object variant |
| `change.match_override` | required | object |  |
| `change.match_override.track_id` | required | string, minimum length `1`, maximum length `512` |  |
| `change.match_override.accepted` | required | boolean |  |
| `change.match_override.observation` | optional | object |  |
| `change.match_override.observation.range` | required | object |  |
| `change.match_override.observation.range.to` | required | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `change.match_override.observation.range.to` | when using this variant | object | object variant |
| `change.match_override.observation.range.to.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `change.match_override.observation.range.to.denominator` | required | integer, minimum `1` |  |
| `change.match_override.observation.range.from` | required | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `change.match_override.observation.range.from` | when using this variant | object | object variant |
| `change.match_override.observation.range.from.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `change.match_override.observation.range.from.denominator` | required | integer, minimum `1` |  |
| `change.match_override.observation.word_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `change` | when using this variant | object | object variant |
| `change.named_select` | required | object |  |
| `change.named_select.name` | required | string, minimum length `1`, maximum length `512` |  |
| `change` | when using this variant | object | object variant |
| `change.pause_protection` | required | object |  |
| `change.pause_protection.name` | required | string, minimum length `1`, maximum length `512` |  |
| `change` | when using this variant | object | object variant |
| `change.split_speaker` | required | object |  |
| `change.split_speaker.speaker_id` | required | string, minimum length `1`, maximum length `512` |  |
| `change.split_speaker.name` | required | string, minimum length `1`, maximum length `512` |  |
| `selections` | optional | array of object, minimum items `1`, maximum items `64` | Ordered passages used by a correction, including both ranges of a two-passage correction. |
| `selections[].first_word_id` | required | string, minimum length `1`, maximum length `512` |  |
| `selections[].last_word_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selections[].space` | optional | `source` / `group` / `current_cut` |  |
| `selections[].kind` | optional | `phrase` / `gap` |  |
| `selections[].first_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selections[].last_occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `selections[].leading_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `selections[].leading_padding` | when using this variant | object | object variant |
| `selections[].leading_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `selections[].leading_padding.denominator` | required | integer, minimum `1` |  |
| `selections[].trailing_padding` | optional | string, minimum length `1`, maximum length `128` or object | Exact binding adjustment in seconds. Use a rational string or numerator and denominator. |
| `selections[].trailing_padding` | when using this variant | object | object variant |
| `selections[].trailing_padding.numerator` | required | integer, minimum `-9223372036854775808` |  |
| `selections[].trailing_padding.denominator` | required | integer, minimum `1` |  |
| `selections[].attachment_id` | optional | string, maximum length `512` | Transcript attachment for this passage. Supply for selections spanning attachments. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. Required when several transcripts are attached, unless each selection carries attachment_id or an occurrence ID. |

### `transcript_editor_words_read`

Page words in the selected transcript clock and scope. Rows are compact: id, word_id, text, from, to, speaker, and the recording when it differs between rows; a recording shared by the whole page is under shared. Set lines to read dialogue as one row per utterance, the cheapest way to read a transcript. Set verbose for full word records.

Returns a page of words with its total and `next_offset` when more remain. A compact row holds `id`, `word_id`, `text`, `from`, `to`, the speaker, the `attachment_id`, and `source_id` or `file` for the recording. A flag such as `original_text`, `precision`, `audibility`, `partial` or `approximate` appears only where the word departs from an ordinary recognized one. When every row shares an attachment or a recording, it is reported once under `shared`. With `lines`, each row is a run of words by one speaker in one utterance and clip: `text`, `from`, `to`, the speaker, a `words` count and `first_word_id`, `first_occurrence_id`, `last_word_id` and `last_occurrence_id`, which a selection takes as they are. The top-level `words` counts the words the page covered. With `verbose`, each row is the full word record: bindings, lanes, routing, ranges on every clock and evidence.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `500` | Maximum words for this page. Defaults to 50. The server can return a shorter page. |
| `space` | optional | `source` / `group` / `current_cut` | Select the source, synchronized group or current cut clock. |
| `file` | optional | string, maximum length `4096` | Sequence source file to include in read or search results. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |
| `verbose` | optional | boolean | Return full word records with binding, lane, routing and evidence fields, about 2 KB per word. Omit for compact rows. |
| `lines` | optional | boolean | Group this page's words into dialogue lines: text, from, to, speaker, a word count, and the first and last word and occurrence IDs a selection takes. Offset, limit and next_offset still count words. Not with verbose. |

### `transcript_editor_words_search`

Find a phrase. Each match is one compact row: the matched text, from, to, speaker, the first and last word and occurrence IDs a selection takes, and the surrounding words as before and after text. Set verbose for full word records.

Returns a page of items with its total and continuation offset. A match or take is one compact row: `text`, `from`, `to`, the speaker, a `words` count, the four `first_` and `last_` word and occurrence IDs a selection takes, and the adjacent words as `before` and `after` text. With `verbose`, `words`, `before` and `after` are arrays of full word records.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `space` | optional | `source` / `group` / `current_cut` | Select the source, synchronized group or current cut clock. |
| `query` | required | string, minimum length `1`, maximum length `4096` | Words to find or compare. |
| `file` | optional | string, maximum length `4096` | Sequence source file to include in read or search results. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |
| `verbose` | optional | boolean | Return full word records with binding, lane, routing and evidence fields, about 2 KB per word. Omit for compact rows. |

### `transcript_file_attachment_bind`

Run transcript attachment bind on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.attachment_id` | optional | string |  |
| `request.audio_stream_index` | optional | integer, minimum `0` |  |
| `request.bindings` | optional | array of object |  |
| `request.channel` | optional | integer, minimum `0` |  |
| `request.file` | optional | string, pattern `^/` | Absolute local path. |
| `request.in_place` | optional | boolean |  |
| `request.origin` | optional | string or object |  |
| `request.origin` | when using this variant | object | object variant |
| `request.origin.numerator` | required | integer |  |
| `request.origin.denominator` | required | integer |  |
| `request.out_project` | optional | string, pattern `^/` | Absolute local path. |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.source_id` | optional | string |  |
| `request.track_id` | optional | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_attachment_detach`

Run transcript attachment detach on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.attachment_id` | optional | string |  |
| `request.in_place` | optional | boolean |  |
| `request.out_project` | optional | string, pattern `^/` | Absolute local path. |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_attachment_import`

Run transcript attachment import on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.attachment_id` | optional | string |  |
| `request.audio_stream_index` | optional | integer, minimum `0` |  |
| `request.bindings` | optional | array of object |  |
| `request.channel` | optional | integer, minimum `0` |  |
| `request.file` | optional | string, pattern `^/` | Absolute local path. |
| `request.format` | optional | string |  |
| `request.in_place` | optional | boolean |  |
| `request.job_directory` | optional | string, pattern `^/` | Absolute local path. |
| `request.job_id` | optional | string |  |
| `request.origin` | optional | string or object |  |
| `request.origin` | when using this variant | object | object variant |
| `request.origin.numerator` | required | integer |  |
| `request.origin.denominator` | required | integer |  |
| `request.out_project` | optional | string, pattern `^/` | Absolute local path. |
| `request.output` | optional | string, pattern `^/` | Absolute local path. |
| `request.project_path` | optional | string, pattern `^/` | Absolute local path. |
| `request.source_id` | optional | string |  |
| `request.track_id` | optional | string |  |
| `request.transcript` | optional | string, pattern `^/` | Absolute local path. |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_attachment_inspect`

Run transcript attachment inspect on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.attachment_id` | optional | string |  |
| `request.format` | optional | string |  |
| `request.limit` | optional | integer, minimum `1`, maximum `500` |  |
| `request.offset` | optional | integer, minimum `0` |  |
| `request.origin` | optional | string or object |  |
| `request.origin` | when using this variant | object | object variant |
| `request.origin.numerator` | required | integer |  |
| `request.origin.denominator` | required | integer |  |
| `request.lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `request.project_path` | optional | string, pattern `^/` | Absolute local path. |
| `request.track_id` | optional | string |  |
| `request.transcript` | optional | string, pattern `^/` | Absolute local path. |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_edit_apply`

Run transcript edit apply on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.action` | optional | string |  |
| `request.angle_id` | optional | string |  |
| `request.attachment_id` | optional | string |  |
| `request.boundary_policy` | optional | string |  |
| `request.edge` | optional | string |  |
| `request.end_frame_nudge` | optional | integer |  |
| `request.first_occurrence_id` | optional | string |  |
| `request.first_word_id` | optional | string |  |
| `request.in_place` | optional | boolean |  |
| `request.kind` | optional | string |  |
| `request.last_occurrence_id` | optional | string |  |
| `request.last_word_id` | optional | string |  |
| `request.leading_padding` | optional | string or object |  |
| `request.leading_padding` | when using this variant | object | object variant |
| `request.leading_padding.numerator` | required | integer |  |
| `request.leading_padding.denominator` | required | integer |  |
| `request.name` | optional | string |  |
| `request.out_project` | optional | string, pattern `^/` | Absolute local path. |
| `request.plan` | optional | object |  |
| `request.plan_file` | optional | string, pattern `^/` | Absolute local path. |
| `request.position` | optional | string or object |  |
| `request.position` | when using this variant | object | object variant |
| `request.position.numerator` | required | integer |  |
| `request.position.denominator` | required | integer |  |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.request` | optional | object |  |
| `request.retained_duration` | optional | string or object |  |
| `request.retained_duration` | when using this variant | object | object variant |
| `request.retained_duration.numerator` | required | integer |  |
| `request.retained_duration.denominator` | required | integer |  |
| `request.selection` | optional | object |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.start_frame_nudge` | optional | integer |  |
| `request.trailing_padding` | optional | string or object |  |
| `request.trailing_padding` | when using this variant | object | object variant |
| `request.trailing_padding.numerator` | required | integer |  |
| `request.trailing_padding.denominator` | required | integer |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_edit_plan`

Run transcript edit plan on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.action` | optional | string |  |
| `request.angle_id` | optional | string |  |
| `request.attachment_id` | optional | string |  |
| `request.boundary_policy` | optional | string |  |
| `request.edge` | optional | string |  |
| `request.end_frame_nudge` | optional | integer |  |
| `request.first_occurrence_id` | optional | string |  |
| `request.first_word_id` | optional | string |  |
| `request.kind` | optional | string |  |
| `request.last_occurrence_id` | optional | string |  |
| `request.last_word_id` | optional | string |  |
| `request.leading_padding` | optional | string or object |  |
| `request.leading_padding` | when using this variant | object | object variant |
| `request.leading_padding.numerator` | required | integer |  |
| `request.leading_padding.denominator` | required | integer |  |
| `request.name` | optional | string |  |
| `request.output` | optional | string, pattern `^/` | Absolute local path. |
| `request.plan` | optional | object |  |
| `request.plan_file` | optional | string, pattern `^/` | Absolute local path. |
| `request.position` | optional | string or object |  |
| `request.position` | when using this variant | object | object variant |
| `request.position.numerator` | required | integer |  |
| `request.position.denominator` | required | integer |  |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.request` | optional | object |  |
| `request.retained_duration` | optional | string or object |  |
| `request.retained_duration` | when using this variant | object | object variant |
| `request.retained_duration.numerator` | required | integer |  |
| `request.retained_duration.denominator` | required | integer |  |
| `request.selection` | optional | object |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.start_frame_nudge` | optional | integer |  |
| `request.trailing_padding` | optional | string or object |  |
| `request.trailing_padding` | when using this variant | object | object variant |
| `request.trailing_padding.numerator` | required | integer |  |
| `request.trailing_padding.denominator` | required | integer |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_edits_suggest`

Run transcript words suggest on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.assembly_index` | optional | integer, minimum `0` |  |
| `request.attachment_id` | optional | string |  |
| `request.clip_id` | optional | string |  |
| `request.expected_attachment_results` | optional | object |  |
| `request.file` | optional | string, pattern `^/` | Absolute local path. |
| `request.filler_terms` | optional | array of string |  |
| `request.include_inferred` | optional | boolean |  |
| `request.limit` | optional | integer, minimum `1`, maximum `500` |  |
| `request.offset` | optional | integer, minimum `0` |  |
| `request.lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.source_id` | optional | string |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.speaker_id` | optional | string |  |
| `request.track_id` | optional | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_excerpt_queue`

Run transcript excerpt queue on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.action` | optional | string |  |
| `request.angle_id` | optional | string |  |
| `request.attachment_id` | optional | string |  |
| `request.boundary_policy` | optional | string |  |
| `request.edge` | optional | string |  |
| `request.end_frame_nudge` | optional | integer |  |
| `request.first_occurrence_id` | optional | string |  |
| `request.first_word_id` | optional | string |  |
| `request.in_place` | optional | boolean |  |
| `request.kind` | optional | string |  |
| `request.last_occurrence_id` | optional | string |  |
| `request.last_word_id` | optional | string |  |
| `request.leading_padding` | optional | string or object |  |
| `request.leading_padding` | when using this variant | object | object variant |
| `request.leading_padding.numerator` | required | integer |  |
| `request.leading_padding.denominator` | required | integer |  |
| `request.name` | optional | string |  |
| `request.out_project` | optional | string, pattern `^/` | Absolute local path. |
| `request.plan` | optional | object |  |
| `request.plan_file` | optional | string, pattern `^/` | Absolute local path. |
| `request.position` | optional | string or object |  |
| `request.position` | when using this variant | object | object variant |
| `request.position.numerator` | required | integer |  |
| `request.position.denominator` | required | integer |  |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.request` | optional | object |  |
| `request.retained_duration` | optional | string or object |  |
| `request.retained_duration` | when using this variant | object | object variant |
| `request.retained_duration.numerator` | required | integer |  |
| `request.retained_duration.denominator` | required | integer |  |
| `request.selection` | optional | object |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.start_frame_nudge` | optional | integer |  |
| `request.trailing_padding` | optional | string or object |  |
| `request.trailing_padding` | when using this variant | object | object variant |
| `request.trailing_padding.numerator` | required | integer |  |
| `request.trailing_padding.denominator` | required | integer |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_export`

Run transcript export on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.assembly_index` | optional | integer, minimum `0` |  |
| `request.attachment_id` | optional | string |  |
| `request.clip_id` | optional | string |  |
| `request.expected_attachment_results` | optional | object |  |
| `request.file` | optional | string, pattern `^/` | Absolute local path. |
| `request.format` | optional | string |  |
| `request.include_inferred` | optional | boolean |  |
| `request.output` | optional | string, pattern `^/` | Absolute local path. |
| `request.lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.source_id` | optional | string |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.speaker_id` | optional | string |  |
| `request.track_id` | optional | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_job_cancel`

Run transcript job cancel on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.job_directory` | optional | string, pattern `^/` | Absolute local path. |
| `request.job_id` | required | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_job_prepare`

Run transcript job prepare on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.diarization` | optional | boolean |  |
| `request.engine` | optional | string | Transcriberrr engine name. Defaults to qwen3. File jobs do not read desktop Settings. |
| `request.expected_speakers` | optional | integer, minimum `0` |  |
| `request.file` | optional | string, pattern `^/` | Absolute local path. |
| `request.job_directory` | optional | string, pattern `^/` | Absolute local path. |
| `request.language` | optional | string |  |
| `request.model` | optional | string |  |
| `request.operation_id` | optional | string |  |
| `request.options` | optional | object |  |
| `request.policy` | optional | string |  |
| `request.progress` | optional | string |  |
| `request.project_path` | optional | string, pattern `^/` | Absolute local path. |
| `request.selected_tracks` | optional | array of string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_job_reconcile`

Prepare the recognition job linked to a saved attachment using the current project timing. Use transcript_file_job_run and transcript_file_attachment_import to publish the updated result.

Poll the returned file job for the refreshed recognition preparation. Run that durable job and import the reviewed result into the saved project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object |  |
| `request.attachment_id` | optional | string |  |
| `request.job_directory` | optional | string, pattern `^/` | Absolute local path. |
| `request.progress` | optional | string |  |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |

### `transcript_file_job_retry`

Run transcript job retry on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.job_directory` | optional | string, pattern `^/` | Absolute local path. |
| `request.job_id` | required | string |  |
| `request.progress` | optional | string |  |
| `request.project_path` | optional | string, pattern `^/` | Absolute local path. |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_job_run`

Run a prepared saved-file transcription job with the installed provider. Poll the file job for completion.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.job_directory` | optional | string, pattern `^/` | Absolute local path. |
| `request.job_id` | required | string |  |
| `request.download` | optional | boolean | Allow the installed provider to download its selected model. Defaults to false. |
| `request.progress` | optional | `none` / `stderr` / `jsonl` |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_job_status_read`

Run transcript job status on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.job_directory` | optional | string, pattern `^/` | Absolute local path. |
| `request.job_id` | required | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_jobs_list`

List recognition jobs belonging to a saved project in the chosen job directory.

Poll the returned file job to discover durable recognition jobs for the saved project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object |  |
| `request.job_directory` | optional | string, pattern `^/` | Absolute local path. |
| `request.offset` | optional | integer, minimum `0` |  |
| `request.limit` | optional | integer, minimum `1`, maximum `500` |  |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |

### `transcript_file_occurrences_locate`

Run transcript words locate on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.assembly_index` | optional | integer, minimum `0` |  |
| `request.attachment_id` | optional | string |  |
| `request.clip_id` | optional | string |  |
| `request.expected_attachment_results` | optional | object |  |
| `request.file` | optional | string, pattern `^/` | Absolute local path. |
| `request.include_inferred` | optional | boolean |  |
| `request.limit` | optional | integer, minimum `1`, maximum `500` |  |
| `request.occurrence_id` | optional | string |  |
| `request.offset` | optional | integer, minimum `0` |  |
| `request.lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.source_id` | optional | string |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.speaker_id` | optional | string |  |
| `request.track_id` | optional | string |  |
| `request.word_id` | optional | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_provider_capabilities_read`

Run transcript provider capabilities on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_script_align`

Run transcript script align on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.assembly_index` | optional | integer, minimum `0` |  |
| `request.attachment_id` | optional | string |  |
| `request.clip_id` | optional | string |  |
| `request.expected_attachment_results` | optional | object |  |
| `request.file` | optional | string, pattern `^/` | Absolute local path. |
| `request.include_inferred` | optional | boolean |  |
| `request.limit` | optional | integer, minimum `1`, maximum `500` |  |
| `request.offset` | optional | integer, minimum `0` |  |
| `request.lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.script` | optional | string |  |
| `request.script_file` | optional | string, pattern `^/` | Absolute local path. |
| `request.source_id` | optional | string |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.speaker_id` | optional | string |  |
| `request.track_id` | optional | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_selection_resolve`

Resolve a saved-project word selection with optional transcript reader expansion through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.attachment_id` | optional | string |  |
| `request.first_occurrence_id` | optional | string |  |
| `request.first_word_id` | optional | string |  |
| `request.kind` | optional | string |  |
| `request.last_occurrence_id` | optional | string |  |
| `request.last_word_id` | optional | string |  |
| `request.leading_padding` | optional | string or object |  |
| `request.leading_padding` | when using this variant | object | object variant |
| `request.leading_padding.numerator` | required | integer |  |
| `request.leading_padding.denominator` | required | integer |  |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.selection` | optional | object |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.trailing_padding` | optional | string or object |  |
| `request.trailing_padding` | when using this variant | object | object variant |
| `request.trailing_padding.numerator` | required | integer |  |
| `request.trailing_padding.denominator` | required | integer |  |
| `request.expansion` | optional | `earlier` / `later` / `sentence` / `speaker_turn` / `preceding_question` | Expand phrase endpoints using the transcript reader boundaries in the selected clock. |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_takes_compare`

Run transcript words compare on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.assembly_index` | optional | integer, minimum `0` |  |
| `request.attachment_id` | optional | string |  |
| `request.clip_id` | optional | string |  |
| `request.context_words` | optional | integer, minimum `0` |  |
| `request.expected_attachment_results` | optional | object |  |
| `request.file` | optional | string, pattern `^/` | Absolute local path. |
| `request.include_inferred` | optional | boolean |  |
| `request.limit` | optional | integer, minimum `1`, maximum `500` |  |
| `request.offset` | optional | integer, minimum `0` |  |
| `request.lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.query` | required | string |  |
| `request.source_id` | optional | string |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.speaker_id` | optional | string |  |
| `request.track_id` | optional | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_tracks_list`

Run transcript tracks list on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.file` | optional | string, pattern `^/` | Absolute local path. |
| `request.options` | optional | object |  |
| `request.lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `request.project_path` | optional | string, pattern `^/` | Absolute local path. |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_words_correct`

Run transcript words correct on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.attachment_id` | optional | string |  |
| `request.change` | optional | object |  |
| `request.first_occurrence_id` | optional | string |  |
| `request.first_word_id` | optional | string |  |
| `request.in_place` | optional | boolean |  |
| `request.kind` | optional | string |  |
| `request.last_occurrence_id` | optional | string |  |
| `request.last_word_id` | optional | string |  |
| `request.leading_padding` | optional | string or object |  |
| `request.leading_padding` | when using this variant | object | object variant |
| `request.leading_padding.numerator` | required | integer |  |
| `request.leading_padding.denominator` | required | integer |  |
| `request.out_project` | optional | string, pattern `^/` | Absolute local path. |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.record` | optional | object |  |
| `request.record_id` | optional | string, minimum length `1` | Stable ID for the authored correction. Reuse it when repeating the same correction across file jobs. |
| `request.revision` | optional | object |  |
| `request.selection` | optional | object |  |
| `request.selections` | optional | array of object |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.trailing_padding` | optional | string or object |  |
| `request.trailing_padding` | when using this variant | object | object variant |
| `request.trailing_padding.numerator` | required | integer |  |
| `request.trailing_padding.denominator` | required | integer |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_words_read`

Run transcript words read on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.assembly_index` | optional | integer, minimum `0` |  |
| `request.attachment_id` | optional | string |  |
| `request.clip_id` | optional | string |  |
| `request.expected_attachment_results` | optional | object |  |
| `request.file` | optional | string, pattern `^/` | Absolute local path. |
| `request.include_inferred` | optional | boolean |  |
| `request.limit` | optional | integer, minimum `1`, maximum `500` |  |
| `request.occurrence_id` | optional | string |  |
| `request.offset` | optional | integer, minimum `0` |  |
| `request.lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.source_id` | optional | string |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.speaker_id` | optional | string |  |
| `request.track_id` | optional | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_words_search`

Run transcript words search on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.assembly_index` | optional | integer, minimum `0` |  |
| `request.attachment_id` | optional | string |  |
| `request.clip_id` | optional | string |  |
| `request.expected_attachment_results` | optional | object |  |
| `request.file` | optional | string, pattern `^/` | Absolute local path. |
| `request.include_inferred` | optional | boolean |  |
| `request.limit` | optional | integer, minimum `1`, maximum `500` |  |
| `request.offset` | optional | integer, minimum `0` |  |
| `request.lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `request.project_path` | required | string, pattern `^/` | Absolute local path. |
| `request.query` | required | string |  |
| `request.source_id` | optional | string |  |
| `request.space` | optional | `source` / `group` / `current_cut` |  |
| `request.speaker_id` | optional | string |  |
| `request.track_id` | optional | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. An identical retry returns the existing receipt while it is retained. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_provider_capabilities_read`

Read the local transcription provider’s capabilities.

Returns the provider capability document.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |

### `transcript_tracks_list`

List the project tracks available for recognition and their estimated duration.

Returns a page of items with its total and continuation offset when more items are available.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `lane_id` | optional | string, minimum length `1`, maximum length `512` | Filter by multicam audio lane ID. |
| `project_handle` | required | string, minimum length `1`, maximum length `512` | Opaque handle from project_windows_list. |
| `offset` | optional | integer, minimum `0` | Offset for this page. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum entries for this page. The server can return a shorter page. |
| `options` | optional | object |  |
| `options.engine` | optional | string, minimum length `1`, maximum length `512` |  |
| `options.model` | optional | string, minimum length `1`, maximum length `512` |  |
| `options.language` | optional | string, minimum length `1`, maximum length `512` |  |
| `options.expected_speakers` | optional | integer, minimum `1` |  |
| `options.diarization` | optional | boolean |  |
| `options.selected_tracks` | optional | array of string, minimum length `1`, maximum length `512`, minimum items `0`, maximum items `1000` |  |
| `options.track_options` | optional | object with values of type object |  |
| `expected_revision` | optional | integer, minimum `0` | Pin the timeline revision to an earlier response. |
| `expected_transcript_revision` | optional | integer, minimum `0` | Pin the transcript-state revision to an earlier response. |
| `attachment_id` | optional | string, minimum length `1`, maximum length `512` | Attachment from transcript_editor_attachments_list. |
| `result_id` | optional | string, minimum length `1`, maximum length `64` | Result identity returned by the attachment or prior transcript page. |
