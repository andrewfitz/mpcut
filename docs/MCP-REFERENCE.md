# MPCut MCP tool reference

This reference describes the inputs advertised by the bundled stdio helper. The connected host can retrieve the complete JSON Schemas through `tools/list`. Live tool calls use the running app and its local-control setting. The `--files-only` helper exposes saved-file tools through a private CLI worker. Results bound to a live project carry the `project_handle` and the current or applied revision. Starting a saved-file job returns a receipt with a `job_id`. Inspect `isError` first. MPCut domain errors carry a code and message in `structuredContent`. Invalid requests can also return an MCP protocol or SDK validation error. [Setup, clocks, history and recovery](MCP-AGENT-GUIDE.md)

**217 tools.**

## Live analysis

### `analysis_editor_sidecars_save`

Save completed analysis beside the project sources using the native save operation. Poll the returned job with analysis_job_status_read.

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

Returns an analysis job receipt. Poll `analysis_job_status_read` for per-source refresh results, preserved analysis, review issues and any persistence errors.

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

Set the name for every matching view in an analyzed source. An empty name restores the default.

Returns applied status and the current revision. Inspect `analysis_editor_state_read` or the relevant report for the new setting or result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string |  |
| `source_id` | required | string |  |
| `view` | required | integer, minimum `1` |  |
| `name` | required | string, maximum length `1024` |  |

### `silence_editor_pause_review`

Seek, preview, protect or unprotect a pause by its silence_editor_pauses_list ID. Multicam protection applies to the group-time pause across repeated occurrences. Protecting the auditioned multicam pause closes its review. Done closes the review. Use set_retained with a nonnegative total duration in seconds, or reset_retained, for one detected pause in its occurrence. next_cut and keep_and_advance operate on an open detected-pause review.

`review_open` reports whether a cut audition is active. Editing the requested retained duration returns the requested and achieved values. Read the pause list again to inspect protection and retained durations.

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

## File tools and jobs

### `analysis_file_sidecar_build`

Build selected analysis sections beside a recording. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `only` | optional | array of `index` / `scenes` / `audio`, minimum items `1` |  |
| `silence_audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index of the audio to analyze. |
| `silence_threshold_db` | optional | number, minimum `-120`, maximum `0` |  |
| `silence_min_pause_seconds` | optional | number |  |
| `no_sidecar` | optional | boolean |  |
| `only_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |

### `analysis_file_sidecar_inspect`

Inspect the analysis sections saved beside a recording. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `no_sidecar` | optional | boolean |  |

### `cli_help_read`

Read native help, manual, examples, or the multicam project template. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `topic` | optional | string, minimum length `1` | Canonical CLI help topic, such as silence plan or transcript words search. Omit to list commands. |

### `cli_version_read`

Identify the bundled file CLI build. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |

### `export_file_clips_join`

Join ordered clips into one output and report the occurrence-level cut map when available. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry. Group ranges from one Mix project preserve lane IDs and bindings. Use video-only or remove audio to join a Mix project with other sources.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. A render plan that generates gaps reports `generated_still_duration` as an exact rational object alongside `copied_camera_duration` and `encoded_camera_duration`. A cut map retains each ordered occurrence even where multiple uses share a render segment. Use `file_job_result_read` for large payloads.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `space_clips` | optional | string, minimum length `1` | Set gaps between picture items for this render. Use source for source timing or a nonnegative gap duration in exact rational seconds. Applies to project timelines and ordered ranges from picture files. Saved project documents are preserved. |
| `require_camera_copy` | optional | boolean | Require zero encoded camera duration when rendering a saved or inline project. |
| `output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index for the requested audio track. |
| `mode` | optional | `copy` / `smart` / `encode` |  |
| `video` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` |  |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` |  |
| `snap` | optional | `exact` / `nearest` |  |
| `dry_run` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Multicam audio delivery. Separate tracks preserve lane order. Downmix renders the lanes into one mono or stereo track. |

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

### `export_file_ranges_join`

Render ordered or repeated ranges of a single recording. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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

Request cancellation. Poll status until completion to see any outputs the job already published.

Returns `job_id` and `state`. For scene scans, refreshes, and transcript session staging, `progress_event` contains the latest available CLI event. Scene events include durable coverage when it has been saved. Terminal results include `exit_code` and `result_bytes`. Small output is available as `result` for JSON or `output_text` for text. Poll a cancelling job until its terminal state.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `job_id` | required | string, format `uuid` | The job UUID returned when the request was accepted. |

### `file_job_result_read`

Read an exact byte range from the terminal CLI JSON document as base64; concatenate decoded chunks.

Returns a base64 byte page, `next_offset`, `result_bytes` and `done`. Decode each page, concatenate the bytes, then parse the CLI output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `job_id` | required | string, format `uuid` | The job UUID returned when the request was accepted. |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `131072` |  |

### `file_job_status_read`

Get state, native progress and the terminal JSON result. Scene scans and refreshes include the latest available progress event. For large results, read result_bytes using file_job_result_read.

Returns `job_id` and `state`. For scene scans, refreshes, and transcript session staging, `progress_event` contains the latest available CLI event. Scene events include durable coverage when it has been saved. Terminal results include `exit_code` and `result_bytes`. Small output is available as `result` for JSON or `output_text` for text. Poll a cancelling job until its terminal state.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `job_id` | required | string, format `uuid` | The job UUID returned when the request was accepted. |

### `media_file_inspect`

Inspect recording metadata or a bounded window of frames or packets. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `request.operations[].name` | optional | string, minimum length `1` |  |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `request.operations[].name` | optional | string, minimum length `1` |  |
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
| `request.project_path` | required | string |  |

### `project_file_inspect`

Inspect a saved or inline project. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project_path` | required | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `deep` | optional | boolean | Verify stream content even when the file stamp is unchanged. |
| `no_sidecar` | optional | boolean | Check recordings without reading or writing analysis sidecars. |

### `project_file_resolve_export`

Write an editable Resolve timeline. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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

Write JPEG review images and a manifest for a source or every angle at group times. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `output` | required | string, pattern `^/` | Absolute path to a new directory for the JPEGs and manifest. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `no_sidecar` | optional | boolean |  |
| `project_path` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `source_to` | optional | string | Exclusive end in source time. |
| `clip_id` | optional | string, format `uuid` | Stable sequence occurrence ID in the saved project. |
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

### `silence_file_export`

Write shortened media from a recording, project or pause report. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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

### `silence_file_plan`

Plan shortened media from a recording, project or saved pause report. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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

### `silence_file_scan`

Scan a recording or project for pauses. Returns a job_id. Poll file_job_status_read for the CLI result and reuse the operation_id for an identical retry.

Returns a file job receipt. Poll `file_job_status_read` with `job_id` for the CLI result. Use `file_job_result_read` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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

Run still asset relink on a saved project. See cli_help_read for timing and destination options.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `placement` | optional | string |  |
| `project_path` | required | string |  |

### `still_file_project_create`

Run still project create on a saved project. See cli_help_read for timing and destination options.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `out_project` | required | string |  |
| `image` | optional | string |  |
| `gap` | optional | `true` |  |
| `width` | required | integer, minimum `1` |  |
| `height` | required | integer, minimum `1` |  |
| `codec` | required | `h264` / `hevc` / `prores` |  |
| `container` | required | `mp4` / `mov` |  |
| `background` | optional | string |  |
| `color` | optional | `sdr` / `pq` / `hlg` |  |
| `duration` | optional | string |  |
| `frames` | optional | integer, minimum `1` |  |
| `rate` | required | string |  |

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
        }
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `audio_stream_index` | optional | integer, minimum `0` | Zero-based absolute stream index of the audio to analyze. |
| `source_from` | optional | string, minimum length `1` | Inclusive start in source time. |
| `source_to` | optional | string, minimum length `1` | Exclusive end in source time. |
| `columns` | optional | integer, minimum `1`, maximum `65536` |  |
| `no_sidecar` | optional | boolean |  |

## Saved timeline review and multicam analysis

### `history_file_compare`

Compare two saved .cut projects and report project fields and occurrence ranges that changed.

Returns a file job receipt. Poll `file_job_status_read` for the comparison between the two saved projects. It reports changed project fields and before and after occurrence details. Use `file_job_result_read` for a large result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `before_project_path` | required | string | Absolute path to the earlier saved .cut. |
| `project_path` | required | string | Absolute path to the later saved .cut. |

### `multicam_file_switch_coverage_read`

Check picture and routed sound through the proposed group switch interval in a saved multicam project.

Returns a file job receipt. Poll `file_job_status_read` for the exact group interval and its picture status, audio routes and missing ranges.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `project_path` | required | string | Absolute path to the saved multicam .cut. |
| `angle_id` | required | string, minimum length `1` | Camera angle ID for the proposed switch. |
| `group_time` | required | string | Exact proposed group time in rational seconds. |

### `multicam_file_sync_suggest`

Analyze a saved multicam project for offsets, waveform matches and drift. With a replacement file and explicit stream indices, also report offsets relative to the selected camera recording.

Returns a file job receipt. Poll `file_job_status_read` for timestamp evidence, candidate offsets, waveform matches and available drift evidence against the reference source.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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

### `timeline_file_range_map`

Map an exact half-open range of a saved project between source and sequence or group and assembly clocks. Repeated occurrences appear separately.

Returns a file job receipt. Poll `file_job_status_read` for the saved project’s mapping, including the input and output clocks and all intersecting occurrence pieces. Use `file_job_result_read` for a large result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `project_path` | required | string | Absolute path to the saved .cut project. |
| `space` | required | `source` / `sequence` / `group` / `assembly` |  |
| `from` | required | string | Inclusive rational time in the selected clock. |
| `to` | required | string | Exclusive rational time in the selected clock. |
| `file` | optional | string | Absolute path identifying one source file. |
| `occurrence_index` | optional | integer, minimum `0` | Zero-based occurrence index in the saved project. |

## Projects and preferences

### `history_panel_show`

Show the native history sheet for the target project.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |

### `multicam_setup_confirm`

Confirm pending camera setup, optionally supplying source order, names, microphones and opening angle.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

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

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

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

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |
| `visible` | required | boolean |  |

### `preferences_read`

Read shared MPCut settings and inspect the local-control toggle.

Returns current preference values. Changes apply app-wide. Lowering the history limit can trim retained steps immediately.

Pass an empty arguments object.

### `preferences_set`

Change a native preference. Lowering history_max_steps immediately trims retained history in open projects. Local MCP access is controlled in Settings.

Returns current preference values. Changes apply app-wide. Lowering the history limit can trim retained steps immediately.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `key` | required | `history_max_steps` / `analysis_sidecar_reuse_enabled` / `media_auto_refresh_enabled` / `export_tier_downgrade_warning_enabled` / `export_movie_default_mode` / `timeline_snap_target` / `timeline_large_previews_enabled` / `silence_min_pause_seconds` / `silence_max_blip_seconds` / `silence_padding_per_side_seconds` / `playback_preview_volume_fraction` / `playback_preview_muted` / `playback_scrub_audio_enabled` / `export_jpeg_default_preset` |  |
| `value` | required | boolean or string or number | history_max_steps 0–500, playback_preview_volume_fraction 0–1, silence_max_blip_seconds 0–1 second, pause durations in seconds. Enum values match preferences_read. |

Additional schema rules

```json
{
  "allOf": [
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
            "maximum": 500
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "enum": [
              "playback_preview_volume_fraction",
              "silence_max_blip_seconds"
            ]
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "number",
            "minimum": 0,
            "maximum": 1
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
            "minimum": 0.02
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
            "minimum": 0
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "key": {
            "enum": [
              "media_auto_refresh_enabled",
              "export_tier_downgrade_warning_enabled",
              "analysis_sidecar_reuse_enabled",
              "timeline_large_previews_enabled",
              "playback_preview_muted",
              "playback_scrub_audio_enabled"
            ]
          }
        }
      },
      "then": {
        "properties": {
          "value": {
            "type": "boolean"
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
            ]
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
            ]
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
            ]
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

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `kind` | optional | `sequence` / `multicam` |  |
| `paths` | optional | array of string, minimum length `1`, pattern `^/`, minimum items `1`, maximum items `512` |  |

### `project_draft_recover`

Recover an unlocked draft from a path returned by project_drafts_list.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

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

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `paths` | required | array of string, minimum length `1`, pattern `^/`, minimum items `1`, maximum items `512` |  |
| `index` | optional | integer, minimum `0` |  |

### `project_open`

Open a saved MPCut project and wait for native document loading. An already-open document is activated.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

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

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `project_path` | optional | string, minimum length `1`, pattern `^/` | Absolute local filesystem path. |
| `replace_existing` | optional | boolean |  |

### `project_window_focus`

Bring the specified project window to the front.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live handle returned by project_windows_list. |

### `workspace_notice_dismiss`

Dismiss a native informational or error notice after inspecting it. Use its exact message so a newer notice remains visible.

Returns `project_handle`, `revision`, `kind`, `dirty`, `project_path`, `setup_pending` and `monitor_visible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `message` | required | string, minimum length `1` |  |
| `project_handle` | required | string, minimum length `1` |  |

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

Edit a camera or recorder. rename requires name; offset requires offset; nudge/move require direction; nudge also accepts a group time; microphone sets stream (omit to clear); relink requires an absolute path; add_recording requires angle_id, an absolute path and group_start.

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

Inspect the live group, program audio and reference camera. Page sources with offsets, index issues and stream IDs, switches with overrides, suggested switch boundaries and range edges, assembly occurrences, or still placements. For switch_coverage, supply group_time and angle_id to check the proposed snapped interval before committing a take. The audio section gives the saved Mix lanes and bindings and the resolved program spans and gaps.

Returns the chosen page of sources, switches, suggestions, assembly occurrences or stills, group range, audio policy, `total` and revision. Camera rows identify the displayed angle and recording; separate recordings on an angle can carry explicit group coverage. Sources report availability and indexing state, with duration when known. Assembly rows may identify an occurrence-specific `angle_id`. The `switch_coverage` section reports the proposed group interval, picture and audio status, audio routes and missing group intervals. After an export fails at a range edge, the suggestions section includes `edge` with the one-based `range`, its `boundary` (`from` or `to`), the edge time `at` and the verified `times` it can move to.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string |  |
| `section` | required | `sources` / `switches` / `suggestions` / `assembly` / `stills` / `switch_coverage` / `audio` |  |
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

Plan the open project export and report eligible ranges, review findings and the occurrence-level cut map when available.

Starts a live job. Poll `export_editor_job_status_read` for its result. A successful dry run can report `eligible: false` with `reason` and any available structured `issue`, `proposed_ranges`, `alternatives` or `fallback`. An eligible plan or render can include `cut_map.occurrences[]` in playback order, with individual requested, resolved and output ranges and render segment references. Still plans report copied and encoded camera duration, generated still duration, placement ranges and sound actions. Confirm published paths in the job’s `outputs`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `scope` | optional | `timeline` / `selection` / `group` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `require_camera_copy` | optional | boolean | Require zero encoded camera duration when generating stills. |
| `mode` | optional | `smart` / `copy` / `encode` | Defaults to Smart Trim for visible still picture. Other outputs use the native defaults. |
| `codec` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` | Use smaller, balanced or high for H.264 and HEVC. Use 422-lt, 422 or 422-hq for ProRes. Requires movie encode mode. |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` |  |
| `audio_track_ordinal` | optional | integer, minimum `0` | Zero-based track within the ordinary source audio tracks. |
| `use_reviewed_cuts` | optional | boolean | Use the native verified copy-boundary proposal for this ordinary export only. The timeline and its history stay intact. |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Multicam audio delivery. Separate tracks preserve lane order. Downmix renders the lanes into one mono or stereo track. |

### `export_editor_project_render`

Render the open project to the output path and report its occurrence-level cut map when available.

Starts a live job. Poll `export_editor_job_status_read` for its result. A successful dry run can report `eligible: false` with `reason` and any available structured `issue`, `proposed_ranges`, `alternatives` or `fallback`. An eligible plan or render can include `cut_map.occurrences[]` in playback order, with individual requested, resolved and output ranges and render segment references. Still plans report copied and encoded camera duration, generated still duration, placement ranges and sound actions. Confirm published paths in the job’s `outputs`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `scope` | optional | `timeline` / `selection` / `group` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `require_camera_copy` | optional | boolean | Require zero encoded camera duration when generating stills. |
| `mode` | optional | `smart` / `copy` / `encode` | Defaults to Smart Trim for visible still picture. Other outputs use the native defaults. |
| `codec` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` | Use smaller, balanced or high for H.264 and HEVC. Use 422-lt, 422 or 422-hq for ProRes. Requires movie encode mode. |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` |  |
| `audio_track_ordinal` | optional | integer, minimum `0` | Zero-based track within the ordinary source audio tracks. |
| `use_reviewed_cuts` | optional | boolean | Use the native verified copy-boundary proposal for this ordinary export only. The timeline and its history stay intact. |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Multicam audio delivery. Separate tracks preserve lane order. Downmix renders the lanes into one mono or stereo track. |

### `export_queue_entry_remove`

Remove one entry from this project’s native export queue.

Returns the default `coordinate_space` and current `ranges[]` with IDs, names when set, boundaries and captured `items[]`. A multicam entry reports its own group or assembly clock. Items identify the file, source `from` and `to`, and the kind (`clip`, `still`, `angle`, `audio`, `gap` or `replacement`). Multicam items report output bounds, audio items can identify a stream, and generated spans can omit source bounds. Rename preserves the captured contents. Revise recaptures the current marked edit under the same entry ID and name. Extend requires an enclosing interval on the same clock.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `id` | required | string, minimum length `1` |  |

### `export_queue_entry_rename`

Rename a native queue entry while keeping its captured media and bounds.

Returns the default `coordinate_space` and current `ranges[]` with IDs, names when set, boundaries and captured `items[]`. A multicam entry reports its own group or assembly clock. Items identify the file, source `from` and `to`, and the kind (`clip`, `still`, `angle`, `audio`, `gap` or `replacement`). Multicam items report output bounds, audio items can identify a stream, and generated spans can omit source bounds. Rename preserves the captured contents. Revise recaptures the current marked edit under the same entry ID and name. Extend requires an enclosing interval on the same clock.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `id` | required | string, minimum length `1` |  |
| `name` | required | string, minimum length `1` | Display name and default export filename stem. |

### `export_queue_entry_revise`

Recapture the current marked range for an existing queue entry. Extend requires a strict superset in the same coordinate space. Both modes capture the live edit.

Returns the default `coordinate_space` and current `ranges[]` with IDs, names when set, boundaries and captured `items[]`. A multicam entry reports its own group or assembly clock. Items identify the file, source `from` and `to`, and the kind (`clip`, `still`, `angle`, `audio`, `gap` or `replacement`). Multicam items report output bounds, audio items can identify a stream, and generated spans can omit source bounds. Rename preserves the captured contents. Revise recaptures the current marked edit under the same entry ID and name. Extend requires an enclosing interval on the same clock.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `id` | required | string, minimum length `1` |  |
| `mode` | required | `replace` / `extend` |  |

### `export_queue_list`

Read the native export queue and its captured contents. Each entry includes its identifier, exact marked range, and ordered source trims. Mix audio rows include lane_id, lane_label and lane_color_slot. Uncovered audio intervals have kind audio_gap.

Returns the default `coordinate_space` and current `ranges[]` with IDs, names when set, boundaries and captured `items[]`. A multicam entry reports its own group or assembly clock. Items identify the file, source `from` and `to`, and the kind (`clip`, `still`, `angle`, `audio`, `gap` or `replacement`). Multicam items report output bounds, audio items can identify a stream, and generated spans can omit source bounds. Rename preserves the captured contents. Revise recaptures the current marked edit under the same entry ID and name. Extend requires an enclosing interval on the same clock.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |

### `export_queue_plan`

Plan exports of queued entries using their captured ranges.

Returns a live job receipt with `job_id`, `input_revision`, `state`, `progress` and published `outputs`. Poll `export_editor_job_status_read` with the same project. The terminal result reports planned `destinations` and still plans for applicable queue entries.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `container` | optional | string, minimum length `1` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `require_camera_copy` | optional | boolean | Require zero encoded camera duration when generating stills. |
| `mode` | optional | `smart` / `copy` / `encode` |  |
| `codec` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` |  |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` |  |
| `audio_track_ordinal` | optional | integer, minimum `0` | Zero-based track within the ordinary source audio tracks. |
| `subfolder` | optional | string, minimum length `1` | Optional output subfolder. |
| `base_name` | optional | string, minimum length `1` | Optional filename prefix. |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Multicam audio delivery. Separate tracks preserve lane order. Downmix renders the lanes into one mono or stereo track. |

### `export_queue_range_add`

Add the current marked range to the native queue, preserving the captured edit and media.

Returns the default `coordinate_space` and current `ranges[]` with IDs, names when set, boundaries and captured `items[]`. A multicam entry reports its own group or assembly clock. Items identify the file, source `from` and `to`, and the kind (`clip`, `still`, `angle`, `audio`, `gap` or `replacement`). Multicam items report output bounds, audio items can identify a stream, and generated spans can omit source bounds. Rename preserves the captured contents. Revise recaptures the current marked edit under the same entry ID and name. Extend requires an enclosing interval on the same clock.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |

### `export_queue_render`

Render the queued entries to the output directory.

Returns a live job receipt with `job_id`, `input_revision`, `state`, `progress` and published `outputs`. Poll `export_editor_job_status_read` with the same project. The terminal result reports planned `destinations` and still plans for applicable queue entries.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `container` | optional | string, minimum length `1` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `require_camera_copy` | optional | boolean | Require zero encoded camera duration when generating stills. |
| `mode` | optional | `smart` / `copy` / `encode` |  |
| `codec` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` |  |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` / `opus` |  |
| `audio_track_ordinal` | optional | integer, minimum `0` | Zero-based track within the ordinary source audio tracks. |
| `subfolder` | optional | string, minimum length `1` | Optional output subfolder. |
| `base_name` | optional | string, minimum length `1` | Optional filename prefix. |
| `audio_output` | optional | `separate_tracks` / `downmix_mono` / `downmix_stereo` | Multicam audio delivery. Separate tracks preserve lane order. Downmix renders the lanes into one mono or stereo track. |

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

Write an interchange timeline from the current project for Resolve.

Returns a live job receipt for `export_editor_job_status_read`. Published `outputs` can include both the interchange file and the linked WAV directory. The terminal result reports conversion warnings or whether Resolve opened the timeline, as applicable.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |

### `project_editor_resolve_import`

Write an interchange timeline and import it into Resolve.

Returns a live job receipt for `export_editor_job_status_read`. Published `outputs` can include both the interchange file and the linked WAV directory. The terminal result reports conversion warnings or whether Resolve opened the timeline, as applicable.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |

### `review_editor_frames_export`

Export review JPEGs from the live editor. Still and playhead selections sample the program when still placements exist. Supply space to sample exact program times. With no space, times follow native source or multicam group and angle review.

Returns a live job receipt for `export_editor_job_status_read`. A still produces a JPEG. A batch returns its `manifest` path and the written `frames` count, plus `unavailable` for multicam samples where an angle has no picture.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` | Live project handle from project_windows_list. |
| `expected_revision` | required | integer, minimum `0` |  |
| `operation_id` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `selection` | optional | `playhead` / `still` / `times` / `switches` / `scenes` / `non_silent` |  |
| `space` | optional | `sequence` / `group` / `assembly` | Select the program clock for still, playhead or explicit time samples. Omit for the native source and angle review modes. |
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
| `sampling` | optional | `every-frame` / `sparse` |  |
| `include_scenes` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `output` | optional | string, pattern `^/` | Optional absolute path for a new scan JSON file. Pass this file to participant project accept or marker building. |
| `resume_file` | optional | string, pattern `^/` | Optional absolute path to a compatible saved partial scan to resume. |

## Window layout and monitoring

### `timeline_time_reveal`

Reveal the requested exact time on a horizontal timeline surface.

Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `surface` | required | `sequence` / `assembly` / `group` |  |
| `time` | required | string | For reveal_time, a rational timestamp in the named sequence, assembly or group clock. Scrolls the time into view without moving the playhead. |

### `workspace_layout_read`

Read a project window’s timeline zoom, native layout, panel state and scroll positions. Returned scroll surface names identify available controls.

Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |

### `workspace_layout_set`

Change the layout of the requested editor window.

Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `action` | required | `zoom_in` / `zoom_out` / `set_zoom` / `fit` / `restore_zoom` / `set_large_thumbnails` / `set_inspector` / `set_transcript` / `set_waveform_span` / `set_pause_controls` / `set_scroll` / `set_track_label_width` / `set_timeline_height` / `set_inspector_width` |  |
| `zoom` | optional | number, minimum `0`, maximum `13` | Timeline zoom exponent. A value of 0 fits the timeline, and 1 doubles its width. |
| `enabled` | optional | boolean | Used by set_large_thumbnails; shared across windows. |
| `span` | optional | `timeline_zoom` / `whole_clip` / `10_seconds` / `1_second` / `100_milliseconds` / `10_milliseconds` |  |
| `visible` | optional | boolean | Required for set_pause_controls and set_transcript. Defaults to true for set_inspector. |
| `section` | optional | `switches` / `sources` / `assembly` / `export` / `transcript` |  |
| `surface` | optional | `sequence` / `assembly` / `group` / `tracks` |  |
| `fraction` | optional | number, minimum `0`, maximum `1` | Fraction of available scroll travel. Zero shows the beginning; one shows the far end. |
| `points` | optional | number, minimum `1`, maximum `10000` | Divider size in screen points. Track labels accept 106 to 360. Native layout constraints apply. |

| Action | Additional required arguments |
| --- | --- |
| `set_zoom` | `zoom` |
| `set_large_thumbnails` | `enabled` |
| `set_waveform_span` | `span` |
| `set_transcript` | `visible` |
| `set_pause_controls` | `visible` |
| `set_scroll` | `surface`, `fraction` |
| `set_track_label_width` | `points` |
| `set_timeline_height` | `points` |
| `set_inspector_width` | `points` |

### `workspace_panel_show`

Show the requested app or project panel.

Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `show_help` | topic |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `action` | required | `show_about` / `show_settings` / `show_help` / `show_last_export` |  |
| `topic` | optional | `guide` / `agent_guide` / `release_notes` |  |

## Project discovery

### `project_editor_state_read`

Read a live project's revision, editor state and a page of sequence clips or multicam occurrences. Pass the first page's revision on subsequent pages to detect concurrent edits.

State includes `busy`, `modal`, selection, playhead, snapping and `history_max_steps`. Use `offset` and `total` to page `clips[]` or `occurrences[]` at a pinned revision. A sequence row identifies an occurrence by `id` and provides `sequence_from`, `sequence_to`, `source_from` and `source_to`. A multicam row identifies it by zero-based `index` and provides assembly bounds and group bounds for group rows. Insert rows identify the still placement and asset. Still placements are also paged under `stills` when present. `tier` reports the export tier of the timeline: its `id` (`true_lossless`, `lossless`, `reencode`, `checking` or `unavailable`), `name`, the best `mode` and `container`, `warnings`, and the `factors` that lower it, each with an `id`, a `message` and any `nearest` times. `current` is false while a newer timeline is being checked.

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

Return one JPEG image content block from the open project's current playhead, or specify an exact sequence, group or assembly time. For multicam, angle optionally selects a specific camera. Reads the current in-memory edit. Preserves playback, selection, history and disk contents. The longest image edge is at most 640 pixels. Metadata identifies the source frame or still placement, asset and program presentation time.

Returns a JPEG image block in MCP `content` and decoded-frame metadata in `structuredContent`, including `source_time`, `duration`, `width` and `height`. A multicam result identifies the requested or active clock, timestamp, group time and camera. A still result identifies the asset and placement and reports program time. An image-capable host can inspect the picture directly.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | optional | integer, minimum `0` |  |
| `time` | optional | string | Rational seconds such as 1001/30000. Supply space with time. |
| `space` | optional | `sequence` / `group` / `assembly` |  |
| `angle_id` | optional | string, minimum length `1` |  |

Additional schema rules

```json
{
  "allOf": [
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
          "space"
        ]
      },
      "then": {
        "required": [
          "time"
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
| `value` | optional | string | Snap target off, keyframes, scenes, or silence, or a copy container extension supported by this sequence. |
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
| `value` | optional | string | Snap target off, keyframes, scenes, or silence, or a copy container extension supported by this sequence. |

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

Update all uses of a still asset in one native undo step.

Returns the affected `placement` or `asset`, native action, revision, changed and history_retained. Read still_editor_placements_list or the refreshed timeline after structural edits.

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

Insert the source image at the requested time, extending the timeline.

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

Page `items` using `offset` and `total`. Each row supplies stable `placement` and `asset` IDs, operation, framing, authored coordinates and visible program ranges, duration and offline status. Generated gaps have `kind: gap` and `offline: false`. Hidden replacements have zero visible duration.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project_handle` | required | string, minimum length `1` |  |
| `expected_revision` | optional | integer, minimum `0` |  |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `200` |  |

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

Insert a generated color gap at the requested timeline time.

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

## Range mapping and revision comparison

### `history_editor_compare`

Compare a retained undo or redo state with the current timeline without moving the history cursor. Reports affected occurrences and their ranges.

Returns a `comparison` with before and after clocks and durations, changed project fields, and occurrence changes with their before and after values. Pass an index and history token from the same history read and the current editor revision. An unavailable index or stale snapshot is an error.

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

Review a transcript edit and retain its exact boundaries for apply or queue.

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

Find proposed transcript edits using the selected filler terms.

Returns a page of items with its total and continuation offset when more items are available.

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
| `options.engine` | optional | string, minimum length `1`, maximum length `512` |  |
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

Move the playhead to an exact word occurrence in the pinned revision.

Returns the resolved occurrence.

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

### `transcript_editor_occurrences_locate`

Locate occurrences by word ID or read one exact occurrence.

Returns a page of items with its total and continuation offset when more items are available.

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

Page candidate matches for a script beat.

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

Resolve a word selection on the requested clock.

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

Compare takes matching a phrase and include adjacent words.

Returns a page of items with its total and continuation offset when more items are available.

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

Page words in the selected transcript clock and scope.

Returns a page of items with its total and continuation offset when more items are available.

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
| `occurrence_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `expected_attachment_results` | optional | object with values of type string, pattern `^[0-9a-f]{64}$` | Pin every attachment ID and result ID returned by a project-wide request. |
| `speaker_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `source_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `track_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `clip_id` | optional | string, minimum length `1`, maximum length `512` |  |
| `assembly_index` | optional | integer, minimum `0` |  |
| `include_inferred` | optional | boolean |  |

### `transcript_editor_words_search`

Find a phrase and return its matching word occurrences.

Returns a page of items with its total and continuation offset when more items are available.

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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_job_cancel`

Run transcript job cancel on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.job_directory` | optional | string, pattern `^/` | Absolute local path. |
| `request.job_id` | required | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_job_prepare`

Run transcript job prepare on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.diarization` | optional | boolean |  |
| `request.engine` | optional | string |  |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_job_status_read`

Run transcript job status on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `request.job_directory` | optional | string, pattern `^/` | Absolute local path. |
| `request.job_id` | required | string |  |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_provider_capabilities_read`

Run transcript provider capabilities on saved inputs through the bundled CLI.

Returns a file job receipt. Poll `file_job_status_read` using `job_id` or page large payloads with `file_job_result_read`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `request` | required | object | JSON request for this CLI action. See mpcut help transcript --json. |
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
| `working_directory` | optional | string, minimum length `1`, maximum length `4096`, pattern `^/` | Absolute local path. |

### `transcript_file_selection_resolve`

Run transcript words select on saved inputs through the bundled CLI.

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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
| `operation_id` | required | string, minimum length `1`, maximum length `36`, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while the same desktop local-control session or standalone file worker is active. |
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
