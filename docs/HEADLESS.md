# Edit saved projects without opening MPCut

Use the bundled CLI for a shell script. For an MCP client on the same Mac, register a separate stdio connection with the file worker flag.

```sh
codex mcp add mpcut-files -- "/Applications/MPCut.app/Contents/Helpers/mpcut-mcp" --files-only
```

The worker starts with the MCP connection, exposes saved-file tools in discovery, and uses the bundled CLI. It requires neither an editor window nor the desktop local-control setting. The ordinary helper invocation still connects to the running editor and uses its local-control setting. Configure the file worker only in clients you trust to read and write local files under your account.

The local-control switch and the agent permissions in **Settings → Automation** do not gate the file worker, because there is no app to ask. The CLI does not read desktop settings, so file jobs use the factory value of every omitted option. A transcription job that names no engine uses Qwen3, and the worker finds Transcriberrr through the `MPCUT_TRANSCRIBERRR_HELPER` environment variable or the installed app. The cutcache location is shared with the app, and `analysis_file_cache_settings_set` can change it from this worker. To edit open or unsaved projects in the running app, connect the ordinary helper instead. [Live editing from an agent](MCP-AGENT-GUIDE.md)

Use the helper from the bundle whose CLI you checked. In a source checkout, run `dist/MPCut.app/Contents/Helpers/mpcut --version --json` and configure the absolute path to its sibling `mpcut-mcp`. The completed `cli_version_read` job reports the same build ID, supported project schemas and detector capabilities.

MCP edits record **Agent** in project history. Shell edits default to **User**. Set `MPCUT_HISTORY_ORIGIN=agent` when invoking the CLI directly from an agent.

Each request that starts a file job takes an `operation_id` UUID. The returned `job_id` is the same UUID, so you can look up the job even if the response was lost. Reconnect to the files-only server on the same Mac and user account and call `file_job_status_read` with that ID. An identical submission returns the existing job. Using the ID with different arguments returns `operation_id_conflict`.

Poll until the state is `succeeded`, `failed`, `cancelled`, `needs_review`, or `outcome_unknown`. Tiles ISO deliveries return `needs_review` when a blocking issue requires a correction. Call `file_job_cancel` through the worker that started the job, then poll for a terminal state. A normal disconnect cancels active CLI processes. If the worker stops before recording the result, `outcome_unknown` means the CLI may still be finishing or may already have changed files. Reusing the ID preserves that receipt. Inspect the project and any published outputs before deciding whether to start a new operation.

Read a small result from `result`. If status reports `result_bytes` without an inline result, call `file_job_result_read` with `job_id` and `offset: 0`. Base64-decode each page, use its `next_offset` for the next request, and concatenate the bytes through the page with `done: true` before parsing JSON. Offsets count bytes in the original output. On failure, read the available CLI error code and message or the job's `diagnostic` field. Once you have collected the result, `file_job_release` discards its payload and preserves the receipt.

Standalone receipts are retained for seven days after completion or discovery of an interruption. The store holds up to 8,192 receipts and 256 MiB of terminal result payloads. It removes older payloads as needed, so check `result_available` and collect large results promptly. A full receipt store returns `job_receipt_capacity` until older receipts expire. Each worker also admits up to eight active jobs and returns `jobs_busy` when those slots are full. Desktop local-control jobs have a separate ten-minute, session-local retention window.

For example, call `review_file_frames_export` with the following arguments to see the opening frame of a saved multicam assembly. Replace the paths and generate a fresh operation UUID for each distinct request.

```json
{
  "operation_id": "60053d79-65ae-4561-ba58-08e12846b733",
  "project_path": "/Users/editor/Interview/rough.cut",
  "clock": "assembly",
  "at": ["0"],
  "output": "/Users/editor/Interview/opening-frame"
}
```

The successful job returns a manifest of exported frames. To view pixels directly over MCP, start `review_file_frame_read` for one time, poll the job, then request `review_file_frame_result_read`. The JPEG is bounded to 640 pixels on either axis and one MiB.

For an approved movie export, call `export_file_project_render` with a saved `project_path` and `dry_run: true`. Keep the returned `plan_token`. Render using that token and the same destination and options. If a project, media identity, executable build or output setting changed, `stale_render_plan` requires a fresh preflight. Conversions that invoke Resolve, Premiere, or Final Cut still require the corresponding external integration.

The Python walkthrough can discover the file tools and inspect a recording through the private worker.

```sh
python3 docs/mcp_walkthrough.py --files-only --discovery
python3 docs/mcp_walkthrough.py --files-only --file interview.mov
```

## Create and revise a rough cut

`project create` and `project edit` take `--input request.json` or `--stdin`. MCP accepts the same object in the `request` field of `project_file_create` or `project_file_edit`. Use absolute paths in the MCP request. Each command validates the complete edit before publishing a new `.cut`. A changed timeline records the prior edit in history and retains other timeline metadata. Supply exact seconds as strings, including fractions. Relative paths supplied to the CLI resolve from the working directory. Paths already stored in a project resolve from that project's directory.

```sh
mpcut project create --stdin --json <<'JSON'
{
  "kind": "sequence",
  "out_project": "rough.cut",
  "operations": [
    {"action":"append","id":"answer","file":"interview.mov","from":"8","to":"14"},
    {"action":"append","id":"intro","file":"interview.mov","from":"1","to":"3"},
    {"action":"move","id":"intro","index":0}
  ]
}
JSON

mpcut project edit --stdin --json <<'JSON'
{
  "project_path":"rough.cut",
  "out_project":"revised.cut",
  "operations":[
    {"action":"split","id":"answer","at":"11","new_id":"answer-end"},
    {"action":"remove","id":"answer-end"}
  ]
}
JSON
```

| Target | Operations |
| --- | --- |
| Sequence | `append` takes a new `id`, `file`, and optional source `from` and `to`. `trim` takes `id`, `from`, `to`. `split` takes `id`, source `at` and a unique `new_id`. `move` takes `id` and final zero-based item `index`. `remove` takes `id`. |
| Multicam setup | Create with `kind: "multicam"`, `angles: [{"id":"wide","file":"wide.mov"},{"id":"close","file":"close.mov","offset":"1/2"}]`, and `group_end`. The first camera is the reference and opening picture. Audio initially follows the camera. The starting assembly plays the full group. Use `operations: []` to keep that setup. |
| Multicam camera settings | `camera_offset_set` takes `source_id` and signed `offset`. For a feed angle, set the offset on its physical recording. `camera_rename` takes `source_id` and `name`. An empty name resets a physical source's display name to its default. `camera_move` takes `angle_id` and its final zero-based `to_index`. `camera_microphone_set` takes a camera recording's `source_id` and absolute `audio_stream_index`. Omit the stream to clear the camera microphone selection. `group_end_set` takes group `to`. |
| Multicam switches | `switch_set` takes group `at` and `angle_id`, and updates the picture if a switch already exists there. `switch_remove` takes an existing group `at` after the opening switch. `switch_audio_set` takes an existing switch's group `at`, `source_id` and absolute `audio_stream_index`. `switch_audio_clear` takes group `at` to use the group audio policy at that switch. |
| Multicam assembly | `append` adds a group interval using `from` and `to`. `trim` changes the group bounds at `index`. `split` takes `index` and group `at`. `move` takes `index` and final `to_index`. `remove` takes `index`. Indices include still inserts and refer to the result of the preceding operation. |
| Transcript voice links | `voice_angle_set` takes `attachment_id`, `speaker_id` and `angle_id`. `voice_angle_clear` takes `attachment_id` and `speaker_id` to resume automatic matching. Find the IDs in transcript and multicam inspection results. |

To apply a reviewed batch of multicam switches, pass the `project_revision` returned by `tiles switches propose` or `tiles_file_switches_propose` at the top level of the edit request alongside `project_path`. The revision is checked against the original saved project before the operations run. A `switch_set` or `switch_remove` row can also carry `project_revision`. With a request revision, each row revision must match it. Without a request revision, a row revision checks the state at that point in the ordered edit. A stale revision returns `stale_tile_switch` before publication.

For a named source interval, use `source_select_save` with `id`, `name`, `file`, `from` and `to`. Use `source_select_remove` with the ID to delete it. To use one or several ranges, send `source_ranges_apply` with sequence `from` and `to` and a `ranges` list. Each item can supply `file`, `from` and `to` or a `select_id`. Equal sequence bounds insert at that point. Omit a select from the ordered list to leave it unused.

Read saved IDs with `project_file_inspect`. Sequences report `source_selects`. When the result carries the timeline document for a project with stills, read `timeline.source_selects`.

Use `timeline_file_range_map` to locate occurrences matching a saved source or output interval, and `history_file_compare` to see what changed between two saved projects. For a saved multicam project, use `multicam_file_sync_suggest` to review offset evidence and `multicam_file_switch_coverage_read` to inspect the picture and routed sound from a proposed switch to the next switch. [CLI equivalents](CLI.md)

## Resume a review saved in a project

| Task | File tools and result |
| --- | --- |
| Finish Check Tiles | Read `tiles_file_pending_read` for the source. Send its complete revised `choices` object and `review_token` to `tiles_file_pending_stage`. Read the staged project and pass its token to `tiles_file_accept` to approve those choices. Use `tiles_file_pending_discard` with the current token to abandon the review. [CLI example](CLI.md#review-pending-tiles) |
| Verify a privacy change | Call `history_file_compare` with the project and a retained `history_index` or a second project. Inspect `participant_changes` for the affected source, tile and source time. Use the clock mapping below to identify the affected program frame. |
| Recover media needed by Undo | Pass `include_history: true` to `project_file_media_list` and `project_file_media_locate`. Inspect the candidate matches before using `apply_matches: true` with a fresh `out_project` or explicit `in_place: true`. To recover a retained edit as a separate project, use `history_file_restore_copy` with its index and a new path. |
| Set delivery options | Read `project_file_output_read`, then use `project_file_output_set` to save the canvas, frame rate, background, audio routing or unresolved privacy policy. Run export preflight against the resulting project. [Output settings](CLI.md#set-project-export-options) |
| Reclaim analysis space | Call `analysis_file_cache_preview` for the folder and optional project or location. Review the paths and bytes. Pass the selected `clear_tokens` to `analysis_file_cache_clear` with the same scope and `confirm: true`. [Cache commands](CLI.md#save-analysis-and-refresh-sources) |

For a sequence, pass the affected source interval and file to `timeline_file_range_map`. For multicam, add the recording’s signed sync offset to the source times, then map that group interval to the assembly and check which camera supplies the picture. A range must have positive duration. For a change reported at a single point, use the interval of the frame containing it. Read the frame on the intended sequence or assembly occurrence with `review_file_frame_read`. [Project clocks](CUT-FORMAT.md#multicam)

## Review and shorten pauses

```sh
mpcut silence scan --project revised.cut --threshold-db -45 --json
mpcut silence shorten --project revised.cut --threshold-db -45 --out-project shortened.cut --json
```

A sequence scan returns each pause's clip ID, stream, detected threshold, source and sequence bounds, and proposed source removal. Two occurrences of the same recording have distinct pause IDs. Pass `--protect-pause ID` for each pause to keep and repeat the same scan settings. Transcript-authored pause protections also apply. `silence shorten` writes an editable project, `silence plan --output` preflights a media destination, and `silence export --output` renders it. The corresponding MCP tools accept a `project_path` and a `protect_pauses` array. `silence_file_shorten` takes a separate `out_project`. Multicam shortening follows the saved routed assembly. Multicam scan results also contain occurrence-specific pause IDs. To persist a reviewed pause in a project copy, use `silence pause protect` or `silence_file_pause_protect`. To measure a room-tone interval, use `silence room-tone calibrate` or `silence_file_room_tone_calibrate`. Supply the bounds on the selected clock.

Pass `retain_pauses` with rows containing a detected `pause_id` and total `retained_seconds` to override individual pauses. A project scan or plan without a media destination also accepts `take_boundaries` as exact times on the sequence or assembly clock. Inspect the returned `take_candidates` and retained durations.

## Review frames, stills, batches and transcripts

- For a multicam assembly picture at output time zero, call `review_file_frames_export` with `project_path`, `clock: "assembly"`, `at: ["0"]`, and a fresh `output` directory. `clock: "group"` samples the rendered group program when tile processing applies and compares synchronized angles in other multicam projects. Sequence program frames use `sequence`.
- Create a still timeline using `still_file_project_create`. For existing documents use `still_file_placements_list`, `still_file_placement_insert`, `still_file_picture_replace`, `still_file_placement_update`, `still_file_placement_remove`, or `still_file_asset_relink`. `timeline_file_gap_insert` and `timeline_file_clips_space` persist gaps. Mutations accept `out_project` for a copy or explicit `in_place: true` where supported.
- Set `subfolder` and `base_name` on `export_file_ranges_separate` or `scenes_file_export`. Use identical naming settings for plan and render. Dry-run results contain the planned destinations.
- For recognition, run `transcript job prepare`, then `transcript job run --job-id UUID` with the same job directory. The CLI invokes the installed provider and returns its durable record. Pass `--download` on the run command to allow a model download. Use `transcript job status` or `transcript job cancel` from another process. Use `transcript attachment import --job-id UUID` to attach a completed result. The MCP equivalents are `transcript_file_job_prepare`, `transcript_file_job_run`, and `transcript_file_attachment_import`. Poll each outer file job using its receipt's `job_id`. For recognition and attachment import, set `request.job_id` to the durable `id` in the preparation result and use the same `request.job_directory`. For import into a saved project, also supply `request.project_path` and a fresh `request.out_project`.

To reproduce the reconnect, privacy-mask, and approved-render checks, run `python3 Tests/Integration/parity_workflows.py /path/to/mpcut-mcp /path/to/mpcut` with a matching helper and CLI.

Run the desktop-independent integration fixture with `python3 Tests/Integration/headless.py /path/to/MPCut.app/Contents/Helpers/mpcut-mcp`. It creates temporary projects and uses a fixture recognition provider.
