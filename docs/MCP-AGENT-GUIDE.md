# Using MPCut from an MCP agent

An agent connected to MPCut can edit any open timeline, including an unsaved sequence or multicam assembly. Its edits use the same snapping and undo history as yours. File tools use the bundled CLI. Give one a project path and it reads the last saved version. [Tool reference](MCP-REFERENCE.md) · [CLI agent guide](USAGE.md#use-the-cli-from-an-agent)

## Connect an editing agent

1. Open a build of MPCut that includes `Contents/Helpers/mpcut-mcp`. In **Settings → General → Automation**, turn on **Enable local MCP control**. This lets local applications running under your macOS account inspect and edit open projects.
2. Configure the host to launch the bundled helper as a **stdio** server named `mpcut`. Supply the executable’s absolute path as one command value, including any spaces, and leave the arguments empty. Match the helper to the running app bundle. If you move or replace the app, update the host’s path and restart its connection.
3. Open a project and ask, “List my open MPCut projects and tell me which one is an unsaved sequence.” An empty `projects` array means the app responded and has no project windows.

For Codex, register the installed app with this command, then start a new session. Substitute the actual path if your app is elsewhere.

```sh
codex mcp add mpcut -- "/Applications/MPCut.app/Contents/Helpers/mpcut-mcp"
```

For hosts that accept an `mcpServers` JSON configuration, use the same path as a single string.

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

Codex CLI 0.171.0 negotiated `2025-06-18` with a signed MPCut 1.2.0 development bundle in a November 2026 host test. It discovered the tools and read both resources. The Python walkthrough and the official Go SDK integration exercise `2026-07-28`. The version used in a session depends on the host. [Verified workflows](MCP-COVERAGE.md)

Helper tests also exercise `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05` over stdio with the Go SDK.

Open **Help → MPCut Agent Guide** to read these instructions offline. Hosts with MCP resource support can read `mpcut://docs/agent-guide` and `mpcut://docs/tool-reference` through `resources/read`. The installed helper advertises argument schemas through `tools/list`.

### Try a read-only walkthrough

The Python walkthrough uses the July stdio protocol and Python 3’s standard library. Run it from the source checkout as shown below, or run the copy under the installed app’s `Contents/Resources/Documentation/docs/`. Use `--helper` when running a bundle outside Applications. [Python walkthrough](mcp_walkthrough.py)

```sh
python3 docs/mcp_walkthrough.py --discovery
python3 docs/mcp_walkthrough.py
python3 docs/mcp_walkthrough.py --project "HANDLE_FROM_THE_LIST"
python3 docs/mcp_walkthrough.py --file "/absolute/path/to/interview.mov"
```

Discovery reads both built-in guides. With local control enabled, the second command lists windows. Once the chosen project has loaded, the third reads its timeline, history, presentation, analysis, queue and, for multicam, sources. The last command inspects file metadata with sidecar use disabled and reads the completed job result. Increase `--timeout` when a walkthrough needs more than 60 seconds.

## Instructions for the agent

Paste this block into the host’s agent instructions to share MPCut’s editing conventions.

> Discover MPCut’s current tools and argument schemas. For an open or unsaved edit, list projects, resolve the user’s target, then read its live state. If multiple projects or occurrences still match, ask one focused question before editing. Use the returned handle, revision and occurrence references. A focus change does not change the intended target.
>
> State which timeline clock you are using. Supply exact rational times where available. Use the native editing tool and report the actual committed boundary, affected occurrence and history action. Save, export, change settings or send to another application when the user’s request calls for it.
>
> For a new mutation or a file job, generate one UUID for `operationID`. If the response is lost, retry the identical request with the same ID within the documented retry window. On a revision conflict, reread state and re-evaluate the requested edit. For background work, follow the job to its terminal result and report completed outputs and any failures.

## Read the clock before editing

| Clock | A typical instruction | Resolve before calling |
| --- | --- | --- |
| Source | “Use the cut at 12 seconds in the interview recording.” | Source ID and source timestamp. If applying it to a sequence, identify the retained occurrence that contains it. |
| Sequence | “Split 12 seconds into my current edit.” | Sequence output time and the clip occurrence spanning it in the current revision. |
| Multicam group | “Switch to the wide camera at the clap.” | Group time, angle ID, and the switch interval. Repeated uses of that interval share the camera switch. |
| Multicam assembly | “Trim the second replay.” | Assembly output time and occurrence reference from the same revision. |

For live requests, send time as a rational seconds string, such as `"1001/30000"` for one frame at 29.97 fps. Read the indexed timing when media has a variable frame rate. Ranges include their start and exclude their end. A clip name or source timestamp alone can match several occurrences.

To seek to a specific multicam replay from a group timestamp, send its assembly `occurrence` index and the corresponding `expectedRevision` with `space: "group"`. The preview opens on the assembly clock at that occurrence.

## Worked example: split an unsaved sequence

**Editor request:** “In Interview selects, split the second use of the interview clip at 12 seconds on the sequence. Leave it open for review.”

| Step | Agent action | Evidence |
| --- | --- | --- |
| 1 | Discover the tools, then call `list_projects`. Choose the sequence named Interview selects. | The project handle identifies its live window even if another window gains focus. |
| 2 | Call `get_editor_state` for that handle. Find the second occurrence and confirm that 12 seconds is strictly between its `sequenceFrom` and `sequenceTo`. Read the revision, snapping and history settings. | If 12 seconds is already an edge of the intended clip, report the existing boundary. If 12 seconds falls in a different occurrence, clarify which target the editor intended. |
| 3 | Call `split_at` with the handle, revision, a fresh operation ID, the occurrence, sequence coordinates and time `12`. | The committed result identifies the actual cut, both resulting occurrences and the applied revision. A background preflight may take time. |
| 4 | Read back the dirty flag, then report it and the actual boundary. When history is retained, name the action the editor can undo. | “Split the second interview clip at 12 s on the sequence. The edit is unsaved. Focus Interview selects and use Command-Z to undo Split Clip.” |

For an ordinary sequence, construct the arguments from the actual state response. This JavaScript fragment assumes the client has located the relevant `clip` in `state.clips`.

```javascript
const splitArgs = {
  project: state.project,
  expectedRevision: state.revision,
  operationID: crypto.randomUUID(),
  occurrence: clip.id,
  space: "sequence",
  time: "12"
};
// Pass { name: "split_at", arguments: splitArgs } to tools/call.
// Retain these arguments until the outcome is known.
```

Inspect the MCP result’s `isError` and `structuredContent`. An ordinary successful split reports `action`, `boundary`, `sequenceTime`, `sourceTime`, `left`, `right`, `historyRetained` and the applied `revision`. A split exactly at an existing edge returns `invalid_boundary` for an ordinary sequence. If you already see the boundary in state, report it directly. Supply the current revision with the next edit. [Tool reference](MCP-REFERENCE.md)

## Edit still images

Read `get_editor_state` and page `list_stills` at that revision. Source rows carry source bounds. Inserted still rows carry a placement ID, an asset ID and output bounds. Multicam assembly indices include both cards and group ranges. Refresh indices after each structural edit.

- Call `add_still` with `operation: "replace"`, an absolute image `path`, and `from` and `to` in sequence or multicam group time. A replacement keeps the underlying sound. Group replacements appear in each assembly occurrence of the covered group interval.
- For a title or other insert, call `add_still` with `operation: "insert"`, `at` and `duration` in sequence or assembly time. The duration shifts later picture and sound. Supply an exact `cadence` frame interval when the current timeline has no verified fixed cadence.
- Use `update_still` to adjust framing, change an insert's duration or position, or edit replacement coverage. Refer to fragments by the current index under their placement. `relink_still` updates all uses of an asset in one undo step. `remove_still` reveals the camera under a replacement or removes an insert and closes its gap.
- Call `review_frame` at a program time to see what plays. In multicam, supply an explicit angle to inspect a camera. For JPEG files use `export_review_frames` with a program `space` and `selection: "times"` or sample the active playhead.
- Preflight with `render_project` and `dryRun: true`. An omitted mode chooses Smart Trim for visible still picture. Set `requireCameraCopy: true` when the export must preserve all retained camera packets. Read the exact camera copy, camera encode and generated still durations, plus the per-track sound actions. To accept a verified whole-timeline boundary change, pass its `stillAdjustment` to `apply_export_review` with the same render settings.

## Editing and delivery recipes

| Editor request | Agent workflow | What to report |
| --- | --- | --- |
| “Recover yesterday’s untitled selects, apply this CSV and save a copy.” | Identify the draft, recover it, inspect the selected occurrence and CSV mode, apply ordered keep ranges or split points, review the timeline, then Save As to the requested destination. | Recovered project, resulting clips, retained history and saved path. |
| “Put the wide angle on the first question, then shorten only its second replay.” | Read group switches, program audio and assembly occurrences. Apply the camera switch in group time. Refresh the revision, identify the second replay, and trim that assembly occurrence. | Affected group interval, audio routing and the specific occurrence trimmed. |
| “Review the quiet gaps, keep the breath before the answer, and queue the takes.” | Select the microphone or routed program, scan with the requested threshold and padding, audition the relevant join, protect the pause, then queue retained takes. | Protected interval, queued ranges and analysis settings. If the user asks to shorten the timeline, verify the native history entry. |
| “Find every wide shot and give me review images.” | Scan scenes, identify the recurring view by its samples, and use `file_frames` with the matching exact source `times` from the report. For a live check, `review_frame` accepts an exact sequence, group or assembly time. | View, sample rule, exact source times and output paths. |
| “Check whether this selection will copy cleanly.” | Read the live selection and track layout. Run export preflight with the requested container, mode and streams. Inspect proposed boundary changes or encoding options. | Copy eligibility, reason, proposed boundaries and whether any media was written. |
| “Export these ranges as separate files with the processed soundtrack.” | Inspect source and replacement streams and timing. Establish which queue/export workflows support replacement. If they require separate steps, verify the replacement output before using it as the source for a file-based batch. Preflight destinations, then follow the jobs. | Source binding, stream IDs, completed files and any failed range. |
| “Send this unsaved multicam assembly to Resolve as an editable timeline.” | Read the live assembly, choose the requested interchange route and handle reported prerequisites or loss options. Send the captured revision and follow conversion through the requested external open/import step. | Revision, interchange file, warnings and external import outcome. |
| “Get packet timing and a waveform from this recording.” | Use file inspection on the supplied path, choose the stream, bound the time window and waveform columns, and inspect the sidecar inventory if reuse matters. | Stream, exact window, returned timing and analysis provenance where available. |
| “Restore the state just before the last trim.” | List retained history for the named window, resolve the trim and preceding state, restore using that history snapshot, then read back the current state. | Restored state, current position and redo availability. |

## Tool sequences for common requests

Use these sequences with the tool names and argument schemas advertised by the installed helper. Values such as project handles, occurrence IDs, group angle IDs and revisions come from prior results.

| Workflow | Calls and inputs |
| --- | --- |
| Start a sequence and review a clip | Call `new_project` with a fresh `operationID` and absolute media `paths`, then read `get_editor_state`. For an existing window, use `add_media` with its handle and revision. Use `seek` with `space: "sequence"` and rational `time`, then `set_playback` with `playing: true` or `false`. |
| Recover, apply CSV and save | `list_drafts` → `recover_project` with the returned `path` → `get_editor_state` → `sequence_control` with `action: "applyCSV"`, `occurrence` ID and absolute CSV `path` → `save_project` with the updated revision and a new absolute `.cut` path. |
| Work with multicam | `new_project` with `kind: "multicam"` and media paths → `get_multicam_setup` → `multicam_setup` with `action: "confirm"` and the desired opening source ID in `opening`. In an existing project, use `get_multicam` with `section: "sources"`. Pass the source ID as `angle` or the displayed `number` to `set_camera_at`, with a group `time`. Read `get_editor_state` for current assembly indices before calling `multicam_assembly`. |
| Remove or queue pauses | `configure_silence` → `scan_analysis` with `kind: "silence"` → poll the analysis receipt → `list_pauses`. Use a returned `pause` ID with `review_pause` to preview or protect it. `apply_pauses` uses `mode: "queue"` to enqueue or `"shorten"` to edit. Check `get_export_queue` or `get_history`. |
| Inspect pictures | `scan_analysis` with `kind: "scenes"` scans all sources by default. For one clip or camera, add `scope: "selected"` and its stable ID in `target`. Poll the receipt and read `list_scenes` with the `source` or sequence `clip` ID. Use `export_review_frames` with `selection: "scenes"` and a new directory in `output` for the active picture source. Poll `live_job_status` for JPEGs and the manifest. |
| Check for changed recordings | Call `refresh_project_media` with the project revision and a fresh `operationID`. Poll the analysis receipt for changes and read `analysis_state` for sources that need review. For a saved project, use `file_refresh` and poll the file job. |
| Preflight and export | `render_project` with the live handle, revision, operation ID, mode, absolute output path and `dryRun: true`. Read the terminal job’s `result.eligible` and plan or reason. For an authorized export, send a new operation ID with `dryRun: false`. Confirm the completed job’s `outputs`. |
| Remux without re-encoding | For a live project, use `render_project` with `mode: "copy"` and an output path ending in the desired extension. If preflight refuses, inspect `result.alternatives` for a `copyOtherContainer` rung. Retry with its mode, a fresh path ending in its container extension and a new operation ID. For saved projects or file edits, use `file_export` with `mode: "copy"` and `dry_run: true`. Read `result` from `file_job_status` for the CLI plan or `result.error.alternatives` for a refusal. |
| Choose monitoring and layout | `get_presentation` → `set_presentation` with an action such as `"fit"`, then `set_video_monitor` with `visible: true`. Read shared values with `get_preferences`. A `set_preference` change to `volume` applies across the app. |
| Inspect saved media and deliver files | `file_inspect` with a fresh UUID in `operationID`, absolute `file` and `detail: "audio_packets"`. Follow the file job, then query `file_waveform` with the absolute stream index. Use `file_export` or `file_bulk` for specified saved inputs. |
| Send a timeline to another editor | `convert_live_project` or `send_live_to_resolve` → `live_job_status`. Report warnings, outputs and whether external import was requested and succeeded. Native Resolve, Premiere and Final Cut workflows require the host apps and their documented integrations. [Interchange requirements](../README.md#convert-projects) |
| Undo or restore a specific edit | `get_history` → `restore_history` with a fresh operation ID, current revision, returned `historyToken` and desired `index`. Index zero precedes the first retained action. For one step use `undo` or `redo`. Read back the cursor. |

For a silence threshold on one sequence source, pass its `source` ID to `configure_silence`. Omitting it uses the source at the playhead. To calibrate from room tone, mark a quiet interval on the sequence, group or assembly clock, then call `use_room_tone`. Multicam protection follows the selected group pause across repeated uses. To queue or shorten pauses in just one replay, select that interval on the assembly clock before calling `list_pauses` or `apply_pauses`. Group marks include every replay of the marked interval.

### Follow work through completion

- A job-based live output tool returns `job`, `state` and `inputRevision`. Poll `live_job_status` with the project handle and `job` until `succeeded`, `failed` or `cancelled`. Report published `outputs` and the terminal `result` or `error`. To stop, use `cancel_live_job` and observe the final state. Applying reviewed cuts and replacing live audio return their edit outcomes directly.
- A file tool returns `job_id`. Poll `file_job_status` until `succeeded`, `failed` or `cancelled`. Read the CLI’s inline `result` or `output_text` when present. For a large result, call `file_job_result` from offset zero, decode each `base64` page, advance to `next_offset` until `done`, and concatenate the bytes before parsing. Receipts are retained for ten minutes after completion. `file_job_cancel` requests cancellation. An export may already have published files.
- A native scan, sidecar save or media refresh returns `job`, `inputRevision`, `kind` and `status`. Poll `analysis_job_status` with the project handle and job ID. On a shared scene worker, `analysis_job_cancel` releases your receipt while other subscribers keep scanning. The final subscriber waits for checkpoint results. Read `coverage` for confirmed and durable positions, and inspect saved sections with `file_sidecar` and `status: true`.
- Use `get_native_operations` for an existing GUI import, export, multicam operation or conversion. To cancel a specific native operation at the editor’s request, pass its `nativeOperation` and a fresh `operationID` to `cancel_native_operation`. Supply the same project scope used for the lookup.

For file operations use absolute paths and explicit sidecar and dry-run options as needed. Live output tools use camelCase options such as `dryRun`. File tools mirror CLI terms such as `dry_run`. Use each tool’s advertised field names. [Tool reference](MCP-REFERENCE.md)

## Recovery

| Observation | Next action |
| --- | --- |
| Tools appear, but the app is unavailable | Check the app instance and its local-control setting. If the user disabled control, return control to them. |
| Project disappeared or a handle expired | List projects again. Re-establish the intended document before applying any edit. |
| A person edited while the agent was planning | Read the new revision and locate the original occurrence and interval. Proceed if the requested edit is still unambiguous. |
| An edit reply was lost or MPCut reports `outcome_unknown` | Replay the identical operation ID and arguments within ten minutes of completion while the same document and enabled app session remain valid. A replay can describe a cut the editor has since undone. After expiry, a relaunch or a change to the local-control setting, inspect timeline and history before retrying. |
| A successful close reply was lost | Replay the same `close_project` request within the retry window. The result uses the closed document’s original handle, even if a new window now has its file open. |
| MPCut reports `response_too_large` | For reads, narrow the time window or page size where the tool supports it. Retrieve file results with `file_job_result`. For an edit, check current timeline state and history for its outcome before submitting further edits. |
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

## Maintain the documentation

Update `Sources/MPCutApp/MCPResources/` when a tool’s inputs change. Maintain the result and action descriptions in `scripts/mcp-reference.py`, run `python3 scripts/mcp-reference.py`, then verify the generated reference with `python3 scripts/mcp-reference.py --check`. For each implemented capability, publish the following materials alongside the feature.

1. **Human setup guide.** Document app and helper versions, supported hosts and protocol revisions, exact configuration for each tested host, install paths, Settings behavior, a first connection test and how to disconnect. Record the host and build used to verify each example.
2. **Agent instructions and tool reference.** Keep the instruction block concise. Derive the reference from registered schemas. For every tool document scope, parameters, units and coordinate space, defaults, dynamic choices, prerequisites, side effects, history/dirty/save behavior, cancellation, retries, outputs and recovery codes. Include each capability’s availability in the installed version.
3. **Executable examples.** Capture sanitized request/result pairs against fixtures. Include a successful edit, a no-op, a stale revision, a lost reply, a partial export, and two windows with changing focus. Use handles returned by earlier calls. Give each operation family in the matrix at least one runnable example, and each conditional variant a documented input and expected result.
4. **Publication and maintenance.** Link the guide from Usage and release notes, include it in the app’s existing offline documentation bundle, and expose version-matched help to connected agents. Compare reference entries against runtime discovery on release; run the recipes from a clean host configuration and check links in the packaged guide. Mark tested hosts and workflows with their actual results.
