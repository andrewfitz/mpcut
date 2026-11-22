# Saved projects, media files and the bundled CLI

The desktop connection runs the bundled CLI through typed MCP file jobs. Use this route for a named recording, a saved project or an explicit file-based edit. Paths refer to files on the Mac running MPCut. Supply absolute paths and set `working_directory` when an input document contains relative references. For “my current edit,” use the [live window](live-editor.md), including any unsaved changes.

| Request or CLI topic | Desktop route |
| --- | --- |
| Help, version, multicam template | `file_version` identifies the CLI. `file_help` without a topic returns its command inventory. Supply an advertised topic for a smaller result. The CLI's `multicam` topic provides help and a template. Camera editing uses the live tools. |
| Inspect picture, sound or timing | `file_inspect` reads stream metadata, a saved timeline or a bounded window of frames, keyframes or audio packets. Use `file_waveform` with an absolute audio stream index and column count for a signed envelope. |
| Analyze shots, silence or cached data | `file_scenes` detects shots or exports grouped scenes/views. `file_silence` analyzes audio or a saved project, can reuse a report and can write a shortened result. `file_sidecar` inspects or builds analysis sections. On supporting builds, `file_refresh` checks media referenced by a saved project. |
| Extract pictures | `file_frames` writes review or full-size JPEGs and a manifest to a new directory. Choose explicit times or representative scene/take samples. For camera comparisons read angle availability and group time from the manifest. |
| Produce one movie | `file_export` renders a saved project or a structured edit. A project takes a separate output path. A structured edit carries its own output and ordered clips. Inspect the advertised track, soundtrack replacement, mode and container options. |
| Repeat ranges or produce many files | `file_rearrange` joins ordered, possibly repeated ranges from one source. `file_bulk` writes separate numbered outputs. Use `dry_run` to preview eligible settings, ordering and destinations. Inspect partial successes before retrying a batch. |
| Exchange editable projects | `file_convert` converts a saved project for MPCut, Resolve, Premiere or Final Cut. Check supported direction, warnings, host prerequisites and any requested flattening. `file_resolve` writes an editable timeline with optional import into the open Resolve project. |

Read the start receipt's `job_id` and poll `file_job_status` until succeeded, failed or cancelled. For cancellation use `file_job_cancel` and continue polling. Read the inline result or output text when present. For a paged result, start `file_job_result` at offset zero, decode each base64 page, advance to its `next_offset` until `done`, then concatenate the decoded bytes before parsing JSON. Keep the original receipt and UUID for an identical retry.

## When a CLI option has no typed field

Compare the installed tool's input schema with the matching CLI's help. CLI flags do not automatically become MCP arguments. For example, the source CLI supports an explicit project clock for `frames`, and the typed file tool currently omits that field. For an open project use the live review-frame export with its advertised clock. For saved-project still authoring, source builds offer `still create`, `add`, `list`, `update`, `relink` and `remove` under the `still` command. The current file MCP catalog has no saved-project still command.

When the request concerns a file and the desktop host already has authorized local execution on the same Mac, a CLI-only operation can use the matching app's `Contents/Helpers/mpcut`. Check `help <command> --json` there first, pass arguments separately, and read the result and exit status. For a saved still edit use a new `--out-project` for a requested copy and `--in-place` only for an explicit change to the saved original. Keep live edits on their window handle. In an MCP-only conversation, explain the specific missing operation and offer a live equivalent when it preserves the requested outcome.
