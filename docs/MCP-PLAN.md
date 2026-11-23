# Live project control over MCP

A local MCP client can inspect an unsaved project, navigate its preview, and perform the same timeline edits a person can make in its window. The existing CLI handles one-shot work on files. MPCut owns playback, frame selection, and the edit history. A client can request a cut at a precise media time without timing its request to playback.

## What the editor should experience

| Request | Visible result |
| --- | --- |
| “Which project has the interview open?” | The client lists open projects, including untitled sequences. It reads the chosen window’s timeline and selection even after focus moves elsewhere. |
| “Split the second use of this clip at 12 seconds on the sequence.” | The specified occurrence splits at the boundary allowed by native snapping. The response identifies both halves and the actual cut time. With history enabled, the editor sees **Split Clip** in that project’s History and can undo it in that window. |
| “Switch to camera B at this group time.” | The multicam timeline shows the switch. The response identifies the affected group interval, which may appear in several assembly occurrences. Splitting one repeated assembly occurrence is a separate, occurrence-specific edit. |
| “Let me take over.” | Turning off **Enable local MCP control** in Settings takes effect immediately across open windows. The editor can continue working, including undoing or redoing earlier MCP edits. |

## Settings and connection

Add **Enable local MCP control** under **Settings → General → Automation**, backed by the shared `EditorPreferences` and persisted in the app’s defaults. Start disabled on first launch. Explain beside the toggle that enabling it lets local programs running as this user inspect and edit open projects. Wire the preference to one app-owned listener across all windows. Enabling starts it immediately. Show the actual listener status beside the setting and surface startup errors there. Disabling first revokes permission to commit, then closes the listener and active connections and cancels pending MCP work. Re-enabling creates a fresh connection generation. The switch acts on remote work independently of native GUI jobs. [EditorSettings.swift](../Sources/MPCutApp/EditorSettings.swift) · [EditorPreferences.swift](../Sources/MPCutApp/EditorPreferences.swift)

The host launches the bundled `MPCut.app/Contents/Helpers/mpcut-mcp` over stdio. The helper builds with the official Go SDK v1.8.0 and a pinned toolchain. The module checksums live alongside its manifest. Support for the stable 2026-07-28 protocol starts at SDK v1.7.0. The published Swift SDK documents 2025-11-25. The Go dependency is confined to building the helper. Tool discovery works with the app closed. An unavailable endpoint returns guidance to open MPCut and enable the setting. [Helper module](../mcp/go.mod) · [Go SDK release](https://github.com/modelcontextprotocol/go-sdk/releases/tag/v1.7.0) · [Swift SDK](https://github.com/modelcontextprotocol/swift-sdk#overview) · [July stdio binding](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)

The helper forwards versioned, typed requests over a Unix-domain socket in a user-private directory. Validate the peer’s user, bound message size, and reject incompatible bridge versions. On startup, distinguish a stale socket from another live instance before binding. Keep errors and logs off MCP stdout. Document the host configuration using the installed executable’s absolute path as a single command field, including paths with spaces.

## Native commands and history

Route MCP and the corresponding menu, toolbar, and shortcut actions through the **same Swift editor command**. GUI adapters supply their current selection, playhead, and interaction context. MCP supplies an explicit document, occurrence, and time. The app invokes the command on that window’s ordinary or multicam model without synthesizing clicks, changing focus, or rewriting the project file. The native model owns snapping, validation, selection changes, dirty state, History, redo invalidation, draft recovery, and save behavior. The helper only translates requests and results. [EditorModel.swift](../Sources/MPCutApp/EditorModel.swift) · [MulticamEditorModel.swift](../Sources/MPCutApp/MulticamEditorModel.swift)

Use the native action name and history granularity. A committed split creates one undoable **Split Clip** entry subject to the user’s history limit. Failed edits, no-ops, playback, and seeks add zero entries. Expose the effective history limit in editor state. The current default is 50 retained steps, with a maximum of 500 across undo and redo. At zero, both GUI and MCP edits still work and the result identifies the edit as unretained. Lowering the limit trims both interfaces’ shared history. Save, reopen, and draft recovery follow the project’s existing history rules. Command-Z follows native focus routing, so an edit in window A is undone by focusing A’s timeline. The operation-retry cache described below is transient and independent of project history. [Project history format](CUT-FORMAT.md#edit-history)

## Initial tool contract

The first tools below establish the live editing path. The [operation coverage matrix](MCP-COVERAGE.md) defines the full implementation scope, including file operations, native editing, analysis, interchange and exports.

| Tool | Inputs and result |
| --- | --- |
| `project_windows_list` | Return handles, display names, editor kinds, and focus as a hint. An open app with no projects returns an empty list. |
| `project_editor_state_read` | Given a handle, return revision, dirty/busy state, available operations, playhead, selection and a bounded timeline page. Include clip IDs, angle IDs, or revision-scoped occurrence references as appropriate. Pin subsequent pages to the same revision. |
| `timeline_playhead_seek`, `playback_transport_play` / `playback_transport_pause` | Give the target handle, coordinate space and position for seek, or the desired playing/paused state for transport. Return the accepted state. Frame delivery and playback timing belong to the app. |
| `timeline_item_split` | Give the handle, expected revision, operation ID, occurrence, coordinate space and rational timestamp. Return the native action, applied revision, resulting references, and actual boundary in the requested space. |
| `multicam_camera_take` | Give the handle, expected revision, operation ID, angle ID and multicam group time. Return the switch, affected group interval, and applied revision. Preserve the native switch’s audio behavior. |

Use MPCut rational time strings such as `1001/30000`. Distinguish source, sequence, group, and assembly coordinates. The existing ordinary segment UUID identifies a particular use of a source. For multicam ranges, a revision plus assembly index identifies repeated occurrences without changing the project format. Resolve both the occurrence and time, rejecting incompatible pairs, out-of-range targets, and uneditable boundaries. Snapshot the effective native snap policy when preparing an edit, and report the actual boundary after native validation.

Report domain failures as MCP tool results with `isError: true`, with machine-readable codes and short recovery instructions. Distinguish a closed document, stale revision, busy editor, unavailable analysis, and invalid target. A no-op returns the current state. The caller can refresh after a conflict. Publish stable tool schemas even when a particular window cannot currently perform an operation. [MCP tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools#error-handling)

## Concurrency and retries

1. Resolve the opaque handle in the registry of *existing* windows. Include a fresh document generation when a project opens, is recovered or replaced, or changes editor kind. Preserve it across Save As for the same live document. Unknown handles fail without creating a session or falling back to focus. [ProjectSessions.swift](../Sources/MPCutApp/ProjectSessions.swift)
2. Compare the expected document revision on the main actor. Advance it at native document commits, including GUI edits, undo, redo, and history jumps. Playback ticks, selection, and focus changes do not advance it. Check modal states, busy flags and active GUI gestures before beginning an edit.
3. Reserve the operation ID in the app before starting work. A duplicate with identical arguments joins the pending operation or replays its recorded outcome before checking the current edit revision. Reusing the ID with different arguments fails. Check the access setting and document generation before revealing a cached result. Retain completed results for a documented bounded retry period. A replay identifies the original committed revision even if the user subsequently undid it.
4. A native ordinary split can validate candidate boundaries on a background task. Capture its inputs, perform expensive work off the main actor, then recheck permission generation, document, revision, cancellation, editability and snap context immediately before the native commit. Apply and record the result together on the main actor. Return success only after the edit commits. If cancellation wins before commit, discard the proposal. If a reply is lost after commit, the client can retry using the original ID or reread the timeline.

## Documentation deliverables

The bundle carries a [user and agent guide](MCP-AGENT-GUIDE.md), a [schema-derived tool reference](MCP-REFERENCE.md) with result semantics, and a [runnable walkthrough](mcp_walkthrough.py). The helper serves both guides as static resources when the app is closed. Use `python3 scripts/mcp-reference.py --check` to compare the published reference against the discovery catalog.

Author and ship the [agent usage guide and workflow recipes](MCP-AGENT-GUIDE.md) alongside the tools. Its authoring checklist covers human setup, host instructions, schema-derived reference, use cases, troubleshooting, versioned in-app help and executable examples. Each coverage row needs documentation and a verified example as part of delivery.

## Delivery and acceptance

| Milestone | Evidence required |
| --- | --- |
| Settings, packaging and read access | Toggle at runtime and across relaunch. Exercise closed app, zero windows, two windows, stale endpoint, disable/re-enable and an outdated helper. Build the helper early against the existing arm64, macOS 14.0 Mach-O, dependency and signing checks. Launch the packaged helper from a real host with no Go installation. Verify optional July discovery and direct `tools/list` and `tools/call` requests. Record the version actually used by the host and independently exercise the July wire format. [Bundle script](../scripts/build-app.sh) |
| One ordinary edit through both interfaces | Apply equivalent GUI and MCP splits to the same starting timeline and compare boundaries, selection, native History label, undo/redo, dirty state and saved/reopened history. Include history disabled, audio-only media, keyframe snap with background checks, and a boundary that cannot split. Interleave human and MCP edits, restore an intermediate state through **Edit → Project History**, and verify that a new edit clears the redo branch. Confirm only A changes when B is focused. |
| Concurrent editing and recovery | Race two clients against the same revision. Retry after a dropped reply and after GUI undo. Disable control, replace the document, or change snapping while validation is pending. Verify at most one native commit, the expected terminal outcome, and no late edits after revocation. Exercise untitled draft recovery. |
| Multicam editing | Repeat a group interval twice in the assembly. Split only its second occurrence, then place a group camera switch and verify every affected occurrence, the existing audio selection, and native undo/redo. |
| Full operation coverage | Deliver the remaining operations and typed options in the [coverage matrix](MCP-COVERAGE.md). Introduce job status, cancellation and result retrieval alongside long-running operations. Verify real MCP calls against GUI behavior and CLI results, including history, errors and output files. |
| Documentation and agent onboarding | Verify setup in each documented host using the packaged helper. Compare the tool reference with discovery, replay documented fixture workflows, and open the bundled guide offline. Publish actual results and supported versions. |

The first editing milestone passes when an editor can enable control, have a real client inspect and split an unsaved sequence, undo the cut in the GUI, disable control, and continue editing while the client is still open.
