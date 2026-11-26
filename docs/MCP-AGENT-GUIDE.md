# Using MPCut from an MCP agent

For unattended work on saved media, launch the stdio helper with `--files-only`. See [headless setup and examples](HEADLESS.md).

An agent connected to MPCut can edit any open timeline, including an unsaved sequence or multicam assembly. Its edits use the same snapping and undo history as yours. File tools use the bundled CLI. Supply a saved file in `project_path` to inspect its last saved revision. Use the window’s `project_handle` for an unsaved edit. [Tool reference](MCP-REFERENCE.md) · [CLI scripting](CLI.md#script-mpcut)

## Connect an editing agent

1. Open a build of MPCut that includes `Contents/Helpers/mpcut-mcp`. In **Settings → Automation**, turn on **Enable local MCP control**. Local MCP control starts off in 2.0, including after upgrading from 1.x. Turning it on lets local applications running under your macOS account inspect and edit open projects.
2. Configure the host to launch the bundled helper as a **stdio** server named `mpcut`. Supply the executable’s absolute path as one command value, including any spaces, and leave the arguments empty. Match the helper to the running app bundle. If you move or replace the app, update the host’s path and restart its connection.
3. Open a project and ask, “List my open MPCut projects and tell me which one is an unsaved sequence.” An empty `projects` array means the app responded and has no project windows.

For desktop plugin or Grok connector setup, follow the host-specific instructions. [Desktop setup](DESKTOP-PLUGINS.md)

For Codex CLI, register the installed app with this command, then start a new session. Substitute the actual path if your app is elsewhere.

```sh
codex mcp add mpcut -- "/Applications/MPCut.app/Contents/Helpers/mpcut-mcp"
```

For hosts that accept an `mcpServers` JSON configuration, use the same path as a single string. **Settings → Automation** shows the helper’s path with **Copy**, and **Copy Agent Configuration** copies this block with the path of the running app’s helper.

```json
{
  "mcpServers": {
    "mpcut": {
      "command": "/Applications/MPCut.app/Contents/Helpers/mpcut-mcp",
      "args": []
    }
  }
}
```

The helper uses the official Go SDK and supports the `2026-07-28` protocol. Tool discovery and documentation work while the app is closed. Both live and file tool calls require the running app and its local-control setting. Turn off local control in Settings to revoke existing access. An already committed edit remains in the project and follows the configured history limit.

The local-control setting does not gate a helper started with `--files-only`. That worker runs the saved-file tools through the bundled CLI, works while the app is closed and never reads desktop Settings, so only configure it in clients you trust with your files. Under `--files-only`, `analysis_file_cache_settings_set` can still change the cutcache location that the app and the CLI share. [Headless setup](HEADLESS.md)

Codex CLI 0.171.0 negotiated `2025-06-18` with a signed MPCut 1.2.0 development bundle in a November 2026 host test. It discovered the tools and read both resources. The Python walkthrough and the official Go SDK integration exercise `2026-07-28`. The version used in a session depends on the host. [Verified workflows](MCP-COVERAGE.md)

Helper tests also exercise `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05` over stdio with the Go SDK.

Open **Help → MPCut Agent Guide** to read these instructions offline. Hosts with MCP resource support can read `mpcut://docs/agent-guide` and `mpcut://docs/tool-reference` through `resources/read`. The installed helper advertises argument schemas through `tools/list`.

### Advertise fewer tools

The catalog has 325 tools and about 490 KB of schema. A host that loads tools on demand pays for the ones it uses. A host that puts every schema in the model’s context pays for all of them on each request, which is over 100,000 tokens. For such a host, pass helper arguments to advertise part of the catalog:

- `--live-only` leaves out the saved-file tools, about 45% of the catalog. Use it when the agent only edits open projects.
- `--toolsets GROUP,GROUP` advertises the named groups. Project discovery is always included with live tools, and the `file_job_*` receipts with file tools. An unknown name stops the helper with the list of valid ones.
- Both combine with each other, and `--toolsets` combines with `--files-only`.

| Group | Covers | Live | File |
| --- | --- | ---: | ---: |
| `projects`, `lifecycle` | Windows, open, save, close, drafts, preferences | 30 KB | |
| `sequence`, `source_ranges`, `timeline_review` | Sequence edits, history, selects, range mapping | 19 KB | |
| `review`, `file_frame`, `file_review` | Inline frames; saved-file frames and frame export | 4 KB | 10 KB |
| `transcript` | Reading, searching, editing and recognition | 84 KB | 39 KB |
| `multicam`, `sync` | Cameras, switches, assembly, sync | 20 KB | |
| `outputs`, `output_settings` | Exports, the queue and their job status | 31 KB | 2 KB |
| `analysis`, `cache` | Scenes, silence, waveforms, sidecars | 14 KB | 3 KB |
| `stills`, `media`, `file_media` | Still placements; project media and relinking | 21 KB | 10 KB |
| `presentation` | Window layout and monitors | 5 KB | |
| `tiles`, `participants` | Tiles, feeds and ISO delivery | 47 KB | 68 KB |
| `file` | Saved-file editing, inspection and jobs | | 80 KB |

For transcript-led editing of an open sequence, `--live-only --toolsets lifecycle,sequence,timeline_review,review,transcript,outputs` advertises about 160 KB. A group’s job tools travel with it: live exports and transcript exports are polled with `export_editor_job_status_read` in `outputs`, and scans with `analysis_job_status_read` in `analysis`.

```json
{
  "mcpServers": {
    "mpcut": {
      "command": "/Applications/MPCut.app/Contents/Helpers/mpcut-mcp",
      "args": ["--live-only", "--toolsets", "lifecycle,sequence,timeline_review,review,transcript,outputs"]
    }
  }
}
```

### Settings and agent permissions

`preferences_read` returns every shared setting. `preferences_set` changes one, except `automation_local_mcp_enabled`, `automation_preferences_write_enabled`, `automation_file_replace_enabled`, `draft_retention_days` and `analysis_shared_cache_max_bytes`, which agents can read but not set. To show the editor a setting, call `workspace_panel_show` with `action: "show_settings"` and an optional `page`: `general`, `editing`, `playback`, `media`, `transcripts`, `export`, `storage` or `automation`. Without a page, Settings reopens on the last page shown. Other actions ignore `page`. The two stills timeline pixel keys take even numbers only.

**Settings → Automation** has two agent permissions. Both start on, and only the editor can change them.

- **Let agents change settings.** With it off, every agent write of a setting fails with `settings_write_disabled`. This covers `preferences_set`, the `workspace_layout_set` actions `set_large_thumbnails`, `set_full_height_panel` and `set_track_label_width`, the `snap` action of `timeline_selection_set` and `multicam_preview_control`, and `analysis_file_cache_settings_set` sent through the app. Reads still work, and `set_transcript_suggested_camera` stays allowed.
- **Let agents replace existing project files.** With it off, `project_save`, or `project_close` with `changes: "save"`, fails with `file_replace_disabled` when `replace_existing` would write over another existing file. Every file tool sent through the app with `in_place: true` fails with the same code, including the transcript file tools that carry `in_place` inside `request`: `transcript_file_attachment_import`, `transcript_file_attachment_bind`, `transcript_file_attachment_detach`, `transcript_file_words_correct`, `transcript_file_edit_apply` and `transcript_file_excerpt_queue`. Saving to the project’s own path still works.

When a live editor call omits an option, some tools take the editor’s Settings value. `export_editor_project_plan` and `export_editor_project_render` use the default movie export mode, the re-encode codec and quality, and in multicam the multicam audio layout. The Settings codec applies to an ordinary or multicam Re-encode, a Tiles render and a still project without its own format, but only where the destination extension can hold it; otherwise the export uses H.264 with its quality. `export_queue_plan` and `export_queue_render` use the same codec and quality for ordinary ranges and Tiles ranges, and the H.264 and HEVC container unless it is Automatic or cannot carry the requested audio. A Settings downmix applies only when the output keeps sound, `audio` is omitted, `auto`, `pcm` or `aac`, and the destination renders that sound; otherwise the output has separate tracks. `transcript_editor_job_start` without an engine uses the preferred engine, resolved as job setup resolves Automatic. Every other omitted argument keeps its documented fallback. File jobs and the CLI never read desktop Settings and use factory values. Each schema says which applies. [Settings defaults](USAGE.md#set-editing-and-export-defaults)

### Try a read-only walkthrough

The Python walkthrough uses the July stdio protocol and Python 3’s standard library. Run it from the source checkout as shown below, or run the copy under the installed app’s `Contents/Resources/Documentation/docs/`. Use `--helper` when running a bundle outside Applications. [Python walkthrough](mcp_walkthrough.py)

```sh
python3 docs/mcp_walkthrough.py --discovery
python3 docs/mcp_walkthrough.py
python3 docs/mcp_walkthrough.py --project "HANDLE_FROM_THE_LIST"
python3 docs/mcp_walkthrough.py --file "/absolute/path/to/interview.mov"
```

Discovery reads both built-in guides. With local control enabled, the second command lists windows. Once the chosen project has loaded, the third reads its timeline, history, presentation, analysis, queue and, for multicam, sources. The last command inspects file metadata with sidecar use disabled and reads the completed job result. Increase `--timeout` when a walkthrough needs more than 60 seconds. Use `--timings NEW_FILE.json` to record client-observed RPC durations, request and response sizes, and polling waits. Use `--poll-interval SECONDS` to compare polling cadences. RPC durations include transport and server work.

## Instructions for the agent

Paste this block into the host’s agent instructions to share MPCut’s editing conventions.

> Discover MPCut’s current tools and argument schemas. For an open or unsaved edit, list projects, resolve the user’s target, then read its live state. If multiple projects or occurrences still match, ask one focused question before editing. Use the returned handle, revision and occurrence references. A focus change does not change the intended target.
>
> State which timeline clock you are using. Supply exact rational times where available. Use the native editing tool and report the actual committed boundary, affected occurrence and history action. Save, export, change settings or send to another application when the user’s request calls for it.
>
> For a new mutation or a file job, generate one UUID for `operation_id`. If the response is lost, retry the identical request with the same ID within the documented retry window. On a revision conflict, reread state and re-evaluate the requested edit. For background work, follow the job to its terminal result and report completed outputs and any failures.

## Read the clock before editing

| Clock | A typical instruction | Resolve before calling |
| --- | --- | --- |
| Source | “Use the cut at 12 seconds in the interview recording.” | Source ID and source timestamp. If applying it to a sequence, identify the retained occurrence that contains it. |
| Sequence | “Split 12 seconds into my current edit.” | Sequence output time and the clip occurrence spanning it in the current revision. |
| Multicam group | “Switch to the wide camera at the clap.” | Group time, angle ID, and the switch interval. Repeated uses of that interval share the camera switch. |
| Multicam assembly | “Trim the second replay.” | Assembly output time and occurrence reference from the same revision. |

For live requests, send time as a rational seconds string, such as `"1001/30000"` for one frame at 29.97 fps. Read the indexed timing when media has a variable frame rate. Ranges include their start and exclude their end. A clip name or source timestamp alone can match several occurrences.

To seek to a specific multicam replay from a group timestamp, send its assembly `occurrence` index and the corresponding `expected_revision` with `space: "group"`. The preview opens on the assembly clock at that occurrence.

Use `timeline_editor_range_map` to translate an interval between clocks. Read each returned piece in occurrence order, including repeats. To map an earlier edit or compare it with the current edit using `history_editor_compare`, first call `history_read` for its retained index and matching history token.

## Check what the edit can export

Read the optional `tier` in `project_editor_state_read` for a sequence or multicam project. When the assessment is current and includes a mode, use its container and factors to explain what the complete edit can preserve. An empty sequence has no tier. For delivery, preflight the requested tracks, container and range separately, especially if the user wants a single excerpt. [Export quality in the editor](USAGE.md#check-export-quality)

After an unsafe multicam cut, inspect `multicam_state_read` with `section: "suggestions"`. The returned `edge` gives the one-based `range_number`, its `from` or `to` boundary, the current `group_time`, and the offered `times`. To accept one, call `multicam_assembly_edit` with `action: "apply_edge_suggestion"` and put the chosen time in `to`. Use the normal revision and operation ID for the mutation. Switch suggestions apply to a camera switch on the group clock. [Multicam tool arguments](MCP-REFERENCE.md#multicam_assembly_edit)

## Find dialogue and review an edit

1. Use `project_windows_list`, then `transcript_editor_attachments_list`. Keep the project handle, timeline `revision`, `transcript_revision`, and the chosen attachment’s `id` and `result_id`.
2. Search with `transcript_editor_words_search`, a `query`, and `space: "current_cut"`. Read `source` for deleted takes and `group` for synchronized multicam dialogue. Follow `next_offset` in the same revision until the page omits it. Each match is one compact row with the matched text, its `from` and `to`, the surrounding words, and the `first_word_id`, `first_occurrence_id`, `last_word_id` and `last_occurrence_id` to copy into a selection. When the line appears more than once, choose the row you mean.
3. Call `transcript_editor_edit_plan` with an `edit` containing the action, selections, and boundary policy. Check the requested and resolved boundaries, copy-safe alternatives, affected occurrences, duration, and any tier assessment.
4. Use `transcript_editor_edit_apply`, the reviewed `plan_id`, and a new operation ID. Pass the same expected timeline and transcript revisions and result identity. If the tool returns `stale_transcript_plan`, refresh and review again. A committed edit appears in native history.

To read dialogue, call `transcript_editor_words_read` with `lines: true` and a `limit` up to 500 words. Each row is one utterance: its text, speaker, `from`, `to` and the four selection identifiers. It costs a small fraction of a word-by-word page. Without `lines`, a row is one compact word. Transcript reads return full word records, with bindings, lanes, routing and evidence, only when you pass `verbose: true`. A full record is about 2 KB per word, so ask for it when you need those fields.

To see what was on screen at a line, pass the row’s time to `review_editor_frame_read` on the same clock. A source-clock row gives a `file` or `source_id`, under `shared` when the whole page has one recording. Send it with `space: "source"` to read material the edit has removed.

For a named excerpt, plan with `edit.action: "queue"`, then use `transcript_editor_excerpt_queue`, the plan ID, and a name. Read its ID and name with `export_queue_list`. Use `transcript_editor_excerpt_save` to write the captured queue entry as an editable `.cut`. For a transcript file, use `transcript_editor_attachment_export`, an absolute path, and a format. Poll both outputs with `export_editor_job_status_read`.

Read, search, locate, compare and export use all attached transcripts when you omit `attachment_id` and `result_id`. Project-wide pages return `attachment_results`, which you can send as `expected_attachment_results` on later pages. An occurrence identifies its attachment even when another recording has the same word ID. Supply that attachment for track evidence or edits.

Call `transcript_editor_script_align` for one summary per nonempty script beat. Page takes with `transcript_editor_script_candidates_list` or missing and additional terms with `transcript_editor_script_qualifiers_list`. Supply the same script and the returned zero-based `beat`. A qualifier index selects the term whose occurrences you want to page.

Use `transcript_editor_track_activity_read` to page through the optional audio levels supplied by the provider for a track. The stored transcript retains each frame’s source-clock bounds and level. The selection waveform in the editor comes from the linked recording. [Transcript guide](TRANSCRIPTS.md)

Use `transcript_editor_coverage_read` for timed gaps in the requested clock. Source and group clocks also return track recognition and binding statuses. Page that list separately with `track_offset` and `track_limit`.

The bundled Python walkthrough can find and export an excerpt from a saved project with an attached transcript. Supply an existing empty output folder. If a phrase appears more than once, rerun with the intended `--match` from the search results. [Runnable walkthrough](mcp_walkthrough.py)

```sh
python3 docs/mcp_walkthrough.py --transcript-project "/absolute/path/interview.cut" \
  --quote "the line to find" --output-dir "/absolute/path/excerpts"
```

For a project with no attachments, add `--import-transcript "/absolute/path/interview.json" --bind-source lav --bind-stream 0`. In a sequence, use `--bind-file` with the recording path. Set `--bind-track` if the imported track ID differs from `source`.

Use `transcript_provider_capabilities_read` and `transcript_tracks_list` to check the local Transcriberrr provider and choose inputs. For requested recognition, call `transcript_editor_job_start` with the current timeline and transcript revisions and a fresh operation ID. The request’s `download` flag permits a model download. Keep the returned `job_id`, poll `transcript_editor_job_status_read`, and page the per-track coverage. Use `transcript_editor_job_warnings_list` for diagnostics and check `attached` before reading the result from the project. A transcript job can continue after local control is turned off. After reopening the project, obtain its current handle and use `transcript_editor_jobs_list` to recover job IDs.

After changing a multicam source offset, use `transcript_editor_job_reconcile`, the current project handle, attachment ID, result ID, timeline and transcript revisions, and a fresh `operation_id`. The controller keeps valid recognition and recomputes alignment at the new offsets. Poll `transcript_editor_job_status_read` with the returned `job_id` until it reports `completed` or `partial` with `attached: true`. Read the updated attachment before planning edits.

For a saved project, pass the corresponding CLI JSON request to the matching `transcript_file_*` tool under `request` with a UUID `operation_id`. Poll `file_job_status_read` and use `file_job_result_read` when the output is too large to return inline. [Transcript tools](MCP-REFERENCE.md#transcripts) · [CLI transcript commands](USAGE.md)

## Worked example: split an unsaved sequence

**Editor request:** “In Interview selects, split the second use of the interview clip at 12 seconds on the sequence. Leave it open for review.”

| Step | Agent action | Evidence |
| --- | --- | --- |
| 1 | Discover the tools, then call `project_windows_list`. Choose the sequence named Interview selects. | The project handle identifies its live window even if another window gains focus. |
| 2 | Call `project_editor_state_read` for that handle. Find the second occurrence and confirm that 12 seconds is strictly between its `sequence_from` and `sequence_to`. Read the revision, snapping and history settings. | If 12 seconds is already an edge of the intended clip, report the existing boundary. If 12 seconds falls in a different occurrence, clarify which target the editor intended. |
| 3 | Call `timeline_item_split` with the handle, revision, a fresh operation ID, the occurrence, sequence coordinates and time `12`. | The committed result identifies the actual cut, both resulting occurrences and the applied revision. A background preflight may take time. |
| 4 | Read back the dirty flag, then report it and the actual boundary. When history is retained, name the action the editor can undo. | “Split the second interview clip at 12 s on the sequence. The edit is unsaved. Focus Interview selects and use Command-Z to undo Split Clip.” |

For an ordinary sequence, construct the arguments from the actual state response. This JavaScript fragment assumes the client has located the relevant `clip` in `state.clips`.

```javascript
const splitArgs = {
  project_handle: state.project_handle,
  expected_revision: state.revision,
  operation_id: crypto.randomUUID(),
  occurrence: clip.id,
  space: "sequence",
  time: "12"
};
// Pass { name: "timeline_item_split", arguments: splitArgs } to tools/call.
// Retain these arguments until the outcome is known.
```

Inspect the MCP result’s `isError` and `structuredContent`. An ordinary successful split reports `action`, `boundary`, `sequence_time`, `source_time`, `left`, `right`, `history_retained` and the applied `revision`. A split exactly at an existing edge returns `invalid_boundary` for an ordinary sequence. If you already see the boundary in state, report it directly. Supply the current revision with the next edit. [Tool reference](MCP-REFERENCE.md)

## Edit still images

Read `project_editor_state_read` and page `still_editor_placements_list` at that revision. Source rows carry source bounds. Inserted still rows carry a placement ID, an asset ID and output bounds. Multicam assembly indices include both cards and group ranges. Refresh indices after each structural edit.

- Call `still_editor_picture_replace` with an absolute image `path`, and `from` and `to` in sequence or multicam group time. A replacement keeps the underlying sound. Group replacements appear in each assembly occurrence of the covered group interval.
- For a title or other insert, call `still_editor_placement_insert` with the image path, `at` and `duration` in sequence or assembly time. The duration shifts later picture and sound. Supply an exact `cadence` frame interval when the current timeline has no verified fixed cadence.
- Use `still_editor_placement_update` to adjust framing, change an insert's duration or position, or edit replacement coverage. Refer to fragments by the current index under their placement. `still_editor_asset_relink` follows a moved image across all uses and retained history. `still_editor_placement_remove` reveals the camera under a replacement or removes an insert and closes its gap.
- Call `review_editor_frame_read` at a program time to see Output. Supply `view: "source"` to inspect untreated pixels, with an explicit `angle_id` for another multicam camera. Pass `times` with up to 12 times to review a cut point or sample a stretch in one call. Each image follows a `frame N` label. With `space: "source"` and a `source_id` or `file`, times are on the recording’s own clock, so you can look at material before a trim or inside a deleted range, which has no sequence time. Images are 640 pixels on the long edge, whatever the footage, which is enough to identify a shot. When a result carries `native_width` and `native_height`, the picture was reduced. Text is reliable only when it is about 8 pixels or taller in the returned picture. Smaller text can be misread without looking wrong, so do not quote it. To read it, ask again: pass `region` with `x`, `y`, `width` and `height` as fractions from the top left to get that part of the frame at its own pixels, or set `max_edge` up to 3840 for more detail in the whole frame. A region costs far fewer tokens, because cost grows with the picture’s area. Lower `max_edge` to 320 for a cheap contact sheet.

| Returned picture of a 4K frame | Smallest text read reliably (font size in the 4K frame) | Typical size |
| --- | --- | --- |
| Whole frame, 640 (default) | 52 px: titles and slide headings | 11 KB |
| Whole frame, 960 | 26 px: body text on a high-density screen share | 20 KB |
| Whole frame, 1280 | 20 px | 33 KB |
| Whole frame, 1920 | 16 px | 62 KB |
| Whole frame, 2576 | 16 px, and 12 px in part | 102 KB |
| Whole frame, 3840 | 16 px, and 12 px in part | 201 KB |
| Quarter-frame `region`, 1280 | 12 px | 19 KB |
| Quarter-frame `region`, 1920 | 12 px, every line | 42 KB |

These come from a November 2026 test in which Claude Haiku and Claude Opus transcribed random codes from generated 4K frames. The two read almost the same lines. JPEG quality from 0.30 to 0.85 changed little, so a picture that would pass 1 MiB is encoded at a lower quality. Sizes are for flat graphics. A grainy 4K frame is about 240 KB at 1920 and 1.9 MB at 3840 before that step. For a full-size file on disk, use `review_editor_frames_export` with `preset: "full"`. For JPEG files use `review_editor_frames_export` with a program `space` and `selection: "times"` or sample the active playhead.
- Preflight with `export_editor_project_plan`. An omitted mode chooses Smart Trim for visible still picture. Set `require_camera_copy: true` when the export must preserve all retained camera packets. Read the exact camera copy, camera encode and generated still durations, plus the per-track sound actions. To accept a verified whole-timeline boundary change, pass its `still_adjustment` to `export_editor_boundary_apply` with the same render settings.

To pair an image with a recording, call `still_editor_soundtrack_attach` with the audio path and optional `fit_soundtrack: true`, `still_editor_soundtrack_fit` to fit the single image later, or `still_editor_soundtrack_detach` to remove it. Saved projects use the `still_file_soundtrack_*` tools. Export tools accept `still_timing: "held"` to store one sample per visible hold and `container` to override the saved default. [Still images](STILL-IMAGES.md)

For gaps between picture items, use `timeline_clips_space` with a uniform rational `duration` or `source_timing: true`. A duration of zero removes gaps between picture items. Source timing requires chronological, nonoverlapping ranges of the same recording or multicam group. Read the resulting gaps with `still_editor_placements_list`. Spacing is one native history action. For rendering, `export_file_project_render` or `export_file_clips_join` accepts `space_clips` for the render. Use the CLI’s `timeline clips space` command to write the spacing into a saved project.

## Editing and delivery recipes

| Editor request | Agent workflow | What to report |
| --- | --- | --- |
| “Recover yesterday’s untitled selects, apply this CSV and save a copy.” | Identify the draft, recover it, inspect the selected occurrence and CSV mode, apply ordered keep ranges or split points, review the timeline, then Save As to the requested destination. | Recovered project, resulting clips, retained history and saved path. |
| “Put the wide angle on the first question, then shorten only its second replay.” | Read group switches, program audio and assembly occurrences. Apply the camera switch in group time. Refresh the revision, identify the second replay, and trim that assembly occurrence. | Affected group interval, audio routing and the specific occurrence trimmed. |
| “Review the quiet gaps, keep the breath before the answer, and queue the takes.” | Select the microphone or routed program, scan with the requested threshold and padding, audition the relevant join, protect the pause, then queue retained takes. | Protected interval, queued ranges and analysis settings. If the user asks to shorten the timeline, verify the native history entry. |
| “Find every wide shot and give me review images.” | Scan scenes, identify the recurring view by its samples, and use `review_file_frames_export` with the matching exact source times in `at` from the report. For a live check, `review_editor_frame_read` accepts an exact sequence, group or assembly time. | View, sample rule, exact source times and output paths. |
| “Check whether this selection will copy cleanly.” | Read the live selection and track layout. Run export preflight with the requested container, mode and streams. Inspect proposed boundary changes or encoding options. | Copy eligibility, reason, proposed boundaries and whether any media was written. |
| “Export these ranges as separate files with the processed soundtrack.” | Inspect source and replacement streams and timing. Establish which queue/export workflows support replacement. If they require separate steps, verify the replacement output before using it as the source for a file-based batch. Preflight destinations, then follow the jobs. | Source binding, stream IDs, completed files and any failed range. |
| “Send this unsaved multicam assembly to Resolve as an editable timeline.” | Read the live assembly, choose the requested interchange route and handle reported prerequisites or loss options. Send the captured revision and follow conversion through the requested external open/import step. | Revision, interchange file, warnings and external import outcome. |
| “Get packet timing and a waveform from this recording.” | Use file inspection on the supplied path, choose the stream, bound the time window and waveform columns, and inspect the sidecar inventory if reuse matters. | Stream, exact window, returned timing and analysis provenance where available. |
| “Restore the state just before the last trim.” | List retained history for the named window, resolve the trim and preceding state, restore using that history snapshot, then read back the current state. | Restored state, current position and redo availability. |

## Edit camera feeds and recorded calls

Use `tiles_file_export_isos` with the absolute recording or saved project path, an output directory and a UUID `operation_id`. Poll `file_job_status_read`. If the job ends in `needs_review`, read its timestamped `issues` and `review_project_path`. Open the review project, or call `tiles_file_inspect` with that path and `issues: true`. For a count mismatch, use `tiles_file_accept` on the review project with revised `expected_feeds` or `max_visible_tiles`, or with `clear_count_hints: true` to clear both. For an open project, use `tiles_editor_accept`. These count edits need no scan. After making corrections, run the export against the saved review project to preserve feed IDs. Verify the delivery with `tiles_file_angles_verify`.

Use `workspace_panel_show` with `action: "show_tiles"` and read `workspace_layout_read` for `tiles_visible`. For an unsaved editor revision, use the corresponding `tiles_editor_*` tool with `project_handle`. Mutations take `expected_revision` and each changed result is one undoable edit. Poll live Tiles scans and deliveries with `analysis_job_status_read` and the same project handle. File mutations require either `out_project` or `in_place: true`. [Tiles and ISO delivery tools](MCP-REFERENCE.md#tiles-and-iso-delivery)

The `participants_file_*` tools mirror the CLI’s participant commands. Start `participants_file_scan` with a fresh UUID `operation_id`, an absolute `file` and an `output` path, and poll `file_job_status_read`. Scans default to adaptive sampling. Pass `sampling: "every-frame"` before a redaction, and `feed_layout` (`auto` or a grid such as `2x2`) for a camera multiview. Accept the scan into a saved project with `participants_file_project_accept`, then use `participants_file_render_plan` and `participants_file_render_export` for a composed movie. For a dialogue edit, read `participants_file_angles_list`, take an angle at an output time with `participants_file_angles_take`, and write aligned angle media with `participants_file_angles_plan` and `participants_file_angles_render`. Each edit needs `out_project` or `in_place: true`. Use `tiles_file_reconcile` to preview a changed or copied recording, then apply the reviewed reconciliation token. [Feed and participant guide](PARTICIPANTS.md)

## Tool sequences for common requests

Create a feed for manual box editing with `tiles_editor_feeds_add` or `tiles_file_feeds_add`. Pass the returned `feed_id` to the corresponding `box_add` or `link` tool.

Review issues that decide one tile's feed share a `group_id` and report `group_count`. An issue's `feed_id` is the scan's own feed for the tile, and `candidate_feed_ids` lists the earlier feeds it may be. To keep the tile on its own feed, call `tiles_editor_link` or `tiles_file_link` with that `tile_id` and `feed_id` and no `from` or `to`. For the same person as an earlier feed, first call the corresponding `feeds_merge` tool with the own feed and `into_feed_id` set to the earlier one, then link the whole tile to the earlier feed. Either settles every issue in the group.

Use these sequences with the tool names and argument schemas advertised by the installed helper. Open a saved edit by passing its absolute `project_path` to `project_open`. Pass the returned `project_handle` on subsequent calls to that window. Resolve occurrence IDs, group angle IDs and revisions from live state.

| Workflow | Calls and inputs |
| --- | --- |
| Start a sequence and review a clip | Call `project_create` with a fresh `operation_id` and absolute media `paths`, then read `project_editor_state_read`. Use `timeline_playhead_seek` with `space: "sequence"` and a rational `time`. Start playback with `playback_transport_play` and stop with `playback_transport_pause`. |
| Create a still-only timeline | In a blank project window, pass `initial_format` on the first `still_editor_placement_insert` or `timeline_gap_insert`. For a 30 fps timeline use `cadence: "1/30"` in the format. Subsequent placements use the established format. |
| Review history and resume editing | Open `history_panel_show`, inspect `history_read` or compare a retained state with `history_editor_compare`. Call `history_panel_close` before `project_save`. |
| Change the viewer or transcript reader | Read `workspace_layout_read`. Use `workspace_layout_set` with `set_monitor_picture` for Source or Output, `set_cut_sections` for cut visibility, or `set_full_height_panel` for docking. Use `set_transcript_follow_playback` or `set_transcript_suggested_camera` for reader preferences. To save a voice-to-camera assignment in the project, use `multicam_voice_angle_edit`. |
| Reopen a recent document | Read `recent_files_list` to identify the path. `recent_files_clear` clears the editor’s Open Recent menu. |
| Recover, apply CSV and save | List drafts with `project_drafts_list`. Pass the returned `draft_path` to `project_draft_recover`, then find the target occurrence in `project_editor_state_read`. Call `sequence_clip_edit` with `action: "apply_csv"`, the occurrence ID and absolute CSV path. Call `project_save` with the `project_handle`, new revision and destination `project_path`. |
| Save or assemble source ranges | Read `source_selects_list`, then use `source_select_save` to retain a named source range. Supply absolute source ranges or saved select IDs in order to `sequence_source_ranges_apply`. Use equal sequence bounds to insert or distinct bounds to replace. |
| Work with multicam | Call `project_create` with `kind: "multicam"` and media paths. Read `multicam_setup_read`, then call `multicam_setup_confirm` with the desired opening source ID in `opening`. In an existing project, use `multicam_state_read` with `section: "sources"`. Pass the source ID as `angle_id` or its displayed `camera_number` to `multicam_camera_take` with `group_time`. Read current assembly indices before calling `multicam_assembly_edit`. |
| Align sources or assess a switch | Use `multicam_sync_suggest` for candidate offsets and drift evidence. To check a proposed take, read the `switch_coverage` section of `multicam_state_read` with the angle and group time. Inspect both picture and routed audio through the next switch. |
| Change the picture on one replay | Read the assembly occurrences and call `multicam_assembly_edit` with `action: "angle_set"`, the occurrence index and the target angle. Use `angle_clear` to return that occurrence to the group switches. |
| Remove or queue pauses | Choose the track with `silence_editor_track_select` and set its threshold with `silence_editor_threshold_set` as needed. Start `silence_editor_scan`, poll `analysis_job_status_read`, then read `silence_editor_pauses_list`. Use a returned pause ID with `silence_editor_pause_review` to preview or protect it. Choose `silence_editor_takes_queue` to queue retained takes or `silence_editor_pauses_shorten` to edit the timeline. |
| Inspect pictures | Call `scenes_editor_scan` to scan all sources. For one source, add `scope: "selected"` and its stable ID in `target`. Poll the receipt and read `scenes_editor_boundaries_list` with the source or clip ID. Use `review_editor_frames_export` with `selection: "scenes"` and a new directory in `output`. Poll `export_editor_job_status_read` for JPEGs and the manifest. |
| Check for changed recordings | Call `project_editor_media_refresh` with the project revision and a fresh `operation_id`. Poll the analysis receipt for changes and read `analysis_editor_state_read` for sources that need review. For a saved project, use `project_file_media_refresh` and poll the file job. |
| Preflight and export | Call `export_editor_project_plan` with the handle, revision, operation ID, mode and absolute output path. Poll `export_editor_job_status_read` and inspect eligibility and the plan. To produce the requested movie, call `export_editor_project_render` with a fresh operation ID and check its completed outputs. |
| Inspect or revise a queued excerpt | Read `export_queue_list` and inspect the entry’s captured items. Use `export_queue_entry_rename` to change its name. To revise the contents, set new marks and call `export_queue_entry_revise` in replace or extend mode. When an entry reports that a media change requires replanning, use `mode: "replan"` to capture the current edit at its original bounds. Verify the returned capture before rendering. |
| Remux without re-encoding | Plan the live edit with `export_editor_project_plan`, `mode: "copy"` and the desired output extension. Inspect any offered alternative containers and preflight the chosen one. For a saved project, use `export_file_project_render` with `dry_run: true`. For a list of file clips, use `export_file_clips_join` with the same copy and dry-run settings. Read the result or refusal through `file_job_status_read`. |
| Choose monitoring and layout | Read `workspace_layout_read`, then fit the timeline with `workspace_layout_set` and `action: "fit"`. Use `playback_monitor_visibility_set` with `visible: true` to show the monitor. Read `preferences_read` before changing app-wide preview volume with `preferences_set`, `key: "playback_preview_volume_fraction"` and a numeric `value` from 0 to 1. |
| Inspect saved media and deliver files | `media_file_inspect` with a fresh UUID in `operation_id`, absolute `file` and `detail: "audio_packets"`. Follow the file job, then query `waveform_file_envelope_read` with the absolute stream index. Use `export_file_clips_join` or `export_file_ranges_separate` for specified saved inputs. |
| Send a timeline to another editor | Call `project_editor_convert` to write the requested project format. For Resolve, choose `project_editor_resolve_export` to write interchange or `project_editor_resolve_import` to also import it. Poll `export_editor_job_status_read` and report warnings, paths and any import result. [Interchange requirements](../README.md#convert-projects) |
| Undo or restore a specific edit | `history_read` → `history_state_restore` with a fresh operation ID, current revision, returned `history_token` and desired `index`. Index zero precedes the first retained action. For one step use `history_undo` or `history_redo`. Read back the cursor. |

To treat a click lasting up to 300 ms between quiet stretches as part of one pause, call `preferences_set` with `key: "silence_max_blip_seconds"`, `value: 0.30` and a fresh `operation_id`. Set `value: 0` to split at every interruption. A separate `preferences_set` with `key: "silence_padding_per_side_seconds"` controls how much quiet audio to keep on each side of a cut. Sequence and multicam editors share both settings. Read them back with `preferences_read`.

For example, these are the `tools/call` parameters for the 300 ms blip setting. Generate a new UUID when issuing your own operation.

```json
{
  "name": "preferences_set",
  "arguments": {
    "operation_id": "beac5b8a-5c99-4bc1-9152-d63d21b9fe31",
    "key": "silence_max_blip_seconds",
    "value": 0.30
  }
}
```

To set the threshold for one sequence source, pass its `source` ID and `silence_threshold_db` to `silence_editor_threshold_set`. Omitting the ID uses the source at the playhead. To measure room tone, mark a quiet interval on the sequence, group or assembly clock and call `silence_threshold_calibrate_from_marks`. Multicam protection follows a group pause across replays. To queue or shorten pauses in one replay, select the interval on the assembly clock first. Group marks include every replay of the marked interval.

Set a detected pause’s retained duration with `silence_editor_pause_review` and `action: "set_retained"`. Read back the requested and aligned duration. To correct missed take boundaries, use `silence_editor_take_boundary_edit` and inspect `silence_editor_take_candidates_list` before queueing. To audition an existing join, use `timeline_editor_join_preview` with the sequence clip or multicam assembly occurrence immediately after it, or with the group switch time.

### Follow work through completion

- A job-based live output tool returns `job_id`, `state` and `input_revision`. Poll `export_editor_job_status_read` with the project handle and `job_id` until `succeeded`, `failed` or `cancelled`. Report published `outputs` and the terminal `result` or `error`. To stop, use `export_editor_job_cancel` and observe the final state. Applying reviewed cuts and replacing live audio return their edit outcomes directly.
- For an export with a cut map, read `cut_map.occurrences` from the completed plan or render. Use its occurrence and clock fields to distinguish individual uses and the render segments that contain them.
- A file tool returns `job_id`, which equals its `operation_id`. Poll `file_job_status_read` until `succeeded`, `failed`, `cancelled`, `needs_review` or `outcome_unknown`. Use the original UUID after reconnecting to a standalone worker. Standalone receipts persist for seven days after completion or a recorded interruption. Read the CLI’s inline `result` or `output_text` when present. For a large result, call `file_job_result_read` from offset zero, decode each `base64` page, advance to `next_offset` until `done`, and concatenate the bytes before parsing. Once collected, `file_job_release` frees the payload and keeps the receipt. Request cancellation through the worker that started the job. An interrupted export may already have published files.
- Read `project_editor_media_list` for source paths, statuses and uses. Use `project_editor_media_locate` to search a folder and poll `analysis_job_status_read` for candidates. Apply selected mappings with `project_editor_media_relink` at the receipt's input revision. Pass the receipt ID as `locate_job_id` to check the reviewed file generations. Relink follows the same recording through retained undo and redo states. Use `project_editor_media_replace` for a different recording, read its ripple report, then repeat the request with its `preview_id`, `confirm: true` and a fresh operation ID to commit an undoable edit.
- Use the corresponding `project_file_media_*` tools for saved projects and poll `file_job_status_read`. Applying a file relink or confirming a replacement needs `out_project` or `in_place: true`.
- A native scan, sidecar save or media refresh returns `job_id`, `input_revision`, `kind` and `status`. Poll `analysis_job_status_read` with the project handle and job ID. On a shared scene worker, `analysis_job_cancel` releases your receipt while other subscribers keep scanning. The final subscriber waits for checkpoint results. Read `coverage` for confirmed and durable positions, and inspect saved sections with `analysis_file_sidecar_inspect`.
- Use `project_operations_list` for an existing GUI import, export, multicam operation or conversion. To cancel a specific native operation at the editor’s request, pass its `native_operation_id` and a fresh `operation_id` to `project_operation_cancel`. Supply the same project scope used for the lookup.

Use absolute paths for file operations. Read each tool’s schema for its sidecar options and output settings. [Tool reference](MCP-REFERENCE.md)

## Recovery

| Observation | Next action |
| --- | --- |
| Tools appear, but the app is unavailable | Check the app instance and its local-control setting. If the user disabled control, return control to them. |
| MPCut reports `settings_write_disabled` or `file_replace_disabled` | The user turned off an agent permission in **Settings → Automation**. Report what was refused; nothing changed. Save to a new path, or pass `out_project` instead of `in_place`, only if the user asks for that. |
| Project disappeared or a handle expired | List projects again. Re-establish the intended document before applying any edit. |
| A transcript edit plan is stale | Refresh the timeline and transcript revisions, resolve the intended occurrences and review a new plan with `transcript_editor_edit_plan` before applying it. |
| A person edited while the agent was planning | Read the new revision and locate the original occurrence and interval. Proceed if the requested edit is still unambiguous. |
| A files-only job reply was lost | Reconnect to the standalone helper and look up the original UUID with `file_job_status_read`. Receipts persist for seven days. If the state is `outcome_unknown`, inspect the saved project and destination before starting another operation. [Recovery details](HEADLESS.md) |
| A live editor edit reply was lost | Replay the identical operation ID and arguments within ten minutes of completion while the same document and enabled app session remain valid. A replay can describe a cut the editor has since undone. After expiry, a relaunch or a change to the local-control setting, inspect timeline and history before retrying. |
| A successful close reply was lost | Replay the same `project_close` request within the retry window. The result uses the closed document’s original handle, even if a new window now has its file open. |
| MPCut reports `response_too_large` | For reads, narrow the time window or page size where the tool supports it. Retrieve file results with `file_job_result_read`. For an edit, check current timeline state and history for its outcome before submitting further edits. |
| MPCut reports `stale_revision` or `stale_history` | Read the current timeline and retained history. Use new references and a fresh operation ID after resolving the intended edit again. |
| An operation ID already belongs to another request | For `operation_conflict` or `operation_id_conflict`, inspect the previous outcome. Supply a fresh UUID for each distinct request. |
| The app is indexing, busy or displaying a modal panel | Inspect job and window state. Wait for the relevant job or surface the specific interaction the editor needs to complete. |
| The app is waiting on a quit decision | For `app_quitting`, wait for the editor to finish the quit interaction. If the app is still open, list projects again before resuming edits. |
| An export failed after writing several files | Inspect its terminal result and completed outputs. Retry only the outstanding work using valid destinations. |
| MPCut reports `unknown_job` or `job_unavailable` | Check the original project scope and job ID. Completed receipts are retained for a limited period. If a receipt expired, inspect the requested destinations and current project before submitting more work. |
| Undo is unavailable | Inspect the history limit and retained states. A zero limit disables history retention. Report the setting and the actual edit outcome. |

## Verify a source build

On a macOS desktop, run the fixture workflow from the repository root while the user’s local-control listener is off. Replace the path with the absolute location of the built app. The tests start a separate MPCut instance, open disposable projects and connect with the official SDK. macOS Accessibility permission is required for the native menu and Settings checks.

```sh
go test -C mcp ./integration -v -count=1 -args -bundle="/absolute/path/to/MPCut.app"
```

The fixture provides executable examples for a two-window split, a repeated request, stale revision recovery, an unsaved interchange snapshot, inline JPEG review, and file jobs with both dry-run and published results. The native fixtures exercise cancellation and partial outputs. [Verification by workflow](MCP-COVERAGE.md)

The tool reference is generated from `Sources/MPCutApp/MCPResources/` and the result descriptions in `scripts/mcp-reference.py`. Run `python3 scripts/mcp-reference.py --check` to compare the reference with those sources.
