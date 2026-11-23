# Edit saved projects without opening MPCut

Use the bundled CLI for a shell script. For an MCP client on the same Mac, register a separate stdio connection with the file worker flag.

```sh
codex mcp add mpcut-files -- "/Applications/MPCut.app/Contents/Helpers/mpcut-mcp" --files-only
```

The worker starts with the MCP connection, exposes saved-file tools in discovery, and uses the bundled CLI. It requires neither an editor window nor the desktop local-control setting. The ordinary helper invocation still connects to the running editor and uses its local-control setting. Configure the file worker only in clients you trust to read and write local files under your account.

MCP edits record **Agent** in project history. Shell edits default to **User**. Set `MPCUT_HISTORY_ORIGIN=agent` when invoking the CLI directly from an agent.

Each file operation takes an `operation_id` UUID. Poll `file_job_status_read` with the returned `job_id` until the state is `succeeded`, `failed`, or `cancelled`. Identical retries return the existing job within the same worker session while it is running and for ten minutes after completion. Reusing the ID with different arguments returns `operation_id_conflict`. Call `file_job_cancel` with the `job_id` to request cancellation, then poll for the terminal state. A disconnect ends the worker and cancels active CLI processes. Use fresh destinations and inspect any published outputs before retrying in a new session.

Read a small result directly from `result`. If status reports `result_bytes` without an inline result, call `file_job_result_read` with `job_id` and `offset: 0`. Base64-decode each page, use its `next_offset` for the next request, and concatenate the bytes through the page with `done: true` before parsing JSON. Offsets count bytes in the original output. On failure, read the available CLI error code and message or the job's `diagnostic` field.

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

The successful job returns a manifest of exported frames. Conversions that invoke Resolve, Premiere, or Final Cut still require the corresponding external integration.

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
| Multicam switches | `switch_set` takes group `at` and `angle_id`, and updates the picture if a switch already exists there. `switch_remove` takes an existing group `at` after the opening switch. |
| Multicam assembly | `append` adds a group interval using `from` and `to`. `trim` changes the group bounds at `index`. `split` takes `index` and group `at`. `move` takes `index` and final `to_index`. `remove` takes `index`. Indices include still inserts and refer to the result of the preceding operation. |

For a named source interval, use `source_select_save` with `id`, `name`, `file`, `from` and `to`. Use `source_select_remove` with the ID to delete it. To use one or several ranges, send `source_ranges_apply` with sequence `from` and `to` and a `ranges` list. Each item can supply `file`, `from` and `to` or a `select_id`. Equal sequence bounds insert at that point. Omit a select from the ordered list to leave it unused.

Read saved IDs with `project_file_inspect`. Sequences report `source_selects`. When the result carries the timeline document for a project with stills, read `timeline.source_selects`.

Use `timeline_file_range_map` to locate occurrences matching a saved source or output interval, and `history_file_compare` to see what changed between two saved projects. For a saved multicam project, use `multicam_file_sync_suggest` to review offset evidence and `multicam_file_switch_coverage_read` to inspect the picture and routed sound from a proposed switch to the next switch. [CLI equivalents](CLI.md)

## Review and shorten pauses

```sh
mpcut silence scan --project revised.cut --threshold-db -45 --json
mpcut silence shorten --project revised.cut --threshold-db -45 --out-project shortened.cut --json
```

A sequence scan returns each pause's clip ID, stream, detected threshold, source and sequence bounds, and proposed source removal. Two occurrences of the same recording have distinct pause IDs. Pass `--protect-pause ID` for each pause to keep and repeat the same scan settings. Transcript-authored pause protections also apply. `silence shorten` writes an editable project, `silence plan --output` preflights a media destination, and `silence export --output` renders it. The corresponding MCP tools accept a `project_path` and a `protect_pauses` array. `silence_file_shorten` takes a separate `out_project`. Multicam shortening follows the saved routed assembly. Explicit occurrence protection currently addresses sequence scans.

Pass `retain_pauses` with rows containing a detected `pause_id` and total `retained_seconds` to override individual pauses. A project scan or plan without a media destination also accepts `take_boundaries` as exact times on the sequence or assembly clock. Inspect the returned `take_candidates` and retained durations.

## Review frames, stills, batches and transcripts

- For a multicam assembly picture at output time zero, call `review_file_frames_export` with `project_path`, `clock: "assembly"`, `at: ["0"]`, and a fresh `output` directory. Use `clock: "group"` for synchronized angle comparisons. Ordinary sequence program frames use `sequence`.
- Create a still timeline using `still_file_project_create`. For existing documents use `still_file_placements_list`, `still_file_placement_insert`, `still_file_picture_replace`, `still_file_placement_update`, `still_file_placement_remove`, or `still_file_asset_relink`. `timeline_file_gap_insert` and `timeline_file_clips_space` persist gaps. Mutations accept `out_project` for a copy or explicit `in_place: true` where supported.
- Set `subfolder` and `base_name` on `export_file_ranges_separate` or `scenes_file_export`. Use identical naming settings for plan and render. Dry-run results contain the planned destinations.
- For recognition, run `transcript job prepare`, then `transcript job run --job-id UUID` with the same job directory. The CLI invokes the installed provider and returns its durable record. Pass `--download` on the run command to allow a model download. Use `transcript job status` or `transcript job cancel` from another process. Use `transcript attachment import --job-id UUID` to attach a completed result. The MCP equivalents are `transcript_file_job_prepare`, `transcript_file_job_run`, and `transcript_file_attachment_import`. Poll each outer file job using its receipt's `job_id`. For recognition and attachment import, set `request.job_id` to the durable `id` in the preparation result and use the same `request.job_directory`. For import into a saved project, also supply `request.project_path` and a fresh `request.out_project`.

Run the desktop-independent integration fixture with `python3 Tests/Integration/headless.py /path/to/MPCut.app/Contents/Helpers/mpcut-mcp`. It creates temporary projects and uses a fixture recognition provider.
