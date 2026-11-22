# MPCut MCP tool reference

This reference describes the inputs advertised by the bundled stdio helper. The connected host can retrieve the complete JSON Schemas through `tools/list`. Tool calls use the running app and its local-control setting. Successful project-bound results carry the project handle and the current or applied revision. Inspect `isError` first. MPCut domain errors carry a code and message in `structuredContent`. Invalid requests can also return an MCP protocol or SDK validation error. [Setup, clocks, history and recovery](MCP-AGENT-GUIDE.md)

**83 tools.**

## Live analysis

### `analysis_job_cancel`

Request cancellation of this specific MCP-started scan or sidecar save. Poll analysis_job_status for its terminal state.

Reads the project-bound analysis receipt with `job`, `inputRevision`, `kind`, `status` and progress when available. Poll until succeeded, failed or cancelled. Sidecar saves report published outputs even when interrupted.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `job` | required | string |  |

### `analysis_job_status`

Return the state, original revision, progress when available, and terminal details for a retained native analysis or sidecar job.

Reads the project-bound analysis receipt with `job`, `inputRevision`, `kind`, `status` and progress when available. Poll until succeeded, failed or cancelled. Sidecar saves report published outputs even when interrupted.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `job` | required | string |  |

### `analysis_state`

Read native scene and silence scan progress, issues, current settings and a bounded page of analyzed source IDs and absolute audio stream indices.

Returns scan settings, readiness, progress where available, status and issues. Page `sources.items` for source IDs, index availability, and absolute audio stream indices. Sequence state also identifies the source at the playhead.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `500` |  |

### `apply_pauses`

Shorten detected pauses using the native timeline edit and history, or queue retained takes using the native export queue.

`mode`, `queueCount`, `changed` and `historyRetained` describe the outcome. A committed edit can include a draft-write warning. Shortening uses native history. Queueing adds retained takes to the project’s export queue.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string |  |
| `mode` | required | `shorten` / `queue` |  |

### `cancel_analysis`

Cancel the active native scene or silence scan in this project.

Returns `status: idle` or `status: cancel_requested` for the selected scan family. For a specific MCP-owned job, use `analysis_job_cancel` with its receipt.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string |  |
| `kind` | required | `scenes` / `silence` |  |

### `configure_silence`

Set at least one native silence option. Sequence trackOrdinal is zero-based. A sequence threshold applies to the named source, or the source at the playhead when omitted. A null threshold restores automatic detection. Minimum and retained padding are shared editor preferences.

Returns applied status and the current revision. Inspect `analysis_state` or the relevant report for the new setting or result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string |  |
| `trackOrdinal` | optional | integer, minimum `0` |  |
| `source` | optional | string |  |
| `minimumPause` | optional | number, minimum `0.02`, maximum `86400` |  |
| `leavePause` | optional | number, minimum `0`, maximum `86400` |  |
| `thresholdDB` | optional | number or null, minimum `-120`, maximum `0` |  |

### `get_waveform`

Read signed minimum and maximum sample amplitudes for equal-width source-time bins using the same envelope decoder as the GUI and CLI. Use source IDs and absolute stream indices from analysis_state.

Returns signed `low` and `high` arrays for the specified column count, source clock, stream and actual time window in seconds.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `source` | required | string |  |
| `stream` | required | integer, minimum `0` |  |
| `columns` | optional | integer, minimum `1`, maximum `2048` |  |
| `from` | optional | string |  |
| `to` | optional | string |  |

### `get_waveform_peaks`

Read linear-amplitude peak bins from a completed native waveform on the selected sequence track or a routed multicam track. Unobserved bins are null. Stream uses an absolute stream index. Use get_waveform for a signed envelope or another indexed stream.

Returns source ID, stream, `fromSeconds`, `toSeconds`, source clock, `peaks` and `binsPerSecond`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `source` | required | string |  |
| `stream` | required | integer, minimum `0` |  |
| `columns` | optional | integer, minimum `1`, maximum `2048` |  |
| `from` | optional | string |  |
| `to` | optional | string |  |

### `list_pauses`

Read detected pauses, proposed removals, clock and protection state from the current sequence or multicam assembly. Use the returned pause ID for review.

Returns `items`, `offset` and `total`. Use returned pause IDs for reviews. Read each pause’s clock, occurrence where applicable, and protected/removal fields. A multicam assembly selection limits results to its occurrences.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `500` |  |

### `list_scenes`

Read one analyzed source’s scenes, exact source-relative boundaries and recurring view names.

Returns `items`, `offset` and `total`. Each item pairs source-clock scene boundaries with its view ID and label.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `source` | required | string |  |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `500` |  |

### `rename_view`

Set the name for every matching view in an analyzed source. An empty name restores the default.

Returns applied status and the current revision. Inspect `analysis_state` or the relevant report for the new setting or result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string |  |
| `source` | required | string |  |
| `view` | required | integer, minimum `1` |  |
| `name` | required | string, maximum length `1024` |  |

### `review_pause`

Seek, preview, protect or unprotect a pause by its list_pauses ID. Multicam protection applies to the group-time pause across repeated occurrences. Protecting the auditioned multicam pause closes its review. Done closes the review. NextCut and keepAndAdvance operate on an open sequence review.

`reviewOpen` reports whether the cut audition is active. Read the pause list again to inspect protection state.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `seek`, `protect`, `unprotect`, `preview` | pause ID returned by list_pauses |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string |  |
| `pause` | optional | string |  |
| `action` | required | `seek` / `preview` / `protect` / `unprotect` / `nextCut` / `keepAndAdvance` / `done` |  |

### `save_analysis_sidecars`

Save completed analysis beside the project sources using the native save operation. Poll the returned job with analysis_job_status.

Returns an analysis job receipt. Poll `analysis_job_status` for terminal status and outputs. Use `file_sidecar` with `status` to inspect persisted sections.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string |  |

### `scan_analysis`

Start native background scene or silence analysis or rescan completed silence. Poll analysis_job_status using the returned job ID. An existing GUI scan returns its origin.

Returns an analysis receipt with `job`, `kind`, `inputRevision` and `status`. Poll `analysis_job_status` for that receipt. A scan already running in the editor returns `origin: editor` and can be followed through `analysis_state`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string |  |
| `kind` | required | `scenes` / `silence` |  |

### `set_skip_pauses`

Enable or disable native skipping of detected pauses during playback.

Returns applied status and the current revision. Inspect `analysis_state` or the relevant report for the new setting or result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string |  |
| `enabled` | required | boolean |  |

### `use_room_tone`

Calibrate manual thresholds from measured audio in the marked sequence, group, or assembly range and clear the consumed marks.

Returns applied status and the current revision. Inspect `analysis_state` or the relevant report for the new setting or result.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string |  |

## File tools and jobs

### `file_bulk`

Write separate numbered outputs for ranges of one recording. Results include completed outputs on a partial failure. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
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
| `audio_stream` | optional | integer, minimum `0` |  |
| `mode` | optional | `copy` / `smart` / `encode` |  |
| `video` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` |  |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` |  |
| `snap` | optional | `exact` / `nearest` |  |
| `dry_run` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `ranges_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |

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

### `file_convert`

Convert between editable MPCut, Resolve, Premiere and Final Cut Pro projects. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `to` | optional | string, minimum length `1` | Destination format name or extension. |
| `allow_loss` | optional | boolean |  |
| `flatten_multicam` | optional | boolean |  |

### `file_export`

Render an ordered edit, replace a soundtrack, or export a saved project. For a project provide output; for an edit supply edit.output. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `edit` | optional | object |  |
| `edit.clips` | required | array of object, minimum items `1` |  |
| `edit.clips[].file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.clips[].project` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `edit.clips[].from` | optional | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `edit.clips[].from` | when using this variant | object | object variant |
| `edit.clips[].from.numerator` | required | integer |  |
| `edit.clips[].from.denominator` | required | integer, minimum `1` |  |
| `edit.clips[].to` | optional | string, minimum length `1` or object | Time in seconds, timecode, exact rational string such as 1001/30000, or a rational object. |
| `edit.clips[].to` | when using this variant | object | object variant |
| `edit.clips[].to.numerator` | required | integer |  |
| `edit.clips[].to.denominator` | required | integer, minimum `1` |  |
| `edit.clips[].csv` | optional | string, pattern `^/` | CSV split points or keep ranges. For file-based exports. |
| `edit.clips[].rangesFile` | optional | string, pattern `^/` | Native CSV/JSON ranges file. For file-based exports. |
| `edit.clips[].replaceAudio` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.clips[].replaceTrack` | optional | integer, minimum `0` |  |
| `edit.clips[].replacementStream` | optional | integer, minimum `0` |  |
| `edit.file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `edit.order` | optional | array of integer, minimum `1`, minimum items `1` |  |
| `edit.replaceAudio` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.replaceTrack` | optional | integer, minimum `0` |  |
| `edit.replacementStream` | optional | integer, minimum `0` |  |
| `output` | optional | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream` | optional | integer, minimum `0` |  |
| `mode` | optional | `copy` / `smart` / `encode` |  |
| `video` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` |  |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` |  |
| `snap` | optional | `exact` / `nearest` |  |
| `dry_run` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `clips_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `order_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |

Additional schema rules

```json
{
  "allOf": [
    {
      "oneOf": [
        {
          "required": [
            "project"
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
              "project"
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

### `file_frames`

Write JPEG review images and a manifest for a source or every angle at group times. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `project` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `output` | required | string, pattern `^/` | Absolute path to a new directory for the JPEGs and manifest. |
| `at` | optional | array of string, minimum length `1`, minimum items `1` |  |
| `preset` | optional | `review` / `full` |  |
| `select` | optional | `scenes` / `non-silent` |  |
| `sample` | optional | `first` / `midpoint` |  |
| `limit` | optional | integer, minimum `1` |  |
| `stream` | optional | integer, minimum `0` |  |
| `threshold_db` | optional | number, minimum `-120`, maximum `0` |  |
| `min_pause` | optional | number |  |
| `no_sidecar` | optional | boolean |  |
| `at_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |

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
            "project"
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

### `file_help`

Read native help, manual, examples, or the multicam project template. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `topic` | optional | `help` / `manual` / `version` / `inspect` / `convert` / `resolve` / `multicam` / `waveform` / `silence` / `scenes` / `frames` / `sidecar` / `export` / `rearrange` / `bulk` |  |

### `file_inspect`

Inspect one file, saved project, or inline .cut document. Choose a half-open window for frame or packet queries. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `project` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `detail` | optional | `metadata` / `frames` / `keyframes` / `audio_packets` |  |
| `from` | optional | string, minimum length `1` | Time in seconds, timecode, or exact rational seconds such as 1001/30000. |
| `to` | optional | string, minimum length `1` | Time in seconds, timecode, or exact rational seconds such as 1001/30000. |
| `stream` | optional | integer, minimum `0` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream` | optional | integer, minimum `0` |  |
| `no_sidecar` | optional | boolean |  |

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
            "project"
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

### `file_job_cancel`

Request cancellation. Poll status until completion to see any outputs the job already published.

Returns `job_id` and `state`. Terminal results include `exit_code` and `result_bytes`. Small output is available as `result` for JSON or `output_text` for text. Poll a cancelling job until its terminal state.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `job_id` | required | string, format `uuid` | The job UUID returned when the request was accepted. |

### `file_job_result`

Read an exact byte range from the terminal CLI JSON document as base64; concatenate decoded chunks.

Returns a base64 byte page, `next_offset`, `result_bytes` and `done`. Decode each page, concatenate the bytes, then parse the CLI output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `job_id` | required | string, format `uuid` | The job UUID returned when the request was accepted. |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `131072` |  |

### `file_job_status`

Get state, native progress when available and the terminal JSON result. For large results, read result_bytes using file_job_result.

Returns `job_id` and `state`. Terminal results include `exit_code` and `result_bytes`. Small output is available as `result` for JSON or `output_text` for text. Poll a cancelling job until its terminal state.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `job_id` | required | string, format `uuid` | The job UUID returned when the request was accepted. |

### `file_rearrange`

Render ordered or repeated ranges of a single recording. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
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
| `audio_stream` | optional | integer, minimum `0` |  |
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

### `file_resolve`

Write an editable Resolve timeline with optional import into the currently open Resolve project. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `project` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
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
| `edit.clips[].replaceAudio` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.clips[].replaceTrack` | optional | integer, minimum `0` |  |
| `edit.clips[].replacementStream` | optional | integer, minimum `0` |  |
| `edit.file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.output` | required | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `edit.order` | optional | array of integer, minimum `1`, minimum items `1` |  |
| `edit.replaceAudio` | optional | string, pattern `^/` | Absolute path to the source file. |
| `edit.replaceTrack` | optional | integer, minimum `0` |  |
| `edit.replacementStream` | optional | integer, minimum `0` |  |
| `open` | optional | boolean |  |
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
            "project"
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
              "project"
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

### `file_scenes`

Detect scene cuts or export grouped scenes/views from a file or saved report. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `report` | optional | object | Existing native CLI JSON report; retain its file, source stamp, and indices. |
| `export_to` | optional | string, pattern `^/` | Absolute path to an existing output directory. Each rendered file needs a new name. |
| `group_by` | optional | `scene` / `view` |  |
| `container` | optional | string, minimum length `1` | Container extension. |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream` | optional | integer, minimum `0` |  |
| `dry_run` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `scenes_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |

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
    },
    {
      "if": {
        "oneOf": [
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
      "then": {
        "required": [
          "export_to"
        ]
      }
    }
  ]
}
```

### `file_sidecar`

Read the sidecar inventory or build and merge selected analysis sections. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `status` | optional | boolean |  |
| `only` | optional | array of `index` / `scenes` / `audio`, minimum items `1` |  |
| `stream` | optional | integer, minimum `0` |  |
| `threshold_db` | optional | number, minimum `-120`, maximum `0` |  |
| `min_pause` | optional | number |  |
| `no_sidecar` | optional | boolean |  |
| `only_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |

### `file_silence`

Analyze a recording or a project soundtrack, replay a saved silence report, or write shortened media. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | optional | string, pattern `^/` | Absolute path to the source file. |
| `project` | optional | string, pattern `^/` | Absolute path to a saved project. Unsaved GUI changes are excluded. |
| `project_data` | optional | object | Inline .cut document. Use absolute media paths, or set working_directory for relative assets. |
| `report` | optional | object | Existing native CLI JSON report; retain its file, source stamp, and indices. |
| `stream` | optional | integer, minimum `0` |  |
| `threshold_db` | optional | number, minimum `-120`, maximum `0` |  |
| `min_pause` | optional | number |  |
| `leave` | optional | number, minimum `0` |  |
| `waveform` | optional | integer, minimum `1`, maximum `8192` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `audio_stream` | optional | integer, minimum `0` |  |
| `mode` | optional | `smart` / `copy` |  |
| `output` | optional | string, pattern `^/` | Absolute destination path. Existing media outputs are protected. |
| `dry_run` | optional | boolean |  |
| `no_sidecar` | optional | boolean |  |
| `input_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |
| `pauses_file` | optional | string, pattern `^/` | Absolute path to a native CLI input/list file. |

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
            "project"
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
    }
  ]
}
```

### `file_version`

Identify the bundled file CLI build. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |

### `file_waveform`

Query a signed audio amplitude envelope. Starts a file job; poll file_job_status for its native CLI result. Supply the same operationID when retrying.

Returns a file job receipt. Poll `file_job_status` with `job_id` for the CLI result. Use `file_job_result` for large payloads. See the bundled CLI help for this command’s JSON output.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, format `uuid` | A fresh UUID for each distinct job. Identical requests can reuse it while running and for ten minutes after completion while local control stays enabled. |
| `working_directory` | optional | string, pattern `^/` | Existing base directory for relative paths embedded in reports or project documents. |
| `file` | required | string, pattern `^/` | Absolute path to the source file. |
| `stream` | optional | integer, minimum `0` |  |
| `from` | optional | string, minimum length `1` | Time in seconds, timecode, or exact rational seconds such as 1001/30000. |
| `to` | optional | string, minimum length `1` | Time in seconds, timecode, or exact rational seconds such as 1001/30000. |
| `columns` | optional | integer, minimum `1`, maximum `65536` |  |
| `no_sidecar` | optional | boolean |  |

## Projects and preferences

### `add_media`

Add local recordings using the native editor. In a sequence, append or insert at index; in a multicam editor this opens source setup. Read editor state after partial import.

Returns `project`, `revision`, `kind`, `dirty`, `path`, `setupPending` and `monitorVisible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live handle returned by list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `paths` | required | array of string, minimum length `1`, pattern `^/`, minimum items `1`, maximum items `512` |  |
| `index` | optional | integer, minimum `0` |  |

### `cancel_native_operation`

Cancel the exact native worker returned by get_native_operations. Supply its same project handle for window-owned work. An ended worker cannot cancel its successor.

`cancellationRequested` acknowledges the request for the supplied native operation ID. Read active operations again. An operation that ended can return `operation_ended`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | optional | string, minimum length `1` | Target live window. Omit for app-wide project conversion. |
| `nativeOperation` | required | string, format `uuid` |  |
| `operationID` | required | string, minimum length `1`, maximum length `128` |  |

### `close_project`

Close this window. Specify what to do with unsaved edits; save requires a .cut path if the document is untitled.

`closed` reports whether the window closed. A dirty project requires a `changes` decision. Saving an untitled project also requires `path`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live handle returned by list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `changes` | optional | `save` / `discard` / `cancel` |  |
| `path` | optional | string, minimum length `1`, pattern `^/` | Absolute local filesystem path. |
| `replaceExisting` | optional | boolean |  |

### `dismiss_notice`

Dismiss a native informational or error notice after inspecting it. Use its exact message so a newer notice remains visible.

Returns `project`, `revision`, `kind`, `dirty`, `path`, `setupPending` and `monitorVisible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `message` | required | string, minimum length `1` |  |
| `project` | required | string, minimum length `1` |  |

### `focus_project`

Bring the specified project window to the front.

Returns `project`, `revision`, `kind`, `dirty`, `path`, `setupPending` and `monitorVisible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live handle returned by list_projects. |

### `get_multicam_setup`

Inspect the pending setup after a multicam import. Returns source IDs, picture/stream availability, and whether the project already exists.

`sources[]` identifies pending source IDs, paths, video presence and available audio streams. `adding` distinguishes extending an existing project from initial setup.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live handle returned by list_projects. |

### `get_native_operations`

Inspect current native UI import/export/multicam workers for a specified project, including conversion started in that window. Omit project to inspect app-wide conversion. Scene/silence scans use analysis_state.

`operations[]` identifies active native workers by `nativeOperation`, kind, label, state and progress when available. Supply the project for a project-owned worker. Omit it for an unowned project conversion.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | optional | string, minimum length `1` | Target live window. Omit for app-wide project conversion. |

### `get_preferences`

Read shared MPCut settings and inspect the local-control toggle.

Returns current preference values. Changes apply app-wide. Lowering the history limit can trim retained steps immediately.

Pass an empty arguments object.

### `list_drafts`

List unlocked untitled project recovery files and last-modified times.

`drafts[]` contains recoverable paths and modification times.

Pass an empty arguments object.

### `multicam_setup`

Confirm or dismiss native multicam source setup. For creation you can choose opening camera and program audio. Options use the source IDs from get_multicam_setup.

Returns `project`, `revision`, `kind`, `dirty`, `path`, `setupPending` and `monitorVisible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `confirm` | optional sourceOrder must contain every pending ID once. Opening and audio apply during initial setup |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live handle returned by list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `action` | required | `confirm` / `dismiss` |  |
| `sourceOrder` | optional | array of string, minimum length `1` |  |
| `names` | optional | object with values of type string |  |
| `audioStreams` | optional | object with values of type integer, minimum `0` or null |  |
| `opening` | optional | string, minimum length `1` |  |
| `audio` | optional | object |  |
| `audio.mode` | required | `follow` / `none` / `fixed` |  |
| `audio.source` | optional | string, minimum length `1` |  |
| `audio.stream` | optional | integer, minimum `0` |  |

### `new_project`

Create a new ordinary sequence or multicam project window. Supply local recording paths for initial import. Multicam requires a camera and opens the setup sheet.

Returns `project`, `revision`, `kind`, `dirty`, `path`, `setupPending` and `monitorVisible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `kind` | optional | `sequence` / `multicam` |  |
| `paths` | optional | array of string, minimum length `1`, pattern `^/`, minimum items `1`, maximum items `512` |  |

### `open_project`

Open a saved MPCut project and wait for native document loading. An already-open document is activated.

Returns `project`, `revision`, `kind`, `dirty`, `path`, `setupPending` and `monitorVisible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `path` | required | string, minimum length `1`, pattern `^/` | Absolute local filesystem path. |

### `recover_project`

Recover an unlocked draft from a path returned by list_drafts.

Returns `project`, `revision`, `kind`, `dirty`, `path`, `setupPending` and `monitorVisible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `path` | required | string, minimum length `1`, pattern `^/` | Absolute local filesystem path. |

### `save_project`

Save the live project with native history. Supply a new .cut path for Save As. Writing over another existing destination requires replaceExisting.

Returns `project`, `revision`, `kind`, `dirty`, `path`, `setupPending` and `monitorVisible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live handle returned by list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `path` | optional | string, minimum length `1`, pattern `^/` | Absolute local filesystem path. |
| `replaceExisting` | optional | boolean |  |

### `set_preference`

Change a native preference. Lowering historyLimit immediately trims retained history in open projects. Local MCP access is controlled in Settings.

Returns current preference values. Changes apply app-wide. Lowering the history limit can trim retained steps immediately.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `operationID` | required | string, minimum length `1`, maximum length `128` | Unique operation ID for identical retries. |
| `key` | required | `historyLimit` / `useAnalysisSidecars` / `defaultExportMode` / `snapTarget` / `largeThumbnails` / `minimumPause` / `leavePause` / `volume` / `isMuted` / `scrubSoundEnabled` / `jpegPreset` |  |
| `value` | required | boolean or string or number | historyLimit 0–500, volume 0–1, pause durations in seconds. Enum values match get_preferences. |

Additional schema rules

```json
{
  "allOf": [
    {
      "if": {
        "properties": {
          "key": {
            "const": "historyLimit"
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
            "const": "volume"
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
            "const": "minimumPause"
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
            "const": "leavePause"
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
              "useAnalysisSidecars",
              "largeThumbnails",
              "isMuted",
              "scrubSoundEnabled"
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
            "const": "defaultExportMode"
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
            "const": "snapTarget"
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
            "const": "jpegPreset"
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

### `set_video_monitor`

Show or close the target window’s native video monitor.

Returns `project`, `revision`, `kind`, `dirty`, `path`, `setupPending` and `monitorVisible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live handle returned by list_projects. |
| `visible` | required | boolean |  |

### `show_history`

Show the native history sheet for the target project.

Returns `project`, `revision`, `kind`, `dirty`, `path`, `setupPending` and `monitorVisible`. Complete pending multicam setup before editing. Supply a destination path when saving an untitled project.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live handle returned by list_projects. |

## Multicam

### `get_multicam`

Inspect the live group, program audio and reference camera. Page sources with offsets, index issues and stream IDs, switches with overrides, or suggested switch boundaries.

Returns the chosen page of sources, switches or suggestions, group range, audio policy, `total` and revision. A camera source reports its displayed `number`. Sources report availability and indexing state, with duration when known.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string |  |
| `section` | required | `sources` / `switches` / `suggestions` |  |
| `offset` | optional | integer, minimum `0` |  |
| `limit` | optional | integer, minimum `1`, maximum `200` |  |
| `expectedRevision` | optional | integer, minimum `0` |  |

### `multicam_assembly`

Edit retained occurrences. append requires group from/to; trim requires occurrence and from or to; move requires occurrence and before; remove requires an explicit occurrence. Removing the last explicit occurrence restores the implicit full group. Selection actions require space, from and to matching the selected range; read those values from multicam_select. Use trim_edge or preview_trim with occurrence, edge and group time for native handle snapping.

Reports `revision`, `changed` and `historyRetained`. `trim_edge` and `preview_trim` report an exact group `boundary`. A committed edit reports its native action and can carry a draft-write warning.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `append` | group from and to |
| `trim` | occurrence with new group from and/or to |
| `trim_edge`, `preview_trim` | occurrence, edge and group time |
| `move`, `remove` | occurrence. Move also needs the insertion slot in before |
| `split_selection`, `subtract_selection` | select a nonempty group or assembly interval first, then pass its exact space, from and to |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Live project handle returned by list_projects. |
| `expectedRevision` | required | integer | Revision from get_editor_state. |
| `operationID` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `action` | required | `append` / `trim` / `move` / `remove` / `split_selection` / `subtract_selection` / `trim_edge` / `preview_trim` |  |
| `occurrence` | optional | integer | Zero-based assembly occurrence. |
| `before` | optional | integer | Zero-based insertion slot before removal, from 0 through count. |
| `from` | optional | string | Exact rational seconds on the group clock for append or trim, or the selected clock for a selection edit. |
| `to` | optional | string | Exact rational seconds on the group clock for append or trim, or the selected clock for a selection edit. |
| `edge` | optional | `start` / `end` |  |
| `time` | optional | string | Group time for a snapped trim edge. |
| `space` | optional | `group` / `assembly` |  |

### `multicam_audio`

Set program audio routing. A fixed master requires a source ID and an absolute audio stream.

Reports `revision`, `changed` and `historyRetained`. A committed edit reports its native action and can carry a draft-write warning.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Live project handle returned by list_projects. |
| `expectedRevision` | required | integer | Revision from get_editor_state. |
| `operationID` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `mode` | required | `fixed` / `follow` / `none` |  |
| `source` | optional | string | Stable ID of a camera or separate audio source. |
| `stream` | optional | integer | Absolute audio stream index in the indicated source. |

### `multicam_group`

Set the group end using time or extend to the last available camera.

Reports the actual `groupTo`, `revision`, `changed` and `historyRetained`. A committed edit reports its native action and can carry a draft-write warning.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `set_end` | new group end time |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Live project handle returned by list_projects. |
| `expectedRevision` | required | integer | Revision from get_editor_state. |
| `operationID` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `action` | required | `set_end` / `extend` |  |
| `time` | optional | string | Exact rational seconds on the multicam group clock. |

### `multicam_preview`

Set preview mode or transport. audition takes angle; speed takes a rate; shuttle and step actions take direction; snap takes target.

Reports the current clock, `time`, `groupTime`, `playing`, `rate`, forward `speed`, `auditioning` and, in assembly preview, the current `occurrence`.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `audition` | angle ID |
| `shuttle`, `step`, `step_keyframe`, `step_scene`, `step_pause` | direction (-1 or 1) |
| `scrub_group`, `scrub_assembly` | time on the selected clock |
| `speed`, `snap` | speed multiplier, or snap target |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Live project handle returned by list_projects. |
| `action` | required | `group` / `assembly` / `audition` / `program` / `shuttle` / `speed` / `step` / `step_keyframe` / `step_scene` / `step_pause` / `start` / `end` / `snap` / `scrub_group` / `scrub_assembly` / `end_scrub` |  |
| `angle` | optional | string | Stable camera source ID from the live project. |
| `speed` | optional | `0.125` / `0.25` / `0.5` / `0.75` / `1` / `1.25` / `1.5` / `2` / `4` / `8` |  |
| `direction` | optional | `-1` / `1` |  |
| `target` | optional | `off` / `keyframes` / `scenes` / `silence` |  |
| `time` | optional | string | Scrub position in the specified clock, rational seconds. |

### `multicam_select`

Select a switch at group time, occurrence by index, a range with from/to in the named clock, tool or marks in this window.

Reports selection and current preview position. Assembly selection uses the occurrence or bounds from the current revision.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `switch`, `occurrence` | switch time, or occurrence index |
| `group_range`, `assembly_range` | from and to in the chosen clock |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Live project handle returned by list_projects. |
| `action` | required | `switch` / `occurrence` / `group_range` / `assembly_range` / `mark_in` / `mark_out` / `clear_marks` / `pointer` / `range_tool` |  |
| `time` | optional | string | Exact rational seconds on the multicam group clock. |
| `occurrence` | optional | integer | Zero-based assembly occurrence. |
| `from` | optional | string | Inclusive range start, rational seconds. |
| `to` | optional | string | Exclusive range end, rational seconds. |

### `multicam_source`

Edit a camera or recorder. rename requires name; offset requires offset; nudge/move require direction; nudge also accepts a group time; microphone sets stream (omit to clear); relink requires an absolute path.

Reports `revision`, `changed` and `historyRetained`. Nudge reports `groupTime` and the new `offset`. Relink identifies the source. A committed edit reports its native action and can carry a draft-write warning.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `rename`, `offset`, `relink` | source ID and respectively name, offset, or absolute path |
| `move` | source and direction (-1 or 1) |
| `nudge` | source and direction (-1 or 1), plus optional group time |
| `microphone` | source and optional stream. Omit stream to clear the assignment |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Live project handle returned by list_projects. |
| `expectedRevision` | required | integer | Revision from get_editor_state. |
| `operationID` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `action` | required | `rename` / `offset` / `nudge` / `move` / `microphone` / `relink` |  |
| `source` | required | string | Stable ID of a camera or separate audio source. |
| `name` | optional | string | Display name; empty restores default. |
| `offset` | optional | string | Exact sync offset in rational seconds. |
| `time` | optional | string | Group time for the frame or audio sample used by nudge. Omit to use the current group playhead. |
| `direction` | optional | `-1` / `1` |  |
| `stream` | optional | integer | Absolute audio stream index in the indicated source. |
| `path` | optional | string | Absolute replacement file path. |

### `multicam_switch`

Edit an existing group switch at time. move/apply_suggestion require to, angle requires angle, audio requires source and stream. default_audio restores project routing.

Reports `revision`, `changed` and `historyRetained`. A committed edit reports its native action and can carry a draft-write warning.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `move`, `apply_suggestion` | existing switch time and new group time in to |
| `angle` | existing time and angle ID |
| `audio` | existing time, source and stream |
| `delete`, `default_audio` | existing switch time |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Live project handle returned by list_projects. |
| `expectedRevision` | required | integer | Revision from get_editor_state. |
| `operationID` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `action` | required | `move` / `apply_suggestion` / `delete` / `angle` / `audio` / `default_audio` |  |
| `time` | required | string | Exact rational seconds on the multicam group clock. |
| `to` | optional | string | Exact rational seconds on the multicam group clock. |
| `angle` | optional | string | Stable camera source ID from the live project. |
| `source` | optional | string | Stable ID of a camera or separate audio source. |
| `stream` | optional | integer | Absolute audio stream index in the indicated source. |

### `set_camera_at`

Take a camera by angle ID or displayed number at an explicit group time with native snapping and history. Returns the actual time and end of the affected switch interval.

`angle`, `time` and `until` identify the actual group interval affected. Repeated assembly uses share that switch. The result reports `changed` and `historyRetained`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Live project handle returned by list_projects. |
| `expectedRevision` | required | integer | Revision from get_editor_state. |
| `operationID` | required | string | Unique operation ID for this edit. Retry the same request with the same ID. |
| `angle` | optional | string | Stable camera source ID from the live project. |
| `number` | optional | integer, minimum `1` | One-based displayed camera number from the current revision. |
| `time` | required | string | Exact rational seconds on the multicam group clock. |

Additional schema rules

```json
{
  "oneOf": [
    {
      "required": [
        "angle"
      ]
    },
    {
      "required": [
        "number"
      ]
    }
  ]
}
```

## Live exports

### `add_export_range`

Add the current marked range to the native queue, preserving the captured edit and media.

Returns current `ranges[]` with IDs and boundaries, and `coordinateSpace`. Mark a valid range before adding an entry.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |

### `apply_export_review`

Recompute the native ordinary timeline lossless-copy boundary proposal for this output extension and apply it as one undoable edit. Use render_project with dryRun first.

Returns the native action, applied revision and review details when the current copy-boundary proposal is committed. A retained action can be undone through native history.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |

### `cancel_live_job`

Request cancellation of this project’s specific output job; inspect its terminal result to see which outputs were published.

Returns `state`, `progress`, `inputRevision` and published `outputs`. After cancellation, poll until terminal. Read `result` or `error`; a failed batch can already have published files.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |
| `job` | required | string, minimum length `1` |  |

### `convert_live_project`

Export the current unsaved edit as a new .cut, .drp, .drt, .prproj, .fcpxml, .fcpxmld or .fcpbundle. Host applications may be required. Poll live_job_status for warnings and actual output paths.

Returns a live job receipt for `live_job_status`. Published `outputs` can include both the interchange file and the linked WAV directory. The terminal result reports conversion warnings or whether Resolve opened the timeline, as applicable.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `allowLoss` | optional | boolean |  |
| `flattenMulticam` | optional | boolean |  |

### `export_queue`

Check or export queued snapshots to an existing directory. Poll live_job_status for completed outputs, including files already written if a later range fails or is cancelled.

Returns a live job receipt with `job`, `inputRevision`, `state`, `progress` and published `outputs`. Poll `live_job_status` with the same project. The terminal result reports planned `destinations`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `container` | optional | string, minimum length `1` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `mode` | optional | `smart` / `copy` / `encode` |  |
| `codec` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` |  |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` |  |
| `audioTrackOrdinal` | optional | integer, minimum `0` | Zero-based track within the ordinary source audio tracks. |
| `dryRun` | optional | boolean | Defaults to true. Pass false to write output. |

### `export_review_frames`

Export a full-resolution still at the playhead, or a manifest and JPEGs to a new directory. Explicit times use source time on the active ordinary clip and group time on multicam. Playhead, explicit times and switches on multicam sample all angles. Poll live_job_status for the count of written frames and unavailable angle samples.

Returns a live job receipt for `live_job_status`. A still produces a JPEG. A batch returns its `manifest` path and the written `frames` count, plus `unavailable` for multicam samples where an angle has no picture.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `selection` | optional | `playhead` / `still` / `times` / `switches` / `scenes` / `nonSilent` |  |
| `times` | optional | array of string, minimum length `1`, minimum items `1`, maximum items `4096` |  |
| `preset` | optional | `review` / `full` |  |
| `sample` | optional | `first` / `midpoint` |  |
| `limit` | optional | integer, minimum `1` | Optional maximum frame count for scene or non-silent sampling. |

### `get_export_queue`

Read the native export queue. Each entry includes its identifier and exact marked range.

Returns current `ranges[]` with IDs and boundaries, and `coordinateSpace`. Mark a valid range before adding an entry.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |

### `live_job_status`

Read progress, terminal outcome and published paths for an export job in this project.

Returns `state`, `progress`, `inputRevision` and published `outputs`. After cancellation, poll until terminal. Read `result` or `error`; a failed batch can already have published files.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |
| `job` | required | string, minimum length `1` |  |

### `remove_export_range`

Remove one entry from this project’s native export queue.

Returns current `ranges[]` with IDs and boundaries, and `coordinateSpace`. Mark a valid range before adding an entry.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `id` | required | string, minimum length `1` |  |

### `render_project`

Check or render an unsaved timeline snapshot using the native export planner. Read the job with live_job_status. A completed preflight can report eligible false with a structured issue. Ordinary copy preflight can offer verified boundaries and export alternatives.

Starts a live job. Poll `live_job_status` for its result. A successful dry run can report `eligible: false` with `reason` and any available structured `issue`, `proposedRanges`, `alternatives` or `fallback`. An eligible render reports its plan. Confirm published paths in the job’s `outputs`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `scope` | optional | `timeline` / `selection` / `group` |  |
| `tracks` | optional | `all` / `video` / `audio` |  |
| `mode` | optional | `smart` / `copy` / `encode` | Defaults to the native movie preference for full-track movies and copy for a single track type or audio-only sources. |
| `codec` | optional | `h264` / `hevc` / `prores` |  |
| `quality` | optional | `smaller` / `balanced` / `high` / `422-lt` / `422` / `422-hq` | Use smaller, balanced or high for H.264 and HEVC. Use 422-lt, 422 or 422-hq for ProRes. Requires movie encode mode. |
| `audio` | optional | `auto` / `copy` / `aac` / `pcm` / `remove` / `mp3` / `flac` |  |
| `audioTrackOrdinal` | optional | integer, minimum `0` | Zero-based track within the ordinary source audio tracks. |
| `dryRun` | optional | boolean | Defaults to true. Pass false to write output. |
| `useReviewedCuts` | optional | boolean | Use the native verified copy-boundary proposal for this ordinary export only. The timeline and its history stay intact. |

### `replace_live_audio`

Replace the ordinary clip source soundtrack using a new working copy and native history. Supply clip, replacement and output. For multicam choose an existing source/stream or an external replacement recording to set the program soundtrack.

A sequence needs `clip`, `replacement` and an `output` movie. Returns the applied source-audio replacement and output path. A multicam project accepts an existing `source` plus `stream`, or external `replacement`, and returns the program-audio edit.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `clip` | optional | string, minimum length `1` |  |
| `source` | optional | string, minimum length `1` |  |
| `stream` | optional | integer, minimum `0` |  |
| `replacement` | optional | string, minimum length `1` |  |
| `output` | optional | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `targetStream` | optional | integer, minimum `0` |  |
| `replacementStream` | optional | integer, minimum `0` |  |

### `send_live_to_resolve`

Write the live edit as Resolve-compatible FCPXML and optionally import the new timeline into the current Resolve project. The job records the XML and any linked audio directory separately from host import success.

Returns a live job receipt for `live_job_status`. Published `outputs` can include both the interchange file and the linked WAV directory. The terminal result reports conversion warnings or whether Resolve opened the timeline, as applicable.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Live project handle from list_projects. |
| `expectedRevision` | required | integer, minimum `0` |  |
| `operationID` | required | string, minimum length `1` | Unique operation identifier; repeat the exact request after a lost reply. |
| `output` | required | string, minimum length `1` | Absolute local output path. Existing media destinations are protected. |
| `openInResolve` | optional | boolean |  |

## Window layout and monitoring

### `get_presentation`

Read a project window’s timeline zoom, native layout, panel state and scroll positions. Returned scroll surface names identify available controls.

Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` |  |

### `set_presentation`

Adjust a native presentation control in this project window. For setScroll choose a surface and fraction. For sizing supply points. setPauseControls opens the native silence review and may start its scan. showHelp opens the named guide. Thumbnail size and track label width are shared preferences. Returns the resulting presentation state.

Returns the window’s actual presentation state, including zoom, available scroll surfaces and editor-specific layout. Geometry is measured in points.

| Action | Additional inputs or prerequisites |
| --- | --- |
| `setZoom`, `setWaveformSpan` | zoom, or span |
| `setLargeThumbnails`, `setPauseControls` | enabled for thumbnails, visible for pause controls |
| `setInspector` | optional section and visible |
| `setScroll` | surface and fraction |
| `setTrackLabelWidth`, `setTimelineHeight`, `setInspectorWidth` | points |
| `showHelp` | topic |
| `revealTime` | surface and rational time in that surface’s clock |

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` |  |
| `action` | required | `zoomIn` / `zoomOut` / `setZoom` / `fit` / `restoreZoom` / `setLargeThumbnails` / `setInspector` / `setWaveformSpan` / `setPauseControls` / `setScroll` / `setTrackLabelWidth` / `setTimelineHeight` / `setInspectorWidth` / `showAbout` / `showSettings` / `showHelp` / `showLastExport` / `revealTime` |  |
| `zoom` | optional | number, minimum `0`, maximum `13` | Timeline zoom exponent. A value of 0 fits the timeline, and 1 doubles its width. |
| `enabled` | optional | boolean | Used by setLargeThumbnails; shared across windows. |
| `span` | optional | `Timeline zoom` / `Whole clip` / `10 s` / `1 s` / `100 ms` / `10 ms` |  |
| `visible` | optional | boolean | Required for setPauseControls; defaults to true for setInspector. |
| `section` | optional | `Switch` / `Sources` / `Assembly` / `Export` |  |
| `surface` | optional | `sequence` / `assembly` / `group` / `tracks` |  |
| `fraction` | optional | number, minimum `0`, maximum `1` | Fraction of available scroll travel. Zero shows the beginning; one shows the far end. |
| `points` | optional | number, minimum `1`, maximum `10000` | Divider size in screen points. Track labels accept 106 to 360. Native layout constraints apply. |
| `topic` | optional | `guide` / `agentGuide` / `releaseNotes` |  |
| `time` | optional | string | For revealTime, a rational timestamp in the named sequence, assembly or group clock. Scrolls the time into view without moving the playhead. |

## Project discovery

### `get_editor_state`

Read a live project's revision, editor state and a page of sequence clips or multicam occurrences. Pass the first page's revision on subsequent pages to detect concurrent edits.

State includes `busy`, `modal`, selection, playhead, snapping and `historyLimit`. Use `offset` and `total` to page `clips[]` or `occurrences[]` at a pinned revision. A sequence row identifies an occurrence by `id` and provides `sequenceFrom`, `sequenceTo`, `sourceFrom` and `sourceTo`. A multicam row identifies it by zero-based `index` and provides bounds in assembly and group time.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` | Project handle returned by list_projects. |
| `offset` | optional | integer, minimum `0` | Zero-based position of the first timeline entry. Defaults to zero. |
| `limit` | optional | integer, minimum `1`, maximum `200` | Maximum timeline entries to return. Defaults to 50. |
| `expectedRevision` | optional | integer, minimum `0` | Require this document revision for a consistent view across pages. |

### `list_projects`

List the live MPCut project windows, including untitled projects. Use each returned project handle to target exactly that window. Focus is informational.

`projects[]` supplies each window’s opaque `project` handle, name, kind, dirty flag and revision. A saved project includes `path`.

Pass an empty arguments object.

## Inline picture review

### `review_frame`

Return one JPEG image content block from the open project's current playhead, or specify an exact sequence, group or assembly time. For multicam, angle optionally selects a specific camera. Reads the current in-memory edit. Preserves playback, selection, history and disk contents. The longest image edge is at most 640 pixels. Metadata identifies the actual source frame time.

Returns a JPEG image block in MCP `content` and decoded-frame metadata in `structuredContent`, including `sourceTime`, `duration`, `width` and `height`. A multicam result identifies the requested or active clock, timestamp, group time and camera. An image-capable host can inspect the picture directly.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string, minimum length `1` |  |
| `expectedRevision` | optional | integer, minimum `0` |  |
| `time` | optional | string | Rational seconds such as 1001/30000. Supply space with time. |
| `space` | optional | `sequence` / `group` / `assembly` |  |
| `angle` | optional | string, minimum length `1` |  |

## Editing, navigation and history

### `get_history`

Read retained native history, cursor, and history token for this project.

`actions`, `cursor`, `historyToken` and `limit` describe the retained branch. Index zero is the state before the first retained action. A restore needs the index and token from one read. Refresh after a history change.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Opaque live document handle from list_projects. |

### `redo`

Redo one native history action in the specified document.

`actions`, `cursor`, `historyToken` and `limit` describe the retained branch. Index zero is the state before the first retained action. A restore needs the index and token from one read. Refresh after a history change.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Opaque live document handle from list_projects. |
| `expectedRevision` | required | integer | Document revision observed by the caller. |
| `operationID` | required | string | Unique mutation ID. Reuse only for an identical retry. |

### `restore_history`

Restore a retained native history state by zero-based index and get_history token.

`actions`, `cursor`, `historyToken` and `limit` describe the retained branch. Index zero is the state before the first retained action. A restore needs the index and token from one read. Refresh after a history change.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Opaque live document handle from list_projects. |
| `expectedRevision` | required | integer | Document revision observed by the caller. |
| `operationID` | required | string | Unique mutation ID. Reuse only for an identical retry. |
| `index` | required | integer, minimum `0` | 0 is the first retained state. |
| `historyToken` | required | string | Token from get_history. |

### `seek`

Seek within the named project. Source time requires a clip occurrence. Multicam group time with an occurrence seeks that use in assembly preview; an occurrence supplied with assembly time must match the position.

Returns resulting transport and editor state. Ordinary editors include `playheadSeconds`, `playing`, `rate` and selection when present. Multicam transport includes `space`, `time`, `groupTime` and the current occurrence during assembly preview.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Opaque live document handle from list_projects. |
| `space` | required | `sequence` / `source` / `group` / `assembly` |  |
| `time` | required | string | Exact media time as rational seconds, e.g. 1001/30000. |
| `expectedRevision` | optional | integer, minimum `0` | Pin the seek to the document revision used to resolve the occurrence. |
| `occurrence` | optional | string or integer, minimum `0` | Clip UUID for an ordinary editor, or zero-based assembly occurrence index for multicam. |

### `sequence_control`

Operate the ordinary sequence editor. Trim time is source time. from/to are sequence times. Move uses insertion slots. fit toggles fit/previous zoom.

Returns resulting editor state with `revision`, or a command-specific result such as `action: Apply CSV` and `changed`. A trim preview reports the `trimPreview` token and its proposed `sourceTime`.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Opaque live document handle from list_projects. |
| `expectedRevision` | required | integer | Document revision observed by the caller. |
| `operationID` | required | string | Unique mutation ID. Reuse only for an identical retry. |
| `action` | required | `select` / `selectRange` / `markIn` / `markOut` / `clearMarks` / `rangeTool` / `snap` / `copyContainer` / `move` / `trim` / `restoreEdge` / `deleteClip` / `deleteRange` / `splitRange` / `applyCSV` / `step` / `shuttle` / `speed` / `scrub` / `endScrub` / `zoom` / `fit` / `thumbnails` / `previewTrim` / `cancelTrim` |  |
| `occurrence` | optional | string | Clip occurrence UUID from get_editor_state. |
| `from` | optional | string | Sequence start time in seconds. |
| `to` | optional | string | Sequence end time in seconds. |
| `space` | optional | `sequence` / `source` / `group` / `assembly` |  |
| `time` | optional | string | Exact media time as rational seconds, e.g. 1001/30000. |
| `enabled` | optional | boolean | Requested setting. |
| `value` | optional | string | Snap target off, keyframes, scenes, or silence, or a copy container extension supported by this sequence. |
| `slot` | optional | integer, minimum `0` | Insertion slot before moving, 0 through clip count. |
| `edge` | optional | `start` / `end` |  |
| `path` | optional | string | Absolute input CSV path. |
| `direction` | optional | `-1` / `1` |  |
| `unit` | optional | `frame` / `keyframe` / `scene` / `pause` |  |
| `rate` | optional | `0.125` / `0.25` / `0.5` / `0.75` / `1` / `1.25` / `1.5` / `2` / `4` / `8` |  |
| `zoom` | optional | number, minimum `0`, maximum `13` |  |
| `trimPreview` | optional | string, format `uuid` | Receipt identifying your active trim preview. Use it to preview or commit the same occurrence and edge, or to cancel. |

| Action | Additional required arguments |
| --- | --- |
| `select` | `occurrence` |
| `selectRange` | `from`, `to` |
| `markIn` | `space`, `time` |
| `markOut` | `space`, `time` |
| `rangeTool` | `enabled` |
| `snap` | `value` |
| `copyContainer` | `value` |
| `move` | `occurrence`, `slot` |
| `trim` | `occurrence`, `edge`, `time` |
| `restoreEdge` | `occurrence`, `edge` |
| `deleteClip` | `occurrence` |
| `deleteRange` | `from`, `to` |
| `splitRange` | `from`, `to` |
| `applyCSV` | `occurrence`, `path` |
| `step` | `direction`, `unit` |
| `shuttle` | `direction` |
| `speed` | `rate` |
| `scrub` | `space`, `time` |
| `zoom` | `zoom` |
| `thumbnails` | `enabled` |
| `previewTrim` | `occurrence`, `edge`, `time` |
| `cancelTrim` | `trimPreview` |

### `set_playback`

Play or pause the preview in the named project.

Returns resulting transport and editor state. Ordinary editors include `playheadSeconds`, `playing`, `rate` and selection when present. Multicam transport includes `space`, `time`, `groupTime` and the current occurrence during assembly preview.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Opaque live document handle from list_projects. |
| `playing` | required | boolean | Whether the preview should be playing. |

### `split_at`

Split the specified clip or assembly occurrence using native snapping and undo history.

Reports applied `boundary` in the requested clock, `left` and `right` occurrence references and `historyRetained`. Sequence results include `sourceTime` and `sequenceTime`. Multicam results include `groupTime`. Use the returned `revision` with the next edit.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Opaque live document handle from list_projects. |
| `expectedRevision` | required | integer | Document revision observed by the caller. |
| `operationID` | required | string | Unique mutation ID. Reuse only for an identical retry. |
| `space` | required | `sequence` / `source` / `group` / `assembly` |  |
| `time` | required | string | Exact media time as rational seconds, e.g. 1001/30000. |
| `occurrence` | required | string or integer, minimum `0` |  |

### `undo`

Undo one native history action in the specified document.

`actions`, `cursor`, `historyToken` and `limit` describe the retained branch. Index zero is the state before the first retained action. A restore needs the index and token from one read. Refresh after a history change.

| Argument | Presence | Values | Meaning |
| --- | --- | --- | --- |
| `project` | required | string | Opaque live document handle from list_projects. |
| `expectedRevision` | required | integer | Document revision observed by the caller. |
| `operationID` | required | string | Unique mutation ID. Reuse only for an identical retry. |
